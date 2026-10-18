// Port of apps/desktop/e2e/quit.spec.ts "quitting while a folder is measured ends the process at once", windowless:
// what quitting stops, so that nothing keeps the process alive once the windows have closed
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

/// A write service with nothing to run.
private final class IdleWriteService: CoordinatorWriteService, @unchecked Sendable {
    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void { {} }
    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    { throw OperationError("idle") }
    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        throw OperationError("idle")
    }
    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool { false }
    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
        throw OperationError("idle")
    }
    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool { false }
    func cancelOperation(_ operationId: String) -> Bool { false }
}

@MainActor
@Suite struct QuitBackgroundWorkTests {
    // The whole startup disk: seconds to minutes to measure. Quitting stops the walk, and returns at once.
    // F-306 T-9b246326 T-cde7943b
    @Test func quittingWhileAFolderIsMeasuredEndsAtOnce() async throws {
        let jobs = FolderSizeJobs(native: NativeFolderSize())
        let coordinator = WriteCoordinator(writeService: IdleWriteService())
        let started = jobs.start(FolderSizeStartRequest(path: "/System/Volumes/Data", recalculate: true))
        try await Task.sleep(nanoseconds: 300_000_000)
        // The disk was measured before the app quit: there is nothing to show.
        guard jobs.getStatus(jobId: started.jobId).status == .running else { return }

        let clock = ContinuousClock()
        let began = clock.now
        await AppWriteOperations.stopBackgroundWork(coordinator, retry: nil, folderSizes: jobs)

        #expect(clock.now - began < .seconds(3))
        #expect(jobs.getStatus(jobId: started.jobId).status == .cancelled)
        // Nothing new is written once it has quit.
        #expect(coordinator.runWriteAlone { true } == nil)
    }
}
