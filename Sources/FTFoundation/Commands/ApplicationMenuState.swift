// Port of apps/desktop/src/shared/applicationMenuState.ts, renderer/lib/applicationMenuState.ts and the pure rules of
// apps/desktop/src/main/appMenu.ts (resolveApplicationMenuItemStates, undoMenuLabels)
import Foundation

/// What the application menu shows of the explorer window: which commands can run now (the rest are dimmed) and which
/// of its checkmarks are on. The window sends it whenever it changes.
public struct ApplicationMenuState: Equatable, Sendable {
    public var disabledCommands: [RendererCommand]
    public var viewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var foldersFirst: Bool
    public var hiddenFilesShown: Bool
    public var folderTreeOpen: Bool
    public var infoPanelOpen: Bool
    public var infoRowOpen: Bool
    /// Whether the folder the Favorites item acts on is a favorite already.
    public var favoriteIsSet: Bool
    /// A text field has the keyboard: Undo and Redo are its own, and always on.
    public var textEditing: Bool

    public init(
        disabledCommands: [RendererCommand] = [], viewMode: ExplorerViewMode = .list, sortBy: SortByPreference = .name,
        foldersFirst: Bool = true, hiddenFilesShown: Bool = false, folderTreeOpen: Bool = true,
        infoPanelOpen: Bool = false, infoRowOpen: Bool = false, favoriteIsSet: Bool = false, textEditing: Bool = false
    ) {
        self.disabledCommands = disabledCommands
        self.viewMode = viewMode
        self.sortBy = sortBy
        self.foldersFirst = foldersFirst
        self.hiddenFilesShown = hiddenFilesShown
        self.folderTreeOpen = folderTreeOpen
        self.infoPanelOpen = infoPanelOpen
        self.infoRowOpen = infoRowOpen
        self.favoriteIsSet = favoriteIsSet
        self.textEditing = textEditing
    }

    /// INITIAL_APPLICATION_MENU_STATE: before the window has reported, everything is available and nothing checked.
    public static let initial = ApplicationMenuState()

    /// `toApplicationMenuState`: the state as it arrives where command names are plain strings; unknown names are
    /// dropped.
    public init(
        disabledCommandNames: [String], viewMode: ExplorerViewMode, sortBy: SortByPreference, foldersFirst: Bool,
        hiddenFilesShown: Bool, folderTreeOpen: Bool, infoPanelOpen: Bool, infoRowOpen: Bool, favoriteIsSet: Bool,
        textEditing: Bool
    ) {
        self.init(
            disabledCommands: disabledCommandNames.compactMap(RendererCommand.init(rawValue:)), viewMode: viewMode,
            sortBy: sortBy, foldersFirst: foldersFirst, hiddenFilesShown: hiddenFilesShown,
            folderTreeOpen: folderTreeOpen, infoPanelOpen: infoPanelOpen, infoRowOpen: infoRowOpen,
            favoriteIsSet: favoriteIsSet, textEditing: textEditing)
    }

    /// `buildApplicationMenuState`: what the application menu is told about the window: every command that can not
    /// run now, and what its checkmarks show.
    public static func build(
        viewMode: ExplorerViewMode, sortBy: SortByPreference, foldersFirst: Bool, hiddenFilesShown: Bool,
        folderTreeOpen: Bool, infoPanelOpen: Bool, infoRowOpen: Bool, favoriteIsSet: Bool, textEditing: Bool,
        canRun: (RendererCommand) -> Bool
    ) -> ApplicationMenuState {
        // A text field's Undo and Redo are always there, even in a dialog or while a file operation runs: they only
        // change its text.
        let disabled = RendererCommand.allCases.filter { command in
            !(textEditing && (command == .undo || command == .redo)) && !canRun(command)
        }
        return ApplicationMenuState(
            disabledCommands: disabled, viewMode: viewMode, sortBy: sortBy, foldersFirst: foldersFirst,
            hiddenFilesShown: hiddenFilesShown, folderTreeOpen: folderTreeOpen, infoPanelOpen: infoPanelOpen,
            infoRowOpen: infoRowOpen, favoriteIsSet: favoriteIsSet, textEditing: textEditing)
    }
}

/// What one menu item should show (`ApplicationMenuItemState`); a field left nil is left as it is.
public struct ApplicationMenuItemState: Equatable, Sendable {
    public var id: String
    public var enabled: Bool?
    public var checked: Bool?
    public var visible: Bool?

    public init(id: String, enabled: Bool? = nil, checked: Bool? = nil, visible: Bool? = nil) {
        self.id = id
        self.enabled = enabled
        self.checked = checked
        self.visible = visible
    }
}

/// The menu's enable, check and visibility rules.
public enum ApplicationMenu {
    /// Add to Favorites and Remove from Favorites are two items; one shows at a time.
    public static let favoriteAddItemID = "toggleFavorite:add"
    public static let favoriteRemoveItemID = "toggleFavorite:remove"
    /// Hide Folder Tree and Show Folder Tree too.
    public static let folderTreeHideItemID = "toggleFolderTree:hide"
    public static let folderTreeShowItemID = "toggleFolderTree:show"
    /// Undo and Redo are two items each: the files', and a text field's own (plain "Undo" and "Redo", sending the same
    /// command), shown while a text field or another window has the keyboard.
    public static let textUndoItemID = "undo:text"
    public static let textRedoItemID = "redo:text"

    /// The commands that still do something while a window other than an explorer window (Settings) has the keyboard:
    /// the edit commands act on its text field, ⌘W closes it, and New Window opens one beside the explorer window in
    /// front.
    public static let commandsForAnyWindow: Set<RendererCommand> = [
        .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .closeTab, .newWindow,
    ]

