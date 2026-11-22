import Foundation

/// What kind of item a listing row is.
public enum EntryKind: String, Codable, CaseIterable, Sendable, Hashable {
    case directory
    case file
    case symlinkDirectory = "symlink_directory"
    case symlinkFile = "symlink_file"
    /// A Finder alias of a file, or one whose original isn't known yet; once known to lead to a file, it is taken as a
    /// link to a file is.
    case alias
    /// A Finder alias of a folder: it opens as a folder does, and being a file, nothing is put in it.
    case aliasDirectory = "alias_directory"
    case bundle
    case other

    /// A folder, or a link to one: what can hold what is pasted, made or dropped in it.
    public var isDirectoryLike: Bool { self == .directory || self == .symlinkDirectory }

    /// What opens as a folder: a folder, a link to one, or an alias of one (Open in New Tab, Open in Other Pane).
    public var opensAsFolder: Bool { isDirectoryLike || self == .aliasDirectory }

    /// A file, or a link to one.
    public var isEditableFile: Bool { self == .file || self == .symlinkFile }

    /// A link to a folder is not measured, and the folder it points to is not counted twice.
    public var isFolderSizeEligible: Bool { self == .directory || self == .bundle }

    /// A symbolic link or an alias: what Show Original goes to the original of.
    public var isLink: Bool {
        self == .symlinkDirectory || self == .symlinkFile || self == .alias || self == .aliasDirectory
    }
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

/// Where the folder on screen stands with folders' views (View ▸ Folder View).
public struct FolderViewCommandState: Equatable, Sendable {
    /// The folder has a view of its own.
    public var own: Bool
    /// Something kept by the view it uses is changed on screen and not saved.
    public var unsaved: Bool

    public init(own: Bool, unsaved: Bool) {
        self.own = own
        self.unsaved = unsaved
    }
}

/// What the window knows when it asks whether a command can run.
public struct CommandAvailabilityContext: Equatable, Sendable {
    public var shortcutContext: ShortcutContext
    public var currentPath: String
    public var selectedPathsInViewOrder: [String]
    public var activeContentEntries: [CommandEntry]
    /// The list shows at least one item, selected or not: of a folder, what its filter leaves; or search results.
    public var listShowsItems: Bool
    public var selectedEntry: CommandEntry?
    public var selectedTreeTargetPath: String?
    /// The clipboard holds items to paste.
    public var clipboardHasItems: Bool
    /// Some of the items Copy would take are on the clipboard (Remove from Clipboard).
    public var selectionOnClipboard: Bool
    /// What Paste as File finds on the system's clipboard; nil while it isn't read (a text field has the keyboard).
    public var systemClipboard: PasteAsFileChoice?
    public var pasteDestinationPath: String?
    public var isSearchMode: Bool
    /// The list on screen is grouped (View ▸ Group By); nil, a context that doesn't say, for yes.
    public var listIsGrouped: Bool?
    public var openItemLimit: Int
    public var writeOperationLocked: Bool
    // What the menu needs beyond the toolbar. Left out (nil), a command they decide is available.
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    public var hasCachedSearch: Bool?
    public var tabCount: Int?
    /// How many panes the tab shows.
    public var paneCount: Int?
    /// The folder the other pane shows, while the tab shows two: empty while it shows none or search results.
    public var otherPanePath: String?
    /// The folder the other pane is in, whatever it shows of it (the Trash and search results too): where Go to Other
    /// Pane's Folder goes. Nil for the same as `otherPanePath`.
    public var otherPaneFolder: String?
    /// Trash is never added to Favorites; it is offered for removal only when it is one.
    public var trashPath: String?
    /// The Trash is among the favorites, so File ▸ Remove from Favorites can take it out.
    public var trashIsFavorite: Bool
    /// Where the home folder is, to tell what is in the Trash.
    public var homePath: String?
    /// The Trash has nothing to empty (nil: it can't be told).
    public var trashIsEmpty: Bool?
    /// The disk File ▸ Eject ejects; none when nil.
    public var ejectTargetPath: String?
    /// Which of View ▸ Make Bigger, Make Smaller and Default Size would change the view on screen (nil: all of them).
    public var viewSizeSteps: ViewSize.Steps?
    /// View ▸ Pin Filter can act: a filter is typed in the folder, or one is pinned (nil: it can).
    public var filterPinnable: Bool?
    /// The folder's view (nil: every Folder View command can act).
    public var folderView: FolderViewCommandState?
    /// The active pane shows a file in place of its folder (Open in Viewer): what acts on the folder or its items
    /// waits, as neither is on screen.
    public var paneShowsFile = false

