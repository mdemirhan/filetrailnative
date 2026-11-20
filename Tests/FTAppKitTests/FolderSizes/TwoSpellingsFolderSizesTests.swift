import FTFileSystem
import FTFoundation
import Foundation
import Testing

// Two folders whose names differ only in how an accent is spelled, which a disk can keep side by side: each has its
// own size, its own measurement and its own place in a run
@testable import FTAppKit

private let composed = "/x/caf\u{E9}"
private let decomposed = "/x/cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

/// Jobs that tell the two folders apart as a disk does: a job per folder, each running until the test ends it.
@MainActor
private final class ExactJobs: FolderSizeBackend {
    var known: [DiskPath: Int64] = [:]
    var probes: [[String]] = []
    var starts: [FolderSizeStartRequest] = []
    var cancels: [String] = []
    var states: [String: FolderSizeJob] = [:]

    func probeMany(_ paths: [String]) -> [FolderSizeProbe] {
        probes.append(paths)
        return paths.compactMap { path in
            known[DiskPath(path)].map {
                FolderSizeProbe(path: path, sizeBytes: $0, diskBytes: $0, fileCount: 1, folderCount: 0)
            }
        }
    }

    func start(_ request: FolderSizeStartRequest, owner: Int) -> FolderSizeStartResponse {
        starts.append(request)
        return FolderSizeStartResponse(jobId: Self.job(request.path), status: .running)
    }

    func getStatus(jobId: String) -> FolderSizeJob {
        states[jobId] ?? FolderSizeJob(jobId: jobId, path: "", status: .running)
    }

    func cancel(jobId: String, owner: Int) { cancels.append(jobId) }

    /// A job's id says which spelling it measures, in ASCII.
    static func job(_ path: String) -> String {
        "job:" + path.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
    }

    func finish(_ path: String, size: Int64) {
        states[Self.job(path)] = FolderSizeJob(
            jobId: Self.job(path), path: path, status: .ready, sizeBytes: size, diskBytes: size, fileCount: 1,
            folderCount: 0, measuredFolderCount: 1)
    }
}

@MainActor
struct TwoSpellingsFolderSizesTests {
    private let jobs = ExactJobs()
    private let timers = ManualTimers()
    private let sizes: WindowFolderSizes

    init() {
        sizes = WindowFolderSizes(backend: jobs, owner: 1, homePath: "/Users/demo", scheduler: timers) {
            [timers] in timers.time
        }
    }

    private func ready(_ size: Int64) -> FolderSizeEntry {
        .ready(sizeBytes: size, diskBytes: size, fileCount: 1, folderCount: 0)
    }

    // Both folders are asked about, and each is answered with its own size.
    @Test func eachFolderIsAskedAboutAndShowsItsOwnSize() async {
        jobs.known = [DiskPath(composed): 10, DiskPath(decomposed): 20]
        #expect(sizes.entry(composed) == .idle)
        #expect(sizes.entry(decomposed) == .idle)
        await settle()
        #expect(jobs.probes.map(bytes) == [bytes([composed, decomposed])])
        #expect(sizes.entry(composed) == ready(10))
        #expect(sizes.entry(decomposed) == ready(20))
        #expect(sizes.readySize(composed) == 10 && sizes.readySize(decomposed) == 20)
    }

    // A folder the jobs don't know isn't asked about again for a while; the other one still is.
    @Test func oneFolderNotKnownDoesNotKeepTheOtherFromBeingAskedAbout() async {
        _ = sizes.entry(composed)
        await settle()
        #expect(jobs.probes.map(bytes) == [bytes([composed])])
        jobs.known = [DiskPath(decomposed): 20]
        _ = sizes.entry(composed)
        _ = sizes.entry(decomposed)
        await settle()
        #expect(jobs.probes.map(bytes) == [bytes([composed]), bytes([decomposed])])
        #expect(sizes.entry(composed) == .idle)
        #expect(sizes.entry(decomposed) == ready(20))
    }

