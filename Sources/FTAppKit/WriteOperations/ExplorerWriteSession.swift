// Port of the busy, progress and adoption parts of apps/desktop/src/renderer/hooks/useExplorerActions.ts (handleProgress,
// adoptWriteOperation, noteForeignWriteOperation, followForeignMoveOnScreen, takeAdoption, askForAdoption,
// applyWriteOperationCardState, isWriteOperationInFlight, releaseEndedForeignWriteOperation,
// selectionChangedSinceWriteStarted, queueWriteOperationSelection, resolveCompletedTreeSelectionPath, and the New Folder
// end of handleProgress) and of the refs of hooks/useWriteOperations.ts: one explorer window's side of the file operations
import FTFoundation
import FTOperations
import Foundation

/// An operation another window is running (`ForeignWriteOperation`): one runs at a time in the whole app, so while it
/// runs this window starts none.
struct ForeignWriteOperation: Equatable, Sendable {
    var operationId: String
    var action: WriteOperationAction
    /// The item it is on, for the notice when a drag is refused.
    var currentSourcePath: String?
}

/// What a window hears of the file operations, for its progress card, questions and results (P5-08 connects them to
/// P5-09's progress card and toasts).
enum WindowWriteEvent: Equatable, Sendable {
    /// Its own operation's card changed: starting, analyzing, queued, running, waiting for an answer (nil: gone).
    case card(WriteOperationCardState?)
    /// Its own operation's latest progress, a question (`runtimeConflict`) included.
    case progress(WriteOperationEvent)
    /// Its own operation ended. `inTabOnScreen`: it was started in the tab on screen (not taken over), so what it
    /// leaves selected and the questions about it (no Trash) belong here.
    case ended(WriteOperationEvent, inTabOnScreen: Bool)
    /// Another window's operation started or ended: this window is locked meanwhile (B-CLIP-182).
    case foreign(ForeignWriteOperation?)
}

/// What a write's end does to the tab on screen (`refreshDirectory` with its options).
struct WriteEndRefresh: Equatable, Sendable {
    /// The folder the tab shows from now on: where the one on screen went, or its parent when it was removed.
    var path: String
    /// What to select once it is read: what the write made in it (B-CLIP-140); nil to keep the selection.
    var selecting: [String]?
    /// Where the tree selection goes; nil to leave it.
    var treeSelectionPath: String?
    /// The branches of the tree read again.
    var treeReloadPaths: [String]
    /// What the write took out of its folder, which goes from the selection at once.
    var leftPaths: [String] = []
}

/// The explorer window a session belongs to, as the session sees it: its tab on screen, and what a write's end does
/// to it. The app's is its tab group; tests use their own.
@MainActor
protocol WriteSessionHost: AnyObject {
    var isClosed: Bool { get }
    /// The tab on screen (`activeTabIdRef`).
    var activeTabID: Int? { get }
    /// Its folder (`currentPathRef`).
    var currentPath: String { get }
    /// Its selection, in the order it is shown (`selectedPathsInViewOrderRef`).
    var selectedPaths: [String] { get }
    var isSearching: Bool { get }
    /// The folder selected in its tree (`getFileSystemItemPath(selectedTreeItemIdRef)`).
    var selectedTreePath: String? { get }
    /// Reads the folder again after a write, follows it, selects what the write made (`refreshDirectory`).
    func applyWriteEnd(_ refresh: WriteEndRefresh)
    /// A folder another window renamed or moved takes the tab on screen along (`followForeignMoveOnScreen`).
    func followMovesOnScreen(_ moves: [PathMove])
    /// Whether this window may start a write changed: the menu dims its write commands meanwhile.
    func writeLockChanged()
}

/// One explorer window's side of the file operations: the operation it runs or took over, another window's that
/// locks it, and what each one's end does to its tab on screen. It is the window the coordinator sends to.
@MainActor
final class ExplorerWriteSession: WriteOperationWindow {
    unowned let coordinator: WriteCoordinator
    weak var host: (any WriteSessionHost)?
    /// The explorer window it is (`ExplorerTabGroup.windowID`), for the window an operation goes to when it closes.
    var explorerWindowID = 0
    let clipboard: SharedClipboard?
    /// Tells the window of each event (for tests, and P5-08's card and toasts).
    private var observers: [(token: Weak<ExplorerWindowObservation>, handler: (WindowWriteEvent) -> Void)] = []

