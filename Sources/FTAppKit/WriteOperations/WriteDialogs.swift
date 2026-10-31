// Port of getCopyLikePreStartFailureTitle, WRITE_OPERATION_BUSY_MESSAGE and the "not available yet" refusals around
// them (apps/desktop/src/renderer/hooks/useExplorerActions.ts), and of the questions asked before a write starts
// (CopyPasteDialog in apps/desktop/src/renderer/components/AppDialogs.tsx), drawn as the original's in-window alerts
// (Dialogs/)
import AppKit
import FTFoundation
import FTOperations

/// What a write asked for that it wasn't given (`WriteStartAction`): the operations, and Empty Trash.
enum WriteStartAction: Equatable, Sendable {
    case operation(WriteOperationAction)
    case emptyTrash

    /// `getCopyLikePreStartFailureTitle`.
    var failureTitle: String {
        switch self {
        case .emptyTrash: "Couldn\u{2019}t Empty the Trash"
        case .operation(let action):
            switch action {
            case .moveTo: "Couldn\u{2019}t Move"
            case .copyTo: "Couldn\u{2019}t Copy"
            case .duplicate: "Couldn\u{2019}t Duplicate"
            case .trash: "Couldn\u{2019}t Move to Trash"
            case .deleteImmediately: "Couldn\u{2019}t Delete"
            case .rename, .batchRename: "Couldn\u{2019}t Rename"
            case .newFolder: "Couldn\u{2019}t Make a New Folder"
            case .undo: "Couldn\u{2019}t Undo"
            case .redo: "Couldn\u{2019}t Redo"
            case .paste: "Couldn\u{2019}t Paste"
            }
        }
    }
}

/// The modal notices of writes (`showModalNotice`): a refusal, "another file operation is running", what the quit
/// question can't say. They are the original's alert, drawn in the window (`InWindowAlerts`); with no window to draw
/// in, a plain alert with the same words.
@MainActor
struct WriteDialogs {
    /// `WRITE_OPERATION_BUSY_MESSAGE`.
    static let busyMessage = "Another file operation is running. Try again when it has finished."

    /// Shows a warning with `title` and `message` on `window` (or on its own, with none).
    var show: (_ title: String, _ message: String, _ window: NSWindow?) -> Void = { title, message, window in
        WriteDialogs.drawNotice(title, message, window, style: .warning)
    }

    /// Shows a notice that only informs (`type: "info"`), the same way.
    var showInfo: (_ title: String, _ message: String, _ window: NSWindow?) -> Void = { title, message, window in
        WriteDialogs.drawNotice(title, message, window, style: .informational)
    }

    /// Asks `question` on `window` (or on its own); true when the action was chosen.
    var confirm: @MainActor (_ question: WriteQuestion, _ window: NSWindow?) async -> Bool = { question, window in
        await WriteDialogs.drawQuestion(question, window)
    }

    /// Asks for a name (`TextPromptDialog`): each name submitted, trimmed and not empty, goes
    /// to `submit`, whose reply closes the prompt or keeps it open with the reason under what was typed. Returns once
    /// the prompt is closed, by its reply or by Cancel.
    var askName:
        @MainActor (
            _ prompt: NamePrompt, _ window: NSWindow?, _ submit: @escaping @MainActor (String) async -> NamePromptReply
        ) async -> Void = { prompt, window, submit in await WriteDialogs.drawNamePrompt(prompt, window, submit) }

    /// The notices main.ts shows as native message boxes (the recovery and startup notices): plain alerts, not the
    /// in-window one.
    static var native: WriteDialogs {
        var dialogs = WriteDialogs()
        dialogs.show = { title, message, window in WriteDialogs.plainNotice(.warning, title, message, window) }
        dialogs.showInfo = { title, message, window in WriteDialogs.plainNotice(.informational, title, message, window)
        }
        return dialogs
    }