    public init(
        shortcutContext: ShortcutContext = ShortcutContext(), currentPath: String = "",
        selectedPathsInViewOrder: [String] = [], activeContentEntries: [CommandEntry] = [],
        listShowsItems: Bool = false,
        selectedEntry: CommandEntry? = nil, selectedTreeTargetPath: String? = nil, clipboardHasItems: Bool = false,
        selectionOnClipboard: Bool = false,
        pasteDestinationPath: String? = nil, isSearchMode: Bool = false, openItemLimit: Int = 5,
        writeOperationLocked: Bool = false, canGoBack: Bool? = nil, canGoForward: Bool? = nil,
        hasCachedSearch: Bool? = nil, tabCount: Int? = nil, paneCount: Int? = nil, otherPanePath: String? = nil,
        otherPaneFolder: String? = nil, trashPath: String? = nil,
        homePath: String? = nil,
        trashIsEmpty: Bool? = nil, ejectTargetPath: String? = nil, trashIsFavorite: Bool = false,
        viewSizeSteps: ViewSize.Steps? = nil, filterPinnable: Bool? = nil,
        systemClipboard: PasteAsFileChoice? = nil, folderView: FolderViewCommandState? = nil
    ) {
        self.shortcutContext = shortcutContext
        self.currentPath = currentPath
        self.selectedPathsInViewOrder = selectedPathsInViewOrder
        self.activeContentEntries = activeContentEntries
        self.listShowsItems = listShowsItems
        self.selectedEntry = selectedEntry
        self.selectedTreeTargetPath = selectedTreeTargetPath
        self.clipboardHasItems = clipboardHasItems
        self.selectionOnClipboard = selectionOnClipboard
        self.pasteDestinationPath = pasteDestinationPath
        self.isSearchMode = isSearchMode
        self.openItemLimit = openItemLimit
        self.writeOperationLocked = writeOperationLocked
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasCachedSearch = hasCachedSearch
        self.tabCount = tabCount
        self.paneCount = paneCount
        self.otherPanePath = otherPanePath
        self.otherPaneFolder = otherPaneFolder
        self.trashPath = trashPath
        self.homePath = homePath
        self.trashIsEmpty = trashIsEmpty
        self.ejectTargetPath = ejectTargetPath
        self.trashIsFavorite = trashIsFavorite
        self.viewSizeSteps = viewSizeSteps
        self.filterPinnable = filterPinnable
        self.systemClipboard = systemClipboard
        self.folderView = folderView
    }
}

/// Which toolbar and menu commands can run now.
public enum CommandAvailability {
    /// What a running file operation blocks: anything that would start another one. Copy, Cut and Copy Path only fill
    /// a clipboard, so they stay available. A held key runs them once per press (`WriteStartingShortcuts`).
    static let writeLockedCommands: Set<AppCommand> = [
        .undo, .redo, .pasteSelection, .pasteAsFile, .moveSelection, .renameSelection, .duplicateSelection,
        .makeAlias, .newFolder, .newFolderWithSelection, .newTextFile, .saveAsTemplate, .trashSelection,
        .deleteImmediately, .emptyTrash,
        .copyToOtherPane,
        .moveToOtherPane,
        .compressSelection, .extractSelection, .extractSelectionTo, .convertImages,
    ]

    // MARK: Helpers

    /// The first item at `path`.
    static func entry(at path: String?, in entries: [CommandEntry]) -> CommandEntry? {
        guard let path else { return nil }
        return entries.first { JSString.equals($0.path, path) }
    }

    /// Whether Save as Template takes the item: a file New File would list once it is in the Templates folder, so not
    /// a folder or a package, and not a name that starts with a dot, which New File leaves out as hidden: with one
    /// such file among the selected, none is copied.
    static func canBeTemplate(_ entry: CommandEntry) -> Bool {
        entry.kind.isEditableFile && !ItemNames.isHidden(NodePath.basename(entry.path))
    }

