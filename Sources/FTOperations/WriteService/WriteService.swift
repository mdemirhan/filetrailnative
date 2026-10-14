// Port of the WriteService class of packages/core/src/fs/writeService.ts: its dependencies, its state, its one write
// slot and its listeners. Analysis jobs are in WriteServiceAnalysis.swift, the paste in WriteServicePaste.swift.
import FTFoundation
import Foundation
import os

public struct WriteServiceDependencies: Sendable {
    public var fileSystem: any AnalysisFileSystem
    public var now: @Sendable () -> Date
    /// Ids "copy-op-1", "copy-op-2", … when not given.
    public var createOperationId: (@Sendable () -> String)?
    /// Ids "analysis-1", "analysis-2", … when not given.
    public var createAnalysisId: (@Sendable () -> String)?
    public var thresholds: CopyPasteThresholds
    /// Runs a paste once its analysis is ready (`executeCopyPasteFromAnalysis`); see WriteServicePaste.swift.
    public var executeCopyPaste: CopyPasteExecutor?

    public init(
        fileSystem: any AnalysisFileSystem, now: @escaping @Sendable () -> Date = { Date() },
        createOperationId: (@Sendable () -> String)? = nil, createAnalysisId: (@Sendable () -> String)? = nil,
        thresholds: CopyPasteThresholds = .writeService, executeCopyPaste: CopyPasteExecutor? = nil
    ) {
        self.fileSystem = fileSystem
        self.now = now
        self.createOperationId = createOperationId
        self.createAnalysisId = createAnalysisId
        self.thresholds = thresholds
        self.executeCopyPaste = executeCopyPaste
    }
}

/// The copy engine's own coordinator: analysis jobs, one at a time, and the paste that runs from one, one write at
/// a time. Callable from any thread; the disk is read off the calling thread.
public final class WriteService: Sendable {
    typealias Listener = @Sendable (CopyPasteProgressEvent) -> Void

    struct AnalysisJob {
        var analysisId: String
        var request: CopyPasteAnalysisRequest
        var signal: StopSignal
        var status: CopyPasteAnalysisJobStatus
        var report: CopyPasteAnalysisReport?
        var error: String?
    }

    struct State {
        var listeners: [(token: Int, listener: Listener)] = []
        var nextListenerToken = 0
        var signals: [String: StopSignal] = [:]
        var analysisJobs: [String: AnalysisJob] = [:]
        var activeOperationId: String?
        var sequence = 0
        var analysisSequence = 0
    }

    let fileSystem: any AnalysisFileSystem
    let now: @Sendable () -> Date
    let thresholds: CopyPasteThresholds
    let executeCopyPaste: CopyPasteExecutor
    private let operationIds: (@Sendable () -> String)?
    private let analysisIds: (@Sendable () -> String)?
    let state = OSAllocatedUnfairLock(initialState: State())

    public init(_ dependencies: WriteServiceDependencies) {
        fileSystem = dependencies.fileSystem
        now = dependencies.now
        thresholds = dependencies.thresholds
        executeCopyPaste = dependencies.executeCopyPaste ?? unavailableCopyPasteExecutor
        operationIds = dependencies.createOperationId
        analysisIds = dependencies.createAnalysisId
    }

    /// Tells `listener` every progress event; the returned closure stops that.
    public func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void {
        let token = state.withLock { state in
            state.nextListenerToken += 1
            state.listeners.append((state.nextListenerToken, listener))
            return state.nextListenerToken
        }
        return { [weak self] in
            self?.state.withLock { $0.listeners.removeAll { $0.token == token } }
        }
    }

    func emit(_ event: CopyPasteProgressEvent) {
        let listeners = state.withLock { $0.listeners.map(\.listener) }
        for listener in listeners {
            listener(event)
        }
    }

    /// The next operation id, made while `state` is held.
    func nextOperationId(_ state: inout State) -> String {
        if let operationIds {
            return operationIds()
        }
        state.sequence += 1
        return "copy-op-\(state.sequence)"
    }

    /// The next analysis id, made while `state` is held.
    func nextAnalysisId(_ state: inout State) -> String {
        if let analysisIds {
            return analysisIds()
        }
        state.analysisSequence += 1
        return "analysis-\(state.analysisSequence)"
    }

    static func unknownAnalysis(_ analysisId: String) -> OperationError {
        OperationError("Unknown copy/paste analysis job: \(analysisId)")
    }
}

extension WriteService.State {
    var hasActiveAnalysisJob: Bool {
        analysisJobs.values.contains { $0.status == .queued || $0.status == .analyzing }
    }

    /// Drops the analyses that have ended, but not `retainAnalysisId`, nor a finished one in `keep` (one that was
    /// cancelled or failed can't be pasted from, so it goes).
    mutating func pruneTerminalAnalysisJobs(keep: Set<String>, retaining retainAnalysisId: String? = nil) {
        for (analysisId, job) in analysisJobs {
            if analysisId == retainAnalysisId || (keep.contains(analysisId) && job.status == .complete) {
                continue
            }
            if job.status == .complete || job.status == .cancelled || job.status == .error {
                analysisJobs[analysisId] = nil
            }
        }
    }
}
