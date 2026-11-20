// Gathering on the clipboard: Add to Copied Items and Add to Cut Items, with the question an item of a name already
// there asks; Remove from Clipboard; an item switched between copied and cut; Use This One Instead; and Put Back
import AppKit
import FTFoundation

/// The question an Add asks when an item it brings has the name of one on the clipboard: Keep Both (Return), Use This
/// One, or Don't Add (Escape). Tests answer it themselves.
@MainActor
enum ClipboardClashQuestion {
    static var ask: @MainActor (_ clashes: [ClipboardNameClash], _ window: NSWindow?) async -> ClipboardClashAnswer = {
        clashes, window in
        guard let window = InWindowAlerts.host(window) else { return .keepBoth }
        return await InWindowAlerts.ask(
            title: ClipboardTexts.clashTitle(clashes), message: ClipboardTexts.clashMessage(clashes),
            buttons: [
                AlertButtonSpec(ClipboardTexts.clashDontAddTitle(clashes), .plain, answer: .dontAdd),
                AlertButtonSpec(ClipboardTexts.clashUseTitle(clashes), .plain, answer: .useThisOne),
                AlertButtonSpec(ClipboardTexts.clashKeepBothTitle, .default, answer: .keepBoth),
            ], escape: .dontAdd, in: window)
    }
}

extension MainWindowController {
    /// Add to Copied Items, Add to Cut Items: `paths` join what is on the clipboard, to be copied or moved as `mode`
    /// says; on an empty clipboard it is a Copy or a Cut. An item there already with the other intent switches. An
    /// item whose name another on the clipboard has is asked about first, once for all of them.
    func addToClipboard(_ mode: ClipboardMode, paths: [String], entries: [String: ClipboardSourceEntry]) {
        guard !paths.isEmpty else { return }
        let plan = ClipboardRules.planAdd(services.clipboard.contents, mode, paths, entries: entries)
        guard !plan.clashes.isEmpty else {
            finishAdd(mode, paths: paths, entries: entries, answer: .keepBoth)
            return
        }
        Task { @MainActor [weak self] in
            let answer = await ClipboardClashQuestion.ask(plan.clashes, self?.window)
            self?.finishAdd(mode, paths: paths, entries: entries, answer: answer)
        }
    }

    /// The Add, on the clipboard as it is now: another window may have changed it while the question was open.
    private func finishAdd(
        _ mode: ClipboardMode, paths: [String], entries: [String: ClipboardSourceEntry], answer: ClipboardClashAnswer
    ) {
        let clipboard = services.clipboard
        let current = clipboard.contents
        let plan = ClipboardRules.planAdd(current, mode, paths, entries: entries)
        let (next, report) = ClipboardRules.applyAdd(
            plan, to: current, answer: answer, stamp: WindowWriteActions.clipboardStamp())
        if next != current {
            clipboard.set(next, from: windowID)
            clipboardChanged()
        }
        if let message = ClipboardTexts.addMessage(report, clipboard: next) {
            let changed = !report.added.isEmpty || !report.switched.isEmpty
            NotificationOverlay.push(changed ? .success : .info, title: message, in: window)
        } else if plan.changesNothing && report.leftOff.isEmpty {
            NSSound.beep()
        }
    }

    /// Remove from Clipboard: the items at `paths` come off; the rest stay as they are.
    func removeFromClipboard(_ paths: [String]) {
        let clipboard = services.clipboard
        let next = ClipboardRules.removeItems(clipboard.contents, paths)
        guard next != clipboard.contents else { return }
        clipboard.set(next, follows: clipboard.contents.capturedAt, from: windowID)
        clipboardChanged()
    }

    /// Copy Instead of Moving, Move Instead of Copying: the items at `paths` are pasted as `mode` says from now on.
    func setClipboardMode(_ paths: [String], to mode: ClipboardMode) {
        let clipboard = services.clipboard
        let next = ClipboardRules.setMode(
            clipboard.contents, paths, to: mode, at: WindowWriteActions.clipboardStamp())
        guard next != clipboard.contents else { return }
        clipboard.set(next, follows: clipboard.contents.capturedAt, from: windowID)
        clipboardChanged()
    }

    /// Use This One Instead: the item at `path` keeps its name when pasted, and the other of its name takes another.
    func keepClipboardName(of path: String) {
        let clipboard = services.clipboard
        let next = ClipboardRules.keepName(clipboard.contents, of: path)
        guard next != clipboard.contents else { return }
        clipboard.set(next, follows: clipboard.contents.capturedAt, from: windowID)
        clipboardChanged()
    }

    /// Put Back: the clipboard built with Add that a Copy or Cut replaced comes back, and the one it replaced is kept
    /// in its place, so a second Put Back swaps them again.
    func putBackClipboard() {
        let clipboard = services.clipboard
        guard clipboard.putBack(from: windowID) else { return }
        clipboardChanged()
        NotificationOverlay.push(.success, title: ClipboardTexts.putBackMessage(clipboard.contents), in: window)
    }

    /// A Copy or Cut just replaced a clipboard built with Add: the toast says so, with Put Back.
    func clipboardReplaced(keeping kept: CopyPasteClipboard) {
        guard let summary = ClipboardRules.describe(services.clipboard.contents) else { return }
        NotificationOverlay.push(
            .success, title: ClipboardTexts.replacedMessage(summary, replaced: kept.picks.count), in: window,
            action: (ClipboardTexts.putBackButton, { [weak self] in self?.putBackClipboard() }))
    }
}
