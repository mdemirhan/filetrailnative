// Port of the clipboard, paste and drag parts of apps/desktop/src/renderer/lib/explorerAppUtils.ts (formatQuotedNames,
// formatMissingClipboardItemsMessage, selectTopLevelItems, resolvePasteDestinationPath, describeDragRefusedWhileBusy)
// and of getCopyLikeIssueMessage (hooks/useExplorerActions.ts)
import Foundation

/// The words of the clipboard, of paste and of drags.
public enum ClipboardTexts {
    /// `formatQuotedNames`: “a.txt”, “a.txt” and “b.txt”, or “a.txt”, “b.txt”, “c.txt” and 2 more.
    public static func quotedNames(_ paths: [String], maxShown: Int = 3) -> String {
        let names = paths.map { "\u{201C}\(PathText.leafName($0))\u{201D}" }
        guard names.count > 1 else { return names.first ?? "" }
        if names.count <= maxShown {
            return "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
        }
        return "\(names.prefix(maxShown).joined(separator: ", ")) and \(names.count - maxShown) more"
    }

    /// `formatMissingClipboardItemsMessage`: why items on the clipboard were left out of a paste. A cut is "moved".
    public static func missingClipboardItems(_ paths: [String], cut: Bool = false) -> String {
        let one = paths.count == 1
        let subject = one ? "it was" : "they were"
        let verb = cut ? "moved" : "pasted"
        let why =
            cut
            ? "\(subject) deleted or moved elsewhere since \(subject) cut"
            : "\(subject) moved or deleted since \(subject) copied"
        if paths.count <= 3 {
            return "\(quotedNames(paths)) couldn\u{2019}t be \(verb) because \(why)."
        }
        return "\(paths.count) items couldn\u{2019}t be \(verb) because \(why): \(quotedNames(paths))."
    }

    /// The title of the notice that tells which clipboard items were left out (`startPasteFromClipboard`). Nil when
    /// every item was gone: the failure title is used then.
    public static func missingClipboardItemsTitle(missing: Int, requested: Int, cut: Bool) -> String? {
        if missing == requested { return nil }
        let verb = cut ? "moved" : "pasted"
        return missing == 1 ? "An item couldn\u{2019}t be \(verb)" : "Some items couldn\u{2019}t be \(verb)"
    }

    /// `describeDragRefusedWhileBusy`: why a drag doesn't start, or a drop from another app isn't taken, while an
    /// operation runs. `action` is the running operation's (`WriteOperationAction`).
    public static func dragRefusedWhileBusy(action: String, currentSourcePath: String?, drop: Bool = false) -> String {
        let subject =
            currentSourcePath.map { "\u{201C}\(PathText.leafName($0))\u{201D} is" } ?? "items are"
        let refused = "Can't \(drop ? "drop" : "drag") while"
        switch action {
        case "move_to": return "\(refused) \(subject) being moved"
        case "trash": return "\(refused) \(subject) being moved to the Trash"
        case "delete_immediately": return "\(refused) \(subject) being deleted"
        case "rename", "batch_rename": return "\(refused) \(subject) being renamed"
        case "new_folder": return "\(refused) a folder is being made"
        default: return "\(refused) \(subject) being copied"
        }
    }

    /// An analysis issue, as `getCopyLikeIssueMessage` reads it.
    public struct Issue: Equatable, Sendable {
        public var code: String
        public var sourcePath: String?
        public var destinationPath: String?
        public var message: String

        public init(code: String, sourcePath: String?, destinationPath: String?, message: String) {
            self.code = code
            self.sourcePath = sourcePath
            self.destinationPath = destinationPath
            self.message = message
        }
    }

    /// `getCopyLikeIssueMessage`: why the analysis stopped, naming the items; the issues of the first kind found are
    /// told together.
    public static func issueMessage(_ issues: [Issue], destinationDirectoryPath: String, cut: Bool) -> String {
        guard let issue = issues.first else {
            return "File Trail couldn\u{2019}t finish checking the items. Nothing was changed."
        }
        let sources = issues.filter { $0.code == issue.code }.compactMap(\.sourcePath)
        let names = quotedNames(sources)
        let several = sources.count > 1
        let destinationName =
            "\u{201C}\(PathText.leafName(issue.destinationPath ?? destinationDirectoryPath))\u{201D}"
        let folderName = "\u{201C}\(PathText.leafName(destinationDirectoryPath))\u{201D}"
        switch issue.code {
        case "destination_missing":
            return "The folder \(folderName) no longer exists."
        case "destination_not_directory":
            return "\(folderName) isn't a folder."
        case "source_missing":
            return names.isEmpty
                ? "An item to copy no longer exists." : "\(names) no longer \(several ? "exist" : "exists")."
        case "same_path":
            return names.isEmpty
                ? "Source and destination cannot be the same."
                : "\(names) \(several ? "are" : "is") already in \(folderName)."
        case "parent_into_child":
            return names.isEmpty
                ? "You can't place a folder into its own descendant."
                : "\(names) can't be \(cut ? "moved" : "copied") into a folder inside \(several ? "themselves" : "itself")."
        case "duplicate_destination_name":
            return "Two of the items are named \(destinationName), so one would replace the other."
        default:
            return issue.message
        }
    }

