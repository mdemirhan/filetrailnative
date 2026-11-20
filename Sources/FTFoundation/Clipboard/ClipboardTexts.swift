import Foundation

/// The words of the clipboard, of paste and of drags.
public enum ClipboardTexts {
    /// “a.txt”, “a.txt” and “b.txt”, or “a.txt”, “b.txt”, “c.txt” and 2 more.
    public static func quotedNames(_ paths: [String], maxShown: Int = 3) -> String {
        let names = paths.map { "\u{201C}\(PathText.leafName($0))\u{201D}" }
        guard names.count > 1 else { return names.first ?? "" }
        if names.count <= maxShown {
            return "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
        }
        return "\(names.prefix(maxShown).joined(separator: ", ")) and \(names.count - maxShown) more"
    }

    /// Why items on the clipboard were left out of a paste. A cut is "moved"; in a paste of both (`mixed`) an item
    /// left out may be either, so neither is said.
    public static func missingClipboardItems(_ paths: [String], cut: Bool = false, mixed: Bool = false) -> String {
        let one = paths.count == 1
        let subject = one ? "it was" : "they were"
        let verb = cut ? "moved" : "pasted"
        let why =
            cut
            ? "\(subject) deleted or moved elsewhere since \(subject) cut"
            : "\(subject) moved or deleted since \(subject) \(mixed ? "put on the clipboard" : "copied")"
        if paths.count <= 3 {
            return "\(quotedNames(paths)) couldn\u{2019}t be \(verb) because \(why)."
        }
        return "\(paths.count) items couldn\u{2019}t be \(verb) because \(why): \(quotedNames(paths))."
    }

    /// The title of the notice that tells which clipboard items were left out. Nil when
    /// every item was gone: the failure title is used then.
    public static func missingClipboardItemsTitle(missing: Int, requested: Int, cut: Bool) -> String? {
        if missing == requested { return nil }
        let verb = cut ? "moved" : "pasted"
        return missing == 1 ? "An item couldn\u{2019}t be \(verb)" : "Some items couldn\u{2019}t be \(verb)"
    }

    /// Why a drag doesn't start, or a drop from another app isn't taken, while an
    /// operation runs. `action` is the running operation's.
    public static func dragRefusedWhileBusy(
        action: WriteOperationAction, currentSourcePath: String?, drop: Bool = false
    ) -> String {
        let subject =
            currentSourcePath.map { "\u{201C}\(PathText.leafName($0))\u{201D} is" } ?? "items are"
        let refused = "Can't \(drop ? "drop" : "drag") while"
        switch action {
        case .moveTo: return "\(refused) \(subject) being moved"
        case .trash: return "\(refused) \(subject) being moved to the Trash"
        case .deleteImmediately: return "\(refused) \(subject) being deleted"
        case .rename, .batchRename: return "\(refused) \(subject) being renamed"
        case .newFolder: return "\(refused) a folder is being made"
        case .newFolderWithSelection: return "\(refused) \(subject) being moved into a new folder"
        case .pasteAsFile, .newFile: return "\(refused) a file is being saved"
        case .compress: return "\(refused) a zip is being made"
        case .extract: return "\(refused) \(subject) being extracted"
        case .convertImages: return "\(refused) \(subject) being converted"
        // An Undo or Redo may move, rename or put back items: it is named, not what it does to them.
        case .undo: return "\(refused) an Undo is running"
        case .redo: return "\(refused) a Redo is running"
        case .paste, .copyTo, .duplicate: return "\(refused) \(subject) being copied"
        }
    }

    /// An issue the analysis found, as its message reads it.
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

    /// Why the analysis stopped, naming the items; the issues of the first kind found are
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
                ? "A folder can't go into a folder inside itself."
                : "\(names) can't be \(cut ? "moved" : "copied") into a folder inside \(several ? "themselves" : "itself")."
        case "duplicate_destination_name":
            return "Two of the items are named \(destinationName), so one would replace the other."
        default:
            return issue.message
        }
    }

    /// The sources that can be left out of the operation, those a cut would leave where
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

public enum PasteDestination {
    /// The items with no other listed item above them, in their order; items without a path
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

    /// The menu a paste is asked from, if any.
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

