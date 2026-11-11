// What quitting stops, so that nothing keeps the process alive once the windows have closed
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service with nothing to run.
private final class IdleWriteService: CoordinatorWriteService, @unchecked Sendable {
    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void { {} }
    func analyze(_ request: CopyPasteAnalysisRequest, signal: StopSignal) async throws -> CopyPasteAnalysisReport {
        throw OperationError("idle")
    }
    func startCopyPaste(
        report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride]?
    ) throws -> CopyPasteOperationHandle {
        throw OperationError("idle")
    }
    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { false }
    func cancelOperation(_ operationId: String) -> Bool { false }
}

/// A folder walk that lasts until the test ends it, so it is still under way when the app quits however fast the
/// disk. It notes the folders it is asked to walk and each time it is told to stop; being told doesn't end it.
@MainActor
private final class HeldFolderSize: FolderSizeNative {
    @MainActor private final class Gate {
        var outcome: Result<FolderSizeResult, any Error>?
        var continuation: CheckedContinuation<FolderSizeResult, any Error>?

        func end(_ outcome: Result<FolderSizeResult, any Error>) {
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

    private(set) var walked: [String] = []
    private(set) var stops = 0
    private var gate: Gate?

    func getFolderSize(
        _ path: String, background: Bool, onFinished: @escaping @MainActor (FinishedFolders) -> Void
    ) -> Task<FolderSizeResult, any Error> {
        walked.append(path)
        let gate = Gate()
        self.gate = gate
        return Task { @MainActor in try await gate.value() }
    }

    func cancelFolderSize() {
        stops += 1
    }

    /// The walk under way ends, as a stopped walk does.
    func endWalk() {
        gate?.end(.failure(FolderSizeError.cancelled))
        gate = nil
    }
}

@MainActor
@Suite struct QuitBackgroundWorkTests {
    // Quitting stops the folder walk under way and the measurement waiting behind it, and returns without waiting for
    // the walk to end: the walk here lasts until the test ends it, so a quit that waited for it would not return.
    @Test(.timeLimit(.minutes(1)))
    func quittingWhileAFolderIsMeasuredEndsAtOnce() async {
        let native = HeldFolderSize()
        let jobs = FolderSizeJobs(native: native)
        let coordinator = WriteCoordinator(writeService: IdleWriteService(), fileSystem: NativeWriteFileSystem())
        // Two owners: one owner's second measurement would stop its first itself.
        let running = jobs.start(FolderSizeStartRequest(path: "/held/a", recalculate: true), owner: 1)
        let waiting = jobs.start(FolderSizeStartRequest(path: "/held/b", recalculate: true), owner: 2)
        #expect(running.status == .running)
        #expect(waiting.status == .queued)

        await AppWriteOperations.stopBackgroundWork(coordinator, retry: nil, folderSizes: jobs)

        // Back with the walk still under way: it was told to stop, and both measurements read stopped.
        #expect(native.stops == 1)
        #expect(jobs.getStatus(jobId: running.jobId).status == .cancelled)
        #expect(jobs.getStatus(jobId: waiting.jobId).status == .cancelled)
        // Nothing new is written, or measured, once it has quit.
        #expect(coordinator.runWriteAlone { true } == nil)
        #expect(jobs.start(FolderSizeStartRequest(path: "/held/c")).status == .cancelled)

        // The walk ends as a stopped one does, and the measurement that waited is not walked after it.
        native.endWalk()
        await settle()
        #expect(native.walked == ["/held/a"])
        #expect(jobs.getStatus(jobId: running.jobId).status == .cancelled)
    }
}
