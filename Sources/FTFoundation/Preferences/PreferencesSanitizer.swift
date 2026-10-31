// Port of sanitizePreferences and its helpers in apps/desktop/src/main/appStateStore.ts (:556-884)
import Foundation

/// How the Rename sheet's saved settings and presets are checked: by the batch-rename package (`standard`).
public struct BatchRenameSanitizers: Sendable {
    public var settings: @Sendable (JSONNode?) -> JSONNode
    public var presets: @Sendable (JSONNode?) -> JSONNode

    public init(
        settings: @escaping @Sendable (JSONNode?) -> JSONNode, presets: @escaping @Sendable (JSONNode?) -> JSONNode
    ) {
        self.settings = settings
        self.presets = presets
    }

    /// DEFAULT_BATCH_RENAME_SETTINGS (shared/batchRename.ts).
    public static let defaultSettings: JSONNode = .object([
        "mode": .string("replace"), "find": .string(""), "replaceWith": .string(""), "matchCase": .bool(false),
        "useRegex": .bool(false), "addText": .string(""), "addWhere": .string("after"),
        "nameFormat": .string("index"), "formatWhere": .string("after"), "customName": .string("File"),
        "keepNames": .bool(false), "startAt": .number(1), "step": .number(1), "digits": .number(5),
        "separator": .string(" "), "dateSource": .string("created"), "dateFormat": .string("ymd"),
        "dateSeparator": .string("-"), "customDatePattern": .string("YYYY-MM-DD at HH.mm"),
        "caseStyle": .string("lower"), "applyTo": .string("name"), "onConflict": .string("number"),
    ])

