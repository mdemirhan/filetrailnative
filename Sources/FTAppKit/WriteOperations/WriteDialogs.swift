// Port of getCopyLikePreStartFailureTitle, WRITE_OPERATION_BUSY_MESSAGE and the "not available yet" refusals around
// them (apps/desktop/src/renderer/hooks/useExplorerActions.ts), drawn as plain alerts until P6-01 and P6-02 draw them
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
/// question can't say. P6-01 and P6-02 draw them later; here they are plain alerts with the original's words.
@MainActor
struct WriteDialogs {
    /// `WRITE_OPERATION_BUSY_MESSAGE`.
    static let busyMessage = "Another file operation is running. Try again when it has finished."

    /// Shows a notice with `title` and `message` on `window` (or on its own, with none).
    var show: (_ title: String, _ message: String, _ window: NSWindow?) -> Void = { title, message, window in
        let alert = NSAlert()
        alert.alertStyle = .warning
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

/// A write action whose operation isn't ported yet (P3-06 to P3-08 fill them).
struct WriteActionNotAvailable: Error, Equatable, LocalizedError {
    var action: WriteStartAction

    var errorDescription: String? { "\(action.failureTitle): not available yet." }
}