    // One folder being measured doesn't show the other as being measured, and the other's measurement is its own.
    @Test func oneFolderBeingMeasuredDoesNotStandForTheOther() async {
        sizes.calculate(composed)
        #expect(sizes.entry(composed) == .calculating(jobID: ExactJobs.job(composed)))
        #expect(sizes.entry(decomposed) == .idle)
        #expect(sizes.cachedEntry(decomposed) == nil)
        #expect(!sizes.isAskedFor(decomposed) && sizes.isAskedFor(composed))

        sizes.calculate(decomposed)
        #expect(bytes(jobs.starts.map(\.path)) == bytes([composed, decomposed]))
        #expect(sizes.entry(composed) == .calculating(jobID: ExactJobs.job(composed)))
        #expect(sizes.entry(decomposed) == .calculating(jobID: ExactJobs.job(decomposed)))

        // The first ends: it has its size, and the other is still being measured.
        jobs.finish(composed, size: 7)
        sizes.settled(jobId: ExactJobs.job(composed))
        #expect(sizes.entry(composed) == ready(7))
        #expect(sizes.entry(decomposed) == .calculating(jobID: ExactJobs.job(decomposed)))
        jobs.finish(decomposed, size: 8)
        timers.advance(WindowFolderSizes.pollInterval)
        #expect(sizes.entry(composed) == ready(7))
        #expect(sizes.entry(decomposed) == ready(8))

        // Stopping one leaves the other's size.
        sizes.calculate(composed, recalculate: true)
        sizes.cancel(composed)
        #expect(jobs.cancels == [ExactJobs.job(composed)])
        #expect(sizes.entry(decomposed) == ready(8))
    }

    // A run of both measures both, one after the other.
    @Test func aRunOfBothMeasuresBoth() {
        sizes.calculate([composed, decomposed])
        #expect(sizes.activeRuns.map(\.total) == [2])
        #expect(bytes(jobs.starts.map(\.path)) == bytes([composed]))
        #expect(sizes.entry(decomposed) == .calculating(jobID: "", waiting: true))
        jobs.finish(composed, size: 3)
        sizes.settled(jobId: ExactJobs.job(composed))
        #expect(bytes(jobs.starts.map(\.path)) == bytes([composed, decomposed]))
        jobs.finish(decomposed, size: 4)
        sizes.settled(jobId: ExactJobs.job(decomposed))
        #expect(sizes.entry(composed) == ready(3) && sizes.entry(decomposed) == ready(4))
        #expect(sizes.activeRuns.isEmpty)
    }

    // A walk of one folder has what is inside that folder asked about again, and not what is inside the other.
    @Test func whatIsInsideOneFolderIsNotInsideTheOther() async {
        _ = sizes.entry(composed + "/in")
        _ = sizes.entry(decomposed + "/in")
        await settle()
        #expect(jobs.probes.count == 1)
        jobs.known = [DiskPath(composed + "/in"): 1, DiskPath(decomposed + "/in"): 2]
        sizes.calculate(composed)
        jobs.finish(composed, size: 5)
        sizes.settled(jobId: ExactJobs.job(composed))
        await settle()
        #expect(jobs.probes.dropFirst().map(bytes) == [bytes([composed + "/in"])])
        #expect(sizes.cachedEntry(composed + "/in") == ready(1))
        #expect(sizes.cachedEntry(decomposed + "/in") == nil)
    }

    // A write in one folder has that folder's size asked about again, and leaves the other's as it is.
    @Test func aWriteInOneFolderLeavesTheOthersSize() async {
        jobs.known = [DiskPath(composed): 10, DiskPath(decomposed): 20]
        _ = sizes.entry(composed)
        _ = sizes.entry(decomposed)
        await settle()
        jobs.known = [DiskPath(decomposed): 20]
        sizes.forgetChangedSizes([composed + "/new.txt"], intoTrash: false)
        await settle()
        #expect(jobs.probes.map(bytes) == [bytes([composed, decomposed]), bytes([composed])])
        #expect(sizes.cachedEntry(composed) == nil)
        #expect(sizes.cachedEntry(decomposed) == ready(20))
    }

    // The folder the Info panel points at is measured by itself: pointing at the other one stops the first and
    // measures that one.
    @Test func theFolderPointedAtIsToldFromTheOther() {
        let auto = AutoFolderSizeController(sizes: sizes, scheduler: timers)
        auto.setPath(composed)
        timers.advance(AutoFolderSize.delayMilliseconds / 1000 + 0.001)
        #expect(bytes(jobs.starts.map(\.path)) == bytes([composed]))
        auto.setPath(decomposed)
        #expect(jobs.cancels == [ExactJobs.job(composed)])
        timers.advance(AutoFolderSize.delayMilliseconds / 1000 + 0.001)
        #expect(bytes(jobs.starts.map(\.path)) == bytes([composed, decomposed]))
        auto.stop()
    }
}
