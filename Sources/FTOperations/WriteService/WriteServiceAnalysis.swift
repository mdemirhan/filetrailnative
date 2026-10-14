// Port of the analysis jobs of packages/core/src/fs/writeService.ts (startCopyPasteAnalysis,
// getCopyPasteAnalysisUpdate, cancelCopyPasteAnalysis, executeAnalysisJob)
import FTFoundation
import Foundation

extension WriteService {
    /// Room for the review's walk, which goes one call deeper for each folder level of what is pasted.
    static let analysisStackSize = 16 * 1024 * 1024

    /// Starts reviewing a paste. Starting drops the finished analyses, except those in `keep`: reviews still open
    /// in other windows, which can still be pasted from. Refused while a write runs or another analysis does.
    public func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String> = [])
        throws -> CopyPasteAnalysisStartHandle
    {
        let normalizedRequest = normalizeCopyPasteAnalysisRequest(request)
        let job = try state.withLock { state in
            if state.activeOperationId != nil {
                throw OperationError(WriteServiceMessages.writeOperationBusy)
            }
            if state.hasActiveAnalysisJob {
                throw OperationError(WriteServiceMessages.analysisBusy)
            }
            // Only once it starts: a refused start leaves the caller's own review as it was.
            state.pruneTerminalAnalysisJobs(keep: keep)
            // Already "analyzing" when this returns, as the original's job is by then.
            let job = AnalysisJob(
                analysisId: nextAnalysisId(&state), request: normalizedRequest, signal: StopSignal(),
                status: .analyzing, report: nil, error: nil)
            state.analysisJobs[job.analysisId] = job
            return job
        }
        runAnalysisJob(job)
        return CopyPasteAnalysisStartHandle(analysisId: job.analysisId, status: .queued)
    }

    public func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        guard let job = state.withLock({ $0.analysisJobs[analysisId] }) else {
            throw Self.unknownAnalysis(analysisId)
        }
        let done = job.status == .complete || job.status == .cancelled || job.status == .error
        return CopyPasteAnalysisUpdate(
            analysisId: analysisId, status: job.status, done: done, report: job.report, error: job.error)
    }

    /// Stops an analysis; false when there is no such one.
    @discardableResult
    public func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool {
        let signal = state.withLock { state -> StopSignal? in
            guard let job = state.analysisJobs[analysisId] else { return nil }
            state.analysisJobs[analysisId]?.status = .cancelled
            return job.signal
        }
        signal?.stop()
        return signal != nil
    }

    /// The review runs on a thread of its own, off the caller's, with room for deep folders.
    private func runAnalysisJob(_ job: AnalysisJob) {
        let fileSystem = fileSystem
        let thresholds = thresholds
        let thread = Thread { [self] in
            let outcome = Result {
                try buildCopyPasteAnalysisReport(
                    analysisId: job.analysisId, request: job.request, fileSystem: fileSystem, thresholds: thresholds,
                    signal: job.signal)
            }
            finishAnalysisJob(job, outcome)
        }
        thread.stackSize = Self.analysisStackSize
        thread.name = "FileTrail paste review"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func finishAnalysisJob(_ job: AnalysisJob, _ outcome: Result<CopyPasteAnalysisReport, any Error>) {
        state.withLock { state in
            // A job dropped meanwhile stays dropped.
            guard state.analysisJobs[job.analysisId] != nil else { return }
            switch outcome {
            case .success(let report):
                state.analysisJobs[job.analysisId]?.report = report
                state.analysisJobs[job.analysisId]?.status = job.signal.isStopped ? .cancelled : .complete
            case .failure(let error):
                if error is StopError || job.signal.isStopped {
                    state.analysisJobs[job.analysisId]?.status = .cancelled
                } else {
                    state.analysisJobs[job.analysisId]?.status = .error
                    state.analysisJobs[job.analysisId]?.error = errorMessage(error)
                }
            }
        }
    }
}
