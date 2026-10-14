// Ports the cases of apps/desktop/src/renderer/hooks/useFolderSizeCache.test.tsx (by feature row F-828 F-831, B-INFO-131 to
// B-INFO-146) over a stand-in for the folder size jobs and timers moved by hand
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
final class ManualTimers: TimerScheduling {
    private struct Job {
        let id: Int
        let at: TimeInterval
        let action: @MainActor () -> Void
    }

    private(set) var time: TimeInterval = 0
    private var jobs: [Job] = []
    private var next = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> TimerToken {
        next += 1
        let id = next
        jobs.append(Job(id: id, at: time + delay, action: action))
        return TimerToken { [weak self] in
            MainActor.assumeIsolated { self?.jobs.removeAll { $0.id == id } }
        }
    }

    func advance(_ seconds: TimeInterval) {
        let limit = time + seconds
        while let job = jobs.filter({ $0.at <= limit }).min(by: { $0.at < $1.at }) {
            jobs.removeAll { $0.id == job.id }
            time = job.at
            job.action()
        }
        time = limit
    }
}

@MainActor
final class FakeJobs: FolderSizeBackend {
    var known: [String: Int64] = [:]
    var probes: [[String]] = []
    var starts: [FolderSizeStartRequest] = []
    var cancels: [String] = []
    var statuses: [String: JobState] = [:]
    var nextStart = JobStart(jobId: "job-1", status: .running)

    func probeMany(_ paths: [String]) -> [SizeProbe] {
        probes.append(paths)
        return paths.compactMap { path in
            known[path].map { SizeProbe(path: path, sizeBytes: $0, diskBytes: $0, fileCount: 1, folderCount: 0) }
        }
    }

    func start(_ request: FolderSizeStartRequest, owner: Int) -> JobStart {
        starts.append(request)
        return nextStart
    }

    func state(jobId: String) -> JobState {
        statuses[jobId] ?? JobState(status: .running)
    }

    func cancel(jobId: String) { cancels.append(jobId) }

    func finish(_ jobId: String, _ path: String, size: Int64) {
        statuses[jobId] = JobState(
            status: .ready, sizeBytes: size, diskBytes: size, fileCount: 2, folderCount: 1, measuredFolderCount: 1)
    }
}

@MainActor
struct WindowFolderSizesTests {
    let jobs = FakeJobs()
    let timers = ManualTimers()
    let sizes: WindowFolderSizes

    init() {
        sizes = WindowFolderSizes(backend: jobs, owner: 1, homePath: "/Users/demo", scheduler: timers) {
            [timers] in timers.time
        }
    }

    // T-000906ee T-8e6d096f B-INFO-131: a size not in the cache reads as idle, and the questions of a redraw go out
    // as one request.
    @Test func foldersAskedAboutGoOutInOneRequest() async {
        #expect(sizes.entry("/a") == .idle)
        #expect(sizes.entry("/b") == .idle)
        #expect(jobs.probes.isEmpty)
        await settle()
        #expect(jobs.probes == [["/a", "/b"]])
    }

    // T-aa614e35 B-INFO-132: a folder the jobs did not know is not asked about again for 5 s.
    @Test func anUnknownFolderIsAskedAboutAgainOnlyAfterTheCooldown() async {
        _ = sizes.entry("/a")
        await settle()
        _ = sizes.entry("/a")
        await settle()
        #expect(jobs.probes.count == 1)
        timers.advance(5.1)
        _ = sizes.entry("/a")
        await settle()
        #expect(jobs.probes.count == 2)
    }

    // T-fea150dc B-INFO-133: answers store sizes and repaint once.
    @Test func answersAreStoredWithOneRepaint() async {
        jobs.known = ["/a": 10, "/b": 20]
        var repaints = 0
        sizes.onChange = { repaints += 1 }
        _ = sizes.entry("/a")
        _ = sizes.entry("/b")
        await settle()
        #expect(sizes.readySize("/a") == 10 && sizes.readySize("/b") == 20)
        #expect(repaints == 1)
    }

    // T-4c6145e3 T-222fa570 B-INFO-134 B-INFO-135 B-INFO-136: Calculate goes calculating at once; a size the jobs
    // hold goes straight to ready; the flags go through.
    @Test func aKnownSizeGoesStraightToReady() {
        jobs.nextStart = JobStart(jobId: "job-9", status: .ready)
        jobs.finish("job-9", "/a", size: 42)
        sizes.calculate("/a", recalculate: true, automatic: true)
        #expect(sizes.cachedEntry("/a") == .ready(sizeBytes: 42, diskBytes: 42, fileCount: 2, folderCount: 1))
        #expect(jobs.starts.first?.recalculate == true && jobs.starts.first?.automatic == true)
    }