    /// The batch-rename package's checks (`sanitizeBatchRenameSettings`, `sanitizeBatchRenamePresets`).
    public static let standard = BatchRenameSanitizers(
        settings: { value in BatchRename.node(of: BatchRename.sanitizeSettings(value)) },
        presets: { value in
            .array(
                BatchRename.sanitizePresets(value).map { preset in
                    .object(["name": .string(preset.name), "settings": BatchRename.node(of: preset.settings)])
                })
        })
}

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

    /// `sanitizeViewMode`.
    private static func viewMode(_ value: JSONNode?, _ fallback: ExplorerViewMode = .icons) -> ExplorerViewMode {
        value?.string.flatMap { ExplorerViewMode(rawValue: $0) } ?? fallback
    }

    private static func nonEmptyString(_ value: JSONNode?) -> String? {
        guard let text = value?.string, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Open tabs

    /// Tabs from a damaged file are kept as far as they make sense; a tab that does not is dropped rather than failing
    /// the whole list. A tab saved before it kept Favorites and Locations open or closed takes the window's setting.
    static func openTabs(
        _ value: JSONNode?, includeHidden: Bool, foldersFirst: Bool, favoritesExpanded: Bool, locationsExpanded: Bool
    ) -> [OpenTabPreference] {
        guard let candidates = value?.array else { return [] }
        var tabs: [OpenTabPreference] = []
        for candidate in candidates {
            guard let record = candidate.object else { continue }
            let sortBy: SortByPreference =
                switch record["sortBy"]?.string {
                case "modified": .modified
                case "kind": .kind
                case "size": .size
                default: .name
                }
            tabs.append(
                OpenTabPreference(
                    path: nonEmptyString(record["path"]), treeRootPath: nonEmptyString(record["treeRootPath"]),
                    favoritePath: nonEmptyString(record["favoritePath"]), viewMode: viewMode(record["viewMode"]),
                    searchViewMode: viewMode(record["searchViewMode"], .details), sortBy: sortBy,
                    sortDirection: record["sortDirection"]?.string == "desc" ? .desc : .asc,
                    includeHidden: bool(record, "includeHidden", includeHidden),
                    foldersFirst: bool(record, "foldersFirst", foldersFirst),
                    favoritesExpanded: bool(record, "favoritesExpanded", favoritesExpanded),
                    locationsExpanded: bool(record, "locationsExpanded", locationsExpanded)))
            if tabs.count == AppPreferenceLimits.openTabsLimit {
                break
            }
        }
        return tabs
    }

    // MARK: Favorites and applications

    private static func favorites(_ value: JSONNode?, _ fallback: [FavoritePreference]) -> [FavoritePreference] {
        guard let entries = value?.array else { return fallback }
        var seen = Set<[UInt8]>()
        var favorites: [FavoritePreference] = []
        for entry in entries {
            guard let record = entry.object else { continue }
            let path = JSString.trimmed(record["path"]?.string ?? "")
            guard !path.isEmpty, let icon = record["icon"]?.string.flatMap({ FavoriteIconID(rawValue: $0) }) else {
                continue
            }
            // De-duplicated by path, scalar for scalar.
            if seen.insert(Array(path.utf8)).inserted {
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

    // MARK: Preferences

    /// `sanitizePreferences`: every saved value is checked; one that is missing or invalid takes its default from
    /// `defaults` (what a new install starts with, or the preferences a change is applied to).
    public static func sanitize(
        _ value: JSONNode?, defaults: AppPreferences, batchRename: BatchRenameSanitizers = .standard
    ) -> AppPreferences {
        guard let record = value?.object else { return defaults }
        let global = AppPreferences.defaults()
        return AppPreferences(
            theme: choice(record, "theme", defaults.theme),
            accent: record["accent"]?.string.map { AppPreferenceLimits.normalizeAccentColor($0) ?? defaults.accent }
                ?? defaults.accent,
            zoomPercent: AppPreferenceLimits.clampZoomPercent(
                record["zoomPercent"]?.number ?? Double(defaults.zoomPercent)),
            viewMode: viewMode(record["viewMode"]),
            searchViewMode: viewMode(record["searchViewMode"], global.searchViewMode),
            sortBy: choice(record, "sortBy", defaults.sortBy),
            sortDirection: choice(record, "sortDirection", defaults.sortDirection),
            foldersFirst: bool(record, "foldersFirst", defaults.foldersFirst),
            compactListView: bool(record, "compactListView", defaults.compactListView),
            compactDetailsView: bool(record, "compactDetailsView", defaults.compactDetailsView),
            compactIconView: bool(record, "compactIconView", defaults.compactIconView),
            compactTreeView: bool(record, "compactTreeView", defaults.compactTreeView),
            singleClickExpandTreeItems: bool(record, "singleClickExpandTreeItems", defaults.singleClickExpandTreeItems),
            detailColumns: detailColumns(record["detailColumns"], defaults.detailColumns),
            detailColumnOrder: record["detailColumnOrder"] == nil
                ? defaults.detailColumnOrder
                : AppPreferenceLimits.normalizeDetailColumnOrder(record["detailColumnOrder"]),
            detailColumnWidths: detailColumnWidths(record["detailColumnWidths"], defaults.detailColumnWidths),
            searchColumns: searchColumns(record["searchColumns"], defaults.searchColumns),
            searchColumnOrder: record["searchColumnOrder"] == nil
                ? defaults.searchColumnOrder
                : AppPreferenceLimits.normalizeSearchColumnOrder(record["searchColumnOrder"]),
            searchColumnWidths: searchColumnWidths(record["searchColumnWidths"], defaults.searchColumnWidths),
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
            fileActivationAction: choice(record, "fileActivationAction", defaults.fileActivationAction),
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
            treeWidth: AppPreferenceLimits.clampPaneWidth(
                record["treeWidth"]?.number ?? Double(defaults.treeWidth), AppPreferenceLimits.treeWidthRange),
            inspectorWidth: AppPreferenceLimits.clampPaneWidth(
                record["inspectorWidth"]?.number ?? Double(defaults.inspectorWidth),
                AppPreferenceLimits.inspectorWidthRange),
            restoreSessionOnStartup: bool(record, "restoreSessionOnStartup", defaults.restoreSessionOnStartup),
            openTabs: openTabs(
                record["openTabs"], includeHidden: defaults.includeHidden, foldersFirst: defaults.foldersFirst,
                favoritesExpanded: bool(record, "favoritesExpanded", defaults.favoritesExpanded),
                locationsExpanded: bool(record, "locationsExpanded", defaults.locationsExpanded)),
            activeTabIndex: activeTabIndex(record["activeTabIndex"]),
            treeRootPath: nonEmptyString(record["treeRootPath"]),
            lastVisitedPath: nonEmptyString(record["lastVisitedPath"]),
            lastVisitedFavoritePath: nonEmptyString(record["lastVisitedFavoritePath"]),
            favorites: favorites(record["favorites"], defaults.favorites),
            favoritesPlacement: choice(record, "favoritesPlacement", defaults.favoritesPlacement),
            favoritesExpanded: bool(record, "favoritesExpanded", defaults.favoritesExpanded),
            locationsExpanded: bool(record, "locationsExpanded", defaults.locationsExpanded),
            favoritesInitialized: bool(record, "favoritesInitialized", defaults.favoritesInitialized),
            batchRenameSettings: batchRename.settings(record["batchRenameSettings"]),
            batchRenamePresets: batchRename.presets(record["batchRenamePresets"]))
    }

    /// A whole number, zero or more; anything else is zero. A number past what a count can be stops at the largest.
    private static func activeTabIndex(_ value: JSONNode?) -> Int {
        guard let number = value?.integer, number >= 0 else { return 0 }
        return number >= 9_007_199_254_740_991 ? Int(9_007_199_254_740_991) : Int(number)
    }
}
