// Port of the helpers of apps/desktop/src/main/bootstrap/writeOperations.test.ts and writeOperations.windows.test.ts:
// a write service whose events the test sends, windows that record what they hear, a clock the test moves
import FTFileSystem
import FTFoundation
import Foundation
import os

@testable import FTOperations

/// `createSubscribingWriteService`: a write service stub that hands out sequential operation ids and lets the test
/// emit progress events the way the real service does. Every call is recorded.
final class StubWriteService: CoordinatorWriteService, @unchecked Sendable {
    struct Calls {
        var startCopyPaste: [(CopyPasteExecutionRequest, Set<String>)] = []
        var resolveRuntimeConflict: [(String, String, CopyPasteChoice, Bool)] = []
        var cancelOperation: [String] = []
        var startCopyPasteAnalysis: [CopyPasteAnalysisRequest] = []
        var cancelCopyPasteAnalysis: [String] = []
        var getCopyPasteAnalysisUpdate: [String] = []
    }

    private(set) var calls = Calls()
    private var subscribers: [@Sendable (CopyPasteProgressEvent) -> Void] = []
    private var sequence = 0
    /// The analysis ids handed out, in order; "analysis-1" once they run out.
    var analysisIds: [String] = []
    var resolveAnswer = true
    var startCopyPasteImpl: ((CopyPasteExecutionRequest) throws -> CopyPasteOperationHandle)?

    func emit(_ event: CopyPasteProgressEvent) {
        for subscriber in subscribers { subscriber(event) }
    }

    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void {
        subscribers.append(listener)
        return {}
    }

    func startCopyPasteAnalysis(_ request: CopyPasteAnalysisRequest, keep: Set<String>) throws
        -> CopyPasteAnalysisStartHandle
    {
        calls.startCopyPasteAnalysis.append(request)
        let analysisId = analysisIds.isEmpty ? "analysis-1" : analysisIds.removeFirst()
        return CopyPasteAnalysisStartHandle(analysisId: analysisId, status: .queued)
    }

    func getCopyPasteAnalysisUpdate(_ analysisId: String) throws -> CopyPasteAnalysisUpdate {
        calls.getCopyPasteAnalysisUpdate.append(analysisId)
        return CopyPasteAnalysisUpdate(analysisId: analysisId, status: .complete, done: true, report: nil, error: nil)
    }

    func cancelCopyPasteAnalysis(_ analysisId: String) -> Bool {
        calls.cancelCopyPasteAnalysis.append(analysisId)
        return true
    }

    func startCopyPaste(_ start: CopyPasteExecutionRequest, keep: Set<String>) throws -> CopyPasteOperationHandle {
        calls.startCopyPaste.append((start, keep))
        if let startCopyPasteImpl { return try startCopyPasteImpl(start) }
        sequence += 1
        return CopyPasteOperationHandle(operationId: "copy-op-\(sequence)", status: .queued)
    }

    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool {
        calls.resolveRuntimeConflict.append((operationId, conflictId, action, applyToRemaining))
        return resolveAnswer
    }

    func cancelOperation(_ operationId: String) -> Bool {
        calls.cancelOperation.append(operationId)
        return true
    }
}

/// `createLifecycleSender` / `createWindow`: a window that records what it is sent, and can be closed.
@MainActor
final class TestWindow: WriteOperationWindow {
    var isClosed = false
    var throwsOnSend = false
    var onReceive: ((WriteOperationMessage) -> Void)?
    private(set) var messages: [WriteOperationMessage] = []

    func receive(_ message: WriteOperationMessage) throws {
        if throwsOnSend { throw OperationError("Object has been destroyed") }
        messages.append(message)
        onReceive?(message)
    }

    /// `progressSentTo`.
    var progress: [WriteOperationEvent] {
        messages.compactMap { if case .progress(let event) = $0 { event } else { nil } }
    }