    /// Where a paste goes, or nil. From the keyboard or the menu bar, the folder on
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

// MARK: The clipboard of copied and cut items

extension ClipboardTexts {
    /// The title of a part of the clipboard's list: "Cut · 4", "Copied · 3".
    public static func sectionTitle(_ mode: ClipboardMode, count: Int) -> String {
        "\(mode == .cut ? "Cut" : "Copied") \u{B7} \(ContextMenuRules.groupedCount(count))"
    }

    /// What ⌘V does with the items of a part.
    public static func sectionDetail(_ mode: ClipboardMode) -> String {
        mode == .cut ? "Paste moves these" : "Paste copies these"
    }

    /// After the name of an item another on the clipboard has the name of, pasted under one of its own.
    public static let renamedOnPasteNote = "renamed on paste"

    public static let showInFolderTitle = "Show in Folder"
    public static let useThisOneInsteadTitle = "Use This One Instead"
    public static let removeFromClipboardTitle = "Remove from Clipboard"

    /// What a row's mark, and its menu, offer: the other intent.
    public static func switchModeTitle(from mode: ClipboardMode) -> String {
        mode == .cut ? "Copy Instead of Moving" : "Move Instead of Copying"
    }

    /// Put Back's row: "Put Back the 7 Items Before".
    public static func putBackTitle(_ count: Int) -> String {
        count == 1 ? "Put Back the Item Before" : "Put Back the \(ContextMenuRules.groupedCount(count)) Items Before"
    }

    /// A row as VoiceOver and the tests read it.
    public static func itemAccessibilityLabel(_ item: ClipboardItem) -> String {
        var label = "\(item.name), \(item.mode == .cut ? "cut" : "copied")"
        if item.pastedUnderAnotherName { label += ", \(renamedOnPasteNote)" }
        return label
    }

    private static func count(_ count: Int, _ noun: String = "item") -> String {
        "\(ContextMenuRules.groupedCount(count)) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func named(_ paths: [String]) -> String {
        paths.count == 1 ? "\u{201C}\(PathText.leafName(paths[0]))\u{201D}" : count(paths.count)
    }

    /// The toast of an Add: what it did, then the clipboard as it is now. Nil when the clipboard took nothing and
    /// nothing needs saying.
    public static func addMessage(_ report: ClipboardAddReport, clipboard: CopyPasteClipboard) -> String? {
        let summary = ClipboardRules.describe(clipboard)
        let state = summary.map { $0.intentLabel ?? $0.countLabel }
        var parts: [String] = []
        if report.startedClipboard {
            // An Add on an empty clipboard is a Copy or a Cut.
            if !report.added.isEmpty {
                parts.append("\(named(report.added)) \(report.mode == .cut ? "cut" : "copied")")
            }
        } else if !report.added.isEmpty {
            let verb = report.mode == .cut ? "to move" : "to copy"
            // One item kept beside another of its name is said once: "Added “a.txt” to move, renamed on paste".
            let renamed = report.added.count == 1 && report.keptBoth.count == 1 ? ", \(renamedOnPasteNote)" : ""
            parts.append("Added \(named(report.added)) \(verb)\(renamed)")
        }
        if !report.switched.isEmpty {
            let now = report.mode == .cut ? "now moves instead of being copied" : "now copies instead of moving"
            let nowPlural = report.mode == .cut ? "now move instead of being copied" : "now copy instead of moving"
            parts.append("\(named(report.switched)) \(report.switched.count == 1 ? now : nowPlural)")
        }
        if !report.keptBoth.isEmpty && !(report.added.count == 1 && report.keptBoth.count == 1) {
            parts.append("\(named(report.keptBoth)) will be renamed on paste")
        }
        if !report.replacedOnClipboard.isEmpty {
            parts.append("\(named(report.replacedOnClipboard)) came off the clipboard")
        }
        if !report.absorbed.isEmpty {
            parts.append(
                "\(named(report.absorbed)) \(report.absorbed.count == 1 ? "goes" : "go") with the folder added")
        }
        if parts.isEmpty {
            if let inside = report.insideListed.first {
                return report.insideListed.count == 1
                    ? "\u{201C}\(PathText.leafName(inside.path))\u{201D} is inside \u{201C}\(PathText.leafName(inside.folder))\u{201D}, which is on the clipboard"
                    : "\(count(report.insideListed.count)) are inside folders on the clipboard"
            }
            if !report.alreadyThere.isEmpty {
                return report.alreadyThere.count == 1
                    ? "\(named(report.alreadyThere)) is already on the clipboard"
                    : "\(named(report.alreadyThere)) are already on the clipboard"
            }
            return nil
        }
        if !report.insideListed.isEmpty {
            parts.append("\(named(report.insideListed.map(\.path))) left off, inside a folder on the clipboard")
        }
        if !report.alreadyThere.isEmpty {
            parts.append("\(named(report.alreadyThere)) already on it")
        }
        if let state, !report.startedClipboard || clipboard.isMixed {
            parts.append(state)
        }
        return parts.joined(separator: " \u{B7} ")
    }

