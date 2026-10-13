// Port of AppPreferences and DEFAULT_APP_PREFERENCES in apps/desktop/src/shared/appPreferences.ts
import Foundation

/// The durable shape written to `app-state.json`. A saved value the loader does not recognize falls back to its
/// default. It reads and writes the same JSON keys as the original, so files round-trip.
public struct AppPreferences: Codable, Equatable, Sendable {
    public var theme: ThemePreference
    public var accent: String
    /// Kept so files round-trip and imports work; nothing uses it (DEVIATIONS D-005).
    public var zoomPercent: Int
    public var viewMode: ExplorerViewMode
    /// The view search results are shown in, for the tab on screen; List to begin with.
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var foldersFirst: Bool
    public var compactListView: Bool
    public var compactDetailsView: Bool
    public var compactIconView: Bool
    public var compactTreeView: Bool
    public var singleClickExpandTreeItems: Bool
    public var detailColumns: DetailColumnVisibility
    public var detailColumnOrder: [OptionalDetailColumnKey]
    public var detailColumnWidths: DetailColumnWidths
    public var searchColumns: SearchColumnVisibility
    public var searchColumnOrder: [OptionalSearchColumnKey]
    public var searchColumnWidths: SearchColumnWidths
    public var notificationsEnabled: Bool
    /// Items that were copied or cut flash and keep a mark, in the folder tree and the file list.
    public var markClipboardItems: Bool
    /// With the Info panel open, the one folder selected in the home folder is measured by itself.
    public var autoCalculateFolderSizes: Bool
    /// The folder tree on the left (View > Hide Folder Tree).
    public var folderTreeOpen: Bool
    public var propertiesOpen: Bool
    public var detailRowOpen: Bool
    public var topToolbarItems: [ToolbarItemID]
    @NullEncoded public var terminalApp: ApplicationSelection?
    public var defaultTextEditor: ApplicationSelection
    public var openWithApplications: [OpenWithApplication]
    public var fileActivationAction: FileActivationAction
    public var diskImageOpensIn: DiskImageOpensIn
    public var returnKeyAction: ReturnKeyAction
    /// The keyboard shortcuts that differ from their defaults, by command.
    public var shortcutOverrides: ShortcutOverrides
    public var openItemLimit: Int
    public var includeHidden: Bool
    public var searchPatternMode: SearchPatternModePreference
    public var searchMatchScope: SearchMatchScopePreference
    public var searchRecursive: Bool
    public var searchSkipGitFolders: Bool
    public var searchSkipGitIgnored: Bool
    public var searchResultsSortBy: SearchResultsSortByPreference
    public var searchResultsSortDirection: SortDirectionPreference
    public var treeWidth: Int
    public var inspectorWidth: Int
    /// Start where the last session ended: its folder, and its tabs.
    public var restoreSessionOnStartup: Bool
    /// The tabs that were open, in order, and which one was on screen.
    public var openTabs: [OpenTabPreference]
    public var activeTabIndex: Int
    @NullEncoded public var treeRootPath: String?
    @NullEncoded public var lastVisitedPath: String?
    @NullEncoded public var lastVisitedFavoritePath: String?
    public var favorites: [FavoritePreference]
    public var favoritesPlacement: FavoritesPlacement
    public var favoritesExpanded: Bool
    /// The sidebar's Locations (the disks), shown or folded.
    public var locationsExpanded: Bool
    public var favoritesInitialized: Bool
    /// The Rename sheet for several items: its settings as last used, and the ones saved by name. Held as JSON until
    /// the batch-rename package's sanitizers are wired in (see `BatchRenameSanitizers`).
    public var batchRenameSettings: JSONNode
    public var batchRenamePresets: JSONNode

    /// DEFAULT_APP_PREFERENCES, with the theme a new install starts with (`createDefaultPreferences`).
    public static func defaults(theme: ThemePreference = .auto) -> AppPreferences {
        AppPreferences(
            theme: theme, accent: AppPreferenceLimits.defaultAccent, zoomPercent: 100, viewMode: .icons,
            searchViewMode: .details, sortBy: .name, sortDirection: .asc, foldersFirst: true, compactListView: false,
            compactDetailsView: false, compactIconView: false, compactTreeView: false,
            singleClickExpandTreeItems: false, detailColumns: .defaults,
            detailColumnOrder: AppPreferenceLimits.defaultDetailColumnOrder, detailColumnWidths: .defaults,
            searchColumns: .defaults, searchColumnOrder: AppPreferenceLimits.defaultSearchColumnOrder,
            searchColumnWidths: .defaults, notificationsEnabled: true, markClipboardItems: true,
            autoCalculateFolderSizes: true, folderTreeOpen: true, propertiesOpen: false, detailRowOpen: false,
            topToolbarItems: ToolbarItems.defaultTopItems, terminalApp: nil,
            defaultTextEditor: AppPreferenceLimits.defaultTextEditor, openWithApplications: [],
            fileActivationAction: .open, diskImageOpensIn: .window, returnKeyAction: .rename, shortcutOverrides: [:],
            openItemLimit: 5, includeHidden: false, searchPatternMode: .text, searchMatchScope: .name,
            searchRecursive: true, searchSkipGitFolders: true, searchSkipGitIgnored: false,
            searchResultsSortBy: .path, searchResultsSortDirection: .asc, treeWidth: 280, inspectorWidth: 320,
            restoreSessionOnStartup: true, openTabs: [], activeTabIndex: 0, treeRootPath: nil, lastVisitedPath: nil,
            lastVisitedFavoritePath: nil, favorites: [], favoritesPlacement: .integrated, favoritesExpanded: true,
            locationsExpanded: true, favoritesInitialized: false,
            batchRenameSettings: BatchRenameSanitizers.defaultSettings, batchRenamePresets: .array([]))
    }
}