    /// `activeWriteOperationIdRef`: the operation this window started, or took over.
    private(set) var activeOperationId: String?
    /// `foreignWriteOperationRef`.
    private(set) var foreign: ForeignWriteOperation?
    /// `writeOperationCardState`: set from the moment a write starts here until its end.
    private(set) var card: WriteOperationCardState?
    /// `writeOperationProgressEvent`: the latest progress of this window's operation.
    private(set) var progressEvent: WriteOperationEvent?
    let early = EarlyWriteOperationEvents()
    // The operations this window took over from one that closed.
    private var adoptedOperationIds: Set<String> = []
    // The operation taken over last: what it leaves selected belonged to the window that closed.
    private var adoptedOperationId: String?
    // The tab the running operation was started from (`writeOperationTabIdRef`).
    private var startedTabID: Int?
    // What was selected, and in which folder, when the running operation started.
    private var selectionAtStart: (directoryPath: String, paths: [String])?
    // The cut a move clears once it moved something (`clipboardClearAfterMoveRef`).
    private var clipboardClearAfterMove: (operationId: String, capturedAt: String)?
    // `moveOperationSourceSurfaceRef`, for the one surface read at the end: the analysis of a move dragged out of
    // search results, and the operation it became. A review may stand between the two.
    private var moveFromSearchResults: (analysisId: String, operationId: String?)?
    /// The folder the tree selects once the write is done (Move To, Duplicate from the tree; P5-08 sets it).
    var pendingTreeSelectionPath: String?
    /// What the Undo or Redo running does, in the words of its menu item (`runningUndoLabelRef`).
    var runningUndoLabel: String?
    /// `pendingInlineRenamePathRef`: a folder made in the folder on screen, to be renamed in its row once it is listed
    /// (and selected). Leaving the folder forgets it.
    var pendingInlineRenamePath: String?

    init(coordinator: WriteCoordinator, host: any WriteSessionHost, clipboard: SharedClipboard?) {
        self.coordinator = coordinator
        self.host = host
        self.clipboard = clipboard
    }

    var isClosed: Bool { host?.isClosed ?? true }

    /// `isWriteOperationLocked`: one runs here, or in another window.
    var isWriteLocked: Bool { card != nil || foreign != nil }

    /// Tells `handler` of every event until the token goes.
    func observe(_ handler: @escaping (WindowWriteEvent) -> Void) -> ExplorerWindowObservation {
        let token = ExplorerWindowObservation()
        observers.append((Weak(token), handler))
        return token
    }

    private func notify(_ event: WindowWriteEvent) {
        observers.removeAll { $0.token.value?.isValid != true }
        for observer in observers { observer.handler(event) }
    }

    // MARK: What the coordinator sends

    func receive(_ message: WriteOperationMessage) throws {
        switch message {
        case .progress(let event):
            handleProgress(event)
        case .adopted(let adoption):
            takeAdoption(adoption)
            askForAdoption()
        }
    }

    /// Another window's operation, as every window hears it (the original's broadcast reaches the same listener).
    func otherWindowProgress(_ event: WriteOperationEvent) {
        handleProgress(event)
    }

    /// `askForAdoption`: an operation handed over while the window was still opening was told before anything
    /// listened, so it is asked for once the window listens. Each hand-over is told once.
    func askForAdoption() {
        if let adoption = coordinator.adoptedOperation(window: self) {
            takeAdoption(adoption)
        }
    }

    /// `takeAdoption`: the window that started an operation closed and this one has it now: its card, Stop and
    /// questions are here from now on. It may hear of it twice, and takes it once.
    private func takeAdoption(_ adoption: WriteOperationAdoption) {
        let operationId = adoption.operationId
        guard adoptedOperationIds.insert(operationId).inserted else { return }
        noteForeign(nil)
        early.forget(operationId)
        activeOperationId = operationId
        adoptedOperationId = operationId
        // A paste of a cut: the clipboard is cleared here when it is done, as the window that started it would have.
        if let capturedAt = adoption.clearsCutClipboard {
            clipboardClearAfterMove = (operationId, capturedAt)
        }
        if let event = adoption.event {
            handleProgress(event)
        }
    }

