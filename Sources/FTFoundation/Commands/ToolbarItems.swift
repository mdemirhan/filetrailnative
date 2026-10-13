// Port of apps/desktop/src/shared/toolbarItems.ts
import Foundation

public struct ToolbarItemDefinition: Sendable, Equatable {
    public var id: ToolbarItemID
    public var label: String
    public var icon: ToolbarIconName
    public var kind: ToolbarItemKind
    public var commandType: RendererCommand?
    /// Always in the toolbar: it can be moved there, but not taken off.
    public var topRequired: Bool
    /// The command whose shortcut the tooltip shows.
    public var shortcutCommand: ShortcutCommandID?
    /// The command's full name, where the label is a shorter one for the Settings tiles.
    public var tooltipLabel: String?
    public var allowDuplicates: Bool

    init(
        id: ToolbarItemID, label: String, icon: ToolbarIconName, kind: ToolbarItemKind,
        commandType: RendererCommand? = nil, topRequired: Bool = false, shortcutCommand: ShortcutCommandID? = nil,
        tooltipLabel: String? = nil, allowDuplicates: Bool = false
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
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
    /// TOOLBAR_ITEM_IDS.
    public static let ids: [ToolbarItemID] = definitions.map(\.id)

    private static let definitionByID: [ToolbarItemID: ToolbarItemDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    /// `isToolbarItemId`.
    public static func isToolbarItemID(_ value: String) -> Bool {
        ToolbarItemID(rawValue: value) != nil
    }

    /// `getToolbarItemDefinition`.
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

    /// `isRequiredTopToolbarItem`.
    public static func isRequiredTopItem(_ id: ToolbarItemID) -> Bool {
        definition(id).topRequired
    }

    /// The four items every top toolbar holds, in the default's order.
    private static let requiredTopItems = defaultTopItems.filter(isRequiredTopItem)

    /// `sanitizeTopToolbarItems`: every top toolbar holds the title, the clipboard button, search and View Options;
    /// a list without one of them gets it at the end.
    public static func sanitizeTopItems(_ value: JSONNode?) -> [ToolbarItemID] {
        let next = sanitizeItemList(value)
        return next + requiredTopItems.filter { !next.contains($0) }
    }

    /// `getTopToolbarPaletteItems`: what can still be put in the toolbar. Every item it does not hold yet, and the
    /// space, which it can hold any number of times.
    public static func paletteItems(excluding items: [ToolbarItemID]) -> [ToolbarItemID] {
        paletteOrder.filter { definition($0).allowDuplicates || !items.contains($0) }
    }

    /// `addTopToolbarItem`: an item clicked in the palette goes at the far right.
    public static func addTopItem(_ items: [ToolbarItemID], _ id: ToolbarItemID) -> [ToolbarItemID] {
        insertTopItem(items, id, at: items.count)
    }

    /// `insertTopToolbarItem`: an item dropped into the toolbar, at `index` (clamped to the ends).
    public static func insertTopItem(_ items: [ToolbarItemID], _ id: ToolbarItemID, at index: Int) -> [ToolbarItemID] {
        let position = max(0, min(index, items.count))
        return Array(items[..<position]) + [id] + Array(items[position...])
    }

    /// `moveTopToolbarItem`: the item at `from` taken out and put back at `to`, an index in the order without it.
    public static func moveTopItem(_ items: [ToolbarItemID], from: Int, to: Int) -> [ToolbarItemID] {
        guard items.indices.contains(from) else { return items }
        let id = items[from]
        var rest = items
        rest.remove(at: from)
        return insertTopItem(rest, id, at: to)
    }

    /// `removeTopToolbarItem`: the item at `index` taken off the toolbar, unless it is one that always stays.
    public static func removeTopItem(_ items: [ToolbarItemID], at index: Int) -> [ToolbarItemID] {
        guard items.indices.contains(index), !isRequiredTopItem(items[index]) else { return items }
        var rest = items
        rest.remove(at: index)
        return rest
    }
}
