// Port of startCopyPaste and executeActiveOperation (packages/core/src/fs/writeService.ts): the write slot a paste
// claims, and the service's own events around it. The paste itself is `WriteServiceDependencies.executeCopyPaste`.
import FTFoundation
import Foundation

/// A paste to run from its finished analysis, with the review's choices resolved.
public struct CopyPasteExecution: Sendable {
    public var operationId: String
    public var analysisId: String
    public var report: CopyPasteAnalysisReport
    public var policy: CopyPastePolicy
    public var overrides: [CopyPasteNodeOverride]?
    public var resolvedNodes: [ResolvedCopyPasteNode]
    public var signal: StopSignal
    /// Sends a progress event to the service's listeners.
    public var emit: @Sendable (CopyPasteProgressEvent) -> Void
}

/// Runs a paste (`executeCopyPasteFromAnalysis`): its events go out through `emit`, the last with the result.
/// Throwing makes the service report the whole paste as failed (or cancelled, once stopped).
public typealias CopyPasteExecutor = @Sendable (CopyPasteExecution) async throws -> Void

/// Until the engine is plugged in, every paste fails as a whole, the way one that throws does.
let unavailableCopyPasteExecutor: CopyPasteExecutor = { _ in
    throw OperationError("Pasting isn't available yet.")
}

extension WriteService {
    /// Starts pasting from a finished analysis, keeping the finished analyses in `keep` (and this one) when it
    /// drops the others. Refused while another write runs, or for an analysis it doesn't know.
    public func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String> = []) throws
        -> CopyPasteOperationHandle
    {
        let (operationId, mode, signal) = try state.withLock { state in
            if state.activeOperationId != nil {
                throw OperationError(WriteServiceMessages.writeOperationBusy)
            }
            state.pruneTerminalAnalysisJobs(keep: keep, retaining: start.analysisId)
            // Validate before claiming the busy slot so a bad request can't leave it held.
            guard let job = state.analysisJobs[start.analysisId] else {
                throw Self.unknownAnalysis(start.analysisId)
            }
            let operationId = nextOperationId(&state)
            let signal = StopSignal()
            state.signals[operationId] = signal
            state.activeOperationId = operationId
            return (operationId, job.request.mode, signal)
        }
        emit(
            CopyPasteProgressEvent(
                operationId: operationId, analysisId: start.analysisId, mode: mode, status: .queued,
                completedItemCount: 0, totalItemCount: 0, completedByteCount: 0, totalBytes: nil,
                currentSourcePath: nil, currentDestinationPath: nil, runtimeConflict: nil, result: nil))
        Task.detached { [self] in
            await executeActiveOperation(operationId, start, signal)
        }
        return CopyPasteOperationHandle(operationId: operationId, status: .queued)
    }

    private func executeActiveOperation(_ operationId: String, _ request: CopyPasteExecutionRequest, _ signal: StopSignal)
        async
    {
        defer {
            state.withLock { state in
                state.signals[operationId] = nil
                state.analysisJobs[request.analysisId] = nil
                if state.activeOperationId == operationId {
                    state.activeOperationId = nil
                }
            }
        }
        do {
            guard let job = state.withLock({ $0.analysisJobs[request.analysisId] }) else {
                throw Self.unknownAnalysis(request.analysisId)
            }
            guard job.status == .complete, let report = job.report else {
                throw OperationError("Copy/paste analysis is not ready.")
            }
            let fileSystem = fileSystem
            let resolvedNodes = try await Self.withRoomForDepth(name: "FileTrail paste plan") {
                try resolveAnalysisWithPolicy(
                    report: report, policy: request.policy, overrides: request.overrides ?? [], fileSystem: fileSystem)
            }
            try await executeCopyPaste(
                CopyPasteExecution(
                    operationId: operationId, analysisId: request.analysisId, report: report, policy: request.policy,
                    overrides: request.overrides, resolvedNodes: resolvedNodes, signal: signal,
                    emit: { [weak self] in self?.emit($0) }))
        } catch {
            emit(failureEvent(operationId, request, error: error, cancelled: error is StopError || signal.isStopped))
        }
    }

    /// The event a paste that threw ends with: "cancelled" once stopped, else "failed" with every item failed.
    private func failureEvent(
        _ operationId: String, _ request: CopyPasteExecutionRequest, error: any Error, cancelled: Bool
    ) -> CopyPasteProgressEvent {
        let job = state.withLock { $0.analysisJobs[request.analysisId] }
        let report = job?.report
        let message = errorMessage(error)
        let mode = report?.mode ?? job?.request.mode ?? .copy
        var result: CopyPasteOperationResult?
        if !cancelled, let report {
            result = CopyPasteOperationResult(
                operationId: operationId, mode: report.mode, status: .failed,
                destinationDirectoryPath: report.destinationDirectoryPath, startedAt: now(), finishedAt: now(),
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: report.summary.topLevelItemCount, totalItemCount: report.summary.totalNodeCount,
                    completedItemCount: 0, failedItemCount: report.nodes.count, skippedItemCount: 0,
                    cancelledItemCount: 0, completedByteCount: 0, totalBytes: report.summary.totalBytes),
                items: report.nodes.map {
                    CopyPasteItemResult(
                        sourcePath: $0.sourcePath, destinationPath: $0.destinationPath, sourceKind: $0.sourceKind,
                        status: .failed, error: message)
                },
                error: message)
        }
        return CopyPasteProgressEvent(
            operationId: operationId, analysisId: request.analysisId, mode: mode,
            status: cancelled ? .cancelled : .failed, completedItemCount: 0,
            totalItemCount: report?.summary.totalNodeCount ?? 0, completedByteCount: 0,
            totalBytes: report?.summary.totalBytes, currentSourcePath: nil, currentDestinationPath: nil,
            runtimeConflict: nil, result: result)
    }
}
