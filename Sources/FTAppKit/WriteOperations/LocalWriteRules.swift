// Port of NEW_FOLDER_NAME, resolveFreeNewFolderName, resolveNewFolderTargetPath and describeEmptyTrashFailure
// (apps/desktop/src/renderer/lib/explorerAppUtils.ts), of itemsWithoutTrash, needsDotNameConfirmation and
// formatItemSummaryFromPathCount (apps/desktop/src/renderer/hooks/useExplorerActions.ts), and of the confirmTrash,
// confirmDeleteImmediately, confirmDeleteWithoutTrash, confirmEmptyTrash and confirmDotName questions
// (apps/desktop/src/renderer/components/AppDialogs.tsx)
import FTFoundation
import FTOperations
import Foundation

/// What the window decides around rename, New Folder, Trash, Delete Immediately and Empty Trash, before and after
/// the coordinator runs them.
enum LocalWriteRules {
    /// `NEW_FOLDER_NAME`.
    static let newFolderName = "untitled folder"

    /// `resolveFreeNewFolderName`: the first of "untitled folder", "untitled folder 2", … the folder doesn't have,
    /// names compared without case as the disk does.
    static func freeNewFolderName(_ existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.lowercased() })
        if !taken.contains(newFolderName.lowercased()) {
            return newFolderName
        }
        for index in 2..<10_000 {
            let candidate = "\(newFolderName) \(index)"
            if !taken.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return newFolderName
    }

    /// Where a menu's New Folder is about (`contextScope`): the selection it was opened on, or the empty space of
    /// the folder on screen.
    enum Scope: Equatable, Sendable {
        case selection, background
    }

    /// `resolveNewFolderTargetPath`: from the keyboard or the menu bar (no scope), the folder on screen whatever is
    /// selected, so two in a row don't nest the second inside the first; from a folder's own menu, inside it, and
    /// nothing for a file or several items. Never in search results, nor in the Trash.
    static func newFolderTargetPath(
        currentPath: String, selectedEntry: (path: String, isDirectoryLike: Bool)?, selectedPaths: [String],
        isSearchMode: Bool, homePath: String, scope: Scope? = nil
    ) -> String? {
        if isSearchMode { return nil }
        let folderOnScreen = currentPath.isEmpty ? nil : currentPath
        let target: String?
        if scope != .selection || selectedPaths.isEmpty {
            target = folderOnScreen
        } else if selectedPaths.count == 1, let selectedEntry, selectedEntry.isDirectoryLike {
            target = selectedEntry.path
        } else {
            target = nil
        }
        // Nothing is made in the Trash.
        if let target, Paths.isInsideTrash(target, homePath: homePath) { return nil }
        return target
    }

    /// `describeEmptyTrashFailure`: a failure is told in a dialog; the usual one is that macOS has not let File Trail
    /// control Finder.
    static func describeEmptyTrashFailure(_ detail: String) -> (title: String, message: String) {
        let title = "Couldn\u{2019}t Empty the Trash"
        if matches(detail, #"not authori[sz]ed|-1743"#) {
            return (
                title,
                "File Trail needs permission to control Finder. Turn it on in System Settings > Privacy & Security > Automation, then try again."
            )
        }
        if matches(detail, #"-1712\b|timed out"#) {
            return (title, "Finder took too long to answer. It may still be emptying the Trash.")
        }
        if matches(detail, #"-128\b|user canceled"#) {
            return (title, "Emptying the Trash was stopped in Finder.")
        }
        // The script's reason, without its command line or error number.
        var reason = replacing(detail, #"^[\s\S]*execution error:\s*"#)
        reason = replacing(reason, #"^Command failed:[^\n]*\n?"#)
        reason = replacing(reason, #"\s*\(-?\d+\)\s*$"#)
        reason = InlineRenameRules.trimmedName(reason)
        return (title, reason.isEmpty ? "Finder didn't empty the Trash. Try again, or empty it in Finder." : reason)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first match of `pattern` taken out (JavaScript's `replace` with a pattern without `g`).
    private static func replacing(_ text: String, _ pattern: String) -> String {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    /// `itemsWithoutTrash`: the items a Move to Trash couldn't move because their disk has no Trash, when that is
    /// the only thing that went wrong (anything else is reported first, as any failure is).
    static func itemsWithoutTrash(_ event: WriteOperationEvent) -> [String] {
        guard event.action == .trash, let result = event.result else { return [] }
        let failed = result.items.filter { $0.status == .failed }
        if failed.isEmpty || failed.contains(where: { !$0.noTrash }) { return [] }
        return failed.compactMap { item in item.sourcePath.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// `needsDotNameConfirmation`: like Finder, a name that begins with a dot hides the item, so while hidden files
    /// are not shown it would vanish. That is asked first. A name that already began with one hides nothing new.
    static func needsDotNameConfirmation(_ name: String, currentName: String?, hiddenFilesShown: Bool) -> Bool {
        InlineRenameRules.needsDotConfirmation(name: name, hiddenFilesShown: hiddenFilesShown)
            && !(currentName ?? "").hasPrefix(".")
    }

    /// `formatItemSummaryFromPathCount`: "notes.md", or "notes.md and 2 more".
    static func itemSummary(_ paths: [String]) -> String {
        let firstName = NodePath.basename(paths.first ?? "item")
        return paths.count <= 1 ? firstName : "\(firstName) and \(paths.count - 1) more"
    }

    /// `quoteItems`: one item's name in quotes; "notes.md and 2 more" as it is.
    private static func quoted(_ paths: [String]) -> String {
        paths.count == 1 ? "\u{201C}\(itemSummary(paths))\u{201D}" : itemSummary(paths)
    }

    private static func count(_ paths: [String]) -> String {
        paths.count.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    // MARK: Questions

    /// `confirmTrash`: a folder of the tree is moved to the Trash after asking.
    static func trashQuestion(_ paths: [String]) -> WriteQuestion {
        WriteQuestion(
            title: "Move \(quoted(paths)) to the Trash?",
            message: paths.count == 1
                ? "It stays in the Trash until the Trash is emptied."
                : "They stay in the Trash until the Trash is emptied.",
            confirmLabel: "Move to Trash", destructive: true, cancelIsDefault: false)
    }

    /// `confirmDeleteImmediately`: Finder's question, word for word.
    static func deleteImmediatelyQuestion(_ paths: [String]) -> WriteQuestion {
        WriteQuestion(
            title: paths.count == 1
                ? "Are you sure you want to delete \(quoted(paths))?"
                : "Are you sure you want to delete these \(count(paths)) items?",
            message: paths.count == 1
                ? "This item will be deleted immediately. You can\u{2019}t undo this action."
                : "These items will be deleted immediately. You can\u{2019}t undo this action.",
            confirmLabel: "Delete", destructive: true, cancelIsDefault: true)
    }

    /// `confirmDeleteWithoutTrash`: Finder's question for an item on a disk without a Trash.
    static func deleteWithoutTrashQuestion(_ paths: [String]) -> WriteQuestion {
        WriteQuestion(
            title: paths.count == 1
                ? "Are you sure you want to delete \(quoted(paths))?"
                : "Are you sure you want to delete these \(count(paths)) items?",
            message: paths.count == 1
                ? "Its disk has no Trash, so it will be deleted immediately. You can\u{2019}t undo this action."
                : "Their disk has no Trash, so they will be deleted immediately. You can\u{2019}t undo this action.",
            confirmLabel: "Delete", destructive: true, cancelIsDefault: true)
    }

    /// `confirmEmptyTrash`: Finder's question, word for word; Cancel is the default.
    static let emptyTrashQuestion = WriteQuestion(
        title: "Are you sure you want to permanently erase the items in the Trash?",
        message: "You can\u{2019}t undo this action.", confirmLabel: "Empty Trash", destructive: true,
        cancelIsDefault: true)

    /// `confirmDotName`: Finder's question, word for word. Cancel is the default: Return keeps the name from hiding
    /// the item.
    static let dotNameQuestion = WriteQuestion(
        title: "Are you sure you want to use a name that begins with a dot (\u{201C}.\u{201D})?",
        message: "These names are reserved for the system. If you continue, the item will be hidden.",
        confirmLabel: "Use \u{201C}.\u{201D}", destructive: false, cancelIsDefault: true)
}

/// A question asked before a write starts (`CopyPasteDialog` with a primary and a Cancel button).
struct WriteQuestion: Equatable, Sendable {
    var title: String
    var message: String
    var confirmLabel: String
    var destructive: Bool
    /// Return answers Cancel (the action can't be undone, or would hide the item).
    var cancelIsDefault: Bool
    /// The lines listed under the message: the names of the items an undo question is about (`UndoQuestionAlert`).
    var list: [String] = []
}
