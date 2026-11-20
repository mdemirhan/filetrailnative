import Foundation

/// The app's two looks, macOS light and macOS dark.
public enum ThemeMode: String, Codable, Sendable, Hashable {
    case light, dark
}

/// "auto" follows the macOS appearance; "light" or "dark" pins the app to one.
public enum ThemePreference: String, Codable, CaseIterable, Sendable, Hashable {
    case auto, light, dark
}

/// The file list's views. "details" is the one called List, the table; "list" is Compact List, names in columns;
/// "previews" is a grid of large previews of the files' content.
public enum ExplorerViewMode: String, Codable, CaseIterable, Sendable, Hashable {
    case icons, list, details, previews

    /// The views in the order every menu lists them.
    public static let menuOrder: [ExplorerViewMode] = [.icons, .details, .list, .previews]

    /// The names the menus give the views.
    public var menuName: String {
        switch self {
        case .icons: "Icons"
        case .details: "List"
        case .list: "Compact List"
        case .previews: "Previews"
        }
    }
}

/// How the search text is matched.
public enum SearchPatternModePreference: String, Codable, CaseIterable, Sendable, Hashable {
    case text, glob, regex

    /// The mode's name in the search options menu.
    public var label: String {
        switch self {
        case .text: "Plain Text"
        case .glob: "Glob"
        case .regex: "Regex"
        }
    }
}

public enum SearchMatchScopePreference: String, Codable, CaseIterable, Sendable, Hashable {
    case name, path
}

/// Search results sort by name, by the folder they are in, or by kind.
public enum SearchResultsSortByPreference: String, Codable, CaseIterable, Sendable, Hashable {
    case name, path, kind
}

public enum SortDirectionPreference: String, Codable, CaseIterable, Sendable, Hashable {
    case asc, desc
}

/// What the file list can be sorted by.
public enum SortByPreference: String, Codable, CaseIterable, Sendable, Hashable {
    case name, modified, kind, size, added, lastOpened, created

    /// The order every menu lists the fields in: the List's columns' order.
    public static let menuOrder: [SortByPreference] = [
        .name, .modified, .created, .lastOpened, .added, .size, .kind,
    ]

    /// What every menu calls it.
    public var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .kind: "Kind"
        case .size: "Size"
        case .added: "Date Added"
        case .lastOpened: "Date Last Opened"
        case .created: "Date Created"
        }
    }
}

/// What the items of a folder, or search results, are put in groups by (View ▸ Group By). None shows one list.
public enum GroupByPreference: String, Codable, CaseIterable, Sendable, Hashable {
    case none, name, modified, created, lastOpened, added, size, kind, tags, folder

    /// The fields a folder is grouped by, as the menus list them: the order of fields and columns, Tags after Kind.
    public static let menuOrder: [GroupByPreference] = [
        .name, .modified, .created, .lastOpened, .added, .size, .kind, .tags,
    ]

    /// The fields search results are grouped by: what each result carries, as their order is (name, folder, kind).
    /// Dates, sizes and tags are read for the rows on screen only.
    public static let searchMenuOrder: [GroupByPreference] = [.name, .folder, .kind]

    /// What every menu calls it.
    public var title: String {
        switch self {
        case .none: "None"
        case .name: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        case .lastOpened: "Date Last Opened"
        case .added: "Date Added"
        case .size: "Size"
        case .kind: "Kind"
        case .tags: "Tags"
        case .folder: "Folder"
        }
    }

    /// Whether its groups are of dates, which change at midnight.
    public var isDate: Bool { [.modified, .created, .lastOpened, .added].contains(self) }

    /// Whether a folder can be grouped by it (Folder is search results' own).
    public var isForFolders: Bool { self != .folder }

    /// Whether search results can be grouped by it.
    public var isForSearch: Bool { self == .none || Self.searchMenuOrder.contains(self) }

    /// The View ▸ Group By item that groups by it.
    public var command: AppCommand {
        switch self {
        case .none: .groupByNone
        case .name: .groupByName
        case .modified: .groupByModified
        case .created: .groupByCreated
        case .lastOpened: .groupByLastOpened
        case .added: .groupByAdded
        case .size: .groupBySize
        case .kind: .groupByKind
        case .tags: .groupByTags
        case .folder: .groupByFolder
        }
    }

    /// The field a View ▸ Group By item groups by; nil for another command.
    public init?(command: AppCommand) {
        guard let field = Self.allCases.first(where: { $0.command == command }) else { return nil }
        self = field
    }

