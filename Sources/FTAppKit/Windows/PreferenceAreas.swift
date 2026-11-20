// Which parts of a tab read which preference
import FTFoundation

/// The parts of a tab that read the preferences, each done again only when a preference it reads changed. A change is
/// told to every tab of every window, and most are of one part: a column's width dragged in one tab is no reason to
/// build the folder tree again in the others.
struct PreferenceAreas: OptionSet, Sendable {
    let rawValue: Int

    /// The folder tree and the favorites: its rows are worked out and laid out again (`SidebarViewController
    /// .applyPreferences`).
    static let sidebar = PreferenceAreas(rawValue: 1 << 0)
    /// The panes' columns and sizes (`ListColumnState`), the keys the size slider names, and what a pane noted of the
    /// columns and sizes it changed.
    static let columns = PreferenceAreas(rawValue: 1 << 1)
    /// The notifications on screen, which go when they are turned off.
    static let notifications = PreferenceAreas(rawValue: 1 << 2)
    /// The marks of copied and cut items, in the lists and the tree.
    static let clipboardMarks = PreferenceAreas(rawValue: 1 << 3)
    /// What hears `ExplorerWindowChange.preferences`: the toolbar, the Info panel and the menus.
    static let commands = PreferenceAreas(rawValue: 1 << 4)

    static let all: PreferenceAreas = [.sidebar, .columns, .notifications, .clipboardMarks, .commands]

    /// What of a tab is done again for `change`. The tab of the window that made the change goes by every key it set,
    /// also one set to the value it had, as what it changed of its own (a pane's sizes) may show only now, and its
    /// toolbar and menus always follow; the other tabs go by the keys whose values changed. A change that doesn't say
    /// what it set is everything.
    static func touched(by change: PreferencesChange, inWindow windowID: Int?) -> PreferenceAreas {
        let isSender = change.senderID != nil && change.senderID == windowID
        guard let keys = isSender ? change.written : change.changed else { return .all }
        var areas: PreferenceAreas = isSender ? .commands : []
        for key in keys { areas.formUnion(key.areas) }
        return areas
    }
}

extension PreferenceKey {
    /// The parts of a tab that read this preference. Every key is listed, so a new one has to be given its parts. A
    /// key is left out of `commands` only where nothing of the toolbar, the Info panel or the menus reads it: the
    /// widths and sizes, which only the lists read.
    var areas: PreferenceAreas {
        switch self {
        case .density:
            // The tree's row height, the lists' sizes at each density, and the menus' check.
            [.sidebar, .columns, .commands]
        case .favorites, .favoritesPlacement, .favoritesInitialized, .singleClickExpandTreeItems:
            [.sidebar, .commands]
        case .detailColumns, .detailColumnOrder, .searchColumns, .searchColumnOrder:
            // The menus check the columns shown.
            [.columns, .commands]
        case .detailColumnWidths, .searchColumnWidths, .compactListWidths, .iconSizes, .previewCounts:
            .columns
        case .shortcutOverrides:
            // The size slider names the keys of the size commands.
            [.columns, .commands]
        case .notificationsEnabled:
            [.notifications, .commands]
        case .markClipboardItems:
            [.clipboardMarks, .commands]
        case .theme, .accent, .viewMode, .searchViewMode, .sortBy, .sortDirection, .foldersFirst,
            .autoCalculateFolderSizes, .folderTreeOpen, .propertiesOpen, .detailRowOpen, .topToolbarItems,
            .terminalApp, .defaultTextEditor, .openWithApplications, .diskImageOpensIn, .returnKeyAction,
            .openItemLimit, .includeHidden, .searchPatternMode, .searchMatchScope, .searchRecursive,
            .searchSkipGitFolders, .searchSkipGitIgnored, .searchResultsSortBy, .searchResultsSortDirection,
            .treeWidth, .inspectorWidth, .restoreSessionOnStartup, .openTabs, .activeTabIndex, .treeRootPath,
            .lastVisitedPath, .lastVisitedFavoritePath, .favoritesExpanded, .locationsExpanded,
            .batchRenameSettings, .batchRenamePresets, .listFilterMatch, .workspaces, .convertImagesSettings:
            .commands
        }
    }
}
