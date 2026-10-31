// Port of the paste flow of apps/desktop/src/renderer/hooks/useExplorerActions.ts outside the sheets
// (startPasteFromClipboard, collectLeftOutSourcePaths, the analysis issues, surfaceCopyLikePreStartFailureNotice) and
// of the "Preparing to Paste…" dialog of components/AppDialogs.tsx (:290-308)
import AppKit
import FTFoundation
import FTOperations

/// Who asked for a copy-like write (`initiator`): what may be left out of it depends on it.
enum CopyLikeInitiator: Equatable, Sendable {
    case clipboard, dragDrop, moveDialog
}

/// The review's seam: a paste whose items already exist at the destination is reviewed before anything is written;
/// the review (CopyPaste/) then calls `startCopyPaste` with the choices.
@MainActor
protocol PasteReviewPresenting: AnyObject {
    /// The review, opened on `policy` (a retry's opens on the retry policy).
    func review(
        _ report: CopyPasteAnalysisReport, action: WriteOperationAction, policy: CopyPastePolicy,
        clearsCutClipboard: String?, actions: WindowWriteActions)
}

extension PasteReviewPresenting {
    /// The review, opened on the safe policy (`SAFE_COPY_PASTE_POLICY`).
    func review(
        _ report: CopyPasteAnalysisReport, action: WriteOperationAction, clearsCutClipboard: String?,
        actions: WindowWriteActions
    ) {
        review(
            report, action: action, policy: CopyPasteReview.safePolicy, clearsCutClipboard: clearsCutClipboard,
            actions: actions)
    }
}

/// Where the review goes: the review sheet, or the single-conflict alert.
@MainActor
enum PasteReview {
    static var presenter: any PasteReviewPresenting = CopyPasteReviewPresenter.shared
}

/// "Preparing to Paste…" (`CopyPasteDialog` of type `analysis`): shown while a slow check of the destination runs, with
/// Cancel, which stops the analysis. Escape and ⌘. do what Cancel does. When it comes and goes is `PreparingDialog`'s.
@MainActor
enum PreparingSheet {
    /// Off in tests that run no windows.
    static var isEnabled = true

    /// The dialog's title for the action.
    static func title(_ action: WriteOperationAction) -> String {
        switch action {
        case .moveTo: "Preparing to Move\u{2026}"
        case .copyTo: "Preparing to Copy\u{2026}"
        case .duplicate: "Preparing to Duplicate\u{2026}"
        default: "Preparing to Paste\u{2026}"
        }
    }

    static let message = "Checking the destination for items with the same names."

    /// Shows the dialog on `window` and answers how to take it away; nil if it can't be shown now.
    static func show(_ action: WriteOperationAction, in window: NSWindow?, onCancel: @escaping () -> Void)
        -> (() -> Void)?
    {
        guard isEnabled, let window, window.isVisible, window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title(action)
        alert.informativeText = message
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.setAccessibilityIdentifier("preparingSheet")
        var dismissed = false
        alert.beginSheetModal(for: window) { response in
            if !dismissed, response == .alertFirstButtonReturn { onCancel() }
        }
        return {
            guard !dismissed else { return }
            dismissed = true
            window.endSheet(alert.window)
        }
    }
}

/// When "Preparing to Paste…" comes and goes (D-018): only if the analysis is still running after `showDelay`, so a
/// quick paste never shows it; once shown, for at least `minimumVisible`, so it never flashes.
@MainActor
final class PreparingDialog {
    static let showDelay: TimeInterval = 0.5
    static let minimumVisible: TimeInterval = 0.3

    /// Puts the dialog up, told what Cancel does, and answers how to take it away; nil if it can't be shown now.
    typealias Present = (_ onCancel: @escaping () -> Void) -> (() -> Void)?

