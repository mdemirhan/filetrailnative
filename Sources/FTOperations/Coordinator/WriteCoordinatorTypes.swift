// WriteOperationKind, FinishedWrite, WriteOperationSender, and what the coordinator is given
import FTFileSystem
import FTFoundation
import Foundation

/// What the coordinator asks of the copy engine's write service; `WriteService` is it, tests stand in for it.
public protocol CoordinatorWriteService: AnyObject, Sendable {
    func subscribe(_ listener: @escaping @Sendable (CopyPasteProgressEvent) -> Void) -> @Sendable () -> Void
    /// Reviews a paste; stopping `signal` ends it at once with `StopError`.
    func analyze(_ request: CopyPasteAnalysisRequest, signal: StopSignal) async throws -> CopyPasteAnalysisReport
    /// Starts pasting from a review's report.
    func startCopyPaste(
        report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride]?
    ) throws -> CopyPasteOperationHandle
    func resolveRuntimeConflict(
        _ operationId: String, conflictId: String, action: CopyPasteChoice, applyToRemaining: Bool
    ) -> Bool
    func cancelOperation(_ operationId: String) -> Bool
    /// Whether the service has let go of an operation that told its end: it tells it from inside the paste, and lets
    /// go of its own slot just after.
    func hasReleased(_ operationId: String) -> Bool
}

extension CoordinatorWriteService {
    public func hasReleased(_ operationId: String) -> Bool { true }
}

extension WriteService: CoordinatorWriteService {
    public func hasReleased(_ operationId: String) -> Bool {
        state.withLock { $0.activeOperationId != operationId }
    }
}

/// A window an operation answers to: its progress, its questions and its end go there. The app tells the
/// coordinator when one closes (`windowClosed`).
@MainActor
public protocol WriteOperationWindow: AnyObject {
    /// `isDestroyed()`: closed, or on its way out.
    var isClosed: Bool { get }
    /// Sends it a message.
    func receive(_ message: WriteOperationMessage)
}

/// What the coordinator sends a window.
public enum WriteOperationMessage: Equatable, Sendable {
    /// `filetrail:writeOperationProgress`.
    case progress(WriteOperationEvent)
    /// `filetrail:writeOperationAdopted`: the operation is this window's now; the one that started it closed.
    case adopted(WriteOperationAdoption)
}

/// What kind of change the running operation is making, in the words a person would use (`WriteOperationKind`).
public enum WriteOperationKind: String, Sendable, CaseIterable {
    case copy, move, trash, delete, rename
    case batchRename = "batch_rename"
    case newFolder = "new_folder"
    case undo
    case emptyTrash = "empty_trash"

    public init(_ action: WriteOperationAction) {
        switch action {
        case .trash: self = .trash
        case .deleteImmediately: self = .delete
        case .rename: self = .rename
        case .batchRename: self = .batchRename
        case .newFolder: self = .newFolder
        case .undo, .redo: self = .undo
        default: self = .copy
        }
    }
}

/// The operation holding the write slot.
public struct ActiveWriteOperation: Equatable, Sendable {
    public var operationId: String
    public var kind: WriteOperationKind

    public init(operationId: String, kind: WriteOperationKind) {
        self.operationId = operationId
        self.kind = kind
    }
}

/// What a finished operation did, for Undo (`FinishedWrite`): its steps (or why it can't be undone), and its items
/// as the window hears of them, to name it in the Edit menu.
public struct FinishedWrite: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case write(WriteOperationAction)
        case emptyTrash
    }

    public var action: Action
    public var log: UndoLog
    public var items: [WriteOperationItem]

    public init(action: Action, log: UndoLog, items: [WriteOperationItem]) {
        self.action = action
        self.log = log
        self.items = items
    }
}

/// A request to paste from the report of a review.
public struct CopyPasteStart: Equatable, Sendable {
    /// What the review found, which the paste runs from: the report the window was shown.
    public var report: CopyPasteAnalysisReport
    public var action: WriteOperationAction
    public var policy: CopyPastePolicy
    public var overrides: [CopyPasteNodeOverride]?
    /// The cut (by when it was made) the paste clears from the clipboard once it moved something, for the window
    /// that takes it over should this one close.
    public var clearsCutClipboard: String?

    public init(
        report: CopyPasteAnalysisReport, action: WriteOperationAction = .paste, policy: CopyPastePolicy,
        overrides: [CopyPasteNodeOverride]? = nil, clearsCutClipboard: String? = nil
    ) {
        self.report = report
        self.action = action
        self.policy = policy
        self.overrides = overrides
        self.clearsCutClipboard = clearsCutClipboard
    }
}

/// An operation queued in the slot (`{ operationId, status: "queued" }`).
public struct WriteOperationHandle: Equatable, Sendable {
    public var operationId: String
    public var status: WriteOperationStatus

    public init(operationId: String, status: WriteOperationStatus = .queued) {
        self.operationId = operationId
        self.status = status
    }
}

/// An error the coordinator refuses a request with (`new Error(message)`).
public struct WriteCoordinatorError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// `ensureNoWriteOperationInFlight`.
    public static let busy = WriteCoordinatorError(WriteServiceMessages.writeOperationBusy)
    public static let quitting = WriteCoordinatorError("File Trail is quitting.")
    /// One paste is reviewed at a time.
    public static let reviewing = WriteCoordinatorError(WriteServiceMessages.analysisBusy)
}