    // MARK: Starting

    /// `applyWriteOperationCardState`: the card of this window's operation; the first one taken records the tab and
    /// the selection it started from.
    func applyCard(_ next: WriteOperationCardState?) {
        if next != nil, card == nil {
            startedTabID = host?.activeTabID
            selectionAtStart = host.map { ($0.currentPath, $0.selectedPaths) }
        }
        let lockChanged = (next == nil) != (card == nil)
        card = next
        notify(.card(next))
        if lockChanged { host?.writeLockChanged() }
    }

    /// `adoptWriteOperation`: records the operation this window started, then plays back whatever it already said.
    /// The playback waits a moment so the caller's "queued" card goes up first.
    func adoptWriteOperation(_ operationId: String) {
        activeOperationId = operationId
        if foreign?.operationId == operationId {
            noteForeign(nil)
        }
        let kept = early.take(operationId)
        guard !kept.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for event in kept { self?.handleProgress(event) }
            }
        }
    }

    /// Clears the cut `capturedAt` once operation `operationId`, a move of it, moved something.
    func clearCutAfterMove(operationId: String, capturedAt: String) {
        clipboardClearAfterMove = (operationId, capturedAt)
    }

    /// The analysis of a move dragged out of search results.
    func noteMoveFromSearchResults(analysisId: String) {
        moveFromSearchResults = (analysisId, nil)
    }

    /// A paste started from analysis `analysisId`.
    func noteStarted(analysisId: String, operationId: String) {
        if moveFromSearchResults?.analysisId == analysisId { moveFromSearchResults?.operationId = operationId }
    }

    /// Whether operation `operationId` is a move dragged out of search results.
    func isMoveFromSearchResults(_ operationId: String) -> Bool {
        moveFromSearchResults?.operationId == operationId
    }

    // MARK: Another window's operation

    /// `noteForeignWriteOperation`: another window's operation, or none.
    private func noteForeign(_ running: ForeignWriteOperation?) {
        let previous = foreign
        foreign = running
        if previous?.operationId != running?.operationId || previous?.action != running?.action {
            notify(.foreign(running))
            host?.writeLockChanged()
        }
    }

    /// `releaseEndedForeignWriteOperation`: lets go of another window's operation the coordinator says has ended;
    /// true when it did. This window may have missed its end (B-CLIP-108).
    @discardableResult
    func releaseEndedForeign() -> Bool {
        guard let held = foreign else { return false }
        if coordinator.activeOperationId == held.operationId { return false }
        if foreign?.operationId == held.operationId {
            noteForeign(nil)
        }
        return true
    }

    /// Coming to the front: another window's operation whose end this one missed is let go of.
    func cameToFront() {
        if foreign != nil {
            releaseEndedForeign()
        }
    }

    // MARK: Progress

    /// `handleProgress`.
    func handleProgress(_ event: WriteOperationEvent) {
        guard event.operationId == activeOperationId else {
            // Another window's operation: this one starts none while it runs.
            if event.status.isTerminal {
                if foreign?.operationId == event.operationId {
                    noteForeign(nil)
                }
                followForeignMoveOnScreen(event)
            } else {
                noteForeign(
                    ForeignWriteOperation(
                        operationId: event.operationId, action: event.action,
                        currentSourcePath: event.currentSourcePath))
            }
            if activeOperationId == nil {
                early.note(event)
            }
            return
        }
        guard event.status.isTerminal else {
            let stage: WriteOperationStage =
                switch event.status {
                case .queued: .queued
                case .awaitingResolution: .awaitingResolution
                default: .running
                }
            applyCard(
                WriteOperationCardState(
                    action: event.action, stage: stage,
                    targetPath: event.result?.targetPath ?? card?.targetPath ?? host?.currentPath,
                    completedItemCount: event.completedItemCount, totalItemCount: event.totalItemCount,
                    completedByteCount: event.completedByteCount, totalBytes: event.totalBytes,
                    currentSourcePath: event.currentSourcePath))
            progressEvent = event
            notify(.progress(event))
            return
        }
        ended(event)
    }

    private func ended(_ event: WriteOperationEvent) {
        // Another tab may be on screen by now. Its folder is still read again, but what the operation leaves selected
        // belongs to the tab it was started from, or to the window it was started from, when this one took it over.
        let adopted = adoptedOperationId == event.operationId
        adoptedOperationId = nil
        let startedInTabOnScreen = !adopted && (startedTabID == nil || startedTabID == host?.activeTabID)
        startedTabID = nil
        if !startedInTabOnScreen {
            pendingTreeSelectionPath = nil
        }
        if let clear = clipboardClearAfterMove, clear.operationId == event.operationId {
            clipboardClearAfterMove = nil
            if let clipboard, (event.result?.summary.completedItemCount ?? 0) > 0,
                case .ready = clipboard.contents, clipboard.contents.capturedAt == clear.capturedAt
            {
                clipboard.set(.empty, follows: clear.capturedAt, from: nil)
            }
        }
        // The folder made in its row may have been given the next free name.
        if event.action == .newFolder, pendingInlineRenamePath != nil {
            let madePath = event.result?.items.first?.destinationPath
            pendingInlineRenamePath = event.status == .completed ? madePath : nil
        }
        activeOperationId = nil
        let selectionChanged = selectionChangedSinceWriteStarted()
        applyCard(nil)
        progressEvent = event
        notify(.ended(event, inTabOnScreen: startedInTabOnScreen))
        guard let host else { return }
        let currentPath = host.currentPath
        let refresh: WriteEndRefresh
        if let result = event.result {
            refresh = WriteEndRefresh(
                path: AfterWrite.refreshPath(result, currentPath: currentPath),
                selecting: startedInTabOnScreen
                    ? AfterWrite.selection(
                        result, currentPath: currentPath, isSearching: host.isSearching,
                        selectionChanged: selectionChanged) : nil,
                treeSelectionPath: completedTreeSelectionPath(event, result),
                treeReloadPaths: AfterWrite.treeReloadPaths(result),
                // What a Replace removed has another item at its path, which stays selected.
                leftPaths: AfterWrite.pathsLeftByWrite(result).filter { !(result.replacedPaths ?? []).contains($0) })
        } else {
            refresh = WriteEndRefresh(path: currentPath, selecting: nil, treeSelectionPath: nil, treeReloadPaths: [])
        }
        pendingTreeSelectionPath = nil
        host.applyWriteEnd(refresh)
    }

    /// `resolveCompletedTreeSelectionPath`.
    private func completedTreeSelectionPath(_ event: WriteOperationEvent, _ result: WriteOperationResult) -> String? {
        if let explicit = pendingTreeSelectionPath, event.status == .completed || event.status == .partial {
            if result.items.contains(where: { $0.status == .completed && $0.destinationPath == explicit }) {
                return explicit
            }
            // A duplicate's name ("Folder copy") is only known once it is made; it was asked for by the folder it
            // goes into, and the copy is what is selected, as in Finder.
            if event.action == .duplicate, explicit == result.targetPath,
                let duplicate = result.items.first(where: { $0.status == .completed && $0.destinationPath != nil })?
                    .destinationPath
            {
                return duplicate
            }
        }
        return AfterWrite.treeSelectionPath(result, selectedTreePath: host?.selectedTreePath)
    }

    /// `selectionChangedSinceWriteStarted`: whether the person picked something else while the operation ran.
    private func selectionChangedSinceWriteStarted() -> Bool {
        let atStart = selectionAtStart
        selectionAtStart = nil
        guard let atStart, let host, atStart.directoryPath == host.currentPath else { return false }
        let now = host.selectedPaths
        if now.count != atStart.paths.count { return true }
        let pathsAtStart = Set(atStart.paths)
        return now.contains { !pathsAtStart.contains($0) }
    }

    /// `followForeignMoveOnScreen`: a folder another window renamed or moved takes the tab on screen along (or one
    /// inside it), in place in its history.
    private func followForeignMoveOnScreen(_ event: WriteOperationEvent) {
        guard let result = event.result, AfterWrite.movedItems(result) else { return }
        let moves = ExplorerTabs.collectFollowedMoves(
            WriteOperationOutcome(
                action: result.action.rawValue, mode: result.mode.flatMap { CopyPasteMode(rawValue: $0.rawValue) },
                items: result.items.map(\.effect)))
        host?.followMovesOnScreen(moves)
    }
}
