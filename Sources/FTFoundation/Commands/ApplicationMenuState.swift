import Foundation

/// What the application menu shows of the explorer window: which commands can run now (the rest are dimmed) and which
/// of its checkmarks are on. The window sends it whenever it changes.
public struct ApplicationMenuState: Equatable, Sendable {
    public var disabledCommands: [AppCommand]
    public var viewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var foldersFirst: Bool
    public var hiddenFilesShown: Bool
    public var folderTreeOpen: Bool
    public var infoPanelOpen: Bool
    public var infoRowOpen: Bool
    /// The tab shows two panes.
    public var twoPanesShown: Bool
    /// The active pane's filter is pinned.
    public var filterPinned: Bool
    /// Whether the folder the Favorites item acts on is a favorite already.
    public var favoriteIsSet: Bool
    /// A text field has the keyboard: Undo and Redo are its own, and always on.
    public var textEditing: Bool
    /// The workspace the window was opened from or saved as, while it is kept: the menu checks it, and Update names
    /// it.
    public var workspaceID: String?
    public var workspaceName: String?
    /// What Paste as File would write, which its item names.
    public var pasteAsFileKind: PasteAsFileKind?

    public init(
        disabledCommands: [AppCommand] = [], viewMode: ExplorerViewMode = .list, sortBy: SortByPreference = .name,
        foldersFirst: Bool = true, hiddenFilesShown: Bool = false, folderTreeOpen: Bool = true,
        infoPanelOpen: Bool = false, infoRowOpen: Bool = false, twoPanesShown: Bool = false,
        filterPinned: Bool = false, favoriteIsSet: Bool = false,
        textEditing: Bool = false, workspaceID: String? = nil, workspaceName: String? = nil,
        pasteAsFileKind: PasteAsFileKind? = nil
    ) {
        self.disabledCommands = disabledCommands
        self.viewMode = viewMode
        self.sortBy = sortBy
        self.foldersFirst = foldersFirst
        self.hiddenFilesShown = hiddenFilesShown
        self.folderTreeOpen = folderTreeOpen
        self.infoPanelOpen = infoPanelOpen
        self.infoRowOpen = infoRowOpen
        self.twoPanesShown = twoPanesShown
        self.filterPinned = filterPinned
        self.favoriteIsSet = favoriteIsSet
        self.textEditing = textEditing
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.pasteAsFileKind = pasteAsFileKind
    }

    /// Before the window has reported: everything is available and nothing checked.
    public static let initial = ApplicationMenuState()

    /// What the application menu is told about the window: every command that can not
    /// run now, and what its checkmarks show.
    public static func build(
        viewMode: ExplorerViewMode, sortBy: SortByPreference, foldersFirst: Bool, hiddenFilesShown: Bool,
        folderTreeOpen: Bool, infoPanelOpen: Bool, infoRowOpen: Bool, twoPanesShown: Bool = false,
        filterPinned: Bool = false, favoriteIsSet: Bool, textEditing: Bool,
        workspace: (id: String, name: String)? = nil, pasteAsFileKind: PasteAsFileKind? = nil,
        canRun: (AppCommand) -> Bool
    ) -> ApplicationMenuState {
        // A text field's Undo and Redo are always there, even in a dialog or while a file operation runs: they only
        // change its text.
        let disabled = AppCommand.allCases.filter { command in
            !(textEditing && (command == .undo || command == .redo)) && !canRun(command)
        }
        return ApplicationMenuState(
            disabledCommands: disabled, viewMode: viewMode, sortBy: sortBy, foldersFirst: foldersFirst,
            hiddenFilesShown: hiddenFilesShown, folderTreeOpen: folderTreeOpen, infoPanelOpen: infoPanelOpen,
            infoRowOpen: infoRowOpen, twoPanesShown: twoPanesShown, filterPinned: filterPinned,
            favoriteIsSet: favoriteIsSet,
            textEditing: textEditing, workspaceID: workspace?.id, workspaceName: workspace?.name,
            pasteAsFileKind: pasteAsFileKind)
    }
}

/// What one menu item should show; a field left nil is left as it is.
public struct ApplicationMenuItemState: Equatable, Sendable {
    public var id: String
    public var enabled: Bool?
    public var checked: Bool?
    public var title: String?

    public init(id: String, enabled: Bool? = nil, checked: Bool? = nil, title: String? = nil) {
        self.id = id
        self.enabled = enabled
        self.checked = checked
        self.title = title
    }
}

/// The menu's enable, check and title rules.
public enum ApplicationMenu {
    /// The commands that still do something while a window other than an explorer window (Settings) has the keyboard:
    /// the edit commands act on its text field, ⌘W closes it, and New Window opens one beside the explorer window in
    /// front.
    public static let commandsForAnyWindow: Set<AppCommand> = [
        .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .closeTab, .newWindow,
    ]