    /// The items at `paths`, in the order of `paths`, leaving out paths not there.
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

    /// Where New Folder from the keyboard or the menu bar makes a folder, and Paste as File a file: the folder on
    /// screen, whatever is selected; none in search results or in the Trash. The menu bar dims them when there is none.
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

    /// Where New Folder with Selection makes its folder: the folder on screen, when every item selected is in it.
    /// None in search results or in the Trash.
    ///
    /// The folder is given as the items' own paths spell it. The folder on screen is theirs also when it is known
    /// by another encoding of an accent than the disk's (`NameKeys.pathsMatchIgnoringEncoding`), and the items go
    /// into the new folder as a rename beside them, so it is their spelling the folder is made by. Among themselves
    /// the items are in one folder only when it is spelled the same, byte for byte.
    public static func newFolderWithSelectionTarget(
        currentPath: String, selectedPaths: [String], isSearchMode: Bool, homePath: String
    ) -> String? {
        guard let first = selectedPaths.first, let parent = parentDirectoryPath(first),
            let target = newFolderTargetPath(
                currentPath: currentPath, selectedPaths: selectedPaths, isSearchMode: isSearchMode,
                homePath: homePath),
            NameKeys.pathsMatchIgnoringEncoding(parent, target)
        else { return nil }
        let together = selectedPaths.allSatisfy { path in
            parentDirectoryPath(path).map { $0.utf8.elementsEqual(parent.utf8) } ?? false
        }
        return together ? parent : nil
    }

    // MARK: Targets

    /// What the target rules look at.
    public struct TargetContext: Equatable, Sendable {
        public var currentPath: String
        public var selectedPathsInViewOrder: [String]
        public var activeContentEntries: [CommandEntry]
        public var selectedTreeTargetPath: String?
        public var isSearchMode: Bool
        public var trashPath: String?
        public var trashIsFavorite: Bool
        public var focusedPane: FocusedPane?

        public init(
            currentPath: String = "", selectedPathsInViewOrder: [String] = [],
            activeContentEntries: [CommandEntry] = [], selectedTreeTargetPath: String? = nil,
            isSearchMode: Bool = false,
            trashPath: String? = nil, trashIsFavorite: Bool = false, focusedPane: FocusedPane? = nil
        ) {
            self.currentPath = currentPath
            self.selectedPathsInViewOrder = selectedPathsInViewOrder
            self.activeContentEntries = activeContentEntries
            self.selectedTreeTargetPath = selectedTreeTargetPath
            self.isSearchMode = isSearchMode
            self.trashPath = trashPath
            self.trashIsFavorite = trashIsFavorite
            self.focusedPane = focusedPane
        }

        init(_ context: CommandAvailabilityContext) {
            self.init(
                currentPath: context.currentPath, selectedPathsInViewOrder: context.selectedPathsInViewOrder,
                activeContentEntries: context.activeContentEntries,
                selectedTreeTargetPath: context.selectedTreeTargetPath, isSearchMode: context.isSearchMode,
                trashPath: context.trashPath, trashIsFavorite: context.trashIsFavorite,
                focusedPane: context.shortcutContext.focusedPane)
        }
    }

    /// The one folder selected in the list; with `opening`, also an alias of one, which opens as a folder does.
    private static func singleSelectedFolderPath(_ context: TargetContext, opening: Bool = false) -> String? {
        guard context.selectedPathsInViewOrder.count == 1,
            let entry = entry(at: context.selectedPathsInViewOrder[0], in: context.activeContentEntries),
            opening ? entry.kind.opensAsFolder : entry.kind.isDirectoryLike
        else { return nil }
        return entry.path
    }

    /// The folder File > Open in New Tab opens: the tree's folder when the tree has the
    /// keyboard, otherwise the one folder selected in the list.
    public static func newTabTargetPath(_ context: TargetContext) -> String? {
        if context.focusedPane == .tree {
            return context.selectedTreeTargetPath
        }
        return singleSelectedFolderPath(context, opening: true)
    }

    /// The folder File > Add to Favorites acts on: the tree's folder when the tree has the
    /// keyboard, otherwise the one folder selected in the list, or the folder on screen when nothing is selected. The
    /// Trash is never added, as it is always under Locations; a Trash favorite can be taken out.
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
        guard let target else { return nil }
        if let trash = context.trashPath, JSString.equals(trash, target), !context.trashIsFavorite { return nil }
        return target
    }

