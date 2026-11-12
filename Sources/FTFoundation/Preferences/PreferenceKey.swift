import Foundation

/// The name of each preference, as `app-state.json` holds it, in the order the file writes them.
public enum PreferenceKey: String, CaseIterable, Sendable, Hashable {
    case theme, accent, viewMode, searchViewMode, sortBy, sortDirection, foldersFirst, density, detailColumns
    case detailColumnOrder, detailColumnWidths, searchColumns, searchColumnOrder, searchColumnWidths
    case compactListWidths, iconSizes
    case notificationsEnabled, markClipboardItems, autoCalculateFolderSizes, folderTreeOpen, propertiesOpen
    case detailRowOpen, topToolbarItems, terminalApp, defaultTextEditor, openWithApplications, fileActivationAction
    case diskImageOpensIn, returnKeyAction, shortcutOverrides, openItemLimit, includeHidden, searchPatternMode
    case searchMatchScope, searchRecursive, searchSkipGitFolders, searchSkipGitIgnored, searchResultsSortBy
    case searchResultsSortDirection, treeWidth, inspectorWidth, restoreSessionOnStartup, openTabs, activeTabIndex
    case treeRootPath, lastVisitedPath, lastVisitedFavoritePath, favorites, favoritesPlacement, favoritesExpanded
    case locationsExpanded, favoritesInitialized, singleClickExpandTreeItems, batchRenameSettings
    case batchRenamePresets

    /// The field of `AppPreferences` this key names. Every key has one: the switch is the one place that pairs them.
    fileprivate var makeField: PreferenceField {
        switch self {
        case .theme: .of(\.theme)
        case .accent: .of(\.accent)
        case .viewMode: .of(\.viewMode)
        case .searchViewMode: .of(\.searchViewMode)
        case .sortBy: .of(\.sortBy)
        case .sortDirection: .of(\.sortDirection)
        case .foldersFirst: .of(\.foldersFirst)
        case .density: .of(\.density)
        case .detailColumns: .of(\.detailColumns)
        case .detailColumnOrder: .of(\.detailColumnOrder)
        case .detailColumnWidths: .of(\.detailColumnWidths)
        case .searchColumns: .of(\.searchColumns)
        case .searchColumnOrder: .of(\.searchColumnOrder)
        case .searchColumnWidths: .of(\.searchColumnWidths)
        case .compactListWidths: .of(\.compactListWidths)
        case .iconSizes: .of(\.iconSizes)
        case .notificationsEnabled: .of(\.notificationsEnabled)
        case .markClipboardItems: .of(\.markClipboardItems)
        case .autoCalculateFolderSizes: .of(\.autoCalculateFolderSizes)
        case .folderTreeOpen: .of(\.folderTreeOpen)
        case .propertiesOpen: .of(\.propertiesOpen)
        case .detailRowOpen: .of(\.detailRowOpen)
        case .topToolbarItems: .of(\.topToolbarItems)
        case .terminalApp: .of(\.terminalApp)
        case .defaultTextEditor: .of(\.defaultTextEditor)
        case .openWithApplications: .of(\.openWithApplications)
        case .fileActivationAction: .of(\.fileActivationAction)
        case .diskImageOpensIn: .of(\.diskImageOpensIn)
        case .returnKeyAction: .of(\.returnKeyAction)
        case .shortcutOverrides: .of(\.shortcutOverrides)
        case .openItemLimit: .of(\.openItemLimit)
        case .includeHidden: .of(\.includeHidden)
        case .searchPatternMode: .of(\.searchPatternMode)
        case .searchMatchScope: .of(\.searchMatchScope)
        case .searchRecursive: .of(\.searchRecursive)
        case .searchSkipGitFolders: .of(\.searchSkipGitFolders)
        case .searchSkipGitIgnored: .of(\.searchSkipGitIgnored)
        case .searchResultsSortBy: .of(\.searchResultsSortBy)
        case .searchResultsSortDirection: .of(\.searchResultsSortDirection)
        case .treeWidth: .of(\.treeWidth)
        case .inspectorWidth: .of(\.inspectorWidth)
        case .restoreSessionOnStartup: .of(\.restoreSessionOnStartup)
        case .openTabs: .of(\.openTabs)
        case .activeTabIndex: .of(\.activeTabIndex)
        case .treeRootPath: .of(\.treeRootPath)
        case .lastVisitedPath: .of(\.lastVisitedPath)
        case .lastVisitedFavoritePath: .of(\.lastVisitedFavoritePath)
        case .favorites: .of(\.favorites)
        case .favoritesPlacement: .of(\.favoritesPlacement)
        case .favoritesExpanded: .of(\.favoritesExpanded)
        case .locationsExpanded: .of(\.locationsExpanded)
        case .favoritesInitialized: .of(\.favoritesInitialized)
        case .singleClickExpandTreeItems: .of(\.singleClickExpandTreeItems)
        case .batchRenameSettings: .of(\.batchRenameSettings)
        case .batchRenamePresets: .of(\.batchRenamePresets)
        }
    }