/// The keys the original keeps per window (WINDOW_SESSION_PREFERENCE_KEYS); the other keys belong to the app.
public enum WindowSessionKeys {
    public static let all: [String] = [
        "openTabs", "activeTabIndex", "treeRootPath", "lastVisitedPath", "lastVisitedFavoritePath", "viewMode",
        "searchViewMode", "sortBy", "sortDirection", "searchResultsSortBy", "searchResultsSortDirection",
        "includeHidden", "foldersFirst", "favoritesExpanded", "locationsExpanded", "folderTreeOpen", "propertiesOpen",
        "detailRowOpen", "treeWidth", "inspectorWidth", "detailColumnWidths", "searchColumnWidths",
    ]

    private static let set = Set(all)

    /// `isWindowSessionKey`.
    public static func isSessionKey(_ key: String) -> Bool { set.contains(key) }
}

/// What belongs to one explorer window rather than to the app: its tabs and where they are, how its front tab shows its
/// folder, which of its panels are open and how wide, and how wide its columns are. Each window keeps its own; the
/// app's preferences hold the values last set in any window, which a window opened without one of its own starts from.
public struct WindowSession: Codable, Equatable, Sendable {
    public var openTabs: [OpenTabPreference]
    public var activeTabIndex: Int
    @NullEncoded public var treeRootPath: String?
    @NullEncoded public var lastVisitedPath: String?
    @NullEncoded public var lastVisitedFavoritePath: String?
    public var viewMode: ExplorerViewMode
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var searchResultsSortBy: SearchResultsSortByPreference
    public var searchResultsSortDirection: SortDirectionPreference
    public var includeHidden: Bool
    public var foldersFirst: Bool
    public var favoritesExpanded: Bool
    public var locationsExpanded: Bool
    public var folderTreeOpen: Bool
    public var propertiesOpen: Bool
    public var detailRowOpen: Bool
    public var treeWidth: Int
    public var inspectorWidth: Int
    public var detailColumnWidths: DetailColumnWidths
    public var searchColumnWidths: SearchColumnWidths

    /// `pickWindowSession` given whole preferences: a whole session.
    public init(_ preferences: AppPreferences) {
        openTabs = preferences.openTabs
        activeTabIndex = preferences.activeTabIndex
        treeRootPath = preferences.treeRootPath
        lastVisitedPath = preferences.lastVisitedPath
        lastVisitedFavoritePath = preferences.lastVisitedFavoritePath
        viewMode = preferences.viewMode
        searchViewMode = preferences.searchViewMode
        sortBy = preferences.sortBy
        sortDirection = preferences.sortDirection
        searchResultsSortBy = preferences.searchResultsSortBy
        searchResultsSortDirection = preferences.searchResultsSortDirection
        includeHidden = preferences.includeHidden
        foldersFirst = preferences.foldersFirst
        favoritesExpanded = preferences.favoritesExpanded
        locationsExpanded = preferences.locationsExpanded
        folderTreeOpen = preferences.folderTreeOpen
        propertiesOpen = preferences.propertiesOpen
        detailRowOpen = preferences.detailRowOpen
        treeWidth = preferences.treeWidth
        inspectorWidth = preferences.inspectorWidth
        detailColumnWidths = preferences.detailColumnWidths
        searchColumnWidths = preferences.searchColumnWidths
    }

    /// The preferences as a window with this session sees them (`{ ...preferences, ...window.session }`).
    public func applied(to preferences: AppPreferences) -> AppPreferences {
        var merged = preferences
        merged.openTabs = openTabs
        merged.activeTabIndex = activeTabIndex
        merged.treeRootPath = treeRootPath
        merged.lastVisitedPath = lastVisitedPath
        merged.lastVisitedFavoritePath = lastVisitedFavoritePath
        merged.viewMode = viewMode
        merged.searchViewMode = searchViewMode
        merged.sortBy = sortBy
        merged.sortDirection = sortDirection
        merged.searchResultsSortBy = searchResultsSortBy
        merged.searchResultsSortDirection = searchResultsSortDirection
        merged.includeHidden = includeHidden
        merged.foldersFirst = foldersFirst
        merged.favoritesExpanded = favoritesExpanded
        merged.locationsExpanded = locationsExpanded
        merged.folderTreeOpen = folderTreeOpen
        merged.propertiesOpen = propertiesOpen
        merged.detailRowOpen = detailRowOpen
        merged.treeWidth = treeWidth
        merged.inspectorWidth = inspectorWidth
        merged.detailColumnWidths = detailColumnWidths
        merged.searchColumnWidths = searchColumnWidths
        return merged
    }

    /// `frontTabIndex`: which of the window's tabs is in front; an index past its last tab is its last tab.
    public var frontTabIndex: Int {
        min(activeTabIndex, max(0, openTabs.count - 1))
    }
}

extension AppPreferences {
    /// `pickWindowSession(preferences)`.
    public var windowSession: WindowSession { WindowSession(self) }
}
