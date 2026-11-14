import Foundation

/// How a finished operation ended.
public enum WriteEndStatus: String, Sendable, Equatable {
    case completed, failed, cancelled, partial
}

/// How each item of a finished operation ended.
public enum WriteItemEndStatus: String, Sendable, Equatable, Codable {
    case completed, failed, skipped, cancelled
}

/// Why an item was skipped: the plan the review settled on, or an answer given while the operation ran.
public enum WriteSkipReason: String, Sendable, Equatable {
    case plannedConflictPolicy = "planned_conflict_policy"
    case runtimeConflictResolution = "runtime_conflict_resolution"
}

/// A finished operation and its result, as what is said about it looks at it.
public struct WriteEndSummary: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var sourcePath: String?
        public var destinationPath: String?
        public var status: WriteItemEndStatus
        public var skipReason: WriteSkipReason?
        public var note: Bool

        public init(
            sourcePath: String?, destinationPath: String?, status: WriteItemEndStatus,
            skipReason: WriteSkipReason? = nil, note: Bool = false
        ) {
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.status = status
            self.skipReason = skipReason
            self.note = note
        }
    }

    public var action: WriteOperationAction
    public var status: WriteEndStatus
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
        action: WriteOperationAction, status: WriteEndStatus, targetPath: String?, topLevelItemCount: Int,
        completedItemCount: Int,
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

    var isUndoOrRedo: Bool { action == .undo || action == .redo }
}

/// What a toast says.
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
    public static func needsResultSheet(_ write: WriteEndSummary) -> Bool {
        if [.rename, .newFolder, .pasteAsFile].contains(write.action) { return write.status == .failed }
        if write.isUndoOrRedo {
            // A stop before anything was undone still tells of the items the disk check skipped: they leave the
            // history, so this is the only time they are told.
            return write.items.contains(where: \.note) || write.status == .failed || write.status == .partial
                || (write.status == .cancelled
                    && (write.completedItemCount > 0 || write.failedItemCount > 0 || write.skippedItemCount > 0))
        }
        if write.status == .failed { return true }
        // Items an archive held that were left out are told of, even when the rest went well.
        if write.action == .compress || write.action == .extract, write.items.contains(where: \.note) { return true }
        if write.action == .batchRename, write.skippedItemCount > 0 { return true }
        if write.status == .partial { return !isExpectedPlannedSkip(write) }
        guard write.status == .cancelled else { return false }
        return write.completedItemCount > 0 || write.failedItemCount > 0 || write.skippedItemCount > 0
    }

    /// A partial result made only of items the plan skipped.
    public static func isExpectedPlannedSkip(_ write: WriteEndSummary) -> Bool {
        guard write.status == .partial, write.skippedItemCount > 0, write.failedItemCount == 0,
            write.cancelledItemCount == 0
        else { return false }
        return write.items.filter { $0.status == .skipped }.allSatisfy { $0.skipReason == .plannedConflictPolicy }
    }

    /// The toast for an operation that needs no sheet; nil for none. `quietOnScreen`:
    /// items dropped from another app into the folder on screen are in sight there. `undoLabel`: what an Undo or Redo
    /// did, in the words of its menu item.
    public static func toast(
        _ write: WriteEndSummary, quietOnScreen: Bool = false, isSearchMode: Bool = false, currentPath: String = "",
        undoLabel: String? = nil
    ) -> WriteEndToast? {
        if quietOnScreen, write.status == .completed, !isSearchMode, let target = write.targetPath,
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
            guard write.status == .completed, !changedHere else { return nil }
            return WriteEndToast(
                kind: .success, title: write.action == .undo ? "Undone" : "Redone",
                message: undoLabel?.isEmpty == false ? undoLabel : nil)
        }
        // What was extracted is selected where it went, or opens in a new tab or window when no pane shows it.
        if [.newFolder, .pasteAsFile, .rename, .batchRename, .duplicate, .compress, .extract].contains(write.action) {
            return nil
        }
        let summary = itemSummary(write)
        let target = write.targetPath.map(PathText.leafName)
        let completedTitle: String =
            switch write.action {
            case .moveTo: target.map { "Moved to \($0)" } ?? "Moved"
            case .copyTo: target.map { "Copied to \($0)" } ?? "Copied"
            case .trash: "Moved to Trash"
            case .deleteImmediately: "Deleted"
            default: target.map { "Pasted into \($0)" } ?? "Pasted"
            }
        if write.status == .completed {
            return WriteEndToast(kind: .success, title: completedTitle, message: summary)
        }
        if write.status == .cancelled {
            let title: String =
                switch write.action {
                case .moveTo: "Move cancelled"
                case .copyTo: "Copy cancelled"
                case .trash: "Move to Trash cancelled"
                case .deleteImmediately: "Delete cancelled"
                default: "Paste cancelled"
                }
            return WriteEndToast(kind: .info, title: title, message: summary)
        }
        if write.status == .partial, isExpectedPlannedSkip(write) {
            return WriteEndToast(
                kind: .info, title: plannedSkipTitle(write.action, completed: write.completedItemCount),
                message: plannedSkipMessage(write))
        }
        return nil
    }

    static func representativePath(_ write: WriteEndSummary) -> String? {
        func has(_ path: String?) -> Bool { !(path ?? "").isEmpty }
        let item = write.items.first { item in
            switch write.action {
            case .newFolder, .pasteAsFile: has(item.destinationPath)
            case .trash: has(item.sourcePath)
            default: has(item.sourcePath) || has(item.destinationPath)
            }
        }
        if write.action == .newFolder || write.action == .pasteAsFile {
            return item?.destinationPath ?? write.currentDestinationPath
        }
        if write.action == .rename {
            return item?.destinationPath ?? item?.sourcePath ?? write.currentDestinationPath ?? write.currentSourcePath
        }
        if write.action == .trash { return item?.sourcePath ?? write.currentSourcePath }
        return item?.sourcePath ?? item?.destinationPath ?? write.currentSourcePath ?? write.currentDestinationPath
    }

    /// “notes.md”, or “notes.md” and 2 more.
    public static func itemSummary(_ write: WriteEndSummary) -> String? {
        guard let path = representativePath(write) else { return nil }
        let count = write.topLevelItemCount
        let name = "\u{201C}\(PathText.leafName(path))\u{201D}"
        return count <= 1 ? name : "\(name) and \(count - 1) more"
    }

    static func plannedSkipTitle(_ action: WriteOperationAction, completed: Int) -> String {
        let some = completed > 0
        switch action {
        case .moveTo: return some ? "Move finished with skipped items" : "Nothing moved"
        case .duplicate: return some ? "Duplicate finished with skipped items" : "Nothing duplicated"
        case .copyTo: return some ? "Copy finished with skipped items" : "Nothing copied"
        default: return some ? "Paste finished with skipped items" : "Nothing pasted"
        }
    }

    static func plannedSkipMessage(_ write: WriteEndSummary) -> String? {
        var sentences: [String] = []
        if write.completedItemCount > 0 {
            let verb = write.action == .moveTo ? "Moved" : "Copied"
            sentences.append("\(verb) \(ReviewCount.pluralize(write.completedItemCount, "item")).")
        }
        if write.skippedItemCount > 0 {
            let exists = write.skippedItemCount == 1 ? "exists" : "exist"
            sentences.append("Skipped \(ReviewCount.pluralize(write.skippedItemCount, "item")) that already \(exists).")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