    static func plainQuestion(_ question: WriteQuestion, _ window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = question.destructive ? .critical : .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        if !question.list.isEmpty {
            let list = NSTextField(wrappingLabelWithString: question.list.joined(separator: "\n"))
            list.frame.size = list.fittingSize
            alert.accessoryView = list
        }
        // The first button is the one Return presses.
        let confirmFirst = !question.cancelIsDefault
        if confirmFirst {
            alert.addButton(withTitle: question.confirmLabel).hasDestructiveAction = question.destructive
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        } else {
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: question.confirmLabel).hasDestructiveAction = question.destructive
        }
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == (confirmFirst ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    /// The prompt as a plain alert: one that was refused is shown again with what was typed and the reason under it.
    static func plainNamePrompt(
        _ prompt: NamePrompt, _ window: NSWindow?, _ submit: @MainActor (String) async -> NamePromptReply
    ) async {
        var text = prompt.initialName
        var error: String?
        while true {
            let alert = NSAlert()
            alert.messageText = prompt.title
            if let message = prompt.message { alert.informativeText = message }
            let width: CGFloat = 260
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            field.stringValue = text
            field.setAccessibilityLabel(prompt.label)
            if let error {
                let reason = NSTextField(wrappingLabelWithString: error)
                reason.textColor = .systemRed
                let height = ceil(reason.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
                let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24 + 6 + height))
                field.frame.origin.y = height + 6
                reason.frame = NSRect(x: 0, y: 0, width: width, height: height)
                box.addSubview(field)
                box.addSubview(reason)
                alert.accessoryView = box
            } else {
                alert.accessoryView = field
            }
            alert.addButton(withTitle: prompt.submitLabel)
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = field
            let response: NSApplication.ModalResponse
            if let window, window.isVisible {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            text = field.stringValue
            // An empty name can't be submitted.
            let name = InlineRenameRules.trimmedName(text)
            if name.isEmpty { continue }
            switch await submit(name) {
            case .close: return
            case .refuse(let message): error = message
            }
        }
    }

    static func plainNotice(_ style: NSAlert.Style, _ title: String, _ message: String, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// B-CLIP-107: every write asked for while one runs says so the same way.
    func showBusy(_ action: WriteStartAction, in window: NSWindow?) {
        show(action.failureTitle, Self.busyMessage, window)
    }

    /// A write the coordinator refused before it began, with its reason ("Nothing can be pasted into the Trash.").
    func showRefusal(_ action: WriteStartAction, message: String, in window: NSWindow?) {
        show(action.failureTitle, message, window)
    }
}

/// What a name prompt shows (`TextPromptDialog`'s props in `AppDialogs`).
struct NamePrompt: Equatable, Sendable {
    var title: String
    var message: String?
    /// The field's name, for VoiceOver.
    var label: String
    var submitLabel: String
    var initialName: String
    /// The whole name is selected as the prompt opens, so typing replaces it (`selectAllOnOpen`, which both of the
    /// app's prompts set); off, the caret goes to its end.
    var selectsAll = true

    /// Renaming an item that has no row to type in (a folder of the tree).
    static func rename(_ path: String) -> NamePrompt {
        let currentName = NodePath.basename(path)
        return NamePrompt(
            title: "Rename \u{201C}\(currentName)\u{201D}", message: nil, label: "New name", submitLabel: "Rename",
            initialName: currentName, selectsAll: true)
    }

    /// A new folder in `parent`, which is not the folder on screen.
    static func newFolder(in parent: String, initialName: String) -> NamePrompt {
        NamePrompt(
            title: "New Folder", message: "In \u{201C}\(ProgressCardText.leafName(parent))\u{201D}",
            label: "Folder name",
            submitLabel: "Create Folder", initialName: initialName)
    }
}

/// What came of a name submitted in a prompt.
enum NamePromptReply: Equatable, Sendable {
    /// The prompt closes.
    case close
    /// The prompt stays open, with this reason under the name.
    case refuse(String)
}
