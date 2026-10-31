// Port of the types and constants of apps/desktop/src/shared/appPreferences.ts
import Foundation

/// The app's two looks, macOS light and macOS dark.
public enum ThemeMode: String, Codable, Sendable, Hashable {
    case light, dark
}

/// "auto" follows the macOS appearance; "light" or "dark" pins the app to one.
public enum ThemePreference: String, Codable, CaseIterable, Sendable, Hashable {
    case auto, light, dark
}

/// The file list's views. "details" is the one called List, the table; "list" is Compact List, names in columns.
public enum ExplorerViewMode: String, Codable, CaseIterable, Sendable, Hashable {
    case icons, list, details

    /// VIEW_MODE_ORDER: the views in the order every menu lists them.
    public static let menuOrder: [ExplorerViewMode] = [.icons, .details, .list]

    /// VIEW_MODE_NAMES: the names the menus give the views.
    public var menuName: String {
        switch self {
        case .icons: "Icons"
        case .details: "List"
        case .list: "Compact List"
        }
    }
}

/// How the search text is matched.
public enum SearchPatternModePreference: String, Codable, CaseIterable, Sendable, Hashable {
    case text, glob, regex

    /// SEARCH_PATTERN_MODE_LABELS.
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
    case name, modified, kind, size

    /// SORT_BY_ORDER: the order every menu lists it in.
    public static let menuOrder: [SortByPreference] = [.name, .kind, .modified, .size]
}

public enum FavoritesPlacement: String, Codable, CaseIterable, Sendable, Hashable {
    case integrated, separate
}

public enum FileActivationAction: String, Codable, CaseIterable, Sendable, Hashable {
    case open, edit
}

/// Where a disk image's disk opens once it is mounted.
public enum DiskImageOpensIn: String, Codable, CaseIterable, Sendable, Hashable {
    case window, tab
}

/// Finder renames with Return; "open" keeps the older behavior of opening the selection.
public enum ReturnKeyAction: String, Codable, CaseIterable, Sendable, Hashable {
    case rename, open
}

/// The columns of the List view, in display order (DETAIL_COLUMN_KEYS).
public enum DetailColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case name, modified, size, kind, created, permissions

    /// DETAIL_COLUMN_LABELS.
    public var label: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        case .created: "Date Created"
        case .permissions: "Permissions"
        }
    }

    /// DETAIL_COLUMN_WIDTH_LIMITS.
    public var widthLimits: ClosedRange<Int> {
        switch self {
        case .name: 140...720
        case .modified: 80...280
        case .size: 60...240
        case .kind: 60...320
        case .created: 80...280
        case .permissions: 36...260
        }
    }
}

/// DetailColumnKey without Name, which is always shown (OPTIONAL_DETAIL_COLUMN_KEYS).
public enum OptionalDetailColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case modified, size, kind, created, permissions
}

/// The columns of search results' List view (SearchColumnKey).
public enum SearchColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case name, folder, modified, size, kind, created, permissions

    /// SEARCH_COLUMN_LABELS.
    public var label: String {
        self == .folder ? "Folder" : DetailColumnKey(rawValue: rawValue)?.label ?? rawValue
    }

    /// SEARCH_COLUMN_WIDTH_LIMITS.
    public var widthLimits: ClosedRange<Int> {
        self == .folder ? 80...720 : DetailColumnKey(rawValue: rawValue)?.widthLimits ?? 80...720
    }
}

/// OPTIONAL_SEARCH_COLUMN_KEYS: in the order of the columns, Name aside.
public enum OptionalSearchColumnKey: String, Codable, CaseIterable, Sendable, Hashable {
    case folder, modified, size, kind, created, permissions
}

/// `name` is always visible, so only optional columns are persisted as booleans.
public struct DetailColumnVisibility: Codable, Equatable, Sendable {
    public var modified: Bool
    public var size: Bool
    public var kind: Bool
    public var created: Bool
    public var permissions: Bool

    /// DEFAULT_DETAIL_COLUMN_VISIBILITY: Finder's list view columns; Date Created and Permissions are opt-in.
    public static let defaults = DetailColumnVisibility(
        modified: true, size: true, kind: true, created: false, permissions: false)