/// Folder listings and sizes read before an operation finished may show the old contents. The app passes its
/// directory service's cache and the folder sizes.
@MainActor
public struct WriteCaches {
    /// Forgets the listings, and what the operation changed of the folder sizes; what a delete removed is taken off
    /// the sizes of the measured folders that held it.
    public var forget: (_ changedPaths: [String], _ removedItems: [RemovedItem]) -> Void
    public var writeStarting: () -> Void
    public var writeEnded: () -> Void

    public init(
        forget: @escaping (_ changedPaths: [String], _ removedItems: [RemovedItem]) -> Void = { _, _ in },
        writeStarting: @escaping () -> Void = {}, writeEnded: @escaping () -> Void = {}
    ) {
        self.forget = forget
        self.writeStarting = writeStarting
        self.writeEnded = writeEnded
    }
}

/// The time, and timers, of the progress throttle and of quitting (tests use their own).
@MainActor
public struct CoordinatorClock {
    /// Milliseconds.
    public var now: () -> Double
    /// Runs `fire` after `milliseconds` on the main actor; the returned closure cancels it.
    public var schedule: (_ milliseconds: Double, _ fire: @escaping @MainActor () -> Void) -> () -> Void

    public init(
        now: @escaping () -> Double,
        schedule: @escaping (_ milliseconds: Double, _ fire: @escaping @MainActor () -> Void) -> () -> Void
    ) {
        self.now = now
        self.schedule = schedule
    }

    public static var system: CoordinatorClock {
        CoordinatorClock(
            now: { Date().timeIntervalSince1970 * 1000 },
            schedule: { milliseconds, fire in
                let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(milliseconds, 0) / 1000, execute: item)
                return { item.cancel() }
            })
    }
}

/// What the coordinator is given besides its write service.
@MainActor
public struct WriteCoordinatorOptions {
    /// Where the home folder and its Trash are (tests use their own).
    public var homePath: String
    /// Told what each operation did, before the next one can start, so they are kept in the order they happened.
    /// Operations that changed nothing aren't told. The app fills it with the Undo history.
    public var recordUndo: ((FinishedWrite) -> Void)?
    /// Whether the disk holding `path` has a Trash. Copies onto one that hasn't can't be undone. Undo also asks it
    /// from its disk thread.
    public var diskHasTrash: (@Sendable (String) throws -> Bool)?
    /// What Undo and Redo work from. Without it there is nothing to undo.
    public var undoHistory: UndoHistory?
    /// How long an Undo's looks at its items may take, in milliseconds (tests use their own).
    public var undoCheckWithinMs: Double
    /// The batch rename a batch step of an Undo runs (`runBatchRename`, the same as a rename of several).
    public var undoBatchRename: UndoBatchRenamer
    /// Where writes that leave items under hidden names are written down (a rename of several).
    public var writeJournal: (any WriteJournal)?
    /// Every window hears how the running operation is doing, so the others know one is running and can follow
    /// what it changed. Called with each progress event and the window it was sent to.
    public var broadcastProgress: ((WriteOperationEvent, any WriteOperationWindow) -> Void)?
    /// The window an operation goes to when the one that started it closes; nil when there is none, and it is
    /// cancelled.
    public var successorOf: ((any WriteOperationWindow) -> (any WriteOperationWindow)?)?
    /// Told after the Trash was emptied, or tried to be.
    public var onTrashEmptied: (() -> Void)?
    public var caches: WriteCaches
    public var clock: CoordinatorClock
    /// What went wrong, and the error.
    public var logError: (_ message: String, _ error: (any Error)?) -> Void

    public init(
        homePath: String = NSHomeDirectory(), recordUndo: ((FinishedWrite) -> Void)? = nil,
        diskHasTrash: (@Sendable (String) throws -> Bool)? = nil, undoHistory: UndoHistory? = nil,
        undoCheckWithinMs: Double = WriteCoordinator.undoCheckWithinMs,
        undoBatchRename: @escaping UndoBatchRenamer = UndoBatchRename.runBatchRename,
        writeJournal: (any WriteJournal)? = nil,
        broadcastProgress: ((WriteOperationEvent, any WriteOperationWindow) -> Void)? = nil,
        successorOf: ((any WriteOperationWindow) -> (any WriteOperationWindow)?)? = nil,
        onTrashEmptied: (() -> Void)? = nil, caches: WriteCaches = WriteCaches(), clock: CoordinatorClock = .system,
        logError: @escaping (_ message: String, _ error: (any Error)?) -> Void = { _, _ in }
    ) {
        self.homePath = homePath
        self.recordUndo = recordUndo
        self.diskHasTrash = diskHasTrash
        self.undoHistory = undoHistory
        self.undoCheckWithinMs = undoCheckWithinMs
        self.undoBatchRename = undoBatchRename
        self.writeJournal = writeJournal
        self.broadcastProgress = broadcastProgress
        self.successorOf = successorOf
        self.onTrashEmptied = onTrashEmptied
        self.caches = caches
        self.clock = clock
        self.logError = logError
    }
}