    // B-INFO-134: otherwise it is polled every 200 ms until ready.
    @Test func aRunningCalculationIsPolledUntilReady() {
        sizes.calculate("/a")
        #expect(sizes.cachedEntry("/a") == .calculating(jobID: "job-1"))
        timers.advance(0.2)
        #expect(sizes.cachedEntry("/a") == .calculating(jobID: "job-1"))
        jobs.finish("job-1", "/a", size: 7)
        timers.advance(0.2)
        #expect(sizes.readySize("/a") == 7)
    }

    // B-INFO-145: a message that the measurement ended is looked at at once, and one that came early when the
    // wait begins.
    @Test func aSettledMeasurementIsLookedAtAtOnce() {
        sizes.calculate("/a")
        jobs.finish("job-1", "/a", size: 3)
        sizes.settled(jobId: "job-1")
        #expect(sizes.readySize("/a") == 3)
        sizes.settled(jobId: "job-2")
        jobs.nextStart = JobStart(jobId: "job-2", status: .running)
        jobs.finish("job-2", "/b", size: 4)
        sizes.calculate("/b")
        #expect(sizes.readySize("/b") == 4)
    }

    // T-6b8ebfe3 B-INFO-137: Stop cancels the job and returns the entry to idle.
    @Test func stopCancelsAndReturnsToIdle() {
        sizes.calculate("/a")
        sizes.cancel("/a")
        #expect(jobs.cancels == ["job-1"])
        #expect(sizes.cachedEntry("/a") == .idle)
    }

    // B-INFO-138: a job error shows its message.
    @Test func aJobErrorShowsItsMessage() {
        sizes.calculate("/a")
        jobs.statuses["job-1"] = JobState(status: .error)
        timers.advance(0.2)
        #expect(sizes.cachedEntry("/a") == .error(message: "Unknown error"))
    }

    // B-INFO-140: a finished walk asks again about the folders inside it.
    @Test func aFinishedWalkAsksAboutTheFoldersInside() async {
        _ = sizes.entry("/a/inner")
        await settle()
        jobs.known["/a/inner"] = 5
        sizes.calculate("/a")
        jobs.finish("job-1", "/a", size: 9)
        timers.advance(0.2)
        await settle()
        #expect(sizes.readySize("/a/inner") == 5)
    }

    // T-dd1cef4e B-INFO-141: repaints come at most every 100 ms; the first at once.
    @Test func repaintsAreMergedWithinAHundredMilliseconds() {
        var repaints = 0
        sizes.onChange = { repaints += 1 }
        sizes.calculate("/a")
        #expect(repaints == 1)
        sizes.calculate("/b")
        sizes.calculate("/c")
        #expect(repaints == 1)
        timers.advance(0.11)
        #expect(repaints == 2)
    }

    // T-9dae3f9b B-INFO-142: the cache keeps at most 5,000 entries, never a calculation under way.
    @Test func theCacheIsCapped() {
        sizes.calculate("/keep")
        for index in 0..<(WindowFolderSizes.maxEntries + 10) { sizes.calculate("/f\(index)") }
        #expect(sizes.cachedEntry("/keep") != nil)
        #expect(sizes.cachedEntry("/f0") == nil || sizes.cachedEntry("/f\(WindowFolderSizes.maxEntries + 9)") != nil)
    }

    // B-INFO-143: isCalculating is true while any entry in this window is.
    @Test func isCalculatingWhileAnyEntryIs() {
        #expect(!sizes.isCalculating)
        sizes.calculate("/a")
        #expect(sizes.isCalculating)
        sizes.cancel("/a")
        #expect(!sizes.isCalculating)
    }

    // B-INFO-144: letting go of the cache stops the polling.
    @Test func stoppingEndsThePolling() {
        sizes.calculate("/a")
        sizes.stopAll()
        jobs.finish("job-1", "/a", size: 1)
        timers.advance(1)
        #expect(sizes.cachedEntry("/a") == .calculating(jobID: "job-1"))
    }

    // A write forgets what it touched: a folder holding the change is asked about again, one inside it is forgotten.
    @Test func aWriteMakesTheFoldersHoldingItAskedAboutAgain() async {
        jobs.known = ["/a": 10, "/a/b": 5]
        _ = sizes.entry("/a")
        _ = sizes.entry("/a/b")
        await settle()
        jobs.known = ["/a": 4]
        sizes.forgetChangedSizes(["/a/b"], intoTrash: false)
        await settle()
        #expect(sizes.cachedEntry("/a/b") == nil)
        #expect(sizes.readySize("/a") == 4)
    }
}
