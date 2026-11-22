import Foundation

/// Checks everything a saved state holds: a value that is missing or invalid takes its default.
public enum PreferencesSanitizer {
    // MARK: Small checks

    private static func bool(_ record: [String: JSONNode], _ key: String, _ fallback: Bool) -> Bool {
        record[key]?.bool ?? fallback
    }

    private static func choice<Choice: RawRepresentable>(
        _ record: [String: JSONNode], _ key: String, _ fallback: Choice
    ) -> Choice where Choice.RawValue == String {
        record[key]?.string.flatMap { Choice(rawValue: $0) } ?? fallback
    }

    /// `density`, or for a file saved before it, Finder's sizes where all four Compact switches were on.
    private static func density(_ record: [String: JSONNode], _ fallback: Density) -> Density {
        if record["density"] != nil { return choice(record, "density", fallback) }
        let compact = ["compactListView", "compactDetailsView", "compactIconView", "compactTreeView"]
        guard compact.contains(where: { record[$0] != nil }) else { return fallback }
        return compact.allSatisfy { record[$0]?.bool == true } ? .finder : .standard
    }

    private static func viewMode(_ value: JSONNode?, _ fallback: ExplorerViewMode = .icons) -> ExplorerViewMode {
        value?.string.flatMap { ExplorerViewMode(rawValue: $0) } ?? fallback
    }