    /// As a pane is saved with it: nil for none, and for a field the folders (or the results) can't be grouped by.
    public static func saved(_ groupBy: GroupByPreference?, search: Bool) -> GroupByPreference? {
        guard let groupBy, groupBy != .none, search ? groupBy.isForSearch : groupBy.isForFolders else { return nil }
        return groupBy
    }
}

public enum FavoritesPlacement: String, Codable, CaseIterable, Sendable, Hashable {
    case integrated, separate
}

/// Where a disk image's disk opens once it is mounted.
public enum DiskImageOpensIn: String, Codable, CaseIterable, Sendable, Hashable {
    case window, tab
}

/// Finder renames with Return; "open" keeps the older behavior of opening the selection.
public enum ReturnKeyAction: String, Codable, CaseIterable, Sendable, Hashable {
    case rename, open
}

/// The columns of the List view, in display order.
public enum DetailColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case name, modified, size, kind, created, added, lastOpened, permissions

    /// The column's title.
    public var label: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        case .created: "Date Created"
        case .added: "Date Added"
        case .lastOpened: "Date Last Opened"
        case .permissions: "Permissions"
        }
    }

    /// The least and the greatest width the column can be given, in points.
    public var widthLimits: ClosedRange<Int> {
        switch self {
        case .name: 140...1000
        case .modified: 80...280
        case .size: 60...240
        case .kind: 60...320
        case .created, .added, .lastOpened: 80...280
        case .permissions: 36...260
        }
    }
}

/// The List's columns but Name, which is always shown: the ones that can be hidden and moved.
public enum OptionalDetailColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case modified, size, kind, created, added, lastOpened, permissions

    /// The order the menus list them in (the column header's right-click menu, View ▸ Columns): Finder's, the dates
    /// together after Date Modified.
    public static let menuOrder: [OptionalDetailColumnKey] = [
        .modified, .created, .lastOpened, .added, .size, .kind, .permissions,
    ]
}

/// The columns of search results' List view (SearchColumnKey).
public enum SearchColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case name, folder, modified, size, kind, created, added, lastOpened, permissions

    /// The column's title: Folder's own, the others as in a folder's List.
    public var label: String {
        self == .folder ? "Folder" : DetailColumnKey(rawValue: rawValue)?.label ?? rawValue
    }

    /// The least and the greatest width the column can be given: Folder's own, the others as in a folder's List.
    public var widthLimits: ClosedRange<Int> {
        self == .folder ? 80...1000 : DetailColumnKey(rawValue: rawValue)?.widthLimits ?? 80...1000
    }
}

/// Search results' columns but Name, which is always shown, in the order of the columns.
public enum OptionalSearchColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case folder, modified, size, kind, created, added, lastOpened, permissions

    /// The order the column header's right-click menu lists them in: Folder, then a folder's columns in Finder's order.
    public static let menuOrder: [OptionalSearchColumnKey] = [
        .folder, .modified, .created, .lastOpened, .added, .size, .kind, .permissions,
    ]
}

/// `name` is always visible, so only optional columns are persisted as booleans.
public struct DetailColumnVisibility: Codable, Equatable, Sendable {
    public var modified: Bool
    public var size: Bool
    public var kind: Bool
    public var created: Bool
    public var added: Bool = false
    public var lastOpened: Bool = false
    public var permissions: Bool

    /// Before any is changed: Finder's list view columns; the other dates and Permissions are opt-in.
    public static let defaults = DetailColumnVisibility(
        modified: true, size: true, kind: true, created: false, added: false, lastOpened: false,
        permissions: false)

    public subscript(key: OptionalDetailColumnKey) -> Bool {
        get {
            switch key {
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
            case .added: added
            case .lastOpened: lastOpened
            case .permissions: permissions
            }
        }
        set {
            switch key {
            case .modified: modified = newValue
            case .size: size = newValue
            case .kind: kind = newValue
            case .created: created = newValue
            case .added: added = newValue
            case .lastOpened: lastOpened = newValue
            case .permissions: permissions = newValue
            }
        }
    }
}

public struct DetailColumnWidths: Codable, Equatable, Sendable {
    public var name: Int
    public var modified: Int
    public var size: Int
    public var kind: Int
    public var created: Int
    public var added: Int = 152
    public var lastOpened: Int = 152
    public var permissions: Int

