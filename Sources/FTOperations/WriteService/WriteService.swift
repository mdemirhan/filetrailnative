// Its dependencies, its state, its one write slot, its listeners and the review of a paste. The paste is in
// WriteServicePaste.swift, its questions and Stop in WriteServiceRuntime.swift.
import FTFoundation
import Foundation
import os

public struct WriteServiceDependencies: Sendable {
    public var fileSystem: any WriteServiceFileSystem
    /// Remembers folder copies and large file copies in progress (and Replaces), so an interrupted one can be
    /// finished or undone at the next start.
    public var writeJournal: (any WriteJournal)?
    public var now: @Sendable () -> Date
    /// Ids "copy-op-1", "copy-op-2", … when not given.
    public var createOperationId: (@Sendable () -> String)?
    /// Ids "analysis-1", "analysis-2", … when not given.
    public var createAnalysisId: (@Sendable () -> String)?
    /// Runs a paste from its reviewed report; `executeCopyPasteFromAnalysis` when not given (see
    /// WriteServicePaste.swift).
    public var executeCopyPaste: CopyPasteExecutor?

    public init(
        fileSystem: any WriteServiceFileSystem, writeJournal: (any WriteJournal)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }, createOperationId: (@Sendable () -> String)? = nil,
        createAnalysisId: (@Sendable () -> String)? = nil, executeCopyPaste: CopyPasteExecutor? = nil
    ) {
        self.fileSystem = fileSystem
        self.writeJournal = writeJournal
        self.now = now
        self.createOperationId = createOperationId
        self.createAnalysisId = createAnalysisId
        self.executeCopyPaste = executeCopyPaste
    }
}

/// The copy engine's own coordinator: the review of a paste, and the paste that runs from its report, one write at a
/// time. Callable from any thread; the disk is read off the calling thread.
public final class WriteService: Sendable {
    typealias Listener = @Sendable (CopyPasteProgressEvent) -> Void

    /// A question the paste waits on, and where its answer goes.
    struct PendingResolution {
        var conflict: CopyPasteRuntimeConflict
        var answer: RuntimeAnswer
    }

    struct State {
        var listeners: [(token: Int, listener: Listener)] = []
        var nextListenerToken = 0
        var signals: [String: StopSignal] = [:]
        var pendingResolutions: [String: PendingResolution] = [:]
        /// Answers given "for the rest of this operation", by operation, then by the kind of conflict they
        /// answered (`runtimeConflictScope`).
        var standingResolutions: [String: [String: CopyPasteChoice]] = [:]
        var activeOperationId: String?
        var sequence = 0
        var analysisSequence = 0
    }

    let fileSystem: any WriteServiceFileSystem
    let writeJournal: (any WriteJournal)?
    let now: @Sendable () -> Date
    let executeCopyPaste: CopyPasteExecutor
    private let operationIds: (@Sendable () -> String)?
    private let analysisIds: (@Sendable () -> String)?
    let state = OSAllocatedUnfairLock(initialState: State())

    public init(_ dependencies: WriteServiceDependencies) {
        fileSystem = dependencies.fileSystem
        writeJournal = dependencies.writeJournal
        now = dependencies.now
        executeCopyPaste = dependencies.executeCopyPaste ?? engineCopyPasteExecutor
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

    /// Room for walking what is pasted, which goes one call deeper for each folder level: a path of 1,024 bytes
    /// can be 500 folders deep, more than a task's own stack takes.
    static let deepWalkStackSize = 16 * 1024 * 1024

    /// Runs `body` on a thread of its own, off the caller's, with room for deep folders.
    static func runWithRoomForDepth(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.stackSize = deepWalkStackSize
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// `body`'s result, worked out on a thread with room for deep folders.
    static func withRoomForDepth<T: Sendable>(name: String, _ body: @escaping @Sendable () throws -> T) async throws
        -> T
    {
        try await withCheckedThrowingContinuation { continuation in
            runWithRoomForDepth(name: name) {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

extension WriteService {
    /// Reviews a paste: each item, and what is already in its way at the destination. The disk is read on a thread of
    /// its own, with room for deep folders. Stopping `signal` ends the call at once with `StopError`, even while a read
    /// that doesn't answer holds that thread; the review itself stops at its next look at the disk.
    public func analyze(_ request: CopyPasteAnalysisRequest, signal: StopSignal) async throws
        -> CopyPasteAnalysisReport
    {
        let request = normalizeCopyPasteAnalysisRequest(request)
        let analysisId = state.withLock { nextAnalysisId(&$0) }
        let fileSystem = fileSystem
        return try await withCheckedThrowingContinuation { continuation in
            let answer = ReviewAnswer(continuation)
            guard let stopToken = signal.onStop({ answer.give(.failure(StopError())) }) else {
                answer.give(.failure(StopError()))
                return
            }
            Self.runWithRoomForDepth(name: "FileTrail paste review") {
                let outcome = Result {
                    try buildCopyPasteAnalysisReport(
                        analysisId: analysisId, request: request, fileSystem: fileSystem, signal: signal)
                }
                signal.removeHandler(stopToken)
                // A review stopped once it had read everything still counts as stopped.
                answer.give(signal.isStopped ? .failure(StopError()) : outcome)
            }
        }
    }
}

/// The answer of a review: the first of its report and its stop is given, the other dropped.
private final class ReviewAnswer: Sendable {
    private let waiting: OSAllocatedUnfairLock<CheckedContinuation<CopyPasteAnalysisReport, any Error>?>

    init(_ continuation: CheckedContinuation<CopyPasteAnalysisReport, any Error>) {
        waiting = OSAllocatedUnfairLock(initialState: continuation)
    }

    func give(_ outcome: Result<CopyPasteAnalysisReport, any Error>) {
        let continuation = waiting.withLock { waiting in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: outcome)
    }
}
