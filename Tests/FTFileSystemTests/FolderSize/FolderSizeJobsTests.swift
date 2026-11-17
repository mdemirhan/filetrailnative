import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

/// A walker the test drives by hand: the walk under way finishes folders, resolves or rejects when told. As the real
/// walker, it takes one walk at a time: one started while another hasn't settled fails the test (the real walker's
/// check of it is a debug assert).
@MainActor
private final class MockNative: FolderSizeNative {
    @MainActor private final class Gate {
        var outcome: Result<FolderSizeResult, any Error>?
        var continuation: CheckedContinuation<FolderSizeResult, any Error>?

        func settle(_ outcome: Result<FolderSizeResult, any Error>) {
            if let continuation {
                self.continuation = nil
                continuation.resume(with: outcome)
            } else {
                self.outcome = outcome
            }
        }

        func value() async throws -> FolderSizeResult {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    var calls: [(path: String, background: Bool)] = []
    var cancelCount = 0
    private var gate: Gate?
    private var finishedActive: (@MainActor (FinishedFolders) -> Void)?

    func getFolderSize(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error> {
        calls.append((path, background))
        if gate != nil {
            Issue.record("a folder size walk of \(path) started while another was under way")
        }
        let gate = Gate()
        self.gate = gate
        finishedActive = onFinished
        return Task { @MainActor in try await gate.value() }
    }

    func cancelFolderSize() {
        cancelCount += 1
    }

    /// Folders the active walk has finished, handed over while it runs.
    func finish(_ dirs: [String: [Int64]], dev: Int64 = 16) {
        finishedActive?(FinishedFolders(dev: dev, dirs: folders(dirs)))
    }

    func resolveActive(_ result: FolderSizeResult = sampleResult) {
        gate?.settle(.success(result))
        gate = nil
    }

    func rejectActive(_ error: any Error) {
        gate?.settle(.failure(error))
        gate = nil
    }
}

private func folders(_ dirs: [String: [Int64]]) -> [FinishedFolders.Folder] {
    dirs.map { path, totals in
        FinishedFolders.Folder(
            path: path,
            totals: FolderTotals(
                sizeBytes: totals[0], diskBytes: totals[1], fileCount: Int(totals[2]), folderCount: Int(totals[3])))
    }
}

private let sampleResult = FolderSizeResult(
    total: 1000, diskTotal: 1200, fileCount: 42, folderCount: 7, dev: nil,
    dirs: folders(["/test/sub": [500, 600, 20, 3]]))

private func result(
    _ total: Int64, _ disk: Int64, _ files: Int, _ folderCount: Int, dev: Int64 = 16,
    dirs: [String: [Int64]] = [:]
) -> FolderSizeResult {
    FolderSizeResult(
        total: total, diskTotal: disk, fileCount: files, folderCount: folderCount, dev: dev, dirs: folders(dirs))
}

private let cancelledError = FolderSizeError(errnum: ECANCELED, message: "cancelled")

private func removedFile(_ path: String, intoHomeTrash: Bool? = false) -> RemovedItem {
    RemovedItem(
        path: path, item: ItemSize(kind: .file, sizeBytes: 100, diskBytes: 200, dev: 16), intoHomeTrash: intoHomeTrash)
}

private let trashedZip = RemovedItem(
    path: "/Users/demo/Downloads/a.zip", item: ItemSize(kind: .file, sizeBytes: 200, diskBytes: 400, dev: 16),
    intoHomeTrash: true)

/// Lets the walks that were resolved or rejected reach the jobs.
@MainActor
private func settle() async {
    for _ in 0..<40 {
        await Task.yield()
    }
}

@MainActor @Suite(.serialized) struct FolderSizeJobsTests {
    private func make(
        _ native: MockNative, homePath: String = NSHomeDirectory(), onSettled: ((Int?, String) -> Void)? = nil,
        onStored: (() -> Void)? = nil
    ) -> FolderSizeJobs {
        let jobs = FolderSizeJobs(native: native, homePath: homePath, onSettled: onSettled, onStored: onStored)
        // Ids that can't repeat: the tests that count jobs start hundreds within a millisecond, where two of
        // the app's ids (the millisecond and 24 random bits) are the same about once in 400 runs, and the
        // second job replaces the first.
        var made = 0
        jobs.makeJobId = {
            made += 1
            return "folder-size-test-\(made)"
        }
        return jobs
    }

    private func start(
        _ jobs: FolderSizeJobs, _ path: String, owner: Int? = nil, recalculate: Bool = false, automatic: Bool = false
    )
        -> FolderSizeStartResponse
    {
        jobs.start(FolderSizeStartRequest(path: path, recalculate: recalculate, automatic: automatic), owner: owner)
    }

    // What a measurement left out goes with its size: in the job, in what is stored, and with the folders inside.
    @Test func whatASizeLeavesOutGoesWithItWhereverItIsKept() async {
        let native = MockNative()
        let jobs = make(native)
        var inside = FinishedFolders.Folder(
            path: "/test/a/locked-in", totals: FolderTotals(sizeBytes: 5, diskBytes: 8, fileCount: 1, folderCount: 1))
        inside.totals.partial = .noAccess
        let measured = start(jobs, "/test/a")
        native.resolveActive(
            FolderSizeResult(
                total: 10, diskTotal: 16, fileCount: 2, folderCount: 2, dirs: [inside], partial: [.noAccess, .changed]))
        await settle()

        #expect(jobs.getStatus(jobId: measured.jobId).partial == [.noAccess, .changed])
        let probes = jobs.probeMany(["/test/a", "/test/a/locked-in"])
        #expect(probes.map(\.partial) == [[.noAccess, .changed], .noAccess])
        // A size asked for again comes from what is stored, with what it left out.
        let again = start(jobs, "/test/a")
        #expect(jobs.getStatus(jobId: again.jobId).partial == [.noAccess, .changed])
    }

    // The window that asked hears when its measurement ends, whichever way, and only once.
    @Test func tellsTheWindowThatAskedWhenItsMeasurementHasEnded() async {
        let native = MockNative()
        var settled: [(Int?, String)] = []
        let jobs = make(native) { settled.append(($0, $1)) }

        let measured = start(jobs, "/test/a", owner: 7)
        let waiting = start(jobs, "/test/b", owner: 8)
        #expect(settled.isEmpty)
        native.resolveActive()
        await settle()
        #expect(settled.last?.0 == 7 && settled.last?.1 == measured.jobId)

        // Window 8's, now running, fails; a stop afterwards changes nothing it is told.
        native.rejectActive(FolderSizeError(errnum: nil, message: "EIO"))
        await settle()
        #expect(settled.last?.0 == 8 && settled.last?.1 == waiting.jobId)
        jobs.cancel(jobId: waiting.jobId)
        #expect(settled.count == 2)

        // Stopped while it waited: told too.
        let running = start(jobs, "/test/c", owner: 7)
        let queued = start(jobs, "/test/d", owner: 8)
        jobs.cancel(jobId: queued.jobId)
        #expect(settled.last?.0 == 8 && settled.last?.1 == queued.jobId)
        native.resolveActive()
        await settle()
        #expect(settled.last?.0 == 7 && settled.last?.1 == running.jobId)
    }

    @Test func startReturnsRunningAndJobTransitionsToReadyWithAllThreeFields() async {
        let native = MockNative()
        let jobs = make(native)

        let started = start(jobs, "/test")
        #expect(started.status == .running)

        native.resolveActive()
        await settle()

        let status = jobs.getStatus(jobId: started.jobId)
        #expect(status.status == .ready)
        #expect(status.sizeBytes == 1000)
        #expect(status.diskBytes == 1200)
        #expect(status.fileCount == 42)
        #expect(status.folderCount == 7)
        #expect(status.error == nil)
    }

    // A measurement that has ended keeps its answer when it is stopped afterwards (a window closing late), and the walk
    // under way for another isn't stopped for it.
    @Test func stoppingAMeasurementThatHasEndedKeepsItsAnswer() async {
        let native = MockNative()
        let jobs = make(native)
        let done = start(jobs, "/test/done")
        native.resolveActive()
        await settle()
        let running = start(jobs, "/test/running")
        #expect(jobs.getStatus(jobId: running.jobId).status == .running)

        jobs.cancel(jobId: done.jobId)

        #expect(jobs.getStatus(jobId: done.jobId).status == .ready)
        #expect(jobs.getStatus(jobId: done.jobId).sizeBytes == 1000)
        #expect(jobs.getStatus(jobId: running.jobId).status == .running)
    }

    @Test func startWithCacheHitReturnsReadyImmediatelyWithAllFields() async {
        let native = MockNative()
        let jobs = make(native)

        // Populate cache
        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        // Second request should hit cache
        let second = start(jobs, "/test")
        #expect(second.status == .ready)

        let status = jobs.getStatus(jobId: second.jobId)
        #expect(status.sizeBytes == 1000)
        #expect(status.diskBytes == 1200)
        #expect(status.fileCount == 42)
        #expect(status.folderCount == 7)
    }

    @Test func answersAProbeWithTheSizesItKnowsMeasuringNothing() async {
        let native = MockNative()
        let jobs = make(native)
        #expect(jobs.probeMany(["/test"]).isEmpty)
        #expect(native.calls.isEmpty)

        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        #expect(
            jobs.probeMany(["/test", "/test/sub", "/elsewhere"]) == [
                FolderSizeProbe(path: "/test", sizeBytes: 1000, diskBytes: 1200, fileCount: 42, folderCount: 7),
                FolderSizeProbe(path: "/test/sub", sizeBytes: 500, diskBytes: 600, fileCount: 20, folderCount: 3),
            ])
        #expect(native.calls.count == 1)
    }

    // Each probe made a job, and over 256 of them between a window's polls pushed out the finished job it was
    // about to read: "Unknown folder size job."
    @Test func makesNoJobForAProbeSoProbesNeverPushOutAJobAWindowWaitsOn() async {
        let native = MockNative()
        let jobs = make(native)
        let measured = start(jobs, "/test")
        native.resolveActive()
        await settle()

        for index in 0..<1_000 {
            _ = jobs.probeMany(["/probe/\(index)", "/test/sub"])
        }

        #expect(jobs.jobCount == 1)
        let status = jobs.getStatus(jobId: measured.jobId)
        #expect(status.status == .ready)
        #expect(status.sizeBytes == 1000)
    }

    // A trashed 5 GB folder replaced by an empty one of the same name showed 5 GB.
    @Test func forgetsTheSizesOfTheFoldersAWriteTouchedAndKeepsTheOthers() async {
        let native = MockNative()
        let jobs = make(native)
        for path in ["/Users/demo/Project", "/Users/demo/Music"] {
            _ = start(jobs, path)
            native.resolveActive()
            await settle()
        }

        FolderSizeWrites.forget(changedPaths: ["/Users/demo/Project/src/old.txt"])

        #expect(jobs.cachedSize("/Users/demo/Project") == nil)
        #expect(jobs.cachedSize("/Users/demo/Music") == 1000)
    }

    // 100,000 cached sizes against 10,000 changed paths took 55 s, asked one pair at a time.
    @Test func forgetsTheSizesALargeWriteTouchedQuicklyHoweverManyAreKept() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/Users/demo/Library")
        // In takes, with the rest of the app let in between, as a walk's folders arrive.
        for take in 0..<6 {
            var dirs: [String: [Int64]] = [:]
            for index in (take * 5_000)..<((take + 1) * 5_000) {
                dirs["/Users/demo/Library/c\(index % 500)/d\(index)"] = [1, 1, 1, 0]
            }
            native.finish(dirs)
            await Task.yield()
        }
        native.resolveActive()
        await settle()
        let changed = (0..<3_000).map { "/Users/demo/Library/c7/d\($0 * 500 + 7)/new.txt" }

        let (_, seconds) = CPUTime.measureThread { FolderSizeWrites.forget(changedPaths: changed) }
        // Well under 100 ms on a laptop; the bound only catches going back to every pair.
        #expect(seconds < 3, "took \(seconds) s of CPU time")
        #expect(jobs.cachedSize("/Users/demo/Library/c7/d7") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library/c7") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library/c8/d8") == 1)
    }