    /// The widths before any column is resized.
    public static let defaults = DetailColumnWidths(
        name: 320, modified: 152, size: 108, kind: 148, created: 152, added: 152, lastOpened: 152,
        permissions: 108)

    public subscript(key: DetailColumnKey) -> Int {
        get {
            switch key {
            case .name: name
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
            case .added: added
            case .lastOpened: lastOpened
            case .permissions: permissions
            }
        }
        set {
            switch key {
            case .name: name = newValue
            case .modified: modified = newValue
            case .size: size = newValue
            case .kind: kind = newValue
            case .created: created = newValue
            case .added: added = newValue
            case .lastOpened: lastOpened = newValue
            case .permissions: permissions = newValue
            }
        }
    }
}

/// A size kept for each density: the Compact List's column width, the Icons view's icon size.
public struct DensitySizes: Codable, Equatable, Sendable {
    public var standard: Int
    public var finder: Int

    public init(standard: Int, finder: Int) {
        self.standard = standard
        self.finder = finder
    }

    /// The Compact List's column widths before they are changed.
    public static let compactListDefaults = DensitySizes(standard: 292, finder: 252)
    /// The Icons view's icon sizes before they are changed.
    public static let iconDefaults = DensitySizes(standard: 64, finder: 64)
    /// How many previews fill the pane in the Previews view before it is changed (`PreviewGrid`).
    public static let previewCountDefaults = DensitySizes(
        standard: PreviewGrid.defaultCount, finder: PreviewGrid.defaultCount)

    public subscript(density: Density) -> Int {
        get {
            switch density {
            case .standard: standard
            case .finder: finder
            }
        }
        set {
            switch density {
            case .standard: standard = newValue
            case .finder: finder = newValue
            }
        }
    }
}

public struct SearchColumnVisibility: Codable, Equatable, Sendable {
    public var folder: Bool
    public var modified: Bool
    public var size: Bool
    public var kind: Bool
    public var created: Bool
    public var added: Bool = false
    public var lastOpened: Bool = false
    public var permissions: Bool

    /// Before any is changed: Folder, Date Modified and Size.
    public static let defaults = SearchColumnVisibility(
        folder: true, modified: true, size: true, kind: false, created: false, added: false, lastOpened: false,
        permissions: false)

    public subscript(key: OptionalSearchColumnKey) -> Bool {
        get {
            switch key {
            case .folder: folder
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
            case .added: added
            case .lastOpened: lastOpened
            case .permissions: permissions
            }
        }
        set {
            switch key {
            case .folder: folder = newValue
            case .modified: modified = newValue
            case .size: size = newValue
            case .kind: kind = newValue
            case .created: created = newValue
            case .added: added = newValue
            case .lastOpened: lastOpened = newValue
            case .permissions: permissions = newValue
            }
        }
    }
}

public struct SearchColumnWidths: Codable, Equatable, Sendable {
    public var name: Int
    public var folder: Int
    public var modified: Int
    public var size: Int
    public var kind: Int
    public var created: Int
    public var added: Int = DetailColumnWidths.defaults.added
    public var lastOpened: Int = DetailColumnWidths.defaults.lastOpened
    public var permissions: Int

    /// The widths before any column is resized: Name and Folder their own, the others as in a folder's List.
    public static let defaults = SearchColumnWidths(
        name: 300, folder: 240, modified: DetailColumnWidths.defaults.modified, size: DetailColumnWidths.defaults.size,
        kind: DetailColumnWidths.defaults.kind, created: DetailColumnWidths.defaults.created,
        added: DetailColumnWidths.defaults.added, lastOpened: DetailColumnWidths.defaults.lastOpened,
        permissions: DetailColumnWidths.defaults.permissions)

    public subscript(key: SearchColumnKey) -> Int {
        get {
            switch key {
            case .name: name
            case .folder: folder
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
            case .added: added
            case .lastOpened: lastOpened
            case .permissions: permissions
            }
        }
        set {
            switch key {
            case .name: name = newValue
            case .folder: folder = newValue
            case .modified: modified = newValue
            case .size: size = newValue
            case .kind: kind = newValue
            case .created: created = newValue
            case .added: added = newValue
            case .lastOpened: lastOpened = newValue
            case .permissions: permissions = newValue
            }
        }
    }
}

public struct ApplicationSelection: Codable, Equatable, Sendable {
    public var appPath: String
    public var appName: String

    public init(appPath: String, appName: String) {
        self.appPath = appPath
        self.appName = appName
    }
}

