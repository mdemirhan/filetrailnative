// Port of apps/desktop/src/renderer/lib/rendererCommandAvailability.ts, with the few helpers it uses from
// entriesAtPaths.ts, explorerAppUtils.ts and explorerNavigation.ts
import Foundation

/// What kind of item a listing row is (`DirectoryEntry["kind"]`).
public enum EntryKind: String, Codable, CaseIterable, Sendable, Hashable {
    case directory
    case file
    case symlinkDirectory = "symlink_directory"
    case symlinkFile = "symlink_file"
    case bundle
    case other

    /// `isDirectoryLikeEntry`: a folder, or a link to one.
    public var isDirectoryLike: Bool { self == .directory || self == .symlinkDirectory }

    /// `isEditableFileEntry`: a file, or a link to one.
    public var isEditableFile: Bool { self == .file || self == .symlinkFile }

    /// `isFolderSizeEligibleKind`: a link to a folder is not measured, and the folder it points to is not counted twice.
    public var isFolderSizeEligible: Bool { self == .directory || self == .bundle }
}

/// The parts of a listing row the command rules look at.
public struct CommandEntry: Equatable, Sendable {
    public var path: String
    public var kind: EntryKind

    public init(path: String, kind: EntryKind) {
        self.path = path
        self.kind = kind
    }
}

/// What the window knows when it asks whether a command can run (`RendererCommandAvailabilityContext`).
public struct CommandAvailabilityContext: Equatable, Sendable {
    public var shortcutContext: ShortcutContext
    public var currentPath: String
    public var selectedPathsInViewOrder: [String]
    public var activeContentEntries: [CommandEntry]
    public var selectedEntry: CommandEntry?
    public var selectedTreeTargetPath: String?
    /// `hasClipboardItems(copyPasteClipboard)`.
    public var clipboardHasItems: Bool
    public var pasteDestinationPath: String?
    public var isSearchMode: Bool
    public var openItemLimit: Int
    public var writeOperationLocked: Bool
    // What the menu needs beyond the toolbar. Left out (nil), a command they decide is available.
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    public var hasCachedSearch: Bool?
    public var tabCount: Int?
    /// Trash is a favorite that stays: it is never offered for removal.
    public var trashPath: String?
    /// Where the home folder is, to tell what is in the Trash.
    public var homePath: String?
    /// The Trash has nothing to empty (nil: it can't be told).
    public var trashIsEmpty: Bool?
    /// The disk File ▸ Eject ejects; none when nil.
    public var ejectTargetPath: String?

    public init(
        shortcutContext: ShortcutContext = ShortcutContext(), currentPath: String = "",
        selectedPathsInViewOrder: [String] = [], activeContentEntries: [CommandEntry] = [],
        selectedEntry: CommandEntry? = nil, selectedTreeTargetPath: String? = nil, clipboardHasItems: Bool = false,
        pasteDestinationPath: String? = nil, isSearchMode: Bool = false, openItemLimit: Int = 5,
        writeOperationLocked: Bool = false, canGoBack: Bool? = nil, canGoForward: Bool? = nil,
        hasCachedSearch: Bool? = nil, tabCount: Int? = nil, trashPath: String? = nil, homePath: String? = nil,
        trashIsEmpty: Bool? = nil, ejectTargetPath: String? = nil
    ) {
        self.shortcutContext = shortcutContext
        self.currentPath = currentPath
        self.selectedPathsInViewOrder = selectedPathsInViewOrder
        self.activeContentEntries = activeContentEntries
        self.selectedEntry = selectedEntry
        self.selectedTreeTargetPath = selectedTreeTargetPath
        self.clipboardHasItems = clipboardHasItems
        self.pasteDestinationPath = pasteDestinationPath
        self.isSearchMode = isSearchMode
        self.openItemLimit = openItemLimit
        self.writeOperationLocked = writeOperationLocked
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasCachedSearch = hasCachedSearch
        self.tabCount = tabCount
        self.trashPath = trashPath
        self.homePath = homePath
        self.trashIsEmpty = trashIsEmpty
        self.ejectTargetPath = ejectTargetPath
    }
}

/// Which toolbar and menu commands can run now.
public enum CommandAvailability {
    /// What a running file operation blocks: anything that would start another one. Copy, Cut and Copy Path only fill
    /// a clipboard, so they stay available.
    private static let writeLockedCommands: Set<RendererCommand> = [
        .undo, .redo, .pasteSelection, .moveSelection, .renameSelection, .duplicateSelection, .newFolder,
        .trashSelection, .emptyTrash,
    ]

    // MARK: Helpers of the original's other files

    /// `findEntryAtPath`: the first item at `path`.
    static func entry(at path: String?, in entries: [CommandEntry]) -> CommandEntry? {
        guard let path else { return nil }
        return entries.first { JSString.equals($0.path, path) }
    }