    public subscript(key: OptionalDetailColumnKey) -> Bool {
        get {
            switch key {
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
            case .permissions: permissions
            }
        }
        set {
            switch key {
            case .modified: modified = newValue
            case .size: size = newValue
            case .kind: kind = newValue
            case .created: created = newValue
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
    public var permissions: Int

    /// DEFAULT_DETAIL_COLUMN_WIDTHS.
    public static let defaults = DetailColumnWidths(
        name: 320, modified: 152, size: 108, kind: 148, created: 152, permissions: 108)

    public subscript(key: DetailColumnKey) -> Int {
        get {
            switch key {
            case .name: name
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
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
            case .permissions: permissions = newValue
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
    public var permissions: Bool

    /// DEFAULT_SEARCH_COLUMN_VISIBILITY.
    public static let defaults = SearchColumnVisibility(
        folder: true, modified: true, size: true, kind: false, created: false, permissions: false)

    public subscript(key: OptionalSearchColumnKey) -> Bool {
        get {
            switch key {
            case .folder: folder
            case .modified: modified
            case .size: size
            case .kind: kind
            case .created: created
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
    public var permissions: Int

    /// DEFAULT_SEARCH_COLUMN_WIDTHS.
    public static let defaults = SearchColumnWidths(
        name: 300, folder: 240, modified: DetailColumnWidths.defaults.modified, size: DetailColumnWidths.defaults.size,
        kind: DetailColumnWidths.defaults.kind, created: DetailColumnWidths.defaults.created,
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

/// The icons a favorite can have (FAVORITE_ICON_OPTIONS).
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

/// Encodes an absent value as JSON `null`, as the original's files hold it, rather than leaving the key out.
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

    public init(
        path: String?, treeRootPath: String?, favoritePath: String?, viewMode: ExplorerViewMode,
        searchViewMode: ExplorerViewMode, sortBy: SortByPreference, sortDirection: SortDirectionPreference,
        includeHidden: Bool, foldersFirst: Bool, favoritesExpanded: Bool, locationsExpanded: Bool
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
    }
}

/// The saved shortcuts that differ from their defaults, by command id.
public typealias ShortcutOverrides = [String: [String]]

/// Constants and small functions of appPreferences.ts.
public enum AppPreferenceLimits {
    public static let openTabsLimit = 25
    public static let zoomPercentMin = 75
    public static let zoomPercentMax = 150
    public static let openItemLimitMin = 1
    public static let openItemLimitMax = 50
    public static let treeWidthRange = 220...520
    public static let inspectorWidthRange = 260...480

    /// OPTIONAL_DETAIL_COLUMN_KEYS order, which is DEFAULT_DETAIL_COLUMN_ORDER.
    public static let defaultDetailColumnOrder: [OptionalDetailColumnKey] = OptionalDetailColumnKey.allCases
    public static let defaultSearchColumnOrder: [OptionalSearchColumnKey] = OptionalSearchColumnKey.allCases

    /// ACCENT_OPTIONS: macOS's own accents in System Settings order, then the copper the app used to default to.
    public static let accentOptions: [(value: String, label: String)] = [
        ("#007aff", "Blue"), ("#a550a7", "Purple"), ("#f74f9e", "Pink"), ("#e0383e", "Red"), ("#f7821b", "Orange"),
        ("#ffc600", "Yellow"), ("#62ba46", "Green"), ("#8c8c8c", "Graphite"), ("#d4845a", "Copper"),
    ]
    public static let defaultAccent = "#007aff"

    /// THEME_OPTIONS: Auto, Light and Dark, in the order Settings shows them.
    public static let themeOptions: [(value: ThemePreference, label: String)] = [
        (.auto, "Auto"), (.light, "Light"), (.dark, "Dark"),
    ]

    public static let defaultTextEditor = ApplicationSelection(
        appPath: "/System/Applications/TextEdit.app", appName: "TextEdit")
    public static let defaultTerminalApplication = ApplicationSelection(
        appPath: "/System/Applications/Utilities/Terminal.app", appName: "Terminal")

    /// `clampPaneWidth`.
    public static func clampPaneWidth(_ value: Double, _ range: ClosedRange<Int>) -> Int {
        clampRounded(value, Double(range.lowerBound), Double(range.upperBound))
    }

    public static func clampZoomPercent(_ value: Double) -> Int {
        clampRounded(value, Double(zoomPercentMin), Double(zoomPercentMax))
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

    /// `normalizeDetailColumnOrder`: unknown and repeated keys are dropped, and columns the saved order leaves out
    /// follow in their default order.
    public static func normalizeDetailColumnOrder(_ value: JSONNode?) -> [OptionalDetailColumnKey] {
        normalizeColumnOrder(value, defaults: OptionalDetailColumnKey.allCases)
    }

    public static func normalizeSearchColumnOrder(_ value: JSONNode?) -> [OptionalSearchColumnKey] {
        normalizeColumnOrder(value, defaults: OptionalSearchColumnKey.allCases)
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

    public static func favoriteIconLabel(_ icon: FavoriteIconID) -> String { icon.label }
}
