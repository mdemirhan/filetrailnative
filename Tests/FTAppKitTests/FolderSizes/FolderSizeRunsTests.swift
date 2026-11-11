import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// Jobs that run one at a time: a job per folder, each running until the test ends it.
@MainActor
private final class OneAtATimeJobs: FolderSizeBackend {
    var known: [String: Int64] = [:]
    var probes: [[String]] = []
    var starts: [FolderSizeStartRequest] = []
    var cancels: [String] = []
    var states: [String: FolderSizeJob] = [:]

    var started: [String] { starts.map(\.path) }
    var asked: [String] { probes.flatMap { $0 } }

    func probeMany(_ paths: [String]) -> [FolderSizeProbe] {
        probes.append(paths)
        return paths.compactMap { path in
            known[path].map { FolderSizeProbe(path: path, sizeBytes: $0, diskBytes: $0, fileCount: 1, folderCount: 0) }
        }
    }

    func start(_ request: FolderSizeStartRequest, owner: Int) -> FolderSizeStartResponse {
        starts.append(request)
        return FolderSizeStartResponse(jobId: Self.job(request.path), status: .running)
    }

    func getStatus(jobId: String) -> FolderSizeJob {
        states[jobId] ?? FolderSizeJob(jobId: jobId, path: "", status: .running)
    }
    func cancel(jobId: String) { cancels.append(jobId) }

    static func job(_ path: String) -> String { "job:\(path)" }

    func finish(_ path: String, size: Int64 = 9) {
        states[Self.job(path)] = FolderSizeJob(
            jobId: Self.job(path), path: path, status: .ready, sizeBytes: size, diskBytes: size, fileCount: 1,
            folderCount: 0, measuredFolderCount: 1)
    }

    /// The walk of `path` has measured this many folders so far.
    func measured(_ count: Int, in path: String) {
        states[Self.job(path)] = FolderSizeJob(
            jobId: Self.job(path), path: path, status: .running, measuredFolderCount: count)
    }
}

@MainActor
struct FolderSizeRunsTests {
    private let jobs = OneAtATimeJobs()
    private let timers = ManualTimers()
    private let sizes: WindowFolderSizes

    init() {
        sizes = WindowFolderSizes(backend: jobs, owner: 1, homePath: "/Users/demo", scheduler: timers) {
            [timers] in timers.time
        }
    }

    /// What a redraw does: the folders are asked about, the answers stored.
    private func show(_ paths: String...) async {
        for path in paths { _ = sizes.entry(path) }
        await settle()
    }

    private func poll() async {
        timers.advance(WindowFolderSizes.pollInterval)
        await settle()
    }

    // MARK: Several folders in turn

    // One after another in the order given, leaving those known and those
    // being measured; the next starts as soon as the jobs say the last has ended, with no poll in between.
    @Test func severalFoldersAreMeasuredInTurnLeavingThoseKnown() async {
        jobs.known = ["/b": 5]
        await show("/b")
        sizes.calculate("/running")
        sizes.calculate(["/a", "/b", "/running", "/c"])
        #expect(jobs.started == ["/running", "/a"])
        // However long it runs, one at a time.
        timers.advance(1)
        #expect(jobs.started == ["/running", "/a"])
        jobs.finish("/a")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(jobs.started == ["/running", "/a", "/c"])
        #expect(sizes.readySize("/a") == 9)
        #expect(sizes.readySize("/b") == 5)
        #expect(jobs.starts.allSatisfy { !$0.recalculate })
    }

    // Refresh on the selection measures all of them again, known or not.
    @Test func recalculatingLeavesNoneOut() async {
        jobs.known = ["/a": 5]
        await show("/a")
        sizes.calculate(["/a", "/b"], recalculate: true)
        #expect(jobs.started == ["/a"])
        jobs.finish("/a")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(jobs.started == ["/a", "/b"])
        #expect(jobs.starts.map(\.recalculate) == [true, true])
    }

    // Stop on the selection cancels the one being measured and starts no more.
    @Test func stoppingTheRunCancelsTheRunningFolderAndStartsNoMore() {
        sizes.calculate(["/a", "/b", "/c"])
        sizes.cancel(["/a", "/b", "/c"])
        #expect(jobs.cancels == [OneAtATimeJobs.job("/a")])
        #expect(sizes.cachedEntry("/a") == .idle)
        #expect(sizes.entry("/c") == .idle)
        jobs.finish("/a")
        timers.advance(1)
        #expect(jobs.started == ["/a"])
        #expect(sizes.cachedEntry("/a") == .idle)
    }