    var adoptions: [WriteOperationAdoption] {
        messages.compactMap { if case .adopted(let adoption) = $0 { adoption } else { nil } }
    }

    func end(of operationId: String) -> WriteOperationEvent? {
        progress.first { $0.operationId == operationId && $0.status.isTerminal }
    }
}

/// A clock the test moves (`vi.useFakeTimers`).
@MainActor
final class ManualClock {
    var now: Double = 1_000_000
    private var timers: [(id: Int, at: Double, fire: @MainActor () -> Void)] = []
    private var nextId = 0

    var clock: CoordinatorClock {
        CoordinatorClock(
            now: { [unowned self] in now },
            schedule: { [unowned self] milliseconds, fire in
                nextId += 1
                let id = nextId
                timers.append((id, now + milliseconds, fire))
                return { [weak self] in self?.timers.removeAll { $0.id == id } }
            })
    }

    /// `vi.advanceTimersByTime`.
    func advance(_ milliseconds: Double) {
        let end = now + milliseconds
        while let next = timers.filter({ $0.at <= end }).min(by: { $0.at < $1.at }) {
            timers.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.fire()
        }
        now = end
    }
}

/// Opens once; everything waiting goes on.
@MainActor
final class TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = false

    func wait() async {
        if isOpen { return }
        waiting = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// What the coordinator logged (`console.error`).
@MainActor
final class LogRecorder {
    private(set) var messages: [String] = []

    func log(_ message: String, _ error: (any Error)?) {
        messages.append(message)
    }
}

enum Coordinators {
    static let skipMerge = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)

    /// `analyze`.
    @MainActor
    @discardableResult
    static func analyze(
        _ coordinator: WriteCoordinator, _ window: TestWindow, sources: [String] = ["/Users/demo/a.txt"],
        destination: String = "/Users/demo/b", mode: CopyPasteMode = .copy
    ) async throws -> CopyPasteAnalysisStartHandle {
        try await coordinator.startAnalysis(
            CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
            window: window)
    }

    /// `startPaste`: pastes from an analysis the same window started, as the app does.
    @MainActor
    @discardableResult
    static func startPaste(
        _ coordinator: WriteCoordinator, _ window: TestWindow, clearsCutClipboard: String? = nil
    ) async throws -> CopyPasteOperationHandle {
        try await analyze(coordinator, window)
        return try coordinator.startCopyPaste(
            CopyPasteStart(analysisId: "analysis-1", policy: skipMerge, clearsCutClipboard: clearsCutClipboard),
            window: window)
    }

    static func fingerprint() -> NodeFingerprint {
        NodeFingerprint(exists: true, kind: .file, size: 1, mtimeMs: 1, mode: 0o644, ino: 1, dev: 1)
    }

    /// `createRuntimeConflict`.
    static func conflict(_ conflictId: String) -> CopyPasteRuntimeConflict {
        CopyPasteRuntimeConflict(
            conflictId: conflictId, analysisId: "analysis-1", sourcePath: "/Users/demo/source/b.txt",
            destinationPath: "/Users/demo/target/b.txt", sourceKind: .file, destinationKind: .file,
            conflictClass: .fileConflict, reason: .destinationChanged, sourceFingerprint: fingerprint(),
            destinationFingerprint: fingerprint(), currentSourceFingerprint: fingerprint(),
            currentDestinationFingerprint: fingerprint())
    }

    /// `createCopyPasteTerminalEvent` / `copyEvent`.
    static func event(
        _ status: CopyPasteOperationStatus, operationId: String = "copy-op-1", mode: CopyPasteMode = .copy,
        completedItemCount: Int = 0, totalItemCount: Int = 1, runtimeConflict: CopyPasteRuntimeConflict? = nil,
        items: [CopyPasteItemResult] = [], destination: String = "/Users/demo/target", trashedPaths: [String]? = nil,
        undoLog: UndoLog? = nil
    ) -> CopyPasteProgressEvent {
        let terminal = status.isTerminal
        let result =
            terminal
            ? CopyPasteOperationResult(
                operationId: operationId, mode: mode, status: status, destinationDirectoryPath: destination,
                startedAt: Date(timeIntervalSince1970: 1_773_144_000),
                finishedAt: Date(timeIntervalSince1970: 1_773_144_000.05),
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: 1, totalItemCount: max(items.count, 1),
                    completedItemCount: status == .completed ? max(items.count, 1) : 0, failedItemCount: 0,
                    skippedItemCount: 0, cancelledItemCount: status == .cancelled ? 1 : 0, completedByteCount: 0,
                    totalBytes: nil),
                items: items, trashedPaths: trashedPaths, error: nil, undoLog: undoLog) : nil
        return CopyPasteProgressEvent(
            operationId: operationId, analysisId: "analysis-1", mode: mode, status: status,
            completedItemCount: completedItemCount, totalItemCount: totalItemCount, completedByteCount: 0,
            totalBytes: nil, currentSourcePath: nil, currentDestinationPath: nil, runtimeConflict: runtimeConflict,
            result: result)
    }

    /// `copiedEvent`: the end of a paste that copied (or moved) a.txt into /Volumes/Share, with what it did for Undo.
    static func copied(_ mode: CopyPasteMode = .copy) -> CopyPasteProgressEvent {
        event(
            .completed, mode: mode, completedItemCount: 1,
            items: [
                CopyPasteItemResult(
                    sourcePath: "/Users/demo/a.txt", destinationPath: "/Volumes/Share/a.txt", sourceKind: .file,
                    status: .completed, error: nil)
            ], destination: "/Volumes/Share",
            undoLog: .undoable(units: [
                UndoUnit(steps: [.created(path: "/Volumes/Share/a.txt", id: ItemId(dev: 9, ino: 1), stamp: nil)])
            ]))
    }

    /// A local operation that says it runs, waits for `gate`, then ends with `status`: what the original's tests do
    /// with a rename or delete whose disk call the test holds (the local operations themselves are P3-06's). Stopped
    /// while it waits, it ends "cancelled".
    @MainActor
    @discardableResult
    static func heldLocalOperation(
        _ coordinator: WriteCoordinator, _ window: TestWindow, gate: TestGate, action: WriteOperationAction = .rename,
        changedPath: String = "/Users/demo/renamed.txt", undoLog: UndoLog? = nil
    ) throws -> WriteOperationHandle {
        try coordinator.queueLocalWriteOperation(action: action, window: window) { operation in
            operation.emit(operation.progress(.running, totalItemCount: 1, currentSourcePath: "/Users/demo/source.txt"))
            await gate.wait()
            let stopped = operation.signal.isStopped
            let status: WriteOperationStatus = stopped ? .cancelled : .completed
            let now = Date()
            let item = WriteOperationItem(
                sourcePath: "/Users/demo/source.txt", destinationPath: changedPath,
                status: stopped ? .cancelled : .completed)
            operation.emit(
                operation.progress(
                    status, completedItemCount: stopped ? 0 : 1, totalItemCount: 1,
                    result: LocalWriteResults.result(
                        operationId: operation.operationId, action: action, targetPath: changedPath, startedAt: now,
                        finishedAt: now, totalItemCount: 1, completedItemCount: stopped ? 0 : 1, items: [item],
                        status: status, error: stopped ? "Operation cancelled." : nil)),
                undoLog: stopped ? nil : undoLog)
        }
    }

    /// `waitFor`: bounded by time, not by a number of turns, so a busy machine doesn't fail it.
    @MainActor
    static func waitFor<T>(_ read: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(4)
        while true {
            if let value = read() { return value }
            if Date() >= deadline { throw OperationError("Timed out waiting for condition.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// `waitForTerminalEvent`.
    @MainActor
    static func end(of operationId: String, in window: TestWindow) async throws -> WriteOperationEvent {
        try await waitFor { window.end(of: operationId) }
    }
}