    /// What File > Show in Finder reveals: the tree's folder, the selection, or with
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

    /// The folders File > Calculate Size measures: the tree's folder when the tree has the
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

    /// A file (or a link to one) whose name is an archive's Extract takes apart.
    static func isArchive(_ entry: CommandEntry) -> Bool {
        entry.kind.isEditableFile && ArchiveNames.isArchive(NodePath.basename(entry.path))
    }

    private static func selectionIsInOneFolder(_ context: CommandAvailabilityContext) -> Bool {
        !context.isSearchMode
            || Set(context.selectedPathsInViewOrder.map { parentDirectoryPath($0).map { Array($0.utf8) } }).count == 1
    }

    private static func selectionIsInTrash(_ context: CommandAvailabilityContext) -> Bool {
        let homePath = context.homePath ?? ""
        return context.selectedPathsInViewOrder.contains { Paths.isInsideTrash($0, homePath: homePath) }
    }

    // MARK: Rules

    /// What waits while the active pane shows a file: what acts on the items of the list or on the folder on screen,
    /// and how the folder is shown. Neither is on screen, and acting on the file shown instead would act out of sight.
    static func waitsWhileAFileShows(_ command: AppCommand) -> Bool {
        if ShortcutPolicy.treeFocusBucket(of: command) == .contentOnly { return true }
        switch command {
        case .viewAsIcons, .viewAsList, .viewAsDetails, .viewAsPreviews, .showPreviews9, .showPreviews4, .showPreviews2,
            .showPreviews1, .increaseSize, .decreaseSize, .resetSize, .groupByNone, .groupByName, .groupByModified,
            .groupByCreated, .groupByLastOpened, .groupByAdded, .groupBySize, .groupByKind, .groupByTags,
            .groupByFolder, .reverseGroupOrder, .sortByName, .sortByFolder, .sortByModified, .sortByCreated,
            .sortByAdded, .sortByLastOpened, .sortBySize, .sortByKind, .toggleFoldersFirst, .toggleHiddenFiles,
            .showModifiedColumn, .showSizeColumn, .showKindColumn, .showCreatedColumn, .showAddedColumn,
            .showLastOpenedColumn, .showPermissionsColumn, .rememberFolderView, .updateFolderView, .revertFolderView,
            .folderViewOptions, .resetFolderView, .togglePinFilter, .focusFileSearch, .showLastSearchResults,
            .refreshOrApplySearchSort, .newFolder, .newTextFile, .pasteSelection, .pasteAsFile, .moveItemsHere,
            .calculateSize, .showFolderInOtherPane, .copyToOtherPane, .moveToOtherPane,
            // Going elsewhere would do it under the file, out of sight: Back, Forward and Enclosing Folder go to its
            // folder first.
            .goHomeRootTree, .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD, .goApplications,
            .goTrash, .openLocationSheet, .rootTreeAtSelection, .goToOtherPaneFolder:
            return true
        default:
            return false
        }
    }