    /// What the menu still does with no explorer window open, as Finder's does: New Window, and the Go menu's places,
    /// which open a window there.
    public static let commandsWithoutExplorerWindow: Set<RendererCommand> = [
        .newWindow, .goHomeRootTree, .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD,
        .goApplications, .goTrash, .openLocationSheet,
    ]

    /// `undoMenuLabels`: what Undo and Redo say. While a text field (or another window) has the keyboard they are its
    /// own and say just "Undo" and "Redo"; otherwise they name the file operation, or say there is one that can't be
    /// undone.
    public static func undoLabels(undo: String?, redo: String?, cantUndo: Bool, textEditing: Bool)
        -> (undo: String, redo: String)
    {
        if textEditing {
            return ("Undo", "Redo")
        }
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

    /// The window the menu acts on (`resolveApplicationMenuItemStates`' second argument).
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

        public init(
            explorerFocused: Bool, explorerWindowCount: Int? = nil, otherWindowFocused: Bool? = nil,
            undoAvailable: (undo: Bool, redo: Bool)? = nil
        ) {
            self.explorerFocused = explorerFocused
            self.explorerWindowCount = explorerWindowCount
            self.otherWindowFocused = otherWindowFocused
            self.undoAvailable = undoAvailable
        }

        public static func == (left: WindowFacts, right: WindowFacts) -> Bool {
            left.explorerFocused == right.explorerFocused && left.explorerWindowCount == right.explorerWindowCount
                && left.otherWindowFocused == right.otherWindowFocused
                && left.undoAvailable?.undo == right.undoAvailable?.undo
                && left.undoAvailable?.redo == right.undoAvailable?.redo
        }
    }

    /// `resolveApplicationMenuItemStates`: what each menu item should show for the state the explorer window last
    /// reported.
    public static func itemStates(_ state: ApplicationMenuState, window: WindowFacts) -> [ApplicationMenuItemState] {
        let disabled = Set(state.disabledCommands)
        func isEnabled(_ type: RendererCommand) -> Bool {
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
            // A text field's own Undo is always there; the files' only when there is one.
            if type == .undo || type == .redo, !state.textEditing {
                let available = window.undoAvailable
                return (type == .undo ? available?.undo : available?.redo) ?? true
            }
            return true
        }
        func checked(_ type: RendererCommand) -> Bool? {
            switch type {
            case .viewAsIcons: state.viewMode == .icons
            case .viewAsList: state.viewMode == .list
            case .viewAsDetails: state.viewMode == .details
            case .sortByName: state.sortBy == .name
            case .sortByModified: state.sortBy == .modified
            case .sortBySize: state.sortBy == .size
            case .sortByKind: state.sortBy == .kind
            case .toggleFoldersFirst: state.foldersFirst
            case .toggleHiddenFiles: state.hiddenFilesShown
            case .toggleInfoPanel: state.infoPanelOpen
            case .toggleInfoRow: state.infoRowOpen
            default: nil
            }
        }

        var items = RendererCommand.allCases.filter { $0 != .toggleFavorite && $0 != .toggleFolderTree }
            .map { ApplicationMenuItemState(id: $0.rawValue, enabled: isEnabled($0), checked: checked($0)) }
        // A text field's own Undo and Redo while one (or another window) has the keyboard; the files' otherwise.
        let textUndo = state.textEditing || !window.explorerFocused
        for index in items.indices where items[index].id == "undo" || items[index].id == "redo" {
            items[index].visible = !textUndo
        }
        let textUndoEnabled = window.explorerFocused || window.otherWindowFocused != false
        items.append(contentsOf: [
            ApplicationMenuItemState(id: textUndoItemID, enabled: textUndoEnabled, visible: textUndo),
            ApplicationMenuItemState(id: textRedoItemID, enabled: textUndoEnabled, visible: textUndo),
            ApplicationMenuItemState(
                id: favoriteAddItemID, enabled: isEnabled(.toggleFavorite), visible: !state.favoriteIsSet),
            ApplicationMenuItemState(
                id: favoriteRemoveItemID, enabled: isEnabled(.toggleFavorite), visible: state.favoriteIsSet),
            ApplicationMenuItemState(
                id: folderTreeHideItemID, enabled: isEnabled(.toggleFolderTree), visible: state.folderTreeOpen),
            ApplicationMenuItemState(
                id: folderTreeShowItemID, enabled: isEnabled(.toggleFolderTree), visible: !state.folderTreeOpen),
        ])
        return items
    }

    // MARK: Applying the states

    /// What `applyApplicationMenuItemStates` needs of a menu item.
    public protocol ItemControl: AnyObject {
        var isEnabled: Bool { get set }
        var isVisible: Bool { get set }
        var isChecked: Bool { get set }
        /// A radio item is only ever switched on: that switches the others in its group off.
        var isRadio: Bool { get }
    }

    /// `applyApplicationMenuItemStates`: sets what changed on the items the menu has, and skips the others.
    public static func apply<Item: ItemControl>(_ states: [ApplicationMenuItemState], item: (String) -> Item?) {
        for state in states {
            guard let control = item(state.id) else { continue }
            if let enabled = state.enabled, control.isEnabled != enabled {
                control.isEnabled = enabled
            }
            if let visible = state.visible, control.isVisible != visible {
                control.isVisible = visible
            }
            if let checked = state.checked, control.isChecked != checked, !control.isRadio || checked {
                control.isChecked = checked
            }
        }
    }
}
