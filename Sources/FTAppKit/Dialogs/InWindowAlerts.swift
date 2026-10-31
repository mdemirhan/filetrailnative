// Port of apps/desktop/src/renderer/components/{ActionNoticeDialog,CopyPasteDialog,TextPromptDialog}.tsx and of which
// alert AppDialogs.tsx (203-430) shows for what, with which words and which default
import AppKit
import FTFoundation

/// The alerts drawn in a window (`ActionNoticeDialog`, `CopyPasteDialog`, `TextPromptDialog`): each is shown over the
/// window it is for, answered with a button, Return or Escape.
@MainActor
enum InWindowAlerts {
    /// The window an alert goes on when none is named: the one in front.
    static func host(_ window: NSWindow?) -> NSWindow? {
        let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        return window?.contentView == nil ? nil : window
    }

    /// Shows `content` over `window` and returns its scrim. `onClose` hears the window closing under it.
    @discardableResult
    static func present(_ content: AlertContent, in window: NSWindow, onWindowClose: (() -> Void)? = nil)
        -> DialogScrim
    {
        let scrim = DialogScrim(panel: AlertCard(content), placement: .centered)
        scrim.onWindowClose = onWindowClose
        scrim.present(in: window)
        return scrim
    }

    /// Asks with `buttons`, Escape answering `escape`; the alert goes once answered.
    static func ask<Answer: Equatable & Sendable>(
        title: String, message: String?, buttons: [AlertButtonSpec<Answer>], escape: Answer,
        stacked: Bool? = nil, accessory: (any AlertAccessory)? = nil, in window: NSWindow
    ) async -> Answer {
        await withCheckedContinuation { continuation in
            var answered = false
            var scrim: DialogScrim?
            @MainActor func answer(_ value: Answer) {
                guard !answered else { return }
                answered = true
                scrim?.dismiss()
                continuation.resume(returning: value)
            }
            let content = AlertContent(
                title: title, message: message,
                buttons: buttons.map { spec in
                    AlertButton(title: spec.title, variant: spec.variant) { answer(spec.answer) }
                }, stacked: stacked, accessory: accessory, onEscape: { answer(escape) })
            scrim = present(content, in: window) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: escape)
            }
        }
    }

    /// `ActionNoticeDialog` (and `CopyPasteDialog` with one OK): a notice, its detail list under the message. Return
    /// and Escape dismiss it too.
    static func notice(
        title: String, message: String, detailLines: [String] = [], in window: NSWindow,
        onClose: @escaping () -> Void = {}
    ) {
        let list = detailLines.isEmpty ? nil : DetailListView(lines: detailLines)
        Task { @MainActor in
            _ = await ask(
                title: title, message: message, buttons: AlertButtons.notice, escape: .cancel, accessory: list,
                in: window)
            onClose()
        }
    }

    /// `CopyPasteDialog` as a confirmation: true when the action was chosen.
    static func confirm(_ question: WriteQuestion, in window: NSWindow) async -> Bool {
        let buttons = AlertButtons.confirmation(
            question.confirmLabel, destructive: question.destructive, cancelIsDefault: question.cancelIsDefault)
        let list = question.list.isEmpty ? nil : DetailListView(lines: question.list)
        return await ask(
            title: question.title, message: question.message, buttons: buttons, escape: .cancel, accessory: list,
            in: window) == .confirm
    }

    /// `TextPromptDialog`: each name submitted goes to `submit`, whose reply closes the prompt or keeps it open with
    /// the reason under the name. Returns once it is closed, by its reply or by Cancel.
    static func askName(
        _ prompt: NamePrompt, in window: NSWindow, _ submit: @escaping @MainActor (String) async -> NamePromptReply
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let accessory = TextPromptAccessory(
                text: prompt.initialName, label: prompt.label, selectsAll: prompt.selectsAll)
            var closed = false
            var submitting = false
            var scrim: DialogScrim?
            @MainActor func close() {
                guard !closed else { return }
                closed = true
                scrim?.dismiss()
                continuation.resume()
            }
            @MainActor func send(_ name: String) {
                guard !submitting, !closed else { return }
                submitting = true
                Task { @MainActor in
                    let reply = await submit(name)
                    submitting = false
                    switch reply {
                    case .close: close()
                    case .refuse(let message):
                        accessory.error = message
                        scrim?.needsLayout = true
                    }
                }
            }
            accessory.onSubmit = { send($0) }
            let buttons = AlertButtons.prompt(submitLabel: prompt.submitLabel).map { spec in
                AlertButton(title: spec.title, variant: spec.variant) {
                    if spec.answer == .confirm { accessory.submit() } else { close() }
                }
            }
            let content = AlertContent(
                title: prompt.title, message: prompt.message, buttons: buttons, accessory: accessory,
                onEscape: { close() })
            let presented = present(content, in: window) {
                guard !closed else { return }
                closed = true
                continuation.resume()
            }
            scrim = presented
            let submitButton = (presented.panel as? AlertCard)?.defaultButton
            submitButton?.isEnabled = !accessory.trimmed.isEmpty
            accessory.onCanSubmit = { submitButton?.isEnabled = $0 }
        }
    }
}

extension WriteDialogs {
    /// The original's in-window alerts, on `window` (or the window in front); with no window at all, the plain
    /// alerts.
    static func drawNotice(_ title: String, _ message: String, _ window: NSWindow?, style: NSAlert.Style) {
        guard let host = InWindowAlerts.host(window) else {
            plainNotice(style, title, message, window)
            return
        }
        InWindowAlerts.notice(title: title, message: message, in: host)
    }

    static func drawQuestion(_ question: WriteQuestion, _ window: NSWindow?) async -> Bool {
        guard let host = InWindowAlerts.host(window) else { return await plainQuestion(question, window) }
        return await InWindowAlerts.confirm(question, in: host)
    }

    static func drawNamePrompt(
        _ prompt: NamePrompt, _ window: NSWindow?, _ submit: @escaping @MainActor (String) async -> NamePromptReply
    ) async {
        guard let host = InWindowAlerts.host(window) else {
            await plainNamePrompt(prompt, window, submit)
            return
        }
        await InWindowAlerts.askName(prompt, in: host, submit)
    }
}