    public static func canRun(_ command: AppCommand, _ context: CommandAvailabilityContext) -> Bool {
        // The clipboard's own: each runs where the command it is a kind of runs, as the window takes it for that one.
        switch command {
        case .addToCopied: return canRun(.copySelection, context)
        case .addToCut: return canRun(.cutSelection, context)
        case .moveItemsHere: return canRun(.pasteSelection, context)
        case .removeFromClipboard: return context.selectionOnClipboard && canRun(.copySelection, context)
        default: break
        }
        if !ShortcutPolicy.canHandle(command, context.shortcutContext) {
            return false
        }
        if context.writeOperationLocked, writeLockedCommands.contains(command) {
            return false
        }
        if context.paneShowsFile, waitsWhileAFileShows(command) {
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
            // What is in the Trash is already there; it can only be deleted for good.
            return selectedCount > 0 && !selectionIsInTrash(context)
        case .deleteImmediately:
            // Only what is in the Trash, as its menu has it; it asks first.
            return focusedPane != .tree && selectedCount > 0 && selectionIsInTrash(context)
        case .duplicateSelection:
            // A duplicate goes next to its original: search results from several folders have no one folder for
            // theirs. Nothing is made in the Trash.
            return selectedCount > 0 && !selectionIsInTrash(context)
                && (!context.isSearchMode
                    || Set(context.selectedPathsInViewOrder.map { parentDirectoryPath($0).map { Array($0.utf8) } })
                        .count == 1)
        case .makeAlias:
            // Beside each item, where Duplicate puts its copies.
            return focusedPane != .tree && canRun(.duplicateSelection, context)
        case .showOriginal:
            // One symbolic link or alias of the list.
            guard focusedPane != .tree, selectedCount == 1 else { return false }
            return entry(at: context.selectedPathsInViewOrder.first, in: context.activeContentEntries)?.kind.isLink
                ?? false
        case .convertImages:
            // Every item chosen an image, or none is converted; nothing is made in the Trash.
            guard focusedPane != .tree, selectedCount > 0, !selectionIsInTrash(context) else { return false }
            let selected = entries(at: context.selectedPathsInViewOrder, in: context.activeContentEntries)
            return selected.count == selectedCount && ImageConversion.canConvert(selected)
        case .renameSelection:
            // One item in its row; several in the Rename sheet.
            return selectedCount > 0
        case .compressSelection:
            // The zip goes next to its items: search results from several folders have no one folder for it. Nothing
            // is made in the Trash.
            return selectedCount > 0 && !selectionIsInTrash(context) && selectionIsInOneFolder(context)
        case .extractSelection, .extractSelectionTo:
            // Archives only. Extract puts what they hold next to them, never in the Trash; Extract To anywhere else.
            let selected = entries(at: context.selectedPathsInViewOrder, in: context.activeContentEntries)
            return selectedCount > 0 && selected.count == selectedCount && selected.allSatisfy(isArchive)
                && (command == .extractSelectionTo || !selectionIsInTrash(context))
        case .emptyTrash:
            return context.trashIsEmpty != true
        case .ejectVolume:
            return context.ejectTargetPath != nil
        case .newFolder:
            return newFolderTargetPath(
                currentPath: context.currentPath, selectedPaths: context.selectedPathsInViewOrder,
                isSearchMode: context.isSearchMode, homePath: context.homePath ?? "") != nil
        case .saveAsTemplate:
            // Files of the list, wherever they are but in the Trash: New File makes files from files only.
            guard focusedPane != .tree, selectedCount > 0, !selectionIsInTrash(context) else { return false }
            let selected = entries(at: context.selectedPathsInViewOrder, in: context.activeContentEntries)
            return selected.count == selectedCount && selected.allSatisfy(canBeTemplate)
        case .newTextFile:
            // Into the folder on screen, as New Folder and Paste as File.
            return newFolderTargetPath(
                currentPath: context.currentPath, selectedPaths: context.selectedPathsInViewOrder,
                isSearchMode: context.isSearchMode, homePath: context.homePath ?? "") != nil
        case .newFolderWithSelection:
            return newFolderWithSelectionTarget(
                currentPath: context.currentPath, selectedPaths: context.selectedPathsInViewOrder,
                isSearchMode: context.isSearchMode, homePath: context.homePath ?? "") != nil
        case .copySelection, .cutSelection:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0
        case .pasteSelection:
            return context.clipboardHasItems && context.pasteDestinationPath != nil
        case .addToCopied, .addToCut, .moveItemsHere, .removeFromClipboard:
            return false
        case .pasteAsFile:
            // Files copied in another app leave it on, to say why they aren't written.
            guard let found = context.systemClipboard, found != .nothing else { return false }
            return newFolderTargetPath(
                currentPath: context.currentPath, selectedPaths: context.selectedPathsInViewOrder,
                isSearchMode: context.isSearchMode, homePath: context.homePath ?? "") != nil
        case .showClipboard, .clearClipboard:
            return context.clipboardHasItems
        case .copyContents:
            // One file of the list, wherever it is: it is only read.
            guard focusedPane != .tree, selectedCount == 1 else { return false }
            return entry(at: context.selectedPathsInViewOrder.first, in: context.activeContentEntries)?.kind
                .isEditableFile ?? false
        case .shareSelection:
            // The items of the list, wherever they are but in the Trash: what is there is taken out or deleted for good.
            guard focusedPane != .tree, selectedCount > 0 else { return false }
            return !selectionIsInTrash(context)
        case .copyPath:
            if focusedPane == .tree {
                return context.selectedTreeTargetPath != nil
            }
            return selectedCount > 0
        case .openSelectionInNewTab, .openSelectionInNewWindow:
            return newTabTargetPath(target) != nil
        case .quickLookSelection:
            return context.selectedEntry != nil
        case .viewFile:
            // One file of the list.
            guard focusedPane != .tree, selectedCount == 1 else { return false }
            return entry(at: context.selectedPathsInViewOrder.first, in: context.activeContentEntries)?.kind
                .isEditableFile ?? false
        case .deselectAll:
            return selectedCount > 0
        case .invertSelection:
            // Something in the list to select: with nothing selected it selects everything shown, and with everything
            // selected nothing, as it says. The entries the window gives are the selected ones, so they can't tell.
            return context.listShowsItems
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
        // Search results group by what each result carries; a folder by any of its fields but the folder.
        case .groupByNone, .groupByName, .groupByModified, .groupByCreated, .groupByLastOpened, .groupByAdded,
            .groupBySize, .groupByKind, .groupByTags, .groupByFolder:
            guard let field = GroupByPreference(command: command) else { return false }
            return context.isSearchMode ? field.isForSearch : field.isForFolders
        case .reverseGroupOrder:
            // Only while the list is grouped; a context that doesn't say is taken as grouped.
            return context.listIsGrouped ?? true
        // Search results sort by every field a folder does and by their folder; they have no Folders First.
        case .sortByName, .sortByModified, .sortByCreated, .sortByAdded, .sortByLastOpened, .sortBySize, .sortByKind:
            return true
        case .sortByFolder:
            return context.isSearchMode
        case .toggleFoldersFirst:
            return !context.isSearchMode
        case .togglePinFilter:
            return context.filterPinnable != false
        // Search results are no folder: they have no folder's view, and columns of their own.
        case .showModifiedColumn, .showSizeColumn, .showKindColumn, .showCreatedColumn, .showAddedColumn,
            .showLastOpenedColumn, .showPermissionsColumn:
            return !context.isSearchMode
        case .rememberFolderView, .folderViewOptions:
            return !context.isSearchMode && !context.currentPath.isEmpty
        case .updateFolderView, .revertFolderView:
            return !context.isSearchMode && context.folderView?.unsaved != false
        case .resetFolderView:
            return !context.isSearchMode && context.folderView?.own != false
        case .goBack:
            return context.canGoBack != false
        case .goForward:
            return context.canGoForward != false
        case .goEnclosingFolder:
            return !context.currentPath.isEmpty && parentDirectoryPath(context.currentPath) != nil
        case .selectNextTab, .selectPreviousTab, .moveTabToNewWindow:
            return context.tabCount.map { $0 > 1 } ?? true
        case .switchToOtherPane, .swapPanes, .equalizePanes:
            return context.paneCount.map { $0 > 1 } ?? true
        case .openSelectionInOtherPane:
            // A folder shows there; one file of the list shows there in the viewer.
            if newTabTargetPath(target) != nil { return true }
            guard focusedPane != .tree, selectedCount == 1 else { return false }
            return entry(at: context.selectedPathsInViewOrder.first, in: context.activeContentEntries)?.kind
                .isEditableFile ?? false
        case .showFolderInOtherPane:
            return !context.currentPath.isEmpty && !context.isSearchMode
        case .goToOtherPaneFolder:
            // Going to a folder writes nothing into it: the Trash, or the folder searched, is somewhere to go too.
            guard let other = context.otherPaneFolder ?? context.otherPanePath else {
                return context.paneCount == nil
            }
            return !other.isEmpty && other != context.currentPath
        case .copyToOtherPane, .moveToOtherPane:
            // Into the folder the other pane shows, from the list: not when both show one folder.
            guard let other = context.otherPanePath else { return context.paneCount == nil && selectedCount > 0 }
            return selectedCount > 0 && !other.isEmpty && (context.isSearchMode || other != context.currentPath)
        case .increaseSize, .decreaseSize, .resetSize:
            // The Icons view's icon size and the Compact List's column width, short of their ends; the List has none.
            guard let change = ViewSize.Change(command) else { return true }
            return context.viewSizeSteps?.allows(change) ?? true
        default:
            return true
        }
    }
}