/// An app pinned in Open With.
public struct OpenWithApplication: Codable, Equatable, Sendable {
    public var id: String
    public var appPath: String
    public var appName: String

    public init(id: String, appPath: String, appName: String) {
        self.id = id
        self.appPath = appPath
        self.appName = appName
    }
}

/// The icons a favorite can have, in the order Settings offers them.
public enum FavoriteIconID: String, Codable, CaseIterable, Sendable, Hashable {
    case home, applications, desktop, documents, downloads, trash, folder, star, drive, code, terminal, globe, music
    case photos, videos, archive, cloud, server, projects, books, camera, toolbox, network

    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public struct FavoritePreference: Codable, Equatable, Sendable {
    public var path: String
    public var icon: FavoriteIconID

    public init(path: String, icon: FavoriteIconID) {
        self.path = path
        self.icon = icon
    }
}

/// Encodes an absent value as JSON `null`, rather than leaving the key out.
@propertyWrapper
public struct NullEncoded<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

/// The sizes a pane shows its views at: the Icons view's icon size, the Compact List's column width and how many
/// previews fill the pane in the Previews view, each at each density, and the List's column widths, a folder's and
/// search results'. Every pane has its own; the app's (in the preferences) are the ones set last in any pane, which a
/// pane with none of its own starts from.
public struct PaneViewSizes: Codable, Equatable, Sendable {
    public var iconSizes: DensitySizes
    public var compactListWidths: DensitySizes
    public var previewCounts: DensitySizes
    public var detailColumnWidths: DetailColumnWidths
    public var searchColumnWidths: SearchColumnWidths

    public init(
        iconSizes: DensitySizes, compactListWidths: DensitySizes, previewCounts: DensitySizes,
        detailColumnWidths: DetailColumnWidths, searchColumnWidths: SearchColumnWidths
    ) {
        self.iconSizes = iconSizes
        self.compactListWidths = compactListWidths
        self.previewCounts = previewCounts
        self.detailColumnWidths = detailColumnWidths
        self.searchColumnWidths = searchColumnWidths
    }

    /// The app's own sizes: those set last.
    public init(_ preferences: AppPreferences) {
        self.init(
            iconSizes: preferences.iconSizes, compactListWidths: preferences.compactListWidths,
            previewCounts: preferences.previewCounts, detailColumnWidths: preferences.detailColumnWidths,
            searchColumnWidths: preferences.searchColumnWidths)
    }

    /// `preferences` with these sizes in place of the app's.
    public func applied(to preferences: AppPreferences) -> AppPreferences {
        var shown = preferences
        shown.iconSizes = iconSizes
        shown.compactListWidths = compactListWidths
        shown.previewCounts = previewCounts
        shown.detailColumnWidths = detailColumnWidths
        shown.searchColumnWidths = searchColumnWidths
        return shown
    }
}

/// A tab as it is remembered between launches: where it was and how it showed its folder.
/// Its history, selection and search are not kept.
public struct OpenTabPreference: Codable, Equatable, Sendable {
    /// Nil for a tab that showed no folder (Favorites selected in the sidebar).
    @NullEncoded public var path: String?
    @NullEncoded public var treeRootPath: String?
    @NullEncoded public var favoritePath: String?
    public var viewMode: ExplorerViewMode
    /// How the tab shows search results, kept apart from how it shows folders.
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var includeHidden: Bool
    public var foldersFirst: Bool
    public var favoritesExpanded: Bool
    public var locationsExpanded: Bool
    /// The tab's second pane, while it shows two; nil with one. A file saved before panes has none.
    public var secondPane: OpenPanePreference?
    /// The pane the tab has active: 1 for the second; nil for the first.
    public var activePane: Int?
    /// The left pane's share of the room, while the tab shows two.
    public var paneSplit: Double?
    /// The sizes its first pane shows its views at; nil in a file saved before panes kept their own, which then
    /// start from the app's.
    public var viewSizes: PaneViewSizes?
    /// How typing filters its first pane's folders, Fuzzy or Contains; nil in a file saved before panes kept
    /// theirs, and for a tab a new window starts from: the pane then starts with the mode chosen last.
    public var filterMode: NameMatchMode?
    /// What its first pane groups folders by, and search results by; nil for none, as in a file saved before groups.
    public var groupBy: GroupByPreference?
    public var searchGroupBy: GroupByPreference?

