// Port of shouldRenderCopyPasteResultDialog and isExpectedPlannedSkipResult (apps/desktop/src/renderer/lib/
// explorerAppUtils.ts) and of pushTerminalCopyPasteToast, formatWriteOperationItemSummary,
// formatPlannedSkipToastMessage and getPlannedSkipToastTitle (hooks/useExplorerActions.ts)
import Foundation

/// A finished operation, as what is said about it looks at it (`WriteOperationProgressEvent` with its result).
public struct WriteEndSummary: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var sourcePath: String?
        public var destinationPath: String?
        /// "completed", "failed", "skipped", "cancelled".
        public var status: String
        public var skipReason: String?
        public var note: Bool

        public init(
            sourcePath: String?, destinationPath: String?, status: String, skipReason: String? = nil,
            note: Bool = false
        ) {
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.status = status
            self.skipReason = skipReason
            self.note = note
        }
    }

    public var action: String
    /// "completed", "failed", "cancelled", "partial".
    public var status: String
    public var targetPath: String?
    public var topLevelItemCount: Int
    public var completedItemCount: Int
    public var failedItemCount: Int
    public var skippedItemCount: Int
    public var cancelledItemCount: Int
    public var items: [Item]
    /// The event's own: how many items it set out to do, and the item it was on.
    public var totalItemCount: Int
    public var currentSourcePath: String?
    public var currentDestinationPath: String?

    public init(
        action: String, status: String, targetPath: String?, topLevelItemCount: Int, completedItemCount: Int,
        failedItemCount: Int, skippedItemCount: Int, cancelledItemCount: Int, items: [Item], totalItemCount: Int = 0,
        currentSourcePath: String? = nil, currentDestinationPath: String? = nil
    ) {
        self.action = action
        self.status = status
        self.targetPath = targetPath
        self.topLevelItemCount = topLevelItemCount
        self.completedItemCount = completedItemCount
        self.failedItemCount = failedItemCount
        self.skippedItemCount = skippedItemCount
        self.cancelledItemCount = cancelledItemCount
        self.items = items
        self.totalItemCount = totalItemCount
        self.currentSourcePath = currentSourcePath
        self.currentDestinationPath = currentDestinationPath
    }

    var isUndoOrRedo: Bool { action == "undo" || action == "redo" }
}

/// What a toast says (`pushToast`).
public struct WriteEndToast: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case success, info
    }

    public var kind: Kind
    public var title: String
    public var message: String?
}

/// What is said when an operation ends: a result sheet when there is something to read, else a toast or nothing.
public enum WriteEndNotices {
    /// `shouldRenderCopyPasteResultDialog`.
    public static func needsResultSheet(_ write: WriteEndSummary) -> Bool {
        if write.action == "rename" || write.action == "new_folder" { return write.status == "failed" }
        if write.isUndoOrRedo {
            return write.items.contains(where: \.note) || write.status == "failed" || write.status == "partial"
                || (write.status == "cancelled" && write.completedItemCount > 0)
        }
        if write.status == "failed" { return true }
        if write.action == "batch_rename", write.skippedItemCount > 0 { return true }
        if write.status == "partial" { return !isExpectedPlannedSkip(write) }
        guard write.status == "cancelled" else { return false }
        return write.completedItemCount > 0 || write.failedItemCount > 0 || write.skippedItemCount > 0
    }

    /// `isExpectedPlannedSkipResult`: a partial result made only of items the plan skipped.
    public static func isExpectedPlannedSkip(_ write: WriteEndSummary) -> Bool {
        guard write.status == "partial", write.skippedItemCount > 0, write.failedItemCount == 0,
            write.cancelledItemCount == 0
        else { return false }
        return write.items.filter { $0.status == "skipped" }.allSatisfy { $0.skipReason == "planned_conflict_policy" }
    }

