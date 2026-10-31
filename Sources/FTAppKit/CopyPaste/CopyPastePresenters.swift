// Port of where apps/desktop/src/renderer/components/AppDialogs.tsx shows the review (:309-330) and the result
// (:512-537), the single-conflict alert of CopyPasteReviewDialog.tsx (:179-226), and of requestCopyLikePlanStart,
// retryFailedCopyPasteItems and dismissCopyPasteDialog (apps/desktop/src/renderer/hooks/useExplorerActions.ts)
import AppKit
import FTFoundation
import FTOperations

/// The review: the sheet, or for one item that already exists (a file, a package, a type mismatch) the plain alert
/// Finder asks. Either starts the paste through one guard, so it starts once.
@MainActor
final class CopyPasteReviewPresenter: PasteReviewPresenting {
    static let shared = CopyPasteReviewPresenter()

    /// `reviewStartInFlightRef`: the analysis being started; a second start of it is refused.
    private var startInFlight: String?
    /// The time the rows' dates are written against.
    var now: () -> Double = { AppClock.now.epochMilliseconds }
    /// The sheet up, if any.
    private(set) weak var sheet: CopyPasteReviewSheet?
    /// The single-conflict alert up, if any.
    private(set) weak var alert: AlertCard?

    /// The review, opened on `policy` (a retry's opens on the retry policy).
    func review(
        _ report: CopyPasteAnalysisReport, action: WriteOperationAction, policy: CopyPastePolicy,
        clearsCutClipboard: String?, actions: WindowWriteActions
    ) {
        guard let tab = actions.tab, let window = tab.window, window.contentView != nil,
            let copyLike = CopyLikeAction(action)
        else { return }
        let model = ReviewSheetModel(report: report, action: copyLike, policy: policy, now: now())
        let start: (CopyPastePolicy, [CopyPasteNodeOverride]) async -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.start(
                report, policy: $0, overrides: $1, action: action, clearsCutClipboard: clearsCutClipboard,
                actions: actions)
        }
        if let node = ReviewSheetText.singleConflict(model.review, summary: model.summary) {
            presentAlert(node, model: model, on: tab, in: window, start: start)
        } else {
            presentSheet(model, on: tab, in: window, start: start)
        }
    }

    /// `requestCopyLikePlanStart`: true once the operation is under way; false when it didn't start (busy, an
    /// expired analysis, a refusal, which is told), so the review can let the person try again.
    func start(
        _ report: CopyPasteAnalysisReport, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride],
        action: WriteOperationAction, clearsCutClipboard: String?, actions: WindowWriteActions
    ) async -> Bool {
        // A second click on the start button must not start it again.
        guard startInFlight != report.analysisId else { return false }
        startInFlight = report.analysisId
        defer { if startInFlight == report.analysisId { startInFlight = nil } }
        let outcome = await actions.startCopyPaste(
            report, policy: policy, action: action, overrides: overrides, clearsCutClipboard: clearsCutClipboard)
        if case .queued = outcome { return true }
        return false
    }

    private func presentSheet(
        _ model: ReviewSheetModel, on tab: MainWindowController, in window: NSWindow,
        start: @escaping (CopyPastePolicy, [CopyPasteNodeOverride]) async -> Bool
    ) {
        let sheet = CopyPasteReviewSheet(model: model)
        let scrim = CopyPasteDialogs.present(sheet, placement: .sheet, on: tab, in: window)
        self.sheet = sheet
        sheet.onClose = { [weak scrim] in scrim?.dismiss() }
        sheet.onStart = { [weak sheet, weak scrim] in
            // One start only: the button is busy while starting, and works again if the start failed or threw.
            guard let sheet, !sheet.starting else { return }
            sheet.starting = true
            Task { @MainActor in
                let started = await start(model.policy, model.nodeOverrides)
                if started {
                    scrim?.dismiss()
                } else {
                    sheet.starting = false
                    sheet.window?.makeFirstResponder(sheet.primaryButton)
                }
            }
        }
    }

    /// One item that already exists, asked as Finder does: Cancel aside, Replace (red; not where it can't be done),
    /// Keep Both as the default. Return is Keep Both, Escape is Cancel.
    private func presentAlert(
        _ node: ReviewNode, model: ReviewSheetModel, on tab: MainWindowController, in window: NSWindow,
        start: @escaping (CopyPastePolicy, [CopyPasteNodeOverride]) async -> Bool
    ) {
        var scrim: DialogScrim?
        var starting = false
        var card: AlertCard? { scrim?.panel as? AlertCard }
        func close() { scrim?.dismiss() }
        func choose(_ choice: CopyPasteChoice) {
            guard !starting else { return }
            starting = true
            for button in card?.allButtons ?? [] { button.isEnabled = false }
            Task { @MainActor in
                let started = await start(model.policy, [CopyPasteNodeOverride(nodeId: node.id, action: choice)])
                if started {
                    close()
                } else {
                    starting = false
                    for button in card?.allButtons ?? [] { button.isEnabled = true }
                    if let primary = card?.defaultButton { card?.window?.makeFirstResponder(primary) }
                }
            }
        }
        var buttons: [AlertButton] = []
        if node.replaceBlockedReason == nil {
            buttons.append(
                AlertButton(title: CopyPasteReview.label(.overwrite), variant: .destructive) { choose(.overwrite) })
        }
        buttons.append(AlertButton(title: CopyPasteReview.label(.keepBoth), variant: .default) { choose(.keepBoth) })
        let content = AlertContent(
            title: model.text.title, message: ReviewSheetText.singleConflictMessage(node), buttons: buttons,
            stacked: false, aside: AlertButton(title: "Cancel") { close() }, onEscape: { close() },
            onReturn: { choose(.keepBoth) })
        let shown = InWindowAlerts.present(content, in: window)
        CopyPasteDialogs.track(shown, on: tab)
        scrim = shown
        alert = shown.panel as? AlertCard
    }
}