    public init(
        path: String?, treeRootPath: String?, favoritePath: String?, viewMode: ExplorerViewMode,
        searchViewMode: ExplorerViewMode, sortBy: SortByPreference, sortDirection: SortDirectionPreference,
        includeHidden: Bool, foldersFirst: Bool, favoritesExpanded: Bool, locationsExpanded: Bool,
        secondPane: OpenPanePreference? = nil, activePane: Int? = nil, paneSplit: Double? = nil,
        viewSizes: PaneViewSizes? = nil, filterMode: NameMatchMode? = nil, groupBy: GroupByPreference? = nil,
        searchGroupBy: GroupByPreference? = nil
    ) {
        self.path = path
        self.treeRootPath = treeRootPath
        self.favoritePath = favoritePath
        self.viewMode = viewMode
        self.searchViewMode = searchViewMode
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.includeHidden = includeHidden
        self.foldersFirst = foldersFirst
        self.favoritesExpanded = favoritesExpanded
        self.locationsExpanded = locationsExpanded
        self.secondPane = secondPane
        self.activePane = secondPane == nil ? nil : activePane
        self.paneSplit = secondPane == nil ? nil : paneSplit
        self.viewSizes = viewSizes
        self.filterMode = filterMode
        self.groupBy = GroupByPreference.saved(groupBy, search: false)
        self.searchGroupBy = GroupByPreference.saved(searchGroupBy, search: true)
    }

    /// The tab with its active pane alone, as a new window starts from it: that pane's folder, view, order and sizes.
    /// Its pane is a new one, which starts with the filter mode chosen last.
    public var activePaneAlone: OpenTabPreference {
        var alone = self
        if activePane == 1, let second = secondPane {
            alone.path = second.path
            alone.favoritePath = nil
            alone.viewMode = second.viewMode
            alone.searchViewMode = second.searchViewMode
            alone.sortBy = second.sortBy
            alone.sortDirection = second.sortDirection
            alone.includeHidden = second.includeHidden
            alone.foldersFirst = second.foldersFirst
            alone.viewSizes = second.viewSizes
            alone.groupBy = second.groupBy
            alone.searchGroupBy = second.searchGroupBy
        }
        alone.secondPane = nil
        alone.activePane = nil
        alone.paneSplit = nil
        alone.filterMode = nil
        return alone
    }
}

/// A tab's second pane as it is saved: its folder and how it shows it.
public struct OpenPanePreference: Codable, Equatable, Sendable {
    /// Nil for a pane that showed no folder.
    public var path: String?
    public var viewMode: ExplorerViewMode
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var includeHidden: Bool
    public var foldersFirst: Bool
    /// The sizes the pane shows its views at; nil in a file saved before panes kept their own.
    public var viewSizes: PaneViewSizes?
    /// How typing filters the pane's folders; nil in a file saved before panes kept theirs.
    public var filterMode: NameMatchMode?
    /// What the pane groups folders by, and search results by; nil for none.
    public var groupBy: GroupByPreference?
    public var searchGroupBy: GroupByPreference?

    public init(
        path: String?, viewMode: ExplorerViewMode, searchViewMode: ExplorerViewMode, sortBy: SortByPreference,
        sortDirection: SortDirectionPreference, includeHidden: Bool, foldersFirst: Bool,
        viewSizes: PaneViewSizes? = nil, filterMode: NameMatchMode? = nil, groupBy: GroupByPreference? = nil,
        searchGroupBy: GroupByPreference? = nil
    ) {
        self.path = path
        self.viewMode = viewMode
        self.searchViewMode = searchViewMode
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.includeHidden = includeHidden
        self.foldersFirst = foldersFirst
        self.viewSizes = viewSizes
        self.filterMode = filterMode
        self.groupBy = GroupByPreference.saved(groupBy, search: false)
        self.searchGroupBy = GroupByPreference.saved(searchGroupBy, search: true)
    }
}

/// The saved shortcuts that differ from their defaults, by command id.
public typealias ShortcutOverrides = [String: [String]]

/// Constants and small functions of the preferences.
public enum AppPreferenceLimits {
    public static let openTabsLimit = 25
    public static let openItemLimitMin = 1
    public static let openItemLimitMax = 50
    public static let treeWidthRange = 220...520
    public static let inspectorWidthRange = 260...480
    public static let compactListWidthRange = 160...600
    /// View ▸ Make Bigger and Make Smaller widen and narrow the Compact List's columns by this many points.
    public static let compactListWidthStep = 40
    public static let iconSizeRange = 32...128
    /// Icon sizes go in steps of this many points.
    public static let iconSizeStep = 8

