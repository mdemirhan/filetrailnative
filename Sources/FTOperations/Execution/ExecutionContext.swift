// Port of ExecutionContext, UndoRecorder, CopiedItem, the error classes and the item lists of
// packages/core/src/fs/copyPasteExecution.ts
import FTFoundation
import Foundation
import os

let notStartedMessage = "Not started because the operation was stopped."
let cancelledMessage = "Operation cancelled."
/// How many times one item may run into something new at its destination before the paste gives up on it (each
/// time asks, or applies a standing answer).
let maxRuntimeAttempts = 5

/// The answer to a runtime question, which may come later from another thread (the window). The question is
/// registered before it goes out, so an answer given right away isn't lost.
public final class RuntimeAnswer: Sendable {
    private struct State {
        var answered = false
        var answer: CopyPasteChoice?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    /// An answer known already.
    public static func immediate(_ answer: CopyPasteChoice?) -> RuntimeAnswer {
        let pending = RuntimeAnswer()
        pending.resolve(answer)
        return pending
    }

    /// Answers the question (nil: dropped, unanswered). Only the first answer counts.
    public func resolve(_ answer: CopyPasteChoice?) {
        let first = state.withLock { state -> Bool in
            guard !state.answered else { return false }
            state.answered = true
            state.answer = answer
            return true
        }
        if first {
            semaphore.signal()
        }
    }

    /// Waits for the answer, on this thread.
    func wait() -> CopyPasteChoice? {
        semaphore.wait()
        semaphore.signal()
        return state.withLock { $0.answer }
    }
}

/// What a paste is run with (`executeCopyPasteFromAnalysis`'s arguments).
public struct CopyPasteRun: Sendable {
    public var operationId: String
    public var report: CopyPasteAnalysisReport
    public var mode: CopyPasteMode
    public var policy: CopyPastePolicy
    /// The review's per-item choices, applied again when an item is re-resolved at runtime.
    public var overrides: [CopyPasteNodeOverride]
    public var fileSystem: any WriteServiceFileSystem
    public var now: @Sendable () -> Date
    public var signal: StopSignal
    public var resolvedNodes: [ResolvedCopyPasteNode]
    public var emit: @Sendable (CopyPasteProgressEvent) -> Void
    /// Registers a question and returns its answer to come.
    public var requestResolution: @Sendable (CopyPasteRuntimeConflict) -> RuntimeAnswer
    /// An answer already given for "the rest of this operation", used without asking again.
    public var autoResolve: @Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?
    public var writeJournal: (any WriteJournal)?

    public init(
        operationId: String, report: CopyPasteAnalysisReport, mode: CopyPasteMode, policy: CopyPastePolicy,
        overrides: [CopyPasteNodeOverride] = [], fileSystem: any WriteServiceFileSystem,
        now: @escaping @Sendable () -> Date = { Date() }, signal: StopSignal = StopSignal(),
        resolvedNodes: [ResolvedCopyPasteNode], emit: @escaping @Sendable (CopyPasteProgressEvent) -> Void,
        requestResolution: @escaping @Sendable (CopyPasteRuntimeConflict) -> RuntimeAnswer = { _ in
            .immediate(nil)
        },
        autoResolve: @escaping @Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice? = { _ in nil },
        writeJournal: (any WriteJournal)? = nil
    ) {
        self.operationId = operationId
        self.report = report
        self.mode = mode
        self.policy = policy
        self.overrides = overrides
        self.fileSystem = fileSystem
        self.now = now
        self.signal = signal
        self.resolvedNodes = resolvedNodes
        self.emit = emit
        self.requestResolution = requestResolution
        self.autoResolve = autoResolve
        self.writeJournal = writeJournal
    }
}

/// A step of the picked item being worked on. A file it made has its id read when the item is done, in the
/// same look as its stamp (see closeUndoUnit).
enum RecordingStep {
    case step(UndoStep)
    case createdFile(path: String)
}

/// Steps are kept only for the items the person picked: undoing one undoes everything inside it. A merge, a
/// move to another disk or a permanent delete anywhere makes the whole paste one that can't be undone, but only
/// once it has changed something: a merge whose items were all there already leaves Undo as it was.
struct UndoRecorder {
    var topLevelNodeIds: Set<NameKeys.Exact>
    /// The steps of the picked item being worked on, or nil between items.
    var unit: [RecordingStep]?
    var units: [UndoUnit] = []
    var cantUndo: CantUndoReason?
    /// Why the picked item being worked on can't be undone, should it change anything.
    var pendingCantUndo: CantUndoReason?
}

/// An item a move to another disk copied: where (`path`), and the original as it was copied (`source`), a change
/// the person agreed to go on with included. The copy must still match it, as large, before the original goes.
struct CopiedItem {
    var path: String
    var source: NodeFingerprint
}

/// What every step of one paste shares: what the original's context keeps in objects its copies share.
final class ExecutionShared {
    /// Every destination this paste planned or has written so far (`destinationPathKey`), so a runtime "Keep
    /// Both" never takes a name another item will use.
    var reservedPaths: Set<NameKeys.Exact>
    /// Every destination this paste has written so far (`destinationPathKey`), and the same by folder as written
    /// (see assertNotWrittenByThisPaste).
    var writtenPaths: Set<NameKeys.Exact> = []
    var writtenByFolder: [NameKeys.Exact: [String]] = [:]
    /// Shared by every step so progress survives an item that fails half way.
    var completedItemCount = 0
    var completedByteCount: Int64 = 0
    /// What this paste did, for Undo.
    var undo: UndoRecorder
    /// The ids of the folders items were in, read once per paste.
    var folderIds = FolderIds()
    /// Where the items a Replace moved out of the way went in the Trash, which they changed.
    var trashedPaths: [String] = []
    var replacedPaths: [String] = []
    /// The files and links a move to another disk copied under a hidden name, by the path of their original:
    /// each original is removed only once its copy is checked (see removeMovedSources).
    var copiedForMove: [NameKeys.Exact: CopiedItem] = [:]
    /// The folders a move copied whose own metadata (tags, flags, ACLs) the copy couldn't take, by the path of
    /// their original: the original keeps it, so it isn't removed.
    var metadataNotCopied: Set<NameKeys.Exact> = []
    /// Items whose original changed after the review and that the person went on with, as they were copied then,
    /// by path: a move removes the originals it copied (a folder saved anew holds other items), not the ones the
    /// review saw.
    var acceptedNodes: [NameKeys.Exact: ResolvedCopyPasteNode] = [:]

