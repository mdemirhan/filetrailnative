// Port of showModalNotice and askAlwaysOpenWith (apps/desktop/src/renderer/hooks/useExplorerActions.ts) and the
// confirmAlwaysOpenWith dialog of components/AppDialogs.tsx, as a seam P6-01's alerts take over
import AppKit
import FTFileSystem

/// Where the original's notices and questions about an action are shown. P6-01 draws them as the original's alert; until
/// then they are a plain alert with the exact text.
@MainActor
protocol ActionNoticePresenting: AnyObject {
    /// A notice with one button (`showModalNotice`).
    func show(title: String, message: String, in window: NSWindow?)
    /// Finder's question before every file of a kind changes app; true to go ahead.
    func confirmAlwaysOpenWith(appName: String, kindName: String?, in window: NSWindow?) async -> Bool
}

enum ActionNoticeText {
    /// `createOpenItemLimitMessage`.
    static func openItemLimit(_ action: String, selected: Int, limit: Int) -> String {
        let verb = action == "Open" ? "opens" : "edits"
        return
            "File Trail \(verb) up to \(limit) item\(limit == 1 ? "" : "s") at a time, and \(selected) are selected. You can change this in Settings."
    }

    static func alwaysOpenWithTitle(appName: String) -> String {
        "Are you sure you want to change all similar documents to open with the application “\(appName)”?"
    }

    static func alwaysOpenWithMessage(kindName: String?) -> String {
        if let kindName, !kindName.isEmpty {
            return
                "This change will apply to every “\(kindName)” file, opened from File Trail, Finder or any other app."
        }
        return "This change will apply to every file of this kind, opened from File Trail, Finder or any other app."
    }

    static func openFailureTitle(_ appName: String) -> String { "Couldn’t Open in \(appName)" }

    static func openFailureMessage(count: Int, appName: String, detail: String) -> String {
        "File Trail couldn’t open \(count == 1 ? "it" : "them") in \(appName). \(detail)"
    }

    static let terminalFailureTitle = "Couldn’t Open Terminal"
    static let terminalFailureMessage = "File Trail couldn’t open the terminal app in this folder."
    static let finderFailureTitle = "Couldn’t Show in Finder"

    static func finderFailureMessage(count: Int, detail: String?) -> String {
        "Finder couldn’t show \(count == 1 ? "it" : "them"). \(detail ?? "Finder didn’t answer.")"
    }

    /// The end of `openPathExternally`: an item macOS didn't open is only logged, whichever control asked.
    @MainActor static func logOpenFailure(_ result: OperationResult) {
        guard !result.ok else { return }
        (NSApplication.shared.delegate as? AppDelegate)?.logger?
            .error(.text("open in macOS failed: \(result.error ?? "The item didn’t open.")"))
    }
}

/// The plain alert: a sheet on the window (or a floating alert without one).
@MainActor
final class AlertNoticePresenter: ActionNoticePresenting {
    func show(title: String, message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert, in: window)
    }

    func confirmAlwaysOpenWith(appName: String, kindName: String?, in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = ActionNoticeText.alwaysOpenWithTitle(appName: appName)
        alert.informativeText = ActionNoticeText.alwaysOpenWithMessage(kindName: kindName)
        alert.addButton(withTitle: "Change All")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            if let window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            } else {
                continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }

    private func present(_ alert: NSAlert, in window: NSWindow?) {
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