    // So does stopping just the folder being measured.
    @Test func stoppingTheRunningFolderEndsTheRun() {
        sizes.calculate(["/a", "/b"])
        sizes.cancel("/a")
        timers.advance(1)
        #expect(jobs.started == ["/a"])
    }

    // A calculation started meanwhile stops the walk under way (the jobs cancel it) and ends the run.
    @Test func aWalkTheJobsCancelledEndsTheRun() {
        sizes.calculate(["/a", "/b"])
        jobs.states[OneAtATimeJobs.job("/a")] = FolderSizeJob(
            jobId: OneAtATimeJobs.job("/a"), path: "/a", status: .cancelled)
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(sizes.cachedEntry("/a") == .idle)
        #expect(jobs.started == ["/a"])
    }

    // And a new run takes over from the one before, which starts nothing more.
    @Test func aNewRunTakesOverFromTheOneBefore() {
        sizes.calculate(["/a", "/b"])
        sizes.calculate(["/x"])
        jobs.finish("/a")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(jobs.started == ["/a", "/x"])
    }

    // A folder that fails was not stopped: the run goes on (`entry.status === "idle"` only ends it).
    @Test func aFolderThatFailsLeavesTheRunGoing() {
        sizes.calculate(["/a", "/b"])
        jobs.states[OneAtATimeJobs.job("/a")] = FolderSizeJob(
            jobId: OneAtATimeJobs.job("/a"), path: "/a", status: .error, error: "No access")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(sizes.cachedEntry("/a") == .error(message: "No access"))
        #expect(jobs.started == ["/a", "/b"])
    }

    // MARK: Sizes arriving from a walk

    // Each poll that reports more measured folders asks about the unsized ones inside, at any
    // depth; the same count asks nothing, and a folder with its size isn't asked again.
    @Test func foldersInsideAreShownAsTheyAreMeasured() async {
        await show("/out/a", "/out/a/deep", "/out/b", "/outer")
        sizes.calculate("/out")

        jobs.known = ["/out/a": 400, "/out/a/deep": 100, "/outer": 1]
        jobs.measured(2, in: "/out")
        let versionBefore = sizes.version
        await poll()
        timers.advance(WindowFolderSizes.repaintInterval)
        #expect(sizes.version > versionBefore)
        #expect(sizes.cachedEntry("/out") == .calculating(jobID: OneAtATimeJobs.job("/out")))
        #expect(sizes.readySize("/out/a") == 400)
        #expect(sizes.readySize("/out/a/deep") == 100)
        #expect(sizes.cachedEntry("/out/b") == nil)
        // Only inside the walked folder.
        #expect(sizes.cachedEntry("/outer") == nil)

        // Nothing new measured: the folder still waiting isn't asked about again.
        let asked = jobs.probes.count
        await poll()
        #expect(jobs.probes.count == asked)

        jobs.known["/out/b"] = 700
        jobs.known["/out/a"] = 401
        jobs.measured(3, in: "/out")
        await poll()
        #expect(sizes.readySize("/out/b") == 700)
        // Sized already: not asked while the walk runs.
        #expect(sizes.readySize("/out/a") == 400)
        // The finished parent asks about all of them, known or not.
        jobs.finish("/out")
        await poll()
        #expect(sizes.readySize("/out/a") == 401)
    }

    // After Stop the folders measured so far get their sizes; a known one is left as it is.
    @Test func stoppingAWalkKeepsTheSizesMeasuredInside() async {
        jobs.known = ["/out/known": 1]
        await show("/out/a", "/out/known")
        sizes.calculate("/out")
        jobs.known = ["/out/a": 400, "/out/known": 2]
        sizes.cancel("/out")
        await settle()
        #expect(sizes.cachedEntry("/out") == .idle)
        #expect(sizes.readySize("/out/a") == 400)
        #expect(sizes.readySize("/out/known") == 1)
    }