    init(reservedPaths: Set<NameKeys.Exact>, undo: UndoRecorder) {
        self.reservedPaths = reservedPaths
        self.undo = undo
    }
}

/// One step's view of the paste. A step that builds an item under a hidden name works on a copy of it
/// (`with`), as the original spreads its context: the copy shares what the paste shares, and has its own
/// settings and its own count of items to go.
// Used by the paste's own thread; a large file's progress is read on the copy's timer while that thread waits
// in the copy.
final class ExecutionContext: @unchecked Sendable {
    let operationId: String
    let report: CopyPasteAnalysisReport
    var mode: CopyPasteMode
    let policy: CopyPastePolicy
    let overrides: [CopyPasteNodeOverride]
    let fileSystem: any WriteServiceFileSystem
    let signal: StopSignal
    let emit: @Sendable (CopyPasteProgressEvent) -> Void
    let requestResolution: @Sendable (CopyPasteRuntimeConflict) -> RuntimeAnswer
    let autoResolve: @Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?
    let destinationDev: Int64?
    let caseSensitive: Bool
    var totalItemCount: Int
    let totalBytes: Int64?
    let writeJournal: (any WriteJournal)?
    let shared: ExecutionShared
    /// Maps a path being written to the path people know it by: while an item is built under a hidden name,
    /// progress and questions still show the final name.
    var displayPath: ((String) -> String)?
    /// False while a Replace builds its new item under a hidden name: that isn't a step anyone could undo, only
    /// the swap that follows is.
    var recordsUndo = true
    /// While an item is built under a hidden name (a Replace's new item, or a folder copied or moved to another
    /// disk, see executeStagedDirectory): what the paste is (`.cut` for a move). What is inside is then written
    /// straight in, never built aside again.
    var stagingFor: CopyPasteMode?
    /// The folder being built under a hidden name, whose own metadata waits until it has its real name: a copied
    /// rule against deleting it (a copy of ~/Documents has one) would keep it from being renamed into place.
    var metadataLaterFor: String?
    /// The folder made already, under a name of its own reserved for it (see reserveStagingFolder): it is
    /// filled, not made again.
    var folderMadeAt: String?
    /// Where the paste's items really are, looked up once per paste (Replace's).
    var pastedItems: PastedItems?

    init(_ run: CopyPasteRun, destinationDev: Int64?, totalItemCount: Int, totalBytes: Int64?, shared: ExecutionShared)
    {
        operationId = run.operationId
        report = run.report
        mode = run.mode
        policy = run.policy
        overrides = run.overrides
        fileSystem = run.fileSystem
        signal = run.signal
        emit = run.emit
        requestResolution = run.requestResolution
        autoResolve = run.autoResolve
        self.destinationDev = destinationDev
        caseSensitive = run.report.destinationCaseSensitive
        self.totalItemCount = totalItemCount
        self.totalBytes = totalBytes
        writeJournal = run.writeJournal
        self.shared = shared
    }

    private init(copying other: ExecutionContext) {
        operationId = other.operationId
        report = other.report
        mode = other.mode
        policy = other.policy
        overrides = other.overrides
        fileSystem = other.fileSystem
        signal = other.signal
        emit = other.emit
        requestResolution = other.requestResolution
        autoResolve = other.autoResolve
        destinationDev = other.destinationDev
        caseSensitive = other.caseSensitive
        totalItemCount = other.totalItemCount
        totalBytes = other.totalBytes
        writeJournal = other.writeJournal
        shared = other.shared
        displayPath = other.displayPath
        recordsUndo = other.recordsUndo
        stagingFor = other.stagingFor
        metadataLaterFor = other.metadataLaterFor
        folderMadeAt = other.folderMadeAt
        pastedItems = other.pastedItems
    }