    /// The question an Add asks when an item it brings has the name of one on the clipboard (`ClipboardNameClash`).
    public static func clashTitle(_ clashes: [ClipboardNameClash]) -> String {
        guard clashes.count > 1 else {
            return
                "Another item named \u{201C}\(PathText.leafName(clashes.first?.path ?? ""))\u{201D} is on the clipboard"
        }
        return "\(ContextMenuRules.groupedCount(clashes.count)) items have the same names as items on the clipboard"
    }

    public static func clashMessage(_ clashes: [ClipboardNameClash]) -> String {
        guard clashes.count > 1 else {
            let other = PathText.leafName(ClipboardRules.parentPath(clashes.first?.otherPath ?? ""))
            return
                "It\u{2019}s from \u{201C}\(other)\u{201D}. Keep Both pastes this one under another name; Use This One takes the other off the clipboard."
        }
        let names = quotedNames(clashes.map(\.path))
        return
            "\(names). Keep Both pastes the ones added under other names; Use These takes the others off the clipboard."
    }

    public static func clashUseTitle(_ clashes: [ClipboardNameClash]) -> String {
        clashes.count > 1 ? "Use These" : "Use This One"
    }

    public static func clashDontAddTitle(_ clashes: [ClipboardNameClash]) -> String {
        clashes.count > 1 ? "Don\u{2019}t Add Them" : "Don\u{2019}t Add"
    }

    public static let clashKeepBothTitle = "Keep Both"

    /// The toast when a Copy or Cut replaced a clipboard built with Add, which Put Back brings back.
    public static func replacedMessage(_ summary: ClipboardSummary, replaced: Int) -> String {
        "\(summary.label) \u{B7} replaced \(count(replaced)) on the clipboard"
    }

    public static let putBackButton = "Put Back"

    /// The toast of a Put Back.
    public static func putBackMessage(_ clipboard: CopyPasteClipboard) -> String {
        "Put back \(count(clipboard.picks.count)) on the clipboard"
    }

    /// The toast when cut items left the clipboard and nothing else says they went: their disk was ejected, they
    /// were dragged to another app, or Empty Trash erased them. It names the cut items of `before` that `after`
    /// no longer holds; nil when there are none. Copied items that left are not told of.
    public static func cutItemsLeftMessage(from before: CopyPasteClipboard, to after: CopyPasteClipboard) -> String? {
        let held = Set(after.picks.map { ExactKey($0.path) })
        let left = before.cutPaths.filter { !held.contains(ExactKey($0)) }
        guard !left.isEmpty else { return nil }
        return left.count == 1
            ? "\(named(left)) is no longer on the clipboard"
            : "\(count(left.count, "cut item")) are no longer on the clipboard"
    }
}

// MARK: The Edit menu

extension ClipboardTexts {
    /// Paste's title while the files have the keyboard: "Paste Item", "Paste 7 Items", as Finder's.
    public static func pasteTitle(count: Int) -> String {
        count == 1 ? "Paste Item" : count > 1 ? "Paste \(ContextMenuRules.groupedCount(count)) Items" : "Paste"
    }

    /// The line under Paste: what it does with what is on the clipboard ("Moves 4, copies 3"); "" with nothing on it.
    public static func pasteSubtitle(cut: Int, copied: Int) -> String {
        var parts: [String] = []
        if cut > 0 { parts.append("moves \(ContextMenuRules.groupedCount(cut))") }
        if copied > 0 { parts.append("copies \(ContextMenuRules.groupedCount(copied))") }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }

    /// Move Items Here's title: "Move Item Here", "Move 7 Items Here", as Finder's.
    public static func moveItemsHereTitle(count: Int) -> String {
        count == 1
            ? "Move Item Here"
            : count > 1 ? "Move \(ContextMenuRules.groupedCount(count)) Items Here" : "Move Items Here"
    }
}
