// Port of what an explorer window shows of its file operations in apps/desktop/src/renderer/hooks/useExplorerActions.ts
// (handleProgress's end: followClipboardThroughWrite, shouldRenderCopyPasteResultDialog, pushTerminalCopyPasteToast)
// and App.tsx (the progress card in every tab): P3-05's events on P5-09's card and toasts
import AppKit
import FTFoundation
import FTOperations

/// The result's seam: a finished operation with something to read (the result sheet, CopyPaste/).
@MainActor
protocol WriteResultPresenting: AnyObject {
    func present(_ event: WriteOperationEvent, in tab: MainWindowController)
}

/// The name the result's presenter had while it was a plain notice.
typealias PlainResultNotice = CopyPasteResultPresenter

/// What one explorer window shows of its operations: the progress card in each of its tabs (Stop cancels), the
/// clipboard following what ended, the question a paused operation asks, and the toast or the result sheet.
@MainActor
final class WindowWriteUI {
    /// Where results with something to read go.
    static var resultPresenter: any WriteResultPresenting = CopyPasteResultPresenter.shared
    private static var attached: [ObjectIdentifier: WindowWriteUI] = [:]

    private weak var session: ExplorerWriteSession?
    private weak var group: ExplorerTabGroup?
    private var token: ExplorerWindowObservation?
    /// The question the window's operation waits on (`CopyPasteRuntimeConflictDialog`).
    let runtimeConflicts = RuntimeConflictAlertController()

    private init(session: ExplorerWriteSession, group: ExplorerTabGroup) {
        self.session = session
        self.group = group
    }

    /// Shows `session`'s operations in `group`'s tabs (once per session).
    static func attach(to session: ExplorerWriteSession, group: ExplorerTabGroup) {
        let key = ObjectIdentifier(session)
        attached = attached.filter { $0.value.session != nil }
        guard attached[key] == nil else { return }
        let ui = WindowWriteUI(session: session, group: group)
        ui.token = session.observe { [weak ui] event in ui?.handle(event) }
        attached[key] = ui
    }

    #if DEBUG
        /// What shows `session`'s operations (tests).
        static func attached(to session: ExplorerWriteSession) -> WindowWriteUI? {
            attached[ObjectIdentifier(session)]
        }
    #endif

    func handle(_ event: WindowWriteEvent) {
        guard let group else { return }
        // The right-click menus leave out the writes, and dim Paste, while one runs (B-CLIP-059).
        let locked = session?.isWriteLocked ?? false
        for tab in group.tabs { tab.contextMenus.isWriteOperationLocked = locked }
        switch event {
        case .card(let card):
            // The progress shows in every tab of the window (B-VIEW-171).
            for tab in group.tabs {
                guard let progress = tab.notifications?.progress else { continue }
                progress.onStop = { [weak tab] in _ = tab?.writeActions?.cancel() }
                progress.state = card
            }
        case .progress(let event):
            // The question a drop from another app runs into brings the window forward (B-CLIP-178).
            if event.status == .awaitingResolution, TabDragDrop.externalDropOperations.contains(event.operationId) {
                TabDragDrop.bringForward(group.selected?.window)
            }
            // The question the operation paused on, over the window; it goes once the operation goes on.
            runtimeConflicts.update(event, in: group.selected)
        case .ended(let event, let inTabOnScreen):
            runtimeConflicts.ended(event.operationId)
            ended(event, inTabOnScreen: inTabOnScreen)
        case .foreign:
            break
        }
    }

    private func ended(_ event: WriteOperationEvent, inTabOnScreen: Bool) {
        guard let group, let tab = group.selected else { return }
        let fromExternalDrop = TabDragDrop.externalDropOperations.remove(event.operationId) != nil
        // The clipboard follows what the write did before anything is said about it (B-CLIP-047).
        if let result = event.result, let clipboard = session?.clipboard {
            let write = ClipboardWrite(
                action: result.action.rawValue, mode: result.mode.flatMap { ClipboardMode(rawValue: $0.rawValue) },
                items: result.items.map(\.effect), replacedPaths: result.replacedPaths ?? [])
            let followed = ClipboardRules.followThroughWrite(clipboard.contents, write)
            if followed != clipboard.contents {
                clipboard.set(followed, follows: clipboard.contents.capturedAt, from: tab.windowID)
                tab.clipboardChanged()
            }
        }
        guard let result = event.result else { return }
        let undoLabel = session?.runningUndoLabel
        session?.runningUndoLabel = nil
        let summary = WriteEndSummary(
            action: event.action.rawValue, status: event.status.rawValue, targetPath: result.targetPath,
            topLevelItemCount: result.summary.topLevelItemCount, completedItemCount: result.summary.completedItemCount,
            failedItemCount: result.summary.failedItemCount, skippedItemCount: result.summary.skippedItemCount,
            cancelledItemCount: result.summary.cancelledItemCount,
            items: result.items.map {
                WriteEndSummary.Item(
                    sourcePath: $0.sourcePath, destinationPath: $0.destinationPath, status: $0.status.rawValue,
                    skipReason: $0.skipReason?.rawValue, note: $0.note)
            }, totalItemCount: event.totalItemCount, currentSourcePath: event.currentSourcePath,
            currentDestinationPath: event.currentDestinationPath)
        if WriteEndNotices.needsResultSheet(summary) {
            Self.resultPresenter.present(event, in: tab)
            // A drop from another app is still in flight until its result is read: the sheet brings the window
            // forward (B-CLIP-178).
            if fromExternalDrop { TabDragDrop.bringForward(tab.window) }
            return
        }
        if let toast = WriteEndNotices.toast(
            summary, quietOnScreen: fromExternalDrop && inTabOnScreen, isSearchMode: tab.searchRootPath != nil,
            currentPath: tab.shownFolderPath, undoLabel: undoLabel)
        {
            _ = NotificationOverlay.push(
                toast.kind == .success ? .success : .info, title: toast.title, message: toast.message, in: tab.window)
        }
    }
}