    // A walk that fails asks the same.
    @Test func aFailedWalkAsksAboutThoseWithoutASize() async {
        await show("/out/a")
        sizes.calculate("/out")
        jobs.known = ["/out/a": 400]
        jobs.states[OneAtATimeJobs.job("/out")] = FolderSizeJob(
            jobId: OneAtATimeJobs.job("/out"), path: "/out", status: .error)
        await poll()
        #expect(sizes.readySize("/out/a") == 400)
    }

    // A folder whose own calculation was stopped gets the size its parent measured.
    @Test func aStoppedFolderGetsTheSizeItsParentMeasured() async {
        sizes.calculate("/out/a")
        sizes.cancel("/out/a")
        await settle()
        #expect(sizes.cachedEntry("/out/a") == .idle)
        sizes.calculate("/out")
        jobs.known = ["/out/a": 400]
        jobs.measured(1, in: "/out")
        await poll()
        #expect(sizes.readySize("/out/a") == 400)
    }

    // MARK: The cap

    // Over 5,000 the oldest tenth goes at once, never a calculation under way nor what was stored or read since the
    // last repaint; what went reads as unknown and is asked about again.
    @Test func theOldestTenthGoesWhenFullButNotACalculation() async {
        sizes.calculate("/calculating")
        let paths = (0..<WindowFolderSizes.maxEntries).map { "/d/\($0)" }
        jobs.known = Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) })
        jobs.known["/more"] = 1
        for path in paths { _ = sizes.entry(path) }
        await settle()
        // Stored since the last repaint: all kept, over the limit.
        #expect(sizes.cachedEntry("/d/0") != nil)
        timers.advance(WindowFolderSizes.repaintInterval)
        // Read since the last repaint.
        #expect(sizes.readySize("/d/0") == 1)
        _ = sizes.entry("/more")
        await settle()
        #expect(sizes.cachedEntry("/calculating") == .calculating(jobID: OneAtATimeJobs.job("/calculating")))
        #expect(sizes.readySize("/d/0") == 1)
        #expect(sizes.cachedEntry("/d/1") == nil)
        #expect(sizes.cachedEntry("/d/502") == nil)
        #expect(sizes.readySize("/d/503") == 1)
        #expect(sizes.readySize("/d/\(WindowFolderSizes.maxEntries - 1)") == 1)
        #expect(sizes.readySize("/more") == 1)

        jobs.probes = []
        #expect(sizes.entry("/d/1") == .idle)
        await settle()
        #expect(jobs.probes == [["/d/1"]])
        #expect(sizes.readySize("/d/1") == 1)
    }

    // The list of folders the jobs did not know is capped the same way: the oldest are asked about at once.
    @Test func theFoldersNotKnownAreCappedTheSameWay() async {
        for index in 0...WindowFolderSizes.maxEntries { _ = sizes.entry("/m/\(index)") }
        await settle()
        jobs.probes = []
        _ = sizes.entry("/m/\(WindowFolderSizes.maxEntries)")
        await settle()
        #expect(jobs.asked.isEmpty)
        _ = sizes.entry("/m/0")
        await settle()
        #expect(jobs.asked == ["/m/0"])
    }

    // MARK: After a write

    // A folder holding the change that the jobs no longer know is forgotten.
    @Test func aWrittenFolderTheJobsNoLongerKnowIsForgotten() async {
        jobs.known = ["/a": 10]
        await show("/a")
        jobs.known = [:]
        sizes.forgetChangedSizes(["/a/b"], intoTrash: false)
        await settle()
        #expect(sizes.cachedEntry("/a") == nil)
    }

    // One they answer the same for changes nothing, and the window isn't repainted for it.
    @Test func anUnchangedAnswerRepaintsNothing() async {
        jobs.known = ["/a": 10]
        await show("/a")
        timers.advance(1)
        let version = sizes.version
        sizes.forgetChangedSizes(["/a/b"], intoTrash: false)
        await settle()
        timers.advance(1)
        #expect(jobs.probes.count == 2)
        #expect(sizes.version == version)
        jobs.known = ["/a": 11]
        sizes.forgetChangedSizes(["/a/b"], intoTrash: false)
        await settle()
        timers.advance(1)
        #expect(sizes.readySize("/a") == 11)
        #expect(sizes.version > version)
    }
}