    fileprivate var field: PreferenceField { Self.fields[self]! }

    private static let fields = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeField) })
    // Key paths aren't marked Sendable; these are never changed.
    nonisolated(unsafe) private static let byKeyPath = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.makeField.keyPath, $0) })

    /// The key of a field of `AppPreferences`; nil for a path into a field (`\.detailColumnWidths.name`).
    public init?(_ keyPath: PartialKeyPath<AppPreferences>) {
        guard let key = Self.byKeyPath[keyPath] else { return nil }
        self = key
    }

    /// Whether each window keeps its own value (see `WindowSession`); the other keys the whole app shares.
    public var isWindowSessionKey: Bool { WindowSession.keySet.contains(self) }
}

/// What the preferences can do with one of their fields without knowing its type.
private struct PreferenceField: @unchecked Sendable {
    let keyPath: PartialKeyPath<AppPreferences>
    let same: (AppPreferences, AppPreferences) -> Bool
    let copy: (AppPreferences, inout AppPreferences) -> Void
    let encode: (AppPreferences) -> JSONNode

    static func of<Value: Equatable & Encodable>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> PreferenceField {
        PreferenceField(
            keyPath: keyPath, same: { $0[keyPath: keyPath] == $1[keyPath: keyPath] },
            copy: { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] },
            encode: { (try? JSONNode.of($0[keyPath: keyPath])) ?? .null })
    }
}

extension AppPreferences {
    /// The keys whose values differ between these preferences and `other`, field by field, in key order.
    public func keys(differingFrom other: AppPreferences) -> [PreferenceKey] {
        PreferenceKey.allCases.filter { !$0.field.same(self, other) }
    }

    /// The value of `key` in `source` put here.
    public mutating func take(_ key: PreferenceKey, from source: AppPreferences) {
        key.field.copy(source, &self)
    }

    /// The value of `key`, as the file holds it.
    public func node(_ key: PreferenceKey) -> JSONNode {
        key.field.encode(self)
    }
}

/// Preferences being changed: each field is read and written as on `AppPreferences` (`$0.theme = .dark`), and every
/// field written is noted, even one given the value it had.
@dynamicMemberLookup
public struct EditedPreferences {
    public private(set) var preferences: AppPreferences
    /// The keys written, in the order first written.
    public private(set) var written: [PreferenceKey] = []

    public init(_ preferences: AppPreferences) {
        self.preferences = preferences
    }

    /// A field of the preferences. A field is written as a whole, also when only a part of it is set
    /// (`$0.detailColumnWidths.name = 400`).
    public subscript<Value>(dynamicMember keyPath: WritableKeyPath<AppPreferences, Value>) -> Value {
        get { preferences[keyPath: keyPath] }
        set {
            guard let key = PreferenceKey(keyPath) else {
                preconditionFailure("\(keyPath) is not a field of the preferences")
            }
            preferences[keyPath: keyPath] = newValue
            note(key)
        }
    }

    /// A change written on whole preferences: the fields whose values it changed are written.
    public mutating func apply(_ change: (inout AppPreferences) -> Void) {
        var next = preferences
        change(&next)
        for key in next.keys(differingFrom: preferences) {
            take(key, from: next)
        }
    }

    /// The value of `key` in `source` written here.
    public mutating func take(_ key: PreferenceKey, from source: AppPreferences) {
        preferences.take(key, from: source)
        note(key)
    }

    private mutating func note(_ key: PreferenceKey) {
        if !written.contains(key) { written.append(key) }
    }
}

extension PreferencesSanitizer {
    /// `preferences` with the values of `keys` checked as when the file is read: a value past a limit is brought into
    /// it, and one that isn't valid takes its value in `defaults`. The other values are taken as they are.
    public static func sanitize(
        _ keys: some Sequence<PreferenceKey>, of preferences: AppPreferences, defaults: AppPreferences
    ) -> AppPreferences {
        var record: [String: JSONNode] = [:]
        for key in keys {
            record[key.rawValue] = preferences.node(key)
        }
        guard !record.isEmpty else { return preferences }
        // Each value is checked on its own: what a key is read as doesn't depend on the keys beside it, except for
        // values a tab leaves out, and a tab written here leaves none out.
        let checked = sanitize(.object(record), defaults: defaults)
        var result = preferences
        for key in keys {
            result.take(key, from: checked)
        }
        return result
    }
}