    /// What the menu still does with no explorer window open, as Finder's does: New Window, and the Go menu's places,
    /// which open a window there.
    public static let commandsWithoutExplorerWindow: Set<AppCommand> = [
        .newWindow, .goHomeRootTree, .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD,
        .goApplications, .goTrash, .openLocationSheet,
    ]

    /// What the files' Undo and Redo say: the file operation they would undo or redo, or that there is one that can't
    /// be undone. While a text field (or another window) has the keyboard, `itemStates` says just "Undo" and "Redo".
    public static func undoLabels(undo: String?, redo: String?, cantUndo: Bool) -> (undo: String, redo: String) {
        let undoLabel: String
        if cantUndo {
            undoLabel = "Can’t Undo"
        } else if let undo, !undo.isEmpty {
            undoLabel = "Undo \(undo)"
        } else {
            undoLabel = "Undo"
        }
        let redoLabel = redo.flatMap { $0.isEmpty ? nil : "Redo \($0)" } ?? "Redo"
        return (undoLabel, redoLabel)
    }

    /// The window the menu acts on (`itemStates`' second argument).
    public struct WindowFacts: Equatable, Sendable {
        /// Whether the explorer window is the one the menu acts on (false while Settings is).
        public var explorerFocused: Bool
        /// How many explorer windows are open (nil: one). Merging needs two; with none, only
        /// `commandsWithoutExplorerWindow` do anything, besides another window's own.
        public var explorerWindowCount: Int?
        /// Whether a window other than an explorer window (Settings) has the keyboard, rather than no window at all
        /// (nil: it has, when the explorer isn't focused).
        public var otherWindowFocused: Bool?
        /// Whether there is a file operation to undo and to redo (nil: there is).
        public var undoAvailable: (undo: Bool, redo: Bool)?
        /// What the files' Undo and Redo say (`undoLabels`; nil: plain "Undo" and "Redo").
        public var undoLabels: (undo: String, redo: String)?

        public init(
            explorerFocused: Bool, explorerWindowCount: Int? = nil, otherWindowFocused: Bool? = nil,
            undoAvailable: (undo: Bool, redo: Bool)? = nil, undoLabels: (undo: String, redo: String)? = nil
        ) {
            self.explorerFocused = explorerFocused
            self.explorerWindowCount = explorerWindowCount
            self.otherWindowFocused = otherWindowFocused
            self.undoAvailable = undoAvailable
            self.undoLabels = undoLabels
        }

        public static func == (left: WindowFacts, right: WindowFacts) -> Bool {
            left.explorerFocused == right.explorerFocused && left.explorerWindowCount == right.explorerWindowCount
                && left.otherWindowFocused == right.otherWindowFocused
                && left.undoAvailable?.undo == right.undoAvailable?.undo
                && left.undoAvailable?.redo == right.undoAvailable?.redo
                && left.undoLabels?.undo == right.undoLabels?.undo && left.undoLabels?.redo == right.undoLabels?.redo
        }
    }

    /// What each menu item should show for the state the explorer window last
    /// reported.
    public static func itemStates(_ state: ApplicationMenuState, window: WindowFacts) -> [ApplicationMenuItemState] {
        let disabled = Set(state.disabledCommands)
        // While a text field (or another window) has the keyboard, Undo and Redo are its own: plainly named, and on
        // whenever there is a window to send them to.
        let textUndo = state.textEditing || !window.explorerFocused
        func isEnabled(_ type: AppCommand) -> Bool {
            if type == .undo || type == .redo, textUndo {
                return window.explorerFocused || window.otherWindowFocused != false
            }
            if !window.explorerFocused {
                if window.explorerWindowCount == 0 || window.otherWindowFocused == false,
                    commandsWithoutExplorerWindow.contains(type)
                {
                    return true
                }
                return window.otherWindowFocused != false && commandsForAnyWindow.contains(type)
            }
            if disabled.contains(type) {
                return false
            }
            if type == .mergeAllWindows {
                return (window.explorerWindowCount ?? 1) > 1
            }
            // The files' Undo and Redo only when there is one.
            if type == .undo || type == .redo {
                let available = window.undoAvailable
                return (type == .undo ? available?.undo : available?.redo) ?? true
            }
            return true
        }
        func checked(_ type: AppCommand) -> Bool? {
            switch type {
            case .viewAsIcons: state.viewMode == .icons
            case .viewAsList: state.viewMode == .list
            case .viewAsDetails: state.viewMode == .details
            case .viewAsPreviews: state.viewMode == .previews
            case .sortByName: state.sortBy == .name
            case .sortByModified: state.sortBy == .modified
            case .sortBySize: state.sortBy == .size
            case .sortByKind: state.sortBy == .kind
            case .toggleFoldersFirst: state.foldersFirst
            case .toggleHiddenFiles: state.hiddenFilesShown
            case .toggleInfoPanel: state.infoPanelOpen
            case .toggleInfoRow: state.infoRowOpen
            case .toggleTwoPanes: state.twoPanesShown
            case .togglePinFilter: state.filterPinned
            default: nil
            }
        }

        func title(_ type: AppCommand) -> String? {
            switch type {
            case .undo: textUndo ? "Undo" : window.undoLabels?.undo ?? "Undo"
            case .redo: textUndo ? "Redo" : window.undoLabels?.redo ?? "Redo"
            case .toggleFavorite: state.favoriteIsSet ? "Remove from Favorites" : "Add to Favorites"
            case .toggleFolderTree: state.folderTreeOpen ? "Hide Folder Tree" : "Show Folder Tree"
            // What it would write, while it can.
            case .pasteAsFile:
                PasteAsFile.menuTitle(isEnabled(type) ? state.pasteAsFileKind : nil)
            // With no explorer window to act on, no view is named.
            case .increaseSize, .decreaseSize, .resetSize:
                ApplicationMenu.sizeTitle(type, viewMode: window.explorerFocused ? state.viewMode : .details)
            default: nil
            }
        }

        return AppCommand.allCases.map {
            ApplicationMenuItemState(id: $0.rawValue, enabled: isEnabled($0), checked: checked($0), title: title($0))
        }
    }