    // A home folder's walk stores far more sizes than a limit of 100,000 kept, and the first finished, often
    // folders directly in the home folder, showed no size afterwards.
    @Test func keepsEverySizeAMeasurementStoresTheFirstFinishedToo() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test")
        native.finish(["/test/small": [1, 1, 1, 0]])
        // More than the 100,000 an old limit kept, in takes with the rest of the app let in between.
        for take in 0..<11 {
            var dirs: [String: [Int64]] = [:]
            for index in (take * 10_000)..<((take + 1) * 10_000) {
                dirs["/test/big/d\(index)"] = [2, 2, 1, 0]
            }
            native.finish(dirs)
            await Task.yield()
        }
        native.resolveActive()
        await settle()

        #expect(jobs.probeMany(["/test/small"]).count == 1)
        #expect(jobs.cachedSize("/test/big/d0") == 2)
        #expect(jobs.cachedSize("/test") == 1000)
    }

    @Test func measuresAtALowerPriorityWhatTheAppMeasuresByItself() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test/auto", automatic: true)
        native.resolveActive()
        await settle()
        _ = start(jobs, "/test/asked")

        #expect(native.calls.map(\.path) == ["/test/auto", "/test/asked"])
        #expect(native.calls.map(\.background) == [true, false])
    }

    /// Measuring the home folder, whose walk reached its Trash or was refused it.
    private func measureHome(trashReadable: Bool) async -> (native: MockNative, jobs: FolderSizeJobs) {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        _ = start(jobs, "/Users/demo")
        var dirs: [String: [Int64]] = ["/Users/demo/Downloads": [600, 1_200, 6, 0]]
        if trashReadable {
            dirs["/Users/demo/.Trash"] = [50, 100, 1, 0]
        }
        native.resolveActive(result(1_000, 2_000, 10, 3, dirs: dirs))
        await settle()
        return (native, jobs)
    }

    @Test func takesWhatWentToTheTrashOffTheFoldersThatHeldItAsMeasured() async {
        let readable = await measureHome(trashReadable: true)
        FolderSizeWrites.forget(removedItems: [trashedZip])
        #expect(readable.jobs.cachedSize("/Users/demo/Downloads") == 400)
        // Still in the home folder, in its Trash, which its measurement counted.
        #expect(readable.jobs.cachedSize("/Users/demo") == 1_000)
        #expect(readable.jobs.cachedSize("/Users/demo/.Trash") == 250)

        let unreadable = await measureHome(trashReadable: false)
        FolderSizeWrites.forget(removedItems: [trashedZip])
        #expect(unreadable.jobs.cachedSize("/Users/demo/Downloads") == 400)
        #expect(unreadable.jobs.cachedSize("/Users/demo") == 800)
    }

    @Test func learnsThatTheTrashCantBeReadFromMeasuringTheTrashItself() async {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        _ = start(jobs, "/Users/demo/.Trash")
        native.rejectActive(FolderSizeError(errnum: EPERM, message: "denied"))
        await settle()
        _ = start(jobs, "/Users/demo/Downloads")
        native.resolveActive(result(600, 1_200, 6, 0))
        await settle()
        _ = start(jobs, "/Users/demo")
        native.resolveActive(result(1_000, 2_000, 10, 3, dirs: ["/Users/demo/Downloads": [600, 1_200, 6, 0]]))
        await settle()

        FolderSizeWrites.forget(removedItems: [trashedZip])

        #expect(jobs.cachedSize("/Users/demo") == 800)
    }

    // Folder 100 MB holding Inner 50 MB; Inner grew to 80 MB and was measured again by itself. Moving Inner to the
    // Trash took 80 MB off Folder: 20 MB, where 50 MB remained.
    @Test func forgetsAFolderRatherThanTakeOffWhatWasMeasuredAgainInsideIt() async {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        _ = start(jobs, "/Users/demo/Folder")
        native.resolveActive(result(100, 100, 2, 1, dirs: ["/Users/demo/Folder/Inner": [50, 50, 1, 0]]))
        await settle()
        _ = start(jobs, "/Users/demo/Folder/Inner", recalculate: true)
        native.resolveActive(result(80, 80, 2, 0))
        await settle()

        FolderSizeWrites.forget(
            removedItems: [
                RemovedItem(
                    path: "/Users/demo/Folder/Inner",
                    item: ItemSize(kind: .folder, sizeBytes: 0, diskBytes: 0, dev: 16),
                    intoHomeTrash: false)
            ])

        #expect(jobs.cachedSize("/Users/demo/Folder") == nil)
    }

    @Test func measuresAgainAFolderAWriteChangedWhileItWasBeingMeasured() async {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        let started = start(jobs, "/Users/demo/Project")

        var zip = trashedZip
        zip.path = "/Users/demo/Project/a.zip"
        FolderSizeWrites.forget(removedItems: [zip])
        native.resolveActive()
        await settle()

        // The first answer may have seen part of the change: the same job measures again.
        #expect(native.calls.count == 2)
        #expect(jobs.getStatus(jobId: started.jobId).status == .running)
        #expect(jobs.cachedSize("/Users/demo/Project") == nil)
        native.resolveActive()
        await settle()
        let status = jobs.getStatus(jobId: started.jobId)
        #expect(status.status == .ready && status.sizeBytes == 1000)
        #expect(jobs.cachedSize("/Users/demo/Project") == 1000)
    }

    @Test func stopsAMeasurementAWriteHasOutdatedRatherThanLetItFinishForNothing() {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test")

        FolderSizeWrites.forget(changedPaths: ["/elsewhere/new.txt"])
        #expect(native.cancelCount == 0)
        FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])
        FolderSizeWrites.forget(changedPaths: ["/test/another.txt"])

        #expect(native.cancelCount == 1)
    }

    @Test func measuresAgainUnderTheSameJobOneStoppedBecauseAWriteOutdatedIt() async {
        let native = MockNative()
        let jobs = make(native)
        let started = start(jobs, "/test")
        FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])
        native.rejectActive(cancelledError)
        await settle()

        #expect(native.calls.count == 2)
        #expect(jobs.getStatus(jobId: started.jobId).status == .running)
        native.resolveActive()
        await settle()
        let status = jobs.getStatus(jobId: started.jobId)
        #expect(status.status == .ready && status.sizeBytes == 1000)
    }

    // It was left "running" for good: the window showed Calculating… and polled forever.
    @Test func measuresAnOutdatedMeasurementAgainAfterAnotherWindowsWaitingOne() async {
        let native = MockNative()
        let jobs = make(native)
        let first = start(jobs, "/test/a", owner: 1)
        let second = start(jobs, "/test/b", owner: 2)
        FolderSizeWrites.forget(changedPaths: ["/test/a/new.txt"])
        // Finished before the stop reached it.
        native.resolveActive()
        await settle()

        // The other window's measurement runs first; the outdated one waits behind it.
        #expect(native.calls.last?.path == "/test/b")
        #expect(jobs.getStatus(jobId: first.jobId).status == .queued)
        native.resolveActive()
        await settle()
        #expect(jobs.getStatus(jobId: second.jobId).status == .ready)

        #expect(native.calls.last?.path == "/test/a")
        #expect(jobs.getStatus(jobId: first.jobId).status == .running)
        native.resolveActive()
        await settle()
        let status = jobs.getStatus(jobId: first.jobId)
        #expect(status.status == .ready && status.sizeBytes == 1000)
    }

    @Test func takesAWaitingMeasurementOffTheQueueWhenItIsStopped() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test/a", owner: 1)
        let waiting = start(jobs, "/test/b", owner: 2)

        jobs.cancel(jobId: waiting.jobId)
        native.resolveActive()
        await settle()

        #expect(jobs.getStatus(jobId: waiting.jobId).status == .cancelled)
        #expect(native.calls.count == 1)
    }

    @Test func learnsTheTrashWasReadFromMeasuringTheTrashItself() async {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        _ = start(jobs, "/Users/demo/.Trash")
        native.resolveActive(result(50, 100, 1, 0))
        await settle()
        _ = start(jobs, "/Users/demo/Downloads")
        native.resolveActive(result(600, 1_200, 6, 0))
        await settle()

        FolderSizeWrites.forget(removedItems: [trashedZip])

        #expect(jobs.cachedSize("/Users/demo/.Trash") == 250)
        #expect(jobs.cachedSize("/Users/demo/Downloads") == 400)
    }

    @Test func letsStopEndAMeasurementAWriteHadOutdated() async {
        let native = MockNative()
        let jobs = make(native)
        let started = start(jobs, "/test")
        FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])
        jobs.cancel(jobId: started.jobId)
        native.rejectActive(cancelledError)
        await settle()

        #expect(native.calls.count == 1)
        #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
    }

    // Only a running one was marked: a stopped walk that finished all the same kept what it had seen of the change.
    @Test func keepsNothingOfAStoppedMeasurementThatAWriteOutdatesBeforeItEnds() async {
        let native = MockNative()
        let jobs = make(native)
        let started = start(jobs, "/test")
        jobs.cancel(jobId: started.jobId)

        FolderSizeWrites.forget(changedPaths: ["/test/sub/new.txt"])
        // Still stopping: it finishes a folder, then the walk.
        native.finish(["/test/sub": [5, 5, 1, 0]])
        native.resolveActive()
        await settle()

        #expect(jobs.cachedSize("/test/sub") == nil)
        #expect(jobs.cachedSize("/test") == nil)
        #expect(native.calls.count == 1)
        #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
    }

    @Test func dropsTheFinishedJobsItKeepsTooManyOfWhenItMeasuresAgainAtOnce() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test", owner: 1)
        for index in 0..<300 {
            jobs.cancel(jobId: start(jobs, "/waiting/\(index)", owner: 2).jobId)
        }
        #expect(jobs.jobCount == 301)

        FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])
        native.resolveActive()
        await settle()

        #expect(native.calls.count == 2)
        #expect(jobs.jobCount == 257)
    }

    // A walk of the home folder stores hundreds of thousands of sizes, a take of 10,000 folders at a time: each take
    // must be stored in a moment. Four takes show it: storing one at a time costs more
    // with each size kept, and the bound is a fifth of the one for 20 takes.
    @Test func keepsUpWithAWalkThatStoresHundredsOfThousandsOfSizes() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/Users/demo")
        // The CPU time of the takes themselves, not of what runs between them.
        var seconds = 0.0
        for take in 0..<4 {
            var dirs: [String: [Int64]] = [:]
            for index in (take * 10_000)..<((take + 1) * 10_000) {
                dirs["/Users/demo/Library/c\(index % 400)/d\(index)"] = [1, 1, 1, 0]
            }
            seconds += CPUTime.measureThread { native.finish(dirs) }.seconds
            // Lets the rest of the app run between takes, as it does between the walk's.
            await Task.yield()
        }
        // About a fifth of a second on a laptop; the bound only catches going back to one at a time.
        #expect(seconds < 1.2, "took \(seconds) s of CPU time")
        #expect(jobs.cachedSize("/Users/demo/Library/c399/d39999") == 1)
        #expect(jobs.cachedSize("/Users/demo/Library/c0/d0") == 1)
    }

    @MainActor @Suite struct AWindowThatGoesAway {
        @Test func stopsItsMeasurementUnderWayAndDoesntMeasureItAgain() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let started = jobs.start(FolderSizeStartRequest(path: "/test"), owner: 1)
            // Outdated: it would be measured again once stopped.
            FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])
            native.cancelCount = 0

            jobs.forgetOwner(1)
            native.rejectActive(cancelledError)
            await settle()

            #expect(native.cancelCount == 1)
            #expect(native.calls.count == 1)
            #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
        }

        @Test func takesItsWaitingMeasurementsOffTheQueueAndLeavesTheOthersAlone() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let running = jobs.start(FolderSizeStartRequest(path: "/test/a"), owner: 2)
            let gone = jobs.start(FolderSizeStartRequest(path: "/test/b"), owner: 1)
            let other = jobs.start(FolderSizeStartRequest(path: "/test/c"), owner: 3)

            jobs.forgetOwner(1)
            #expect(native.cancelCount == 0)
            native.resolveActive()
            await settle()

            #expect(jobs.getStatus(jobId: running.jobId).status == .ready)
            #expect(jobs.getStatus(jobId: gone.jobId).status == .cancelled)
            #expect(jobs.getStatus(jobId: other.jobId).status == .running)
            #expect(native.calls.last?.path == "/test/c")
        }

        @Test func stopsOneMeasuredAgainForItWaitingBehindAnotherWindowsOne() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let outdated = jobs.start(FolderSizeStartRequest(path: "/test/a"), owner: 1)
            let other = jobs.start(FolderSizeStartRequest(path: "/test/b"), owner: 2)
            FolderSizeWrites.forget(changedPaths: ["/test/a/new.txt"])
            native.resolveActive()
            await settle()
            #expect(jobs.getStatus(jobId: outdated.jobId).status == .queued)

            jobs.forgetOwner(1)
            native.resolveActive()
            await settle()

            #expect(jobs.getStatus(jobId: other.jobId).status == .ready)
            #expect(jobs.getStatus(jobId: outdated.jobId).status == .cancelled)
            #expect(native.calls.count == 2)
        }
    }

    @MainActor @Suite struct TheAppQuitting {
        @Test func stopsTheWalkUnderWayAndRunsNoneOfThoseWaiting() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let running = jobs.start(FolderSizeStartRequest(path: "/test/a"), owner: 1)
            let waiting = jobs.start(FolderSizeStartRequest(path: "/test/b"), owner: 2)

            jobs.stopAll()
            #expect(native.cancelCount == 1)
            native.rejectActive(cancelledError)
            await settle()

            #expect(native.calls.count == 1)
            #expect(jobs.getStatus(jobId: running.jobId).status == .cancelled)
            #expect(jobs.getStatus(jobId: waiting.jobId).status == .cancelled)
        }

        @Test func doesntMeasureAgainAWalkAWriteOutdated() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            _ = jobs.start(FolderSizeStartRequest(path: "/test"), owner: 1)
            FolderSizeWrites.forget(changedPaths: ["/test/new.txt"])

            jobs.stopAll()
            native.rejectActive(cancelledError)
            await settle()

            #expect(native.calls.count == 1)
        }

        @Test func measuresNothingAskedForAfterwards() {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)

            jobs.stopAll()
            let late = jobs.start(FolderSizeStartRequest(path: "/test"), owner: 1)

            #expect(late.status == .cancelled)
            #expect(native.calls.isEmpty)
            #expect(native.cancelCount == 0)
        }
    }

    @MainActor @Suite struct FoldersFinishedWhileMeasuring {
        @Test func keepsEachFolderAsItIsFinishedAndCountsThemForTheWindow() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let started = jobs.start(FolderSizeStartRequest(path: "/test"))

            native.finish(["/test/a/deep": [100, 200, 1, 0], "/test/a": [150, 300, 2, 1]])

            let running = jobs.getStatus(jobId: started.jobId)
            #expect(running.status == .running && running.measuredFolderCount == 2)
            #expect(jobs.cachedSize("/test/a") == 150)
            #expect(jobs.probeMany(["/test/a/deep"]).map(\.sizeBytes) == [100])

            // The rest come with the result.
            native.resolveActive(result(500, 900, 5, 3, dirs: ["/test/b": [300, 500, 2, 0]]))
            await settle()
            let ready = jobs.getStatus(jobId: started.jobId)
            #expect(ready.status == .ready && ready.sizeBytes == 500 && ready.measuredFolderCount == 3)
            #expect(jobs.cachedSize("/test/b") == 300)
            #expect(jobs.cachedSize("/test/a") == 150)
        }

        @Test func keepsTheFoldersFinishedBeforeACancel() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let started = jobs.start(FolderSizeStartRequest(path: "/test"))
            native.finish(["/test/a": [150, 300, 2, 1]])

            jobs.cancel(jobId: started.jobId)
            // Finished before the walk stopped: handed over as it rejects.
            native.finish(["/test/b": [70, 80, 1, 0]])
            native.rejectActive(cancelledError)
            await settle()

            #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
            #expect(jobs.cachedSize("/test") == nil)
            #expect(jobs.cachedSize("/test/a") == 150)
            #expect(jobs.cachedSize("/test/b") == 70)
        }

        @Test func stopsKeepingFoldersOnceAWriteHasOutdatedTheMeasurementUntilItRunsAgain() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native)
            let started = jobs.start(FolderSizeStartRequest(path: "/test"))
            native.finish(["/test/a": [150, 300, 2, 1]])

            FolderSizeWrites.forget(changedPaths: ["/test/b/new.txt"])
            // May have been counted before or after the change.
            native.finish(["/test/b": [70, 80, 1, 0]])
            #expect(jobs.cachedSize("/test/b") == nil)
            // Untouched by the write.
            #expect(jobs.cachedSize("/test/a") == 150)

            native.resolveActive()
            await settle()
            #expect(native.calls.count == 2)
            #expect(jobs.cachedSize("/test") == nil)

            // Measured again: what it finishes is kept, and the count only goes up.
            native.finish(["/test/b": [90, 100, 2, 0]])
            #expect(jobs.cachedSize("/test/b") == 90)
            #expect(jobs.getStatus(jobId: started.jobId).measuredFolderCount == 2)
        }

        // A folder finished after a delete removed something from it already leaves it out: taking it off again
        // when the delete ends would count it twice.
        @Test func measuresAgainRatherThanAdjustsAFolderStoredWhileADeleteWasRunning() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native, homePath: "/Users/demo")
            FolderSizeWrites.noteWriteEnded()
            _ = jobs.start(FolderSizeStartRequest(path: "/Users/demo/Work"))
            native.finish(["/Users/demo/Work/old": [1_000, 2_000, 4, 0]])
            native.resolveActive(result(5_000, 10_000, 20, 2))
            await settle()

            FolderSizeWrites.noteWriteStarting()
            _ = jobs.start(FolderSizeStartRequest(path: "/Users/demo/Projects"))
            // Finished after the delete below had already taken a.txt out of it.
            native.finish(["/Users/demo/Projects/app": [300, 600, 3, 0]])
            native.resolveActive(result(800, 1_600, 6, 1))
            await settle()
            FolderSizeWrites.forget(
                removedItems: [
                    removedFile("/Users/demo/Projects/app/a.txt"), removedFile("/Users/demo/Work/old/b.txt"),
                ])

            #expect(jobs.cachedSize("/Users/demo/Projects/app") == nil)
            #expect(jobs.cachedSize("/Users/demo/Projects") == nil)
            // Stored before the delete started: adjusted as before.
            #expect(jobs.cachedSize("/Users/demo/Work/old") == 900)
            #expect(jobs.cachedSize("/Users/demo/Work") == 4_900)
            FolderSizeWrites.noteWriteEnded()
        }

        // Every size stored after a write started was noted until the next one started.
        @Test func adjustsAFolderStoredWhileAWriteRanOnceThatWritesEndIsCleared() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native, homePath: "/Users/demo")
            FolderSizeWrites.noteWriteStarting()
            _ = jobs.start(FolderSizeStartRequest(path: "/Users/demo/Projects"))
            native.finish(["/Users/demo/Projects/app": [300, 600, 3, 0]])
            native.resolveActive(result(800, 1_600, 6, 1))
            await settle()
            FolderSizeWrites.noteWriteEnded()

            FolderSizeWrites.forget(removedItems: [removedFile("/Users/demo/Projects/app/a.txt")])

            #expect(jobs.cachedSize("/Users/demo/Projects/app") == 200)
            #expect(jobs.cachedSize("/Users/demo/Projects") == 700)
        }

        @Test func learnsWhetherTheTrashWasReadFromTheFoldersAsTheyAreFinished() async {
            let native = MockNative()
            let jobs = FolderSizeJobs(native: native, homePath: "/Users/demo")
            _ = jobs.start(FolderSizeStartRequest(path: "/Users"))
            native.finish(["/Users/demo/Downloads": [600, 1_200, 6, 0], "/Users/demo/.Trash": [50, 100, 1, 0]])
            native.finish(["/Users/demo": [1_000, 2_000, 10, 3]])
            native.resolveActive(result(1_000, 2_000, 10, 4))
            await settle()

            FolderSizeWrites.forget(removedItems: [trashedZip])

            // The Trash was counted, so the zip is still in the home folder.
            #expect(jobs.cachedSize("/Users/demo") == 1_000)
            #expect(jobs.cachedSize("/Users/demo/.Trash") == 250)
        }
    }

    @Test func startWithRecalculateClearsCache() async {
        let native = MockNative()
        let jobs = make(native)

        // Populate cache
        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        // Recalculate should not return ready from cache
        let again = start(jobs, "/test", recalculate: true)
        #expect(again.status == .running)
    }

    @Test func cancelMarksJobAsCancelledAndCallsNativeCancel() {
        let native = MockNative()
        let jobs = make(native)

        let started = start(jobs, "/test")
        jobs.cancel(jobId: started.jobId)
        #expect(native.cancelCount > 0)

        #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
    }

    @Test func getStatusReturnsCorrectFieldsForUnknownJob() {
        let native = MockNative()
        let jobs = make(native)

        let status = jobs.getStatus(jobId: "nonexistent")
        #expect(status.status == .error)
        #expect(status.sizeBytes == nil)
        #expect(status.diskBytes == nil)
        #expect(status.fileCount == nil)
        #expect(status.folderCount == nil)
        #expect(status.error == "Unknown folder size job.")
    }

    // A folder measured again changes the sizes of the folders holding it by the difference, Recalculate included.
    @Test func aFolderMeasuredAgainCorrectsTheFoldersHoldingIt() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test")
        native.resolveActive(
            result(1000, 1200, 42, 7, dirs: ["/test/sub": [500, 600, 20, 3], "/test/sub/in": [50, 60, 2, 0]]))
        await settle()
        _ = start(jobs, "/test/sub", recalculate: true)
        native.resolveActive(result(300, 400, 15, 2, dirs: ["/test/sub/in": [40, 48, 1, 0]]))
        await settle()

        let probes = jobs.probeMany(["/test", "/test/sub"])
        #expect(probes.map(\.sizeBytes) == [800, 300])
        #expect(probes.first.map { [$0.diskBytes, Int64($0.fileCount), Int64($0.folderCount)] } == [1000, 37, 6])
    }

    // Where a folder holding it didn't count the size it had (the folder was measured again since), the folder
    // holding it is forgotten rather than corrected.
    @Test func forgetsAFolderHoldingOneThatItDidntCountAsItWas() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test")
        native.resolveActive(
            result(1000, 1200, 42, 7, dirs: ["/test/a": [500, 600, 20, 3], "/test/a/b": [100, 120, 5, 0]]))
        await settle()
        for size: Int64 in [90, 70] {
            _ = start(jobs, "/test/a/b", recalculate: true)
            native.resolveActive(result(size, size, 5, 0))
            await settle()
        }
        // The first measured again was counted by both, and corrected them; the second was measured after them.
        #expect(jobs.cachedSize("/test/a/b") == 70)
        #expect(jobs.cachedSize("/test/a") == nil && jobs.cachedSize("/test") == nil)
    }

    // What is measured and what waits, the one measured first, for the Activity list; told as it changes.
    @Test func saysWhatIsMeasuredAndWhatWaits() async {
        let native = MockNative()
        let jobs = make(native)
        var told = 0
        jobs.onActivityChanged = { told += 1 }

        let running = start(jobs, "/test/a", owner: 1, automatic: true)
        let waiting = start(jobs, "/test/b", owner: 2)
        native.finish(["/test/a/in": [5, 8, 1, 0]])
        await settle()
        #expect(told > 0)
        // The automatic walk gave way to the one asked for.
        native.rejectActive(cancelledError)
        await settle()
        #expect(
            jobs.activity == [
                FolderSizeActivity(
                    jobId: waiting.jobId, path: "/test/b", isRunning: true, isAutomatic: false, measuredFolderCount: 0),
                FolderSizeActivity(
                    jobId: running.jobId, path: "/test/a", isRunning: false, isAutomatic: true, measuredFolderCount: 1),
            ])
        native.resolveActive()
        await settle()
        native.resolveActive()
        await settle()
        #expect(jobs.activity.isEmpty)
    }

    // Every window is told when sizes are stored, as the walk hands folders over and when it ends.
    @Test func tellsEveryWindowWhenSizesAreStored() async {
        let native = MockNative()
        var stored = 0
        let jobs = make(native, onStored: { stored += 1 })

        _ = start(jobs, "/test", owner: 1)
        native.finish(["/test/sub": [5, 8, 1, 0]])
        await settle()
        #expect(stored == 1)
        native.resolveActive()
        await settle()
        #expect(stored == 2)
    }

    // A measurement asked for never stops another: it waits, and runs when the one before ends.
    @Test func aNewMeasurementWaitsForTheOneRunning() async {
        let native = MockNative()
        let jobs = make(native)

        let first = start(jobs, "/test/a", owner: 1)
        let second = start(jobs, "/test/b", owner: 1)
        #expect(first.status == .running && second.status == .queued)
        #expect(native.cancelCount == 0)
        #expect(jobs.getStatus(jobId: first.jobId).status == .running)

        native.resolveActive()
        await settle()
        #expect(jobs.getStatus(jobId: first.jobId).status == .ready)
        #expect(native.calls.map(\.path) == ["/test/a", "/test/b"])
    }

    // Several windows' measurements wait in the order asked for; none stops another.
    @Test func measurementsWaitInTheOrderAskedFor() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test/a", owner: 1)
        let second = start(jobs, "/test/b", owner: 2)
        let third = start(jobs, "/test/c", owner: 2)
        #expect(second.status == .queued && third.status == .queued)
        #expect(native.cancelCount == 0)

        native.resolveActive()
        await settle()
        native.resolveActive()
        await settle()
        #expect(native.calls.map(\.path) == ["/test/a", "/test/b", "/test/c"])
        #expect(native.calls.allSatisfy { !$0.background })
    }

    // A folder already being measured or waiting is joined: one walk, and every window that asked hears it end.
    // Stop from one window leaves it going for the other.
    @Test func aFolderAskedForTwiceIsWalkedOnce() async {
        let native = MockNative()
        var settled: [Int?] = []
        let jobs = make(native) { owner, _ in settled.append(owner) }

        let first = start(jobs, "/test/a", owner: 1)
        let second = start(jobs, "/test/a", owner: 2, recalculate: true)
        #expect(second.jobId == first.jobId && second.status == .running)
        jobs.cancel(jobId: first.jobId, owner: 1)
        #expect(native.cancelCount == 0)
        #expect(jobs.getStatus(jobId: first.jobId).status == .running)

        native.resolveActive()
        await settle()
        #expect(native.calls.count == 1)
        #expect(settled == [2])

        // Waiting, the same.
        _ = start(jobs, "/test/b", owner: 1)
        let waiting = start(jobs, "/test/c", owner: 1)
        #expect(start(jobs, "/test/c", owner: 2).jobId == waiting.jobId)
        jobs.cancel(jobId: waiting.jobId, owner: 2)
        #expect(jobs.getStatus(jobId: waiting.jobId).status == .queued)
        jobs.cancel(jobId: waiting.jobId, owner: 1)
        #expect(jobs.getStatus(jobId: waiting.jobId).status == .cancelled)
    }

    // A folder waiting inside the one being walked gets its size from that walk, with no walk of its own.
    @Test func aFolderInsideTheOneWalkedIsAnsweredByThatWalk() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test", owner: 1)
        let inside = start(jobs, "/test/sub", owner: 2)
        #expect(inside.status == .queued)
        native.finish(["/test/sub": [500, 600, 20, 3]])
        await settle()
        let status = jobs.getStatus(jobId: inside.jobId)
        #expect(status.status == .ready && status.sizeBytes == 500 && status.folderCount == 3)

        native.resolveActive()
        await settle()
        #expect(native.calls.map(\.path) == ["/test"])
    }

    // Next to run: asked for before automatic; of each, the front window's first; then in the order asked.
    @Test func runsWhatWasAskedForFirstAndTheFrontWindowsFirstAmongThem() async {
        let native = MockNative()
        let jobs = make(native)
        jobs.frontOwner = 1

        _ = start(jobs, "/test/running", owner: 1)
        _ = start(jobs, "/test/auto", owner: 1, automatic: true)
        _ = start(jobs, "/test/other-window", owner: 2)
        _ = start(jobs, "/test/front", owner: 1)
        for _ in 0..<3 {
            native.resolveActive()
            await settle()
        }
        #expect(
            native.calls.map(\.path) == ["/test/running", "/test/front", "/test/other-window", "/test/auto"])
    }

    // An automatic walk of a window not in front gives way to a measurement asked for, from any window, and to the
    // front window's automatic one; it waits again and runs after them.
    @Test func anAutomaticWalkOfAWindowBehindGivesWay() async {
        let native = MockNative()
        let jobs = make(native)
        jobs.frontOwner = 1

        let behind = start(jobs, "/test/behind", owner: 2, automatic: true)
        let asked = start(jobs, "/test/asked", owner: 3)
        #expect(native.cancelCount == 1)
        #expect(jobs.getStatus(jobId: behind.jobId).status == .queued)
        native.rejectActive(cancelledError)
        await settle()
        #expect(native.calls.last?.path == "/test/asked")
        #expect(jobs.getStatus(jobId: behind.jobId).status == .queued)

        native.resolveActive()
        await settle()
        #expect(jobs.getStatus(jobId: asked.jobId).status == .ready)
        #expect(native.calls.map(\.path) == ["/test/behind", "/test/asked", "/test/behind"])
        #expect(native.calls.last?.background == true)

        // The front window's automatic walk stops it too.
        _ = start(jobs, "/test/front", owner: 1, automatic: true)
        #expect(native.cancelCount == 2)
    }

    // An automatic walk that gave way and is stopped before its walk has ended, by Stop or by its window closing,
    // doesn't wait again: the walk is not stopped a second time, and it never runs after what it gave way to.
    @Test func anAutomaticWalkStoppedAfterGivingWayIsNotRunAgain() async {
        for closing in [false, true] {
            let native = MockNative()
            let jobs = make(native)
            jobs.frontOwner = 1

            let behind = start(jobs, "/test/behind", owner: 2, automatic: true)
            let asked = start(jobs, "/test/asked", owner: 3)
            #expect(native.cancelCount == 1)
            #expect(jobs.getStatus(jobId: behind.jobId).status == .queued)
            if closing {
                jobs.forgetOwner(2)
            } else {
                jobs.cancel(jobId: behind.jobId, owner: 2)
            }
            #expect(jobs.getStatus(jobId: behind.jobId).status == .cancelled)
            #expect(native.cancelCount == 1)
            #expect(jobs.activity.map(\.path) == ["/test/asked"])

            native.rejectActive(cancelledError)
            await settle()
            #expect(native.calls.map(\.path) == ["/test/behind", "/test/asked"])
            #expect(jobs.getStatus(jobId: behind.jobId).status == .cancelled)
            native.resolveActive()
            await settle()
            #expect(jobs.getStatus(jobId: asked.jobId).status == .ready)
            #expect(native.calls.map(\.path) == ["/test/behind", "/test/asked"])
            #expect(jobs.activity.isEmpty)
        }
    }

    // A folder moved away or replaced while it was measured fails, and the sizes of the folders inside it, kept as
    // the walk finished them, are forgotten: another folder is at that path now, or none. A walk that fails
    // otherwise keeps them.
    @Test func forgetsTheSizesInsideAFolderReplacedWhileItWasMeasured() async {
        for replaced in [true, false] {
            let native = MockNative()
            let jobs = make(native)
            let started = start(jobs, "/test")
            native.finish(["/test/inside": [100, 200, 1, 0]])
            #expect(jobs.cachedSize("/test/inside") == 100)
            var error = FolderSizeError(errnum: ENOENT, message: "ENOENT: not found")
            error.rootChanged = replaced
            native.rejectActive(error)
            await settle()
            #expect(jobs.getStatus(jobId: started.jobId).status == .error)
            #expect(jobs.cachedSize("/test/inside") == (replaced ? nil : 100))
        }
    }

    // A measurement asked for as another ends (a window measuring several folders in turn asks for the next when it
    // is told the last has ended) starts at once: the walk before it is over, so it doesn't wait. With one waiting
    // longer, that one runs first, and the new one waits its turn.
    @Test func aMeasurementAskedForAsAnotherEndsStartsAtOnce() async {
        let native = MockNative()
        var next: [String] = ["/test/b", "/test/c"]
        var statuses: [FolderSizeJobStatus] = []
        var jobs: FolderSizeJobs?
        jobs = make(
            native,
            onSettled: { _, _ in
                guard let jobs, !next.isEmpty else { return }
                statuses.append(self.start(jobs, next.removeFirst(), owner: 1).status)
            })
        guard let jobs else { return }

        _ = start(jobs, "/test/a", owner: 1)
        native.resolveActive()
        await settle()
        #expect(statuses == [.running])
        #expect(native.calls.map(\.path) == ["/test/a", "/test/b"])

        // Another window's waits behind /test/b: it runs before the one asked for as /test/b ends.
        let other = start(jobs, "/test/other", owner: 2)
        #expect(other.status == .queued)
        native.resolveActive()
        await settle()
        #expect(statuses == [.running, .queued])
        #expect(native.calls.map(\.path) == ["/test/a", "/test/b", "/test/other"])
        native.resolveActive()
        await settle()
        #expect(native.calls.map(\.path) == ["/test/a", "/test/b", "/test/other", "/test/c"])
        native.resolveActive()
        await settle()
        #expect(jobs.activity.isEmpty)
    }

    // The front window's automatic walk doesn't give way; a window coming to the front stops another's.
    @Test func theFrontWindowsAutomaticWalkDoesntGiveWay() async {
        let native = MockNative()
        let jobs = make(native)
        jobs.frontOwner = 1

        _ = start(jobs, "/test/front", owner: 1, automatic: true)
        _ = start(jobs, "/test/asked", owner: 2)
        #expect(native.cancelCount == 0)
        native.resolveActive()
        await settle()

        _ = start(jobs, "/test/behind", owner: 2, automatic: true)
        _ = start(jobs, "/test/next", owner: 3, automatic: true)
        #expect(native.calls.last?.path == "/test/asked")
        native.resolveActive()
        await settle()
        #expect(native.calls.last?.path == "/test/behind")
        #expect(native.cancelCount == 0)
        jobs.frontOwner = 3
        #expect(native.cancelCount == 1)
    }

    // Asked for too, an automatic walk no longer gives way.
    @Test func anAutomaticWalkAskedForByAnotherWindowNoLongerGivesWay() {
        let native = MockNative()
        let jobs = make(native)
        jobs.frontOwner = 1

        let walk = start(jobs, "/test/a", owner: 2, automatic: true)
        #expect(start(jobs, "/test/a", owner: 3).jobId == walk.jobId)
        _ = start(jobs, "/test/b", owner: 1)
        #expect(native.cancelCount == 0)
    }

    // A window has one automatic measurement at a time: a new one stops its other.
    @Test func aWindowsNewAutomaticMeasurementStopsItsOther() {
        let native = MockNative()
        let jobs = make(native)

        let first = start(jobs, "/test/a", owner: 1, automatic: true)
        _ = start(jobs, "/test/b", owner: 1, automatic: true)
        #expect(native.cancelCount == 1)
        #expect(jobs.getStatus(jobId: first.jobId).status == .cancelled)
    }

    // Past the limit of those waiting, the one asked for longest ago is dropped; the one running never is.
    @Test func dropsTheOldestWaitingPastTheLimit() {
        let native = MockNative()
        let jobs = make(native)

        let running = start(jobs, "/test/running", owner: 1)
        let waiting = (0...FolderSizeJobs.maxAskedWaiting).map { start(jobs, "/test/\($0)", owner: 2) }
        #expect(jobs.getStatus(jobId: waiting[0].jobId).status == .cancelled)
        #expect(waiting.dropFirst().allSatisfy { jobs.getStatus(jobId: $0.jobId).status == .queued })
        #expect(jobs.getStatus(jobId: running.jobId).status == .running)
        #expect(native.cancelCount == 0)
    }

    // A window closing stops what only it asked for.
    @Test func aWindowClosingLeavesWhatAnotherAlsoAskedFor() {
        let native = MockNative()
        let jobs = make(native)

        let shared = start(jobs, "/test/a", owner: 1)
        _ = start(jobs, "/test/a", owner: 2)
        jobs.forgetOwner(1)
        #expect(native.cancelCount == 0)
        #expect(jobs.getStatus(jobId: shared.jobId).status == .running)
        jobs.forgetOwner(2)
        #expect(native.cancelCount == 1)
    }

    @Test func subFolderCachePopulationFromWalkResults() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        // Sub-folder should be cached from the walk
        #expect(jobs.cachedSize("/test/sub") == 500)

        // Its counts come along: asking for it afterwards is a cache hit.
        let sub = start(jobs, "/test/sub")
        #expect(sub.status == .ready)
        let status = jobs.getStatus(jobId: sub.jobId)
        #expect(status.fileCount == 20)
        #expect(status.folderCount == 3)
    }

    @Test func queuedJobStartsAfterActiveFinishes() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test/a")
        let second = start(jobs, "/test/b")
        #expect(second.status == .queued)

        // Complete first job (cancel resolves with error)
        native.rejectActive(FolderSizeError(errnum: ECANCELED, message: "ECANCELLED"))
        await settle()

        // Second job should now be running
        #expect(native.calls.count == 2)
        #expect(native.calls.last?.path == "/test/b")
        #expect(native.calls.last?.background == false)
    }

    @Test func errorJobHasNullDiskBytesAndCounts() async {
        let native = MockNative()
        let jobs = make(native)

        let started = start(jobs, "/test")
        native.rejectActive(FolderSizeError(errnum: nil, message: "ENOENT: not found"))
        await settle()

        let status = jobs.getStatus(jobId: started.jobId)
        #expect(status.status == .error)
        #expect(status.sizeBytes == nil)
        #expect(status.diskBytes == nil)
        #expect(status.fileCount == nil)
        #expect(status.folderCount == nil)
        #expect(status.error == "ENOENT: not found")
    }

    @Test func keepsOnlyTheMostRecentFinishedJobsSoRepeatedCalculationsDoNotGrowWithoutBound() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        let running = start(jobs, "/walking")
        // Known already: each answered by a job that is ready at once.
        let known = (0..<1_000).map { _ in start(jobs, "/test/sub", owner: 2) }

        #expect(jobs.jobCount == 257)
        #expect(jobs.getStatus(jobId: running.jobId).status == .running)
        #expect(jobs.getStatus(jobId: known.last?.jobId ?? "").status == .ready)
        #expect(jobs.getStatus(jobId: known[0].jobId).error == "Unknown folder size job.")

        native.resolveActive()
        await settle()
        #expect(jobs.getStatus(jobId: running.jobId).status == .ready)
    }
}