    /// `collectLeftOutSourcePaths`: the sources that can be left out of the operation, those a cut would leave where
    /// they already are and (when allowed) those that no longer exist. Nil when an issue is of any other kind.
    public static func leftOutSourcePaths(
        _ issues: [Issue], sourcePaths: [String], alreadyInPlace: Bool, missing: Bool
    ) -> (alreadyInPlace: [String], missing: [String])? {
        let requested = Set(sourcePaths.map(ExactKey.init))
        var inPlace: [String] = []
        var gone: [String] = []
        for issue in issues {
            guard let source = issue.sourcePath, requested.contains(ExactKey(source)) else { return nil }
            if issue.code == "same_path", alreadyInPlace {
                if !inPlace.contains(where: { JSString.equals($0, source) }) { inPlace.append(source) }
            } else if issue.code == "source_missing", missing {
                if !gone.contains(where: { JSString.equals($0, source) }) { gone.append(source) }
            } else {
                return nil
            }
        }
        return (inPlace, gone)
    }
}

/// `selectTopLevelItems`, `resolvePasteDestinationPath`.
public enum PasteDestination {
    /// `selectTopLevelItems`: the items with no other listed item above them, in their order; items without a path
    /// are kept.
    public static func topLevelItems<T>(_ items: [T], path: (T) -> String?) -> [T] {
        let paths = Set(items.compactMap(path).map(ExactKey.init))
        return items.filter { item in
            guard let source = path(item) else { return true }
            return !hasAncestor(source, paths)
        }
    }

    private static func hasAncestor(_ path: String, _ candidates: Set<ExactKey>) -> Bool {
        let units = Array(path.utf16)
        var index = units.count - 1
        while index > 0 {
            if units[index] == 0x2F, candidates.contains(ExactKey(JSString.string(units[..<index]))) { return true }
            index -= 1
        }
        return false
    }

    /// The menu a paste is asked from, if any (`ContextMenuState`).
    public struct Menu: Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            /// A folder of the tree or a favorite: it pastes into `targetPath`.
            case treeFolder, favorite
            /// An item's menu (or the background's, with no paths).
            case content
        }

        public var target: Target
        public var targetPath: String?
        public var paths: [String]

        public init(target: Target, targetPath: String?, paths: [String]) {
            self.target = target
            self.targetPath = targetPath
            self.paths = paths
        }
    }

    /// `resolvePasteDestinationPath`: where a paste goes, or nil. From the keyboard or the menu bar, the folder on
    /// screen whatever is selected; a folder's own menu into it; an item's only when it is the one folder picked and
    /// not itself on the clipboard. Never in search results, never into the Trash.
    public static func resolve(
        menu: Menu?, menuEntryPath: String? = nil, menuEntryKind: EntryKind? = nil, clipboardSourcePaths: [String],
        currentPath: String, isSearchMode: Bool, homePath: String
    ) -> String? {
        guard
            let destination = ignoringTrash(
                menu: menu, menuEntryPath: menuEntryPath, menuEntryKind: menuEntryKind,
                clipboardSourcePaths: clipboardSourcePaths, currentPath: currentPath, isSearchMode: isSearchMode)
        else { return nil }
        return Paths.isInsideTrash(destination, homePath: homePath) ? nil : destination
    }

    private static func ignoringTrash(
        menu: Menu?, menuEntryPath: String?, menuEntryKind: EntryKind?, clipboardSourcePaths: [String],
        currentPath: String, isSearchMode: Bool
    ) -> String? {
        let currentFolder = currentPath.isEmpty ? nil : currentPath
        if isSearchMode { return nil }
        guard let menu else { return currentFolder }
        if menu.target == .treeFolder || menu.target == .favorite { return menu.targetPath }
        if menu.paths.isEmpty { return currentFolder }
        if menu.paths.count == 1, let path = menuEntryPath, menuEntryKind?.isDirectoryLike == true,
            !clipboardSourcePaths.contains(where: { JSString.equals($0, path) })
        {
            return path
        }
        return nil
    }
}