    // MARK: Workspaces

    /// The id of the Window ▸ Workspaces item that opens a workspace, and of the one ⌥ shows in its place, which opens
    /// it in the window the menu acts on.
    public static func workspaceItemID(_ workspaceID: String, inThisWindow: Bool = false) -> String {
        (inThisWindow ? workspaceHerePrefix : workspacePrefix) + workspaceID
    }

    /// Manage Workspaces…, which opens the list in Settings.
    public static let manageWorkspacesItemID = "manageWorkspaces"

    /// The workspace a Window ▸ Workspaces item opens, and whether in the window the menu acts on; nil for any other
    /// item.
    public static func workspaceItem(_ itemID: String) -> (workspaceID: String, inThisWindow: Bool)? {
        for (prefix, here) in [(workspaceHerePrefix, true), (workspacePrefix, false)] where itemID.hasPrefix(prefix) {
            let id = String(itemID.dropFirst(prefix.count))
            return id.isEmpty ? nil : (id, here)
        }
        return nil
    }

    private static let workspacePrefix = "workspace:"
    private static let workspaceHerePrefix = "workspaceHere:"

    /// The Workspaces items for the window the menu acts on: the workspace it came from is checked, and Update names
    /// it. `workspaceIDs` are the workspaces the menu lists.
    public static func workspaceItemStates(
        _ state: ApplicationMenuState, window: WindowFacts, workspaceIDs: [String]
    ) -> [ApplicationMenuItemState] {
        let linked = window.explorerFocused ? state.workspaceID : nil
        let name = window.explorerFocused ? state.workspaceName : nil
        let update = ApplicationMenuItemState(
            id: AppCommand.updateWorkspace.rawValue,
            title: name.map { "Update \u{201C}\($0)\u{201D}" } ?? "Update Workspace")
        return [update]
            + workspaceIDs.flatMap { id in
                let checked = linked.map { $0.utf16.elementsEqual(id.utf16) } ?? false
                return [
                    ApplicationMenuItemState(id: workspaceItemID(id), checked: checked),
                    ApplicationMenuItemState(id: workspaceItemID(id, inThisWindow: true), checked: checked),
                ]
            }
    }

    /// The size commands name what they change in the view on screen: the icons in the Icons view, the columns in the
    /// Compact List. In the List, which has no size, they keep their names in Settings.
    public static func sizeTitle(_ command: AppCommand, viewMode: ExplorerViewMode) -> String? {
        switch (command, viewMode) {
        case (.increaseSize, .icons): "Make Icons Bigger"
        case (.decreaseSize, .icons): "Make Icons Smaller"
        case (.resetSize, .icons): "Default Icon Size"
        case (.increaseSize, .list): "Make Columns Wider"
        case (.decreaseSize, .list): "Make Columns Narrower"
        case (.resetSize, .list): "Default Column Width"
        case (.increaseSize, .previews): "Make Previews Bigger"
        case (.decreaseSize, .previews): "Make Previews Smaller"
        case (.resetSize, .previews): "Default Preview Size"
        case (.increaseSize, .details): "Make Bigger"
        case (.decreaseSize, .details): "Make Smaller"
        case (.resetSize, .details): "Default Size"
        default: nil
        }
    }

    // MARK: Applying the states

    /// What `apply` needs of a menu item.
    public protocol ItemControl: AnyObject {
        var isEnabled: Bool { get set }
        var isChecked: Bool { get set }
        var title: String { get set }
    }

    /// Sets what changed on the items the menu has, and skips the others.
    public static func apply<Item: ItemControl>(_ states: [ApplicationMenuItemState], item: (String) -> Item?) {
        for state in states {
            guard let control = item(state.id) else { continue }
            if let enabled = state.enabled, control.isEnabled != enabled {
                control.isEnabled = enabled
            }
            if let checked = state.checked, control.isChecked != checked {
                control.isChecked = checked
            }
            if let title = state.title, control.title != title {
                control.title = title
            }
        }
    }
}