    /// `{ ...context, … }`: a copy with some settings changed.
    func with(_ change: (ExecutionContext) -> Void) -> ExecutionContext {
        let copy = ExecutionContext(copying: self)
        change(copy)
        return copy
    }

    /// `getFlags` as the lock checks take it.
    var getFlags: (String) throws -> UInt32 {
        let fileSystem = fileSystem
        return { try fileSystem.getFlags($0) }
    }
}

// MARK: Errors

/// Part of an item being built under a hidden name couldn't be cleared away (an incomplete package inside it):
/// the whole hidden copy is given up, never put in place.
struct StagingCleanupError: CodedError {
    let original: any Error
    var code: String? { nil }
    var message: String { describeCopyPasteError(original) }
}

/// Something appeared at the destination while writing to it (EEXIST). Handled like a runtime conflict: the
/// person decides what happens to the item.
struct DestinationTakenError: CodedError {
    let original: any Error
    var code: String? { nil }
    var message: String { errorMessage(original) }
}

/// A stop inside a folder, carrying what was already done inside it for the result.
struct CancelledWithItemsError: CodedError {
    let childItems: ItemList
    var code: String? { nil }
    var message: String { cancelledMessage }
}

/// An error and where its item was headed when it failed, when that differs from the plan (a runtime "Keep
/// Both" picked another name): the original's `failedDestinations` map, which keeps the first place set.
struct PlacedError: CodedError {
    let underlying: any Error
    let destinationPath: String
    var code: String? { errorCode(underlying) }
    var message: String { errorMessage(underlying) }

    static func placed(_ error: any Error, at destinationPath: String) -> any Error {
        error is PlacedError ? error : PlacedError(underlying: error, destinationPath: destinationPath)
    }
}

/// The error itself, without the place it was headed for.
func rootError(_ error: any Error) -> any Error {
    (error as? PlacedError)?.underlying ?? error
}

/// Where a failed item was headed, when that was noted.
func failedDestination(_ error: any Error) -> String? {
    (error as? PlacedError)?.destinationPath
}

/// `isAbortError`: an AbortError, or any error whose message says "aborted".
func isAbortError(_ error: any Error) -> Bool {
    let root = rootError(error)
    if root is StopError || root is CancelledWithItemsError {
        return true
    }
    return errorMessage(root).lowercased().contains("aborted")
}

// MARK: Item lists

/// What was done inside a folder, for the result: its items, with the lists of the folders in it kept as they
/// are, so a deep item isn't copied again at every folder above it. Made one list once, at the end (see
/// appendItems).
indirect enum ItemListElement: Sendable {
    case item(CopyPasteItemResult)
    case list(ItemList)
}

typealias ItemList = [ItemListElement]

/// Adds the items of `items` to `target` in order, the lists of folders in it included.
func appendItems(_ target: inout [CopyPasteItemResult], _ items: ItemList) {
    for element in items {
        switch element {
        case .item(let item): target.append(item)
        case .list(let list): appendItems(&target, list)
        }
    }
}

func flattenItems(_ items: ItemList) -> [CopyPasteItemResult] {
    var target: [CopyPasteItemResult] = []
    appendItems(&target, items)
    return target
}

func countFailedItems(_ items: ItemList) -> Int {
    var count = 0
    for element in items {
        switch element {
        case .item(let item): count += item.status == .failed ? 1 : 0
        case .list(let list): count += countFailedItems(list)
        }
    }
    return count
}

/// Whether any item in `items` (at any depth) wasn't done.
func hasItemNotDone(_ items: ItemList) -> Bool {
    for element in items {
        switch element {
        case .item(let item): if item.status != .completed { return true }
        case .list(let list): if hasItemNotDone(list) { return true }
        }
    }
    return false
}

/// What executing one item came to.
struct ExecuteNodeResult {
    enum Status { case completed, skipped, failed }

    var itemStatus: Status
    var skipReason: CopyPasteItemResult.SkipReason?
    var error: String?
    /// Where the item ended up (or was headed), after any runtime answer.
    var destinationPath: String
    /// Children to surface in the result (files, and folders that failed themselves).
    var childItems: ItemList

    static func skipped(_ reason: CopyPasteItemResult.SkipReason, _ destinationPath: String) -> ExecuteNodeResult {
        ExecuteNodeResult(
            itemStatus: .skipped, skipReason: reason, error: nil, destinationPath: destinationPath, childItems: [])
    }

    var itemResultStatus: CopyPasteItemResult.Status {
        switch itemStatus {
        case .completed: .completed
        case .skipped: .skipped
        case .failed: .failed
        }
    }
}