    private let timers: any TimerScheduling
    private let present: Present
    private let onCancel: () -> Void
    private var showTimer: TimerToken?
    private var minimumTimer: TimerToken?
    private var takeAway: (() -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    init(timers: any TimerScheduling, present: @escaping Present, onCancel: @escaping () -> Void) {
        self.timers = timers
        self.present = present
        self.onCancel = onCancel
        showTimer = timers.schedule(after: Self.showDelay) { [weak self] in self?.show() }
    }

    /// The dialog is up.
    var isShowing: Bool { takeAway != nil }

    private func show() {
        showTimer = nil
        takeAway = present { [weak self] in self?.cancel() }
        guard takeAway != nil else { return }
        minimumTimer = timers.schedule(after: Self.minimumVisible) { [weak self] in
            self?.minimumTimer = nil
            self?.resume()
        }
    }

    /// Cancel: the system has taken the sheet away already.
    private func cancel() {
        guard !wasCancelled else { return }
        wasCancelled = true
        takeAway = nil
        minimumTimer?.cancel()
        minimumTimer = nil
        onCancel()
        resume()
    }

    private func resume() {
        let waiter = waiting
        waiting = nil
        waiter?.resume()
    }

    /// The analysis ended: the dialog never comes, or goes once it has been up long enough. True if Cancel was pressed
    /// by then, also while the dialog was only staying up.
    func finish() async -> Bool {
        showTimer?.cancel()
        showTimer = nil
        if minimumTimer != nil {
            await withCheckedContinuation { waiting = $0 }
        }
        dismiss()
        return wasCancelled
    }

    /// Takes it away at once (the analysis couldn't be followed).
    func dismiss() {
        showTimer?.cancel()
        showTimer = nil
        minimumTimer?.cancel()
        minimumTimer = nil
        let takeAway = takeAway
        self.takeAway = nil
        takeAway?()
        resume()
    }
}

extension WindowWriteActions {
    /// The analysis found issues (`collectLeftOutSourcePaths` and what follows it).
    func leaveOut(
        _ report: CopyPasteAnalysisReport, mode: FTOperations.CopyPasteMode, sources: [String], destination: String,
        action: WriteOperationAction, clearsCutClipboard: String?, initiator: CopyLikeInitiator?,
        onSourcesMissing: (([String]) -> Void)?, reportsRefusals: Bool, defaultPolicy: CopyPastePolicy,
        moveFromSearchResults: Bool
    ) async -> CopyLikeOutcome {
        let issues = report.issues.map {
            ClipboardTexts.Issue(
                code: $0.code.rawValue, sourcePath: $0.sourcePath, destinationPath: $0.destinationPath,
                message: $0.message)
        }
        let message = ClipboardTexts.issueMessage(
            issues, destinationDirectoryPath: report.destinationDirectoryPath, cut: report.mode == .cut)
        guard
            let leftOut = ClipboardTexts.leftOutSourcePaths(
                issues, sourcePaths: sources, alreadyInPlace: initiator != nil && report.mode == .cut,
                missing: initiator == .clipboard)
        else {
            session.applyCard(nil)
            if reportsRefusals { dialogs.showRefusal(.operation(action), message: message, in: tab?.window) }
            return .blocked(message: message)
        }
        if !leftOut.missing.isEmpty { onSourcesMissing?(leftOut.missing) }
        let out = Set((leftOut.alreadyInPlace + leftOut.missing).map(PathBox.init))
        let remaining = sources.filter { !out.contains(PathBox($0)) }
        if !remaining.isEmpty {
            return await copyLike(
                mode: mode, sources: remaining, destination: destination, action: action,
                clearsCutClipboard: clearsCutClipboard, initiator: initiator, onSourcesMissing: onSourcesMissing,
                reportsRefusals: reportsRefusals, checksBusy: false, defaultPolicy: defaultPolicy,
                moveFromSearchResults: moveFromSearchResults)
        }
        session.applyCard(nil)
        // A paste into the folder the items are in quietly does nothing, and missing items are told by the paste; a
        // drag or Move To that would move nothing says why.
        if initiator == .clipboard || !leftOut.missing.isEmpty { return .cancelled }
        if reportsRefusals { dialogs.showRefusal(.operation(action), message: message, in: tab?.window) }
        return .blocked(message: message)
    }

    /// `startPasteFromClipboard`: what the clipboard holds into `destination`. Items moved or deleted since they were
    /// copied are taken off the clipboard and the rest are pasted; which ones were left out is told afterwards. A
    /// clash goes to the review.
    @discardableResult
    func pasteFromClipboard(into destination: String) async -> CopyLikeOutcome {
        guard let clipboard = session.clipboard,
            case .ready(let mode, let sources, _, let capturedAt) = clipboard.contents
        else { return .cancelled }
        let cut = mode == .cut
        let action: WriteOperationAction = cut ? .moveTo : .paste
        if refuseWhileBusy(.operation(action)) { return .cancelled }
        var missing: [String] = []
        let windowID = tab?.windowID
        let outcome = await copyLike(
            mode: cut ? .cut : .copy, sources: sources, destination: destination, action: action,
            // This cut, and not one made while the review is open, is cleared.
            clearsCutClipboard: cut ? capturedAt : nil, initiator: .clipboard,
            onSourcesMissing: { paths in
                missing += paths
                let now = clipboard.contents
                clipboard.set(ClipboardRules.dropPaths(now, paths), follows: now.capturedAt, from: windowID)
            }, reportsRefusals: false, checksBusy: false)
        if case .review(let report) = outcome {
            PasteReview.presenter.review(
                report, action: action, clearsCutClipboard: cut ? capturedAt : nil, actions: self)
        }
        let window = tab?.window
        guard !missing.isEmpty else {
            switch outcome {
            case .blocked(let message), .error(let message):
                if message == WriteDialogs.busyMessage {
                    dialogs.showBusy(.operation(action), in: window)
                } else {
                    dialogs.showRefusal(.operation(action), message: message, in: window)
                }
            default: break
            }
            return outcome
        }
        let missingMessage = ClipboardTexts.missingClipboardItems(missing, cut: cut)
        switch outcome {
        case .blocked(let message), .error(let message):
            dialogs.showRefusal(.operation(action), message: "\(missingMessage) \(message)", in: window)
        default:
            let title =
                ClipboardTexts.missingClipboardItemsTitle(missing: missing.count, requested: sources.count, cut: cut)
                ?? WriteStartAction.operation(action).failureTitle
            dialogs.show(title, missingMessage, window)
        }
        return outcome
    }
}