    /// `pushTerminalCopyPasteToast`: the toast for an operation that needs no sheet; nil for none. `quietOnScreen`:
    /// items dropped from another app into the folder on screen are in sight there. `undoLabel`: what an Undo or Redo
    /// did, in the words of its menu item (`runningUndoLabelRef`).
    public static func toast(
        _ write: WriteEndSummary, quietOnScreen: Bool = false, isSearchMode: Bool = false, currentPath: String = "",
        undoLabel: String? = nil
    ) -> WriteEndToast? {
        if quietOnScreen, write.status == "completed", !isSearchMode, let target = write.targetPath,
            JSString.equals(target, currentPath)
        {
            return nil
        }
        if write.isUndoOrRedo {
            // Told only when it can't be seen: nothing it changed is in the folder on screen.
            let changedHere = write.items.contains { item in
                [item.sourcePath, item.destinationPath].contains { path in
                    path.flatMap(TreePaths.parent(of:)).map { JSString.equals($0, currentPath) } ?? false
                }
            }
            guard write.status == "completed", !changedHere else { return nil }
            return WriteEndToast(
                kind: .success, title: write.action == "undo" ? "Undone" : "Redone",
                message: undoLabel?.isEmpty == false ? undoLabel : nil)
        }
        if ["new_folder", "rename", "batch_rename", "duplicate"].contains(write.action) { return nil }
        let summary = itemSummary(write)
        let target = write.targetPath.map(PathText.leafName)
        let completedTitle: String =
            switch write.action {
            case "move_to": target.map { "Moved to \($0)" } ?? "Moved"
            case "copy_to": target.map { "Copied to \($0)" } ?? "Copied"
            case "trash": "Moved to Trash"
            case "delete_immediately": "Deleted"
            default: target.map { "Pasted into \($0)" } ?? "Pasted"
            }
        if write.status == "completed" {
            return WriteEndToast(kind: .success, title: completedTitle, message: summary)
        }
        if write.status == "cancelled" {
            let title: String =
                switch write.action {
                case "move_to": "Move cancelled"
                case "copy_to": "Copy cancelled"
                case "trash": "Move to Trash cancelled"
                case "delete_immediately": "Delete cancelled"
                default: "Paste cancelled"
                }
            return WriteEndToast(kind: .info, title: title, message: summary)
        }
        if write.status == "partial", isExpectedPlannedSkip(write) {
            return WriteEndToast(
                kind: .info, title: plannedSkipTitle(write.action, completed: write.completedItemCount),
                message: plannedSkipMessage(write))
        }
        return nil
    }

    /// `getWriteOperationRepresentativePath`.
    static func representativePath(_ write: WriteEndSummary) -> String? {
        func has(_ path: String?) -> Bool { !(path ?? "").isEmpty }
        let item = write.items.first { item in
            switch write.action {
            case "new_folder": has(item.destinationPath)
            case "trash": has(item.sourcePath)
            default: has(item.sourcePath) || has(item.destinationPath)
            }
        }
        if write.action == "new_folder" { return item?.destinationPath ?? write.currentDestinationPath }
        if write.action == "rename" {
            return item?.destinationPath ?? item?.sourcePath ?? write.currentDestinationPath ?? write.currentSourcePath
        }
        if write.action == "trash" { return item?.sourcePath ?? write.currentSourcePath }
        return item?.sourcePath ?? item?.destinationPath ?? write.currentSourcePath ?? write.currentDestinationPath
    }

    /// `formatWriteOperationItemSummary`: “notes.md”, or “notes.md” and 2 more.
    public static func itemSummary(_ write: WriteEndSummary) -> String? {
        guard let path = representativePath(write) else { return nil }
        let count = write.topLevelItemCount
        let name = "\u{201C}\(PathText.leafName(path))\u{201D}"
        return count <= 1 ? name : "\(name) and \(count - 1) more"
    }

    /// `getPlannedSkipToastTitle`.
    static func plannedSkipTitle(_ action: String, completed: Int) -> String {
        let some = completed > 0
        switch action {
        case "move_to": return some ? "Move finished with skipped items" : "Nothing moved"
        case "duplicate": return some ? "Duplicate finished with skipped items" : "Nothing duplicated"
        case "copy_to": return some ? "Copy finished with skipped items" : "Nothing copied"
        default: return some ? "Paste finished with skipped items" : "Nothing pasted"
        }
    }

    /// `formatPlannedSkipToastMessage`.
    static func plannedSkipMessage(_ write: WriteEndSummary) -> String? {
        var sentences: [String] = []
        if write.completedItemCount > 0 {
            let verb = write.action == "move_to" ? "Moved" : "Copied"
            sentences.append("\(verb) \(countLabel(write.completedItemCount, "item")).")
        }
        if write.skippedItemCount > 0 {
            let exists = write.skippedItemCount == 1 ? "exists" : "exist"
            sentences.append("Skipped \(countLabel(write.skippedItemCount, "item")) that already \(exists).")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// `formatResultCountLabel`: `toLocaleString()` grouping.
    private static func countLabel(_ count: Int, _ noun: String) -> String {
        "\(ClipboardSummary.grouped(count)) \(noun)\(count == 1 ? "" : "s")"
    }
}