    /// An icon size within its range, at a whole step.
    public static func clampIconSize(_ value: Double) -> Int {
        let step = Double(iconSizeStep)
        let stepped = (value / step).rounded() * step
        return clampRounded(stepped, Double(iconSizeRange.lowerBound), Double(iconSizeRange.upperBound))
    }

    /// The order of the columns before any is moved: the order `OptionalDetailColumnKey` lists them in.
    /// A column shown for the first time takes its place in the menus' order.
    public static let defaultDetailColumnOrder: [OptionalDetailColumnKey] = OptionalDetailColumnKey.menuOrder
    public static let defaultSearchColumnOrder: [OptionalSearchColumnKey] = OptionalSearchColumnKey.menuOrder

    /// macOS's own accents in System Settings order, then the copper the app used to default to.
    public static let accentOptions: [(value: String, label: String)] = [
        ("#007aff", "Blue"), ("#a550a7", "Purple"), ("#f74f9e", "Pink"), ("#e0383e", "Red"), ("#f7821b", "Orange"),
        ("#ffc600", "Yellow"), ("#62ba46", "Green"), ("#8c8c8c", "Graphite"), ("#d4845a", "Copper"),
    ]
    public static let defaultAccent = "#007aff"

    /// Auto, Light and Dark, in the order Settings shows them.
    public static let themeOptions: [(value: ThemePreference, label: String)] = [
        (.auto, "Auto"), (.light, "Light"), (.dark, "Dark"),
    ]

    public static let defaultTextEditor = ApplicationSelection(
        appPath: "/System/Applications/TextEdit.app", appName: "TextEdit")
    public static let defaultTerminalApplication = ApplicationSelection(
        appPath: "/System/Applications/Utilities/Terminal.app", appName: "Terminal")

    /// A pane width kept within `range`, then rounded half up.
    public static func clampPaneWidth(_ value: Double, _ range: ClosedRange<Int>) -> Int {
        clampRounded(value, Double(range.lowerBound), Double(range.upperBound))
    }

    public static func clampOpenItemLimit(_ value: Double) -> Int {
        clampRounded(value, Double(openItemLimitMin), Double(openItemLimitMax))
    }

    public static func clampDetailColumnWidth(_ key: DetailColumnKey, _ value: Double) -> Int {
        clampRounded(value, Double(key.widthLimits.lowerBound), Double(key.widthLimits.upperBound))
    }

    public static func clampSearchColumnWidth(_ key: SearchColumnKey, _ value: Double) -> Int {
        clampRounded(value, Double(key.widthLimits.lowerBound), Double(key.widthLimits.upperBound))
    }

    /// The saved order of the List's columns, made whole: unknown and repeated keys are dropped, and columns the saved
    /// order leaves out follow in their default order.
    public static func normalizeDetailColumnOrder(_ value: JSONNode?) -> [OptionalDetailColumnKey] {
        normalizeColumnOrder(value, defaults: OptionalDetailColumnKey.menuOrder)
    }

    public static func normalizeSearchColumnOrder(_ value: JSONNode?) -> [OptionalSearchColumnKey] {
        normalizeColumnOrder(value, defaults: OptionalSearchColumnKey.menuOrder)
    }

    private static func normalizeColumnOrder<Key: RawRepresentable & Equatable>(
        _ value: JSONNode?, defaults: [Key]
    ) -> [Key] where Key.RawValue == String {
        var order: [Key] = []
        for item in value?.array ?? [] {
            if let name = item.string, let key = Key(rawValue: name), !order.contains(key) {
                order.append(key)
            }
        }
        return order + defaults.filter { !order.contains($0) }
    }

    /// `resolveEffectiveTheme`: the look actually painted; "auto" follows the current macOS appearance.
    public static func resolveEffectiveTheme(_ theme: ThemePreference, systemPrefersDark: Bool) -> ThemeMode {
        switch theme {
        case .light: .light
        case .dark: .dark
        case .auto: systemPrefersDark ? .dark : .light
        }
    }

    /// `normalizeAccentColor`: a six-digit hex color in lower case, or nil.
    public static func normalizeAccentColor(_ value: String) -> String? {
        let trimmed = JSString.trimmed(value)
        let units = Array(trimmed.utf16)
        guard units.count == 7, units[0] == 0x23 else { return nil }
        for unit in units.dropFirst() {
            switch unit {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66: continue
            default: return nil
            }
        }
        return trimmed.lowercased()
    }
}
