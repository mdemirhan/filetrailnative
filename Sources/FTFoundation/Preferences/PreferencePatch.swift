// Port of apps/desktop/src/main/bootstrap/preferencesPatch.ts
import Foundation

extension AppPreferences {
    /// The preference keys, in the order of `DEFAULT_APP_PREFERENCES`.
    public static let keys: [String] = [
        "theme", "accent", "zoomPercent", "viewMode", "searchViewMode", "sortBy", "sortDirection", "foldersFirst",
        "compactListView", "compactDetailsView", "compactIconView", "compactTreeView", "singleClickExpandTreeItems",
        "detailColumns", "detailColumnOrder", "detailColumnWidths", "searchColumns", "searchColumnOrder",
        "searchColumnWidths", "notificationsEnabled", "markClipboardItems", "autoCalculateFolderSizes",
        "folderTreeOpen", "propertiesOpen", "detailRowOpen", "topToolbarItems", "terminalApp", "defaultTextEditor",
        "openWithApplications", "fileActivationAction", "diskImageOpensIn", "returnKeyAction", "shortcutOverrides",
        "openItemLimit", "includeHidden", "searchPatternMode", "searchMatchScope", "searchRecursive",
        "searchSkipGitFolders", "searchSkipGitIgnored", "searchResultsSortBy", "searchResultsSortDirection",
        "treeWidth", "inspectorWidth", "restoreSessionOnStartup", "openTabs", "activeTabIndex", "treeRootPath",
        "lastVisitedPath", "lastVisitedFavoritePath", "favorites", "favoritesPlacement", "favoritesExpanded",
        "locationsExpanded", "favoritesInitialized", "batchRenameSettings", "batchRenamePresets",
    ]

    private static let keySet = Set(keys)

    /// `toPreferencePatch`: a change sent by a window, as the store applies it. Keys are mapped explicitly so a new
    /// preference is added on purpose rather than flowing through as an unchecked payload: what is not a preference is
    /// dropped. Values that are false, zero, empty or null are changes too.
    public static func patch(from value: [String: JSONNode]) -> [String: JSONNode] {
        value.filter { keySet.contains($0.key) }
    }
}
