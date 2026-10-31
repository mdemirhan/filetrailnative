// Ports the cases of apps/desktop/src/renderer/hooks/useFolderSizeCache.test.tsx about several folders measured in turn,
// the sizes that arrive while a walk runs or after it stops, the cache's cap, and folders a write made unknown
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The jobs of the original's `createOneAtATimeClient`: a job per folder, each running until the test ends it.
@MainActor
private final class OneAtATimeJobs: FolderSizeBackend {
    var known: [String: Int64] = [:]
    var probes: [[String]] = []
    var starts: [FolderSizeStartRequest] = []
    var cancels: [String] = []
    var states: [String: JobState] = [:]

    var started: [String] { starts.map(\.path) }
    var asked: [String] { probes.flatMap { $0 } }

    func probeMany(_ paths: [String]) -> [SizeProbe] {
        probes.append(paths)
        return paths.compactMap { path in
            known[path].map { SizeProbe(path: path, sizeBytes: $0, diskBytes: $0, fileCount: 1, folderCount: 0) }
        }
    }

    func start(_ request: FolderSizeStartRequest, owner: Int) -> JobStart {
        starts.append(request)
        return JobStart(jobId: Self.job(request.path), status: .running)
    }

    func state(jobId: String) -> JobState { states[jobId] ?? JobState(status: .running) }
    func cancel(jobId: String) { cancels.append(jobId) }

    static func job(_ path: String) -> String { "job:\(path)" }

    func finish(_ path: String, size: Int64 = 9) {
        states[Self.job(path)] = JobState(
            status: .ready, sizeBytes: size, diskBytes: size, fileCount: 1, folderCount: 0, measuredFolderCount: 1)
    }

    /// The walk of `path` has measured this many folders so far.
    func measured(_ count: Int, in path: String) {
        states[Self.job(path)] = JobState(status: .running, measuredFolderCount: count)
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

    // T-ecfd5430 T-4789e94f B-INFO-154 B-INFO-076: one after another in the order given, leaving those known and those
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

    // B-INFO-076: refresh on the selection measures all of them again, known or not.
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

    // T-18ca7451 B-INFO-155 B-INFO-076: Stop on the selection cancels the one being measured and starts no more.
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

    // B-INFO-155: so does stopping just the folder being measured.
    @Test func stoppingTheRunningFolderEndsTheRun() {
        sizes.calculate(["/a", "/b"])
        sizes.cancel("/a")
        timers.advance(1)
        #expect(jobs.started == ["/a"])
    }

    // B-INFO-155: a calculation started meanwhile stops the walk under way (the jobs cancel it) and ends the run.
    @Test func aWalkTheJobsCancelledEndsTheRun() {
        sizes.calculate(["/a", "/b"])
        jobs.states[OneAtATimeJobs.job("/a")] = JobState(status: .cancelled)
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(sizes.cachedEntry("/a") == .idle)
        #expect(jobs.started == ["/a"])
    }

    // B-INFO-155: and a new run takes over from the one before, which starts nothing more.
    @Test func aNewRunTakesOverFromTheOneBefore() {
        sizes.calculate(["/a", "/b"])
        sizes.calculate(["/x"])
        jobs.finish("/a")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(jobs.started == ["/a", "/x"])
    }

    // B-INFO-154: a folder that fails was not stopped: the run goes on (`entry.status === "idle"` only ends it).
    @Test func aFolderThatFailsLeavesTheRunGoing() {
        sizes.calculate(["/a", "/b"])
        jobs.states[OneAtATimeJobs.job("/a")] = JobState(status: .error, error: "No access")
        sizes.settled(jobId: OneAtATimeJobs.job("/a"))
        #expect(sizes.cachedEntry("/a") == .error(message: "No access"))
        #expect(jobs.started == ["/a", "/b"])
    }

    // MARK: Sizes arriving from a walk

    // T-019b4291 B-INFO-140: each poll that reports more measured folders asks about the unsized ones inside, at any
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

    // T-f2aa08d1 B-INFO-140: after Stop the folders measured so far get their sizes; a known one is left as it is.
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

    // B-INFO-140: a walk that fails asks the same.
    @Test func aFailedWalkAsksAboutThoseWithoutASize() async {
        await show("/out/a")
        sizes.calculate("/out")
        jobs.known = ["/out/a": 400]
        jobs.states[OneAtATimeJobs.job("/out")] = JobState(status: .error)
        await poll()
        #expect(sizes.readySize("/out/a") == 400)
    }

    // T-aed4e67f B-INFO-140: a folder whose own calculation was stopped gets the size its parent measured.
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

    // T-9dae3f9b T-1131eecd B-INFO-142: over 5,000 the oldest tenth goes at once, never a calculation under way; what
    // went reads as unknown and is asked about again.
    @Test func theOldestTenthGoesWhenFullButNotACalculation() async {
        sizes.calculate("/calculating")
        let paths = (0..<WindowFolderSizes.maxEntries).map { "/d/\($0)" }
        jobs.known = Dictionary(uniqueKeysWithValues: paths.map { ($0, 1) })
        for path in paths { _ = sizes.entry(path) }
        await settle()
        #expect(sizes.cachedEntry("/calculating") == .calculating(jobID: OneAtATimeJobs.job("/calculating")))
        #expect(sizes.cachedEntry("/d/0") == nil)
        #expect(sizes.cachedEntry("/d/500") == nil)
        #expect(sizes.readySize("/d/501") == 1)
        #expect(sizes.readySize("/d/\(WindowFolderSizes.maxEntries - 1)") == 1)

        jobs.probes = []
        #expect(sizes.entry("/d/0") == .idle)
        await settle()
        #expect(jobs.probes == [["/d/0"]])
        #expect(sizes.readySize("/d/0") == 1)
    }

    // B-INFO-142: the list of folders the jobs did not know is capped the same way: the oldest are asked about at once.
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

    // B-INFO-148: a folder holding the change that the jobs no longer know is forgotten.
    @Test func aWrittenFolderTheJobsNoLongerKnowIsForgotten() async {
        jobs.known = ["/a": 10]
        await show("/a")
        jobs.known = [:]
        sizes.forgetChangedSizes(["/a/b"], intoTrash: false)
        await settle()
        #expect(sizes.cachedEntry("/a") == nil)
    }

    // B-INFO-148: one they answer the same for changes nothing, and the window isn't repainted for it.
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
