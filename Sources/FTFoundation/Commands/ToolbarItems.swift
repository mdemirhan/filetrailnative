import Foundation

public struct ToolbarItemDefinition: Sendable, Equatable {
    public var id: ToolbarItemID
    public var label: String
    /// The icon of its button; the items that are not buttons (the space, the title, the view switch) have none.
    public var icon: CommandIcon?
    public var commandType: AppCommand?
    /// Always in the toolbar: it can be moved there, but not taken off.
    public var topRequired: Bool
    /// The command whose shortcut the tooltip shows.
    public var shortcutCommand: ShortcutCommandID?
    /// The command's full name, where the label is a shorter one for the Settings tiles.
    public var tooltipLabel: String?
    public var allowDuplicates: Bool

    init(
        id: ToolbarItemID, label: String, icon: CommandIcon?, commandType: AppCommand? = nil,
        topRequired: Bool = false, shortcutCommand: ShortcutCommandID? = nil, tooltipLabel: String? = nil,
        allowDuplicates: Bool = false
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.commandType = commandType
        self.topRequired = topRequired
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

    /// The four items every top toolbar holds, in the default's order.
    private static let requiredTopItems = defaultTopItems.filter(isRequiredTopItem)

    /// Every top toolbar holds the title, the clipboard button, search and View Options;
    /// a list without one of them gets it at the end.
    public static func sanitizeTopItems(_ value: JSONNode?) -> [ToolbarItemID] {
        let next = sanitizeItemList(value)
        return next + requiredTopItems.filter { !next.contains($0) }
    }

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