/// What a finished operation with something to read shows: the result sheet for the copy-like actions, batch rename,
/// Undo and Redo; the original's alert for the others (`CopyPasteDialog` with `buildCopyPasteResultMessage` and
/// `buildCopyPasteResultDetailLines`).
@MainActor
final class CopyPasteResultPresenter: WriteResultPresenting {
    static let shared = CopyPasteResultPresenter()

    /// The sheet up, if any.
    private(set) weak var sheet: CopyPasteResultSheet?

    func present(_ event: WriteOperationEvent, in tab: MainWindowController) {
        guard let result = event.result else { return }
        guard WriteResultNoticeText.hasResultSheet(event.action) else {
            let summary = result.summary
            let input = WriteResultNoticeInput(
                error: result.error, totalItemCount: summary.totalItemCount,
                completedItemCount: summary.completedItemCount, failedItemCount: summary.failedItemCount,
                skippedItemCount: summary.skippedItemCount, cancelledItemCount: summary.cancelledItemCount,
                itemErrors: result.items.map(\.error))
            tab.showNotice(
                title: ProgressCardText.title(event.action, result: true),
                message: WriteResultNoticeText.message(input),
                detailLines: WriteResultNoticeText.detailLines(input))
            return
        }
        guard let window = tab.window, window.contentView != nil else { return }
        // An Undo is chosen again from the menu, with what it finds then.
        let canRetry = event.action != .undo && event.action != .redo
        let text = CopyPasteResultText(
            action: event.action, targetPath: result.targetPath, error: result.error,
            items: result.items.map(ResultItem.init), canRetry: canRetry)
        let sheet = CopyPasteResultSheet(text: text)
        let scrim = CopyPasteDialogs.present(sheet, placement: .sheet, on: tab, in: window)
        self.sheet = sheet
        // The sheet holds the folder's changes from outside, but not the operation's own read of the folder
        // (`refreshDirectory`), which the write's end asks for right after this: it goes through under the sheet, so
        // what the operation made shows, selected, behind it.
        Task { @MainActor [weak tab, weak scrim] in
            guard let tab, let scrim, !scrim.isDismissed, tab.folderChangesHeld else { return }
            tab.folderChangesHeld = false
            tab.folderChangesHeld = true
        }
        sheet.onDone = { [weak scrim] in scrim?.dismiss() }
        sheet.onRetry = { [weak self, weak scrim, weak tab] in
            scrim?.dismiss()
            guard let self, let tab else { return }
            self.retry(event, in: tab)
        }
    }

    /// `retryFailedCopyPasteItems`: the failed and never-started top-level items, analyzed again into the same folder
    /// with the retry policy (files that arrived are skipped, half-copied folders are merged), which the review opens
    /// with and a retry with nothing to review runs with. A retried move clears its cut once it moved them. A rename
    /// is tried again from its sheet.
    func retry(_ event: WriteOperationEvent, in tab: MainWindowController) {
        guard let result = event.result else { return }
        if event.action == .batchRename {
            tab.reopenBatchRename(after: event)
            return
        }
        guard let actions = tab.writeActions, CopyLikeAction(event.action) != nil else { return }
        let paths = CopyPasteResultText.retrySourcePaths(result.items.map(ResultItem.init))
        guard !paths.isEmpty else { return }
        // Only a cut of these same items is cleared, never an unrelated clipboard.
        var retriedCut: String?
        if event.action == .moveTo,
            case .ready(.cut, let sources, _, let capturedAt) = actions.session.clipboard?.contents,
            paths.contains(where: { path in sources.contains { JSStringEquality.equals($0, path) } })
        {
            retriedCut = capturedAt
        }
        let destination = result.targetPath ?? tab.shownFolderPath
        let action = event.action
        Task { @MainActor in
            let outcome = await actions.copyLike(
                mode: action == .moveTo ? .cut : .copy, sources: paths, destination: destination, action: action,
                clearsCutClipboard: retriedCut, defaultPolicy: CopyPasteReview.retryPolicy)
            if case .review(let report) = outcome {
                PasteReview.presenter.review(
                    report, action: action, policy: CopyPasteReview.retryPolicy, clearsCutClipboard: retriedCut,
                    actions: actions)
            }
        }
    }
}

/// `===` on two paths, unit for unit.
enum JSStringEquality {
    static func equals(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
}

extension AlertCard {
    /// The answers and the aside button (Cancel), which a start disables together (`disabled={starting}`).
    fileprivate var allButtons: [SystemButton] { [asideButton].compactMap { $0 } + buttons }
}