    private static func nonEmptyString(_ value: JSONNode?) -> String? {
        guard let text = value?.string, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Open tabs

    /// Tabs from a damaged file are kept as far as they make sense; a tab that does not is dropped rather than failing
    /// the whole list. A tab saved before it kept Favorites and Locations open or closed takes the window's setting,
    /// and a pane saved with settings of its own but not all of them takes the rest from `own`: its window's, as it
    /// showed them before each pane had its own.
    static func openTabs(
        _ value: JSONNode?, includeHidden: Bool, foldersFirst: Bool, favoritesExpanded: Bool, locationsExpanded: Bool,
        own: PaneViewSizes = PaneViewSizes(AppPreferences.defaults())
    ) -> [OpenTabPreference] {
        func viewSizes(_ value: JSONNode?) -> PaneViewSizes? {
            Self.viewSizes(value, own: own)
        }
        guard let candidates = value?.array else { return [] }
        var tabs: [OpenTabPreference] = []
        for candidate in candidates {
            guard let record = candidate.object else { continue }
            let sortBy = Self.sortBy(record)
            let firstHidden = bool(record, "includeHidden", includeHidden)
            let showsFoldersFirst = bool(record, "foldersFirst", foldersFirst)
            // A second pane takes what it doesn't say from the tab's first.
            var secondPane = record["secondPane"]?.object.map { pane in
                OpenPanePreference(
                    path: nonEmptyString(pane["path"]), viewMode: viewMode(pane["viewMode"]),
                    searchViewMode: viewMode(pane["searchViewMode"], .details), sortBy: Self.sortBy(pane),
                    sortDirection: pane["sortDirection"]?.string == "desc" ? .desc : .asc,
                    includeHidden: bool(pane, "includeHidden", firstHidden),
                    foldersFirst: bool(pane, "foldersFirst", showsFoldersFirst),
                    viewSizes: viewSizes(pane["viewSizes"]), filterMode: filterMode(pane["filterMode"]),
                    groupBy: groupBy(pane["groupBy"]), searchGroupBy: groupBy(pane["searchGroupBy"]),
                    groupReversed: bool(pane, "groupReversed", false),
                    searchGroupReversed: bool(pane, "searchGroupReversed", false),
                    viewer: ViewerPreference.sanitize(pane["viewer"]))
            }
            let activePane = record["activePane"]?.number == 1 ? 1 : nil
            // Hidden Files is the tab's: a tab saved while each pane had its own takes its active pane's.
            let includesHidden = activePane == 1 ? secondPane?.includeHidden ?? firstHidden : firstHidden
            secondPane?.includeHidden = includesHidden
            let split = record["paneSplit"]?.number.flatMap { $0.isFinite ? min(0.8, max(0.2, $0)) : nil }
            tabs.append(
                OpenTabPreference(
                    path: nonEmptyString(record["path"]), treeRootPath: nonEmptyString(record["treeRootPath"]),
                    favoritePath: nonEmptyString(record["favoritePath"]), viewMode: viewMode(record["viewMode"]),
                    searchViewMode: viewMode(record["searchViewMode"], .details), sortBy: sortBy,
                    sortDirection: record["sortDirection"]?.string == "desc" ? .desc : .asc,
                    includeHidden: includesHidden, foldersFirst: showsFoldersFirst,
                    favoritesExpanded: bool(record, "favoritesExpanded", favoritesExpanded),
                    locationsExpanded: bool(record, "locationsExpanded", locationsExpanded), secondPane: secondPane,
                    activePane: activePane, paneSplit: split,
                    viewSizes: viewSizes(record["viewSizes"]), filterMode: filterMode(record["filterMode"]),
                    groupBy: groupBy(record["groupBy"]), searchGroupBy: groupBy(record["searchGroupBy"]),
                    groupReversed: bool(record, "groupReversed", false),
                    searchGroupReversed: bool(record, "searchGroupReversed", false),
                    viewer: ViewerPreference.sanitize(record["viewer"]).flatMap { $0.mode == .inPlace ? $0 : nil }))
            if tabs.count == AppPreferenceLimits.openTabsLimit {
                break
            }
        }
        return tabs
    }

    /// A pane's own filter mode; nil when the file has none for it, or one this build doesn't know.
    private static func filterMode(_ value: JSONNode?) -> NameMatchMode? {
        value?.string.flatMap(NameMatchMode.init(rawValue:))
    }

    /// What a pane groups by; nil when the file has none, or one this build doesn't know.
    private static func groupBy(_ value: JSONNode?) -> GroupByPreference? {
        value?.string.flatMap(GroupByPreference.init(rawValue:))
    }

    /// A pane's own sizes, columns and search settings, each checked; nil when the file has none for it. A folder's
    /// size it doesn't say is the size before any is set. Its columns, their order and widths, its results' order and
    /// its search options, where it doesn't say them, are `own`: its window's, which showed them in every pane before
    /// each pane had its own, so a pane saved then comes back as it was. Its results' sizes, where it has none, are
    /// its folders', as results showed at those.
    private static func viewSizes(_ value: JSONNode?, own: PaneViewSizes) -> PaneViewSizes? {
        guard let record = value?.object else { return nil }
        var sizes = own
        sizes.iconSizes = densitySizes(record["iconSizes"], .iconDefaults) { AppPreferenceLimits.clampIconSize($0) }
        sizes.compactListWidths = densitySizes(record["compactListWidths"], .compactListDefaults) {
            AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
        }
        sizes.previewCounts = densitySizes(record["previewCounts"], .previewCountDefaults) {
            PreviewGrid.valid(read: $0)
        }
        sizes.detailColumns = detailColumns(record["detailColumns"], sizes.detailColumns)
        if record["detailColumnOrder"] != nil {
            sizes.detailColumnOrder = AppPreferenceLimits.normalizeDetailColumnOrder(record["detailColumnOrder"])
        }
        sizes.detailColumnWidths = detailColumnWidths(record["detailColumnWidths"], own.detailColumnWidths)
        sizes.searchIconSizes = densitySizes(record["searchIconSizes"], sizes.iconSizes) {
            AppPreferenceLimits.clampIconSize($0)
        }
        sizes.searchCompactListWidths = densitySizes(record["searchCompactListWidths"], sizes.compactListWidths) {
            AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
        }
        sizes.searchPreviewCounts = densitySizes(record["searchPreviewCounts"], sizes.previewCounts) {
            PreviewGrid.valid(read: $0)
        }
        sizes.searchColumns = searchColumns(record["searchColumns"], sizes.searchColumns)
        if record["searchColumnOrder"] != nil {
            sizes.searchColumnOrder = AppPreferenceLimits.normalizeSearchColumnOrder(record["searchColumnOrder"])
        }
        sizes.searchColumnWidths = searchColumnWidths(record["searchColumnWidths"], own.searchColumnWidths)
        sizes.searchResultsSortBy = choice(record, "searchResultsSortBy", sizes.searchResultsSortBy)
        sizes.searchResultsSortDirection = choice(
            record, "searchResultsSortDirection", sizes.searchResultsSortDirection)
        sizes.searchPatternMode = choice(record, "searchPatternMode", sizes.searchPatternMode)
        sizes.searchMatchScope = choice(record, "searchMatchScope", sizes.searchMatchScope)
        sizes.searchRecursive = bool(record, "searchRecursive", sizes.searchRecursive)
        sizes.searchSkipGitFolders = bool(record, "searchSkipGitFolders", sizes.searchSkipGitFolders)
        sizes.searchSkipGitIgnored = bool(record, "searchSkipGitIgnored", sizes.searchSkipGitIgnored)
        return sizes
    }

    /// How a tab view shows search results, as the file has it, each part checked as a pane's own is: one the file
    /// doesn't say, or says wrongly, is as a new install has it, a column's order is made whole, and a width or a size
    /// is brought into its range. Nil for what is no record at all.
    static func searchResultsKeeps(_ value: JSONNode?) -> SearchResultsKeeps? {
        guard let record = value?.object else { return nil }
        var keeps = SearchResultsKeeps.defaults
        keeps.view = viewMode(record["view"], keeps.view)
        keeps.sortBy = choice(record, "sortBy", keeps.sortBy)
        keeps.sortDirection = choice(record, "sortDirection", keeps.sortDirection)
        keeps.groupBy = groupBy(record["groupBy"]).flatMap { $0.isForSearch ? $0 : nil } ?? .none
        keeps.groupReversed = keeps.groupBy != .none && bool(record, "groupReversed", false)
        keeps.columns = searchColumns(record["columns"], keeps.columns)
        if record["columnOrder"] != nil {
            keeps.columnOrder = AppPreferenceLimits.normalizeSearchColumnOrder(record["columnOrder"])
        }
        keeps.columnWidths = searchColumnWidths(record["columnWidths"], keeps.columnWidths)
        keeps.iconSizes = densitySizes(record["iconSizes"], keeps.iconSizes) { AppPreferenceLimits.clampIconSize($0) }
        keeps.compactListWidths = densitySizes(record["compactListWidths"], keeps.compactListWidths) {
            AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
        }
        keeps.previewCounts = densitySizes(record["previewCounts"], keeps.previewCounts) {
            PreviewGrid.valid(read: $0)
        }
        return keeps
    }

    private static func sortBy(_ record: [String: JSONNode]) -> SortByPreference {
        switch record["sortBy"]?.string {
        case "modified": .modified
        case "kind": .kind
        case "size": .size
        case "added": .added
        case "lastOpened": .lastOpened
        case "created": .created
        default: .name
        }
    }

    // MARK: Favorites and applications

    private static func favorites(_ value: JSONNode?, _ fallback: [FavoritePreference]) -> [FavoritePreference] {
        guard let entries = value?.array else { return fallback }
        var seen = Set<DiskPath>()
        var favorites: [FavoritePreference] = []
        for entry in entries {
            guard let record = entry.object else { continue }
            let path = JSString.trimmed(record["path"]?.string ?? "")
            guard !path.isEmpty, let icon = record["icon"]?.string.flatMap({ FavoriteIconID(rawValue: $0) }) else {
                continue
            }
            // De-duplicated by path, byte for byte.
            if seen.insert(DiskPath(path)).inserted {
                favorites.append(FavoritePreference(path: path, icon: icon))
            }
        }
        return favorites
    }

    private static func application(_ value: JSONNode?) -> ApplicationSelection? {
        guard let record = value?.object else { return nil }
        let appPath = JSString.trimmed(record["appPath"]?.string ?? "")
        let appName = JSString.trimmed(record["appName"]?.string ?? "")
        if appPath.isEmpty || appName.isEmpty {
            return nil
        }
        return ApplicationSelection(appPath: appPath, appName: appName)
    }

    private static func openWithApplications(_ value: JSONNode?, _ defaults: [OpenWithApplication])
        -> [OpenWithApplication]
    {
        guard let entries = value?.array else { return defaults }
        // A pinned app that can't be read is dropped; the others are kept.
        return entries.compactMap { entry in
            guard let record = entry.object else { return nil }
            let id = JSString.trimmed(record["id"]?.string ?? "")
            let appPath = JSString.trimmed(record["appPath"]?.string ?? "")
            let appName = JSString.trimmed(record["appName"]?.string ?? "")
            if id.isEmpty || appPath.isEmpty || appName.isEmpty {
                return nil
            }
            return OpenWithApplication(id: id, appPath: appPath, appName: appName)
        }
    }

    // MARK: Columns

    private static func detailColumns(_ value: JSONNode?, _ defaults: DetailColumnVisibility) -> DetailColumnVisibility
    {
        // Optional detail columns are stored as booleans, but the runtime expects a full record.
        guard let record = value?.object else { return defaults }
        var result = defaults
        for key in OptionalDetailColumnKey.allCases {
            result[key] = record[key.rawValue]?.bool ?? defaults[key]
        }
        return result
    }

    private static func searchColumns(_ value: JSONNode?, _ defaults: SearchColumnVisibility) -> SearchColumnVisibility
    {
        guard let record = value?.object else { return defaults }
        var result = defaults
        for key in OptionalSearchColumnKey.allCases {
            result[key] = record[key.rawValue]?.bool ?? defaults[key]
        }
        return result
    }

    private static func detailColumnWidths(_ value: JSONNode?, _ defaults: DetailColumnWidths) -> DetailColumnWidths {
        // Widths are clamped per column so a bad saved value cannot collapse or explode the table.
        guard let record = value?.object else { return defaults }
        var result = defaults
        for key in DetailColumnKey.allCases {
            result[key] = AppPreferenceLimits.clampDetailColumnWidth(
                key, record[key.rawValue]?.number ?? Double(defaults[key]))
        }
        return result
    }

    private static func searchColumnWidths(_ value: JSONNode?, _ defaults: SearchColumnWidths) -> SearchColumnWidths {
        guard let record = value?.object else { return defaults }
        var result = defaults
        for key in SearchColumnKey.allCases {
            result[key] = AppPreferenceLimits.clampSearchColumnWidth(
                key, record[key.rawValue]?.number ?? Double(defaults[key]))
        }
        return result
    }

    /// A size for each density, each checked by `clamp`; a missing one is its default.
    private static func densitySizes(
        _ value: JSONNode?, _ defaults: DensitySizes, clamp: (Double) -> Int
    ) -> DensitySizes {
        guard let record = value?.object else { return defaults }
        var result = defaults
        for density in Density.allCases {
            result[density] = clamp(record[density.rawValue]?.number ?? Double(defaults[density]))
        }
        return result
    }

    // MARK: Preferences

    /// Every saved value is checked; one that is missing or invalid takes its default from
    /// `defaults` (what a new install starts with, or the preferences a change is applied to).
    public static func sanitize(_ value: JSONNode?, defaults: AppPreferences) -> AppPreferences {
        guard let record = value?.object else { return defaults }
        let global = AppPreferences.defaults()
        let detailWidths = detailColumnWidths(record["detailColumnWidths"], defaults.detailColumnWidths)
        let searchWidths = searchColumnWidths(record["searchColumnWidths"], defaults.searchColumnWidths)
        var checked = AppPreferences(
            theme: choice(record, "theme", defaults.theme),
            accent: record["accent"]?.string.map { AppPreferenceLimits.normalizeAccent($0) ?? defaults.accent }
                ?? defaults.accent,
            viewMode: viewMode(record["viewMode"]),
            searchViewMode: viewMode(record["searchViewMode"], global.searchViewMode),
            sortBy: choice(record, "sortBy", defaults.sortBy),
            sortDirection: choice(record, "sortDirection", defaults.sortDirection),
            foldersFirst: bool(record, "foldersFirst", defaults.foldersFirst),
            density: density(record, defaults.density),
            singleClickExpandTreeItems: bool(record, "singleClickExpandTreeItems", defaults.singleClickExpandTreeItems),
            detailColumns: detailColumns(record["detailColumns"], defaults.detailColumns),
            detailColumnOrder: record["detailColumnOrder"] == nil
                ? defaults.detailColumnOrder
                : AppPreferenceLimits.normalizeDetailColumnOrder(record["detailColumnOrder"]),
            detailColumnWidths: detailWidths,
            searchColumns: searchColumns(record["searchColumns"], defaults.searchColumns),
            searchColumnOrder: record["searchColumnOrder"] == nil
                ? defaults.searchColumnOrder
                : AppPreferenceLimits.normalizeSearchColumnOrder(record["searchColumnOrder"]),
            searchColumnWidths: searchWidths,
            compactListWidths: densitySizes(record["compactListWidths"], defaults.compactListWidths) {
                AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
            },
            iconSizes: densitySizes(record["iconSizes"], defaults.iconSizes) { AppPreferenceLimits.clampIconSize($0) },
            previewCounts: densitySizes(record["previewCounts"], defaults.previewCounts) {
                PreviewGrid.valid(read: $0)
            },
            searchCompactListWidths: densitySizes(record["searchCompactListWidths"], defaults.searchCompactListWidths) {
                AppPreferenceLimits.clampPaneWidth($0, AppPreferenceLimits.compactListWidthRange)
            },
            searchIconSizes: densitySizes(record["searchIconSizes"], defaults.searchIconSizes) {
                AppPreferenceLimits.clampIconSize($0)
            },
            searchPreviewCounts: densitySizes(record["searchPreviewCounts"], defaults.searchPreviewCounts) {
                PreviewGrid.valid(read: $0)
            },
            notificationsEnabled: bool(record, "notificationsEnabled", defaults.notificationsEnabled),
            markClipboardItems: bool(record, "markClipboardItems", defaults.markClipboardItems),
            autoCalculateFolderSizes: bool(record, "autoCalculateFolderSizes", defaults.autoCalculateFolderSizes),
            folderTreeOpen: bool(record, "folderTreeOpen", defaults.folderTreeOpen),
            propertiesOpen: bool(record, "propertiesOpen", defaults.propertiesOpen),
            detailRowOpen: bool(record, "detailRowOpen", defaults.detailRowOpen),
            topToolbarItems: record["topToolbarItems"]?.array != nil
                ? ToolbarItems.sanitizeTopItems(record["topToolbarItems"]) : defaults.topToolbarItems,
            terminalApp: application(record["terminalApp"]),
            defaultTextEditor: application(record["defaultTextEditor"]) ?? defaults.defaultTextEditor,
            openWithApplications: openWithApplications(record["openWithApplications"], defaults.openWithApplications),
            diskImageOpensIn: choice(record, "diskImageOpensIn", defaults.diskImageOpensIn),
            returnKeyAction: choice(record, "returnKeyAction", defaults.returnKeyAction),
            shortcutOverrides: ShortcutCommands.sanitizeOverrides(record["shortcutOverrides"]),
            openItemLimit: AppPreferenceLimits.clampOpenItemLimit(
                record["openItemLimit"]?.number ?? Double(defaults.openItemLimit)),
            includeHidden: bool(record, "includeHidden", defaults.includeHidden),
            searchPatternMode: choice(record, "searchPatternMode", defaults.searchPatternMode),
            searchMatchScope: choice(record, "searchMatchScope", defaults.searchMatchScope),
            searchRecursive: bool(record, "searchRecursive", defaults.searchRecursive),
            searchSkipGitFolders: bool(record, "searchSkipGitFolders", defaults.searchSkipGitFolders),
            searchSkipGitIgnored: bool(record, "searchSkipGitIgnored", defaults.searchSkipGitIgnored),
            searchResultsSortBy: choice(record, "searchResultsSortBy", defaults.searchResultsSortBy),
            searchResultsSortDirection: choice(
                record, "searchResultsSortDirection", defaults.searchResultsSortDirection),
            searchGroupBy: groupBy(record["searchGroupBy"]).flatMap { $0.isForSearch ? $0 : nil }
                ?? defaults.searchGroupBy,
            searchGroupReversed: bool(record, "searchGroupReversed", defaults.searchGroupReversed),
            treeWidth: AppPreferenceLimits.clampPaneWidth(
                record["treeWidth"]?.number ?? Double(defaults.treeWidth), AppPreferenceLimits.treeWidthRange),
            inspectorWidth: AppPreferenceLimits.clampPaneWidth(
                record["inspectorWidth"]?.number ?? Double(defaults.inspectorWidth),
                AppPreferenceLimits.inspectorWidthRange),
            restoreSessionOnStartup: bool(record, "restoreSessionOnStartup", defaults.restoreSessionOnStartup),
            openTabs: [],
            activeTabIndex: activeTabIndex(record["activeTabIndex"]),
            treeRootPath: nonEmptyString(record["treeRootPath"]),
            lastVisitedPath: nonEmptyString(record["lastVisitedPath"]),
            lastVisitedFavoritePath: nonEmptyString(record["lastVisitedFavoritePath"]),
            favorites: favorites(record["favorites"], defaults.favorites),
            favoritesPlacement: choice(record, "favoritesPlacement", defaults.favoritesPlacement),
            favoritesExpanded: bool(record, "favoritesExpanded", defaults.favoritesExpanded),
            locationsExpanded: bool(record, "locationsExpanded", defaults.locationsExpanded),
            favoritesInitialized: bool(record, "favoritesInitialized", defaults.favoritesInitialized),
            batchRenameSettings: BatchRename.sanitizeSettings(record["batchRenameSettings"]),
            batchRenamePresets: BatchRename.sanitizePresets(record["batchRenamePresets"]),
            listFilterMatch: choice(record, "listFilterMatch", defaults.listFilterMatch),
            convertImagesSettings: ConvertImagesSettings.sanitize(record["convertImagesSettings"]),
            textViewerSettings: TextViewerSettings.sanitize(record["textViewerSettings"]),
            // A record that doesn't hold them (a window's session read over the app's) keeps the ones it has.
            tabViews: record["tabViews"] == nil ? defaults.tabViews : TabViews.sanitize(record["tabViews"]),
            windowViews: record["windowViews"] == nil
                ? defaults.windowViews : WindowViews.sanitize(record["windowViews"]),
            // Read on its own, as every key is: one that names no tab view does nothing (`applyNewTabView`).
            newTabViewID: record["newTabViewID"] == nil
                ? defaults.newTabViewID : nonEmptyString(record["newTabViewID"]))
        // The tabs last: a pane saved without some of its own settings takes those read here.
        checked.openTabs = openTabs(
            record["openTabs"], includeHidden: defaults.includeHidden, foldersFirst: defaults.foldersFirst,
            favoritesExpanded: checked.favoritesExpanded, locationsExpanded: checked.locationsExpanded,
            own: PaneViewSizes(checked))
        return checked
    }

    /// A whole number, zero or more; anything else is zero. A number past what a count can be stops at the largest.
    private static func activeTabIndex(_ value: JSONNode?) -> Int {
        guard let number = value?.integer, number >= 0 else { return 0 }
        return number >= 9_007_199_254_740_991 ? Int(9_007_199_254_740_991) : Int(number)
    }
}