    /// `resolveEntriesAtPaths`: the items at `paths`, in the order of `paths`, leaving out paths not there.
    static func entries(at paths: [String], in entries: [CommandEntry]) -> [CommandEntry] {
        if paths.isEmpty { return [] }
        var index: [[UInt8]: CommandEntry] = [:]
        for entry in entries {
            let key = Array(entry.path.utf8)
            if index[key] == nil {
                index[key] = entry
            }
        }
        return paths.compactMap { index[Array($0.utf8)] }
    }

    /// `parentDirectoryPath`: nil for the top of the disk.
    static func parentDirectoryPath(_ path: String) -> String? {
        if path == "/" {
            return nil
        }
        let parts = JSString.components(path, separator: 0x2F)
        if parts.count <= 1 {
            return "/"
        }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// `resolveNewFolderTargetPath` as the Eject, New Folder and menu rules use it (no context scope).
    static func newFolderTargetPath(
        currentPath: String, selectedPaths: [String], isSearchMode: Bool, homePath: String
    ) -> String? {
        if isSearchMode {
            return nil
        }
        let target = currentPath.isEmpty ? nil : currentPath
        // Nothing is made in the Trash.
        if let target, Paths.isInsideTrash(target, homePath: homePath) {
            return nil
        }
        return target
    }

    // MARK: Targets

    /// What the target rules look at (`CommandTargetContext`).
    public struct TargetContext: Equatable, Sendable {
        public var currentPath: String
        public var selectedPathsInViewOrder: [String]
        public var activeContentEntries: [CommandEntry]
        public var selectedTreeTargetPath: String?
        public var isSearchMode: Bool
        public var trashPath: String?
        public var focusedPane: FocusedPane?

        public init(
            currentPath: String = "", selectedPathsInViewOrder: [String] = [],
            activeContentEntries: [CommandEntry] = [], selectedTreeTargetPath: String? = nil,
            isSearchMode: Bool = false,
            trashPath: String? = nil, focusedPane: FocusedPane? = nil
        ) {
            self.currentPath = currentPath
            self.selectedPathsInViewOrder = selectedPathsInViewOrder
            self.activeContentEntries = activeContentEntries
            self.selectedTreeTargetPath = selectedTreeTargetPath
            self.isSearchMode = isSearchMode
            self.trashPath = trashPath
            self.focusedPane = focusedPane
        }

        init(_ context: CommandAvailabilityContext) {
            self.init(
                currentPath: context.currentPath, selectedPathsInViewOrder: context.selectedPathsInViewOrder,
                activeContentEntries: context.activeContentEntries,
                selectedTreeTargetPath: context.selectedTreeTargetPath, isSearchMode: context.isSearchMode,
                trashPath: context.trashPath, focusedPane: context.shortcutContext.focusedPane)
        }
    }

    private static func singleSelectedFolderPath(_ context: TargetContext) -> String? {
        guard context.selectedPathsInViewOrder.count == 1,
            let entry = entry(at: context.selectedPathsInViewOrder[0], in: context.activeContentEntries),
            entry.kind.isDirectoryLike
        else { return nil }
        return entry.path
    }

    /// `resolveNewTabTargetPath`: the folder File > Open in New Tab opens: the tree's folder when the tree has the
    /// keyboard, otherwise the one folder selected in the list.
    public static func newTabTargetPath(_ context: TargetContext) -> String? {
        if context.focusedPane == .tree {
            return context.selectedTreeTargetPath
        }
        return singleSelectedFolderPath(context)
    }

    /// `resolveFavoriteTargetPath`: the folder File > Add to Favorites acts on: the tree's folder when the tree has the
    /// keyboard, otherwise the one folder selected in the list, or the folder on screen when nothing is selected.
    public static func favoriteTargetPath(_ context: TargetContext) -> String? {
        if context.isSearchMode {
            return nil
        }
        let target: String?
        if context.focusedPane == .tree {
            target = context.selectedTreeTargetPath
        } else if context.selectedPathsInViewOrder.isEmpty {
            target = context.currentPath.isEmpty ? nil : context.currentPath
        } else {
            target = singleSelectedFolderPath(context)
        }
        // `targetPath !== context.trashPath`: a missing trash path is undefined, never equal to a path.
        guard let target, context.trashPath.map({ !JSString.equals($0, target) }) ?? true else { return nil }
        return target
    }

    /// `resolveShowInFinderPaths`: what File > Show in Finder reveals: the tree's folder, the selection, or with
    /// nothing selected the folder on screen.
    public static func showInFinderPaths(_ context: TargetContext) -> [String] {
        if context.focusedPane == .tree, let tree = context.selectedTreeTargetPath, !tree.isEmpty {
            return [tree]
        }
        if !context.selectedPathsInViewOrder.isEmpty {
            return context.selectedPathsInViewOrder
        }
        return context.currentPath.isEmpty ? [] : [context.currentPath]
    }

    /// `resolveCalculateSizePaths`: the folders File > Calculate Size measures: the tree's folder when the tree has the
    /// keyboard, the folders among the selection, or with nothing selected the folder on screen.
    public static func calculateSizePaths(_ context: TargetContext) -> [String] {
        if context.focusedPane == .tree, let tree = context.selectedTreeTargetPath, !tree.isEmpty {
            return [tree]
        }
        if context.focusedPane != .tree, !context.selectedPathsInViewOrder.isEmpty {
            return entries(at: context.selectedPathsInViewOrder, in: context.activeContentEntries)
                .filter { $0.kind.isFolderSizeEligible }
                .map(\.path)
        }
        return context.isSearchMode || context.currentPath.isEmpty ? [] : [context.currentPath]
    }

    private static func selectionIsInTrash(_ context: CommandAvailabilityContext) -> Bool {
        let homePath = context.homePath ?? ""
        return context.selectedPathsInViewOrder.contains { Paths.isInsideTrash($0, homePath: homePath) }
    }

    // MARK: Rules

    /// `canRunToolbarRendererCommand`.
    public static func canRun(_ command: RendererCommand, _ context: CommandAvailabilityContext) -> Bool {
        if !ShortcutPolicy.canHandle(command, context.shortcutContext) {
            return false
        }
        if context.writeOperationLocked, writeLockedCommands.contains(command) {
            return false
        }
        let focusedPane = context.shortcutContext.focusedPane
        let selectedCount = context.selectedPathsInViewOrder.count
        let target = TargetContext(context)

        switch command {
        case .openSelection:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0 && selectedCount <= context.openItemLimit
        case .editSelection:
            if selectedCount == 0 || selectedCount > context.openItemLimit {
                return false
            }
            let selected = entries(at: context.selectedPathsInViewOrder, in: context.activeContentEntries)
            return selected.count == selectedCount && selected.allSatisfy { $0.kind.isEditableFile }
        case .openInTerminal:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0 || !context.currentPath.isEmpty
        case .moveSelection:
            return selectedCount > 0
        case .trashSelection:
            // What is in the Trash is already there; it can only be deleted for good, from its menu.
            return selectedCount > 0 && !selectionIsInTrash(context)
        case .duplicateSelection:
            // A duplicate goes next to its original: search results from several folders have no one folder for
            // theirs. Nothing is made in the Trash.
            return selectedCount > 0 && !selectionIsInTrash(context)
                && (!context.isSearchMode
                    || Set(context.selectedPathsInViewOrder.map { parentDirectoryPath($0).map { Array($0.utf8) } })
                        .count == 1)
        case .renameSelection:
            // One item in its row; several in the Rename sheet.
            return selectedCount > 0
        case .emptyTrash:
            return context.trashIsEmpty != true
        case .ejectVolume:
            return context.ejectTargetPath != nil
        case .newFolder:
            return newFolderTargetPath(
                currentPath: context.currentPath, selectedPaths: context.selectedPathsInViewOrder,
                isSearchMode: context.isSearchMode, homePath: context.homePath ?? "") != nil
        case .copySelection, .cutSelection:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0
        case .pasteSelection:
            return context.clipboardHasItems && context.pasteDestinationPath != nil
        case .showClipboard, .clearClipboard:
            return context.clipboardHasItems
        case .copyPath:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0
        case .openSelectionInNewTab, .openSelectionInNewWindow:
            return newTabTargetPath(target) != nil
        case .quickLookSelection:
            return context.selectedEntry != nil
        case .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications, .goTrash:
            return GoMenuPlaceCommand(rawValue: command.rawValue)?.place(homePath: context.homePath ?? "") != nil
        case .calculateSize:
            return !calculateSizePaths(target).isEmpty
        case .revealInFolder:
            // A search result, in the folder it is in.
            return context.isSearchMode && selectedCount > 0
        case .toggleFavorite:
            return favoriteTargetPath(target) != nil
        case .showInFinder:
            return !showInFinderPaths(target).isEmpty
        case .showLastSearchResults:
            return context.hasCachedSearch != false && !context.isSearchMode
        case .sortByName, .sortByModified, .sortBySize, .sortByKind, .toggleFoldersFirst:
            // Search results have an order of their own, chosen in the List view's headers.
            return !context.isSearchMode
        case .goBack:
            return context.canGoBack != false
        case .goForward:
            return context.canGoForward != false
        case .goEnclosingFolder:
            return !context.currentPath.isEmpty && parentDirectoryPath(context.currentPath) != nil
        case .selectNextTab, .selectPreviousTab, .moveTabToNewWindow:
            return context.tabCount.map { $0 > 1 } ?? true
        default:
            return true
        }
    }
}
