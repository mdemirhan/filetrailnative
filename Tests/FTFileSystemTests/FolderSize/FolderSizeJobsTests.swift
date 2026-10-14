// Ports the createFolderSizeHandlers cases of apps/desktop/src/main/bootstrap/responseCache.test.ts
import Foundation
import Testing

@testable import FTFileSystem

/// A walker the test drives by hand: the walk under way finishes folders, resolves or rejects when told.
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

private let cancelledError = FolderSizeError(code: "ECANCELLED", message: "cancelled")

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
        _ native: MockNative, homePath: String = NSHomeDirectory(), onSettled: ((Int?, String) -> Void)? = nil
    ) -> FolderSizeJobs {
        FolderSizeJobs(native: native, homePath: homePath, onSettled: onSettled)
    }

    private func start(
        _ jobs: FolderSizeJobs, _ path: String, owner: Int? = nil, recalculate: Bool = false, automatic: Bool = false
    )
        -> FolderSizeStartResponse
    {
        jobs.start(FolderSizeStartRequest(path: path, recalculate: recalculate, automatic: automatic), owner: owner)
    }

    // The window that asked hears when its measurement ends, whichever way, and only once.
    // T-67a01e63 F-188
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
        native.rejectActive(FolderSizeError(code: nil, message: "EIO"))
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

    // T-3e688ab6 F-142
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

    // T-9ebf15ce F-142 F-187
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

    // T-3e7ee95c F-142 F-188
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
    // T-9b2a9606 F-142 F-188
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
    // T-e1732b0f F-142
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
    // T-6232afa5 F-142
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

        let started = ContinuousClock.now
        FolderSizeWrites.forget(changedPaths: changed)
        // Well under 100 ms on a laptop; the bound only catches going back to every pair.
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(jobs.cachedSize("/Users/demo/Library/c7/d7") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library/c7") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library") == nil)
        #expect(jobs.cachedSize("/Users/demo/Library/c8/d8") == 1)
    }

    // A home folder's walk stores far more sizes than a limit of 100,000 kept, and the first finished, often
    // folders directly in the home folder, showed no size afterwards.
    // T-0387868c F-186
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

    // T-20c6d192 F-142
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

    // T-5dddca5b F-142 F-191 F-192
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

    // T-356dcb8e F-142 F-189
    @Test func learnsThatTheTrashCantBeReadFromMeasuringTheTrashItself() async {
        let native = MockNative()
        let jobs = make(native, homePath: "/Users/demo")
        _ = start(jobs, "/Users/demo/.Trash")
        native.rejectActive(FolderSizeError(code: "EPERM", message: "denied"))
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
    // T-debd8940 F-142
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

    // T-ef1e8709 F-142 F-190
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

    // T-8eb241c9 F-142 F-190
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

    // T-a8f8c8e4 F-142
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
    // T-916feea7 F-142
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

    // T-3e1383e0 F-142 F-187
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

    // T-82cdae2b F-142 F-189
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

    // T-23802c3f F-142
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
    // T-4883170d F-142 F-190
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

    // T-d372879d F-142
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
    // must be stored in a moment.
    // T-2cdd29eb F-186
    @Test func keepsUpWithAWalkThatStoresHundredsOfThousandsOfSizes() async {
        let native = MockNative()
        let jobs = make(native)
        _ = start(jobs, "/Users/demo")
        let started = ContinuousClock.now
        for take in 0..<20 {
            var dirs: [String: [Int64]] = [:]
            for index in (take * 10_000)..<((take + 1) * 10_000) {
                dirs["/Users/demo/Library/c\(index % 400)/d\(index)"] = [1, 1, 1, 0]
            }
            native.finish(dirs)
            // Lets the rest of the app run between takes, as it does between the walk's.
            await Task.yield()
        }
        // About a second on a laptop; the bound only catches going back to one at a time.
        #expect(ContinuousClock.now - started < .seconds(6))
        #expect(jobs.cachedSize("/Users/demo/Library/c399/d199999") == 1)
        #expect(jobs.cachedSize("/Users/demo/Library/c0/d0") == 1)
    }

    @MainActor @Suite struct AWindowThatGoesAway {
        // T-2b5eb9b3 F-142
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

        // T-8a42956f F-142
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

        // T-f8372e10 F-142
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
        // T-e6221bff F-142
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

        // T-6b917767 F-142
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

        // T-7c63c265 F-142
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
        // T-d141735c F-186 F-183
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

        // T-3ce960c3 F-186 F-183
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

        // T-b388a294 F-142
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
        // T-3b12318f F-142 F-190
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
        // T-e95334ab F-142
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

        // T-67c839c9 F-142 F-189
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

    // T-c59e8970 F-142
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

    // T-94e1d120 F-142
    @Test func cancelMarksJobAsCancelledAndCallsNativeCancel() {
        let native = MockNative()
        let jobs = make(native)

        let started = start(jobs, "/test")
        jobs.cancel(jobId: started.jobId)
        #expect(native.cancelCount > 0)

        #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
    }

    // T-702422e8 F-142
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

    // T-cef0a829 F-142 F-187
    @Test func newStartWhileActiveCancelsPreviousAndQueues() {
        let native = MockNative()
        let jobs = make(native)

        let first = start(jobs, "/test/a")
        #expect(first.status == .running)

        let second = start(jobs, "/test/b")
        #expect(second.status == .queued)
        #expect(native.cancelCount == 1)

        // First job was cancelled
        #expect(jobs.getStatus(jobId: first.jobId).status == .cancelled)
    }

    // T-f81a9629 F-142 F-187
    @Test func leavesAnotherWindowsWalkRunningAndQueuesBehindIt() async {
        let native = MockNative()
        let jobs = make(native)

        let first = start(jobs, "/test/a", owner: 1)
        let second = start(jobs, "/test/b", owner: 2)
        #expect(second.status == .queued)
        #expect(native.cancelCount == 0)
        #expect(jobs.getStatus(jobId: first.jobId).status == .running)

        // The second window asks again: its own waiting job gives way, the first window's walk still runs.
        let third = start(jobs, "/test/c", owner: 2)
        #expect(jobs.getStatus(jobId: second.jobId).status == .cancelled)
        #expect(third.status == .queued)
        #expect(native.cancelCount == 0)

        native.resolveActive()
        await settle()
        #expect(jobs.getStatus(jobId: first.jobId).status == .ready)
        #expect(native.calls.last?.path == "/test/c")
        #expect(native.calls.last?.background == false)

        // The first window's next walk stops none of the second's.
        _ = start(jobs, "/test/d", owner: 1)
        #expect(native.cancelCount == 0)
    }

    // T-fdee27bd F-186
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

    // T-702383ad F-142 F-187
    @Test func queuedJobStartsAfterActiveFinishes() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test/a")
        let second = start(jobs, "/test/b")
        #expect(second.status == .queued)

        // Complete first job (cancel resolves with error)
        native.rejectActive(FolderSizeError(code: "ECANCELLED", message: "ECANCELLED"))
        await settle()

        // Second job should now be running
        #expect(native.calls.count == 2)
        #expect(native.calls.last?.path == "/test/b")
        #expect(native.calls.last?.background == false)
    }

    // T-d553078d F-142
    @Test func errorJobHasNullDiskBytesAndCounts() async {
        let native = MockNative()
        let jobs = make(native)

        let started = start(jobs, "/test")
        native.rejectActive(FolderSizeError(code: nil, message: "ENOENT: not found"))
        await settle()

        let status = jobs.getStatus(jobId: started.jobId)
        #expect(status.status == .error)
        #expect(status.sizeBytes == nil)
        #expect(status.diskBytes == nil)
        #expect(status.fileCount == nil)
        #expect(status.folderCount == nil)
        #expect(status.error == "ENOENT: not found")
    }

    // T-8372d0d7 F-186
    @Test func clearCacheEmptiesTheFolderSizeCache() async {
        let native = MockNative()
        let jobs = make(native)

        _ = start(jobs, "/test")
        native.resolveActive()
        await settle()

        #expect(jobs.cachedSize("/test") == 1000)
        jobs.clearCache()
        #expect(jobs.cachedSize("/test") == nil)
    }

    // T-e5c55810 F-142
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
