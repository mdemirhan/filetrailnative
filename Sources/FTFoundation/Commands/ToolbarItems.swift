import Foundation

public struct ToolbarItemDefinition: Sendable, Equatable {
    public var id: ToolbarItemID
    public var label: String
    /// The icon of its button; the items that are not buttons (the space, the title, the view switch) have none.
    public var icon: CommandIcon?
    public var commandType: AppCommand?
    /// Always in the toolbar: it can be moved there, but not taken off.
    public var topRequired: Bool
    /// Kept in the toolbar while it is short of room, as the items that can't be taken off are, before the others go
    /// to the » menu.
    public var highPriority: Bool
    /// The command whose shortcut the tooltip shows.
    public var shortcutCommand: ShortcutCommandID?
    /// The command's full name, where the label is a shorter one for the Settings tiles.
    public var tooltipLabel: String?
    public var allowDuplicates: Bool

    init(
        id: ToolbarItemID, label: String, icon: CommandIcon?, commandType: AppCommand? = nil,
        topRequired: Bool = false, highPriority: Bool = false, shortcutCommand: ShortcutCommandID? = nil,
        tooltipLabel: String? = nil, allowDuplicates: Bool = false
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.commandType = commandType
        self.topRequired = topRequired
        self.highPriority = topRequired || highPriority
        self.shortcutCommand = shortcutCommand
        self.tooltipLabel = tooltipLabel
        self.allowDuplicates = allowDuplicates
    }
}

/// The toolbar over the file list: its items, their order, and what can be done to that order.
/// The table itself (`definitions`, `defaultTopItems`, `paletteOrder`) is in ToolbarItemTable.swift.
public enum ToolbarItems {
    /// Every item, in the table's order.
    public static let ids: [ToolbarItemID] = definitions.map(\.id)

    private static let definitionByID: [ToolbarItemID: ToolbarItemDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    public static func definition(_ id: ToolbarItemID) -> ToolbarItemDefinition {
        definitionByID[id] ?? definitions[0]
    }

    /// An unknown or repeated item is dropped; a separator may repeat.
    static func sanitizeItemList(_ value: JSONNode?) -> [ToolbarItemID] {
        guard let items = value?.array else { return [] }
        var seen = Set<ToolbarItemID>()
        var result: [ToolbarItemID] = []
        for candidate in items {
            guard let name = candidate.string, let id = ToolbarItemID(rawValue: name) else { continue }
            if !definition(id).allowDuplicates {
                if seen.contains(id) { continue }
                seen.insert(id)
            }
            result.append(id)
        }
        return result
    }

    public static func isRequiredTopItem(_ id: ToolbarItemID) -> Bool {
        definition(id).topRequired
    }

    /// The items every top toolbar holds, in the default's order.
    private static let requiredTopItems = defaultTopItems.filter(isRequiredTopItem)

    /// Every top toolbar holds the title and a search field; a list without one of them gets it at the end. Compact Search is the search field as much as Search is, and a list holds one of them: of both, the first.
    public static func sanitizeTopItems(_ value: JSONNode?) -> [ToolbarItemID] {
        var next = sanitizeItemList(value)
        if let search = next.firstIndex(of: .search), let compact = next.firstIndex(of: .compactSearch) {
            next.remove(at: max(search, compact))
        }
        return next
            + requiredTopItems.filter { !next.contains($0) && !($0 == .search && next.contains(.compactSearch)) }
    }

    /// The toolbar holds both search items once one is dragged in beside the other: the one it held before goes, so
    /// the one just added takes its place.
    public static func replacingTheOtherSearch(_ items: [ToolbarItemID], previous: [ToolbarItemID]) -> [ToolbarItemID] {
        guard items.contains(.search), items.contains(.compactSearch) else { return items }
        let old: ToolbarItemID? =
            previous.contains(.compactSearch) && !previous.contains(.search)
            ? .compactSearch : previous.contains(.search) && !previous.contains(.compactSearch) ? .search : nil
        guard let old else { return items }
        return items.filter { $0 != old }
    }

    /// The two items that hold the search field.
    public static func isSearchField(_ id: ToolbarItemID) -> Bool { id == .search || id == .compactSearch }

    /// What can still be put in the toolbar. Every item it does not hold yet, and the
    /// space, which it can hold any number of times.
    public static func paletteItems(excluding items: [ToolbarItemID]) -> [ToolbarItemID] {
        paletteOrder.filter { definition($0).allowDuplicates || !items.contains($0) }
    }

    /// The items a saved order draws: a space with nothing on one side of it, or right after another, divides
    /// nothing and isn't drawn. The saved order keeps it.
    public static func withoutIdleSeparators(_ items: [ToolbarItemID]) -> [ToolbarItemID] {
        var result: [ToolbarItemID] = []
        for id in items {
            if id == .topSeparator, result.isEmpty || result.last == .topSeparator { continue }
            result.append(id)
        }
        if result.last == .topSeparator { result.removeLast() }
        return result
    }
}
