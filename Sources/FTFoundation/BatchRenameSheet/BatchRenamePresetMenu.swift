// Port of the Presets pull-down of apps/desktop/src/renderer/components/BatchRenameSheet.tsx (choosePreset,
// savePreset, the closed title, presetNameTaken) and of savePreset and deletePreset of
// apps/desktop/src/renderer/hooks/useBatchRename.ts
import Foundation

/// The Presets pull-down: the saved presets, a separator, Save as Preset…, and Update and Delete once one is loaded.
public struct BatchRenamePresetMenu: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case preset(String)
        case separator
        case save
        case update(String)
        case delete(String)

        public var title: String {
            switch self {
            case .preset(let name): name
            case .separator: ""
            case .save: "Save as Preset\u{2026}"
            case .update(let name): "Update \u{201C}\(name)\u{201D}"
            case .delete(let name): "Delete \u{201C}\(name)\u{201D}"
            }
        }
    }

    /// What choosing an item does.
    public enum Choice: Equatable, Sendable {
        /// Loads the preset's settings entirely; it becomes the current one.
        case load(BatchRenamePreset)
        /// Asks for a name, starting with the current preset's.
        case startNaming(initialName: String)
        /// Saves the settings over the current preset.
        case update(String)
        /// Removes the current preset and forgets it as current.
        case delete(String)
        case none
    }

    public var presets: [BatchRenamePreset]
    /// The preset last loaded or saved, offered for Update and Delete while it exists.
    public var currentName: String?

    public init(presets: [BatchRenamePreset], currentName: String?) {
        self.presets = presets
        self.currentName = currentName
    }

    /// The current preset, while one of that name is saved.
    public var current: BatchRenamePreset? {
        guard let currentName else { return nil }
        return presets.first { $0.name == currentName }
    }

    /// Whether the settings are still the current preset's: the closed pull-down then shows it as chosen.
    public func matchesCurrent(_ settings: BatchRenameSettings) -> Bool {
        current?.settings == settings
    }

    /// What the closed pull-down says: the preset loaded, marked once its settings are changed, or "Presets".
    public func closedTitle(_ settings: BatchRenameSettings) -> String {
        guard let current else { return "Presets" }
        return matchesCurrent(settings) ? current.name : "\(current.name) (Edited)"
    }

    public var items: [Item] {
        var items = presets.map { Item.preset($0.name) }
        if !presets.isEmpty { items.append(.separator) }
        items.append(.save)
        if let current {
            items.append(.update(current.name))
            items.append(.delete(current.name))
        }
        return items
    }

    /// `choosePreset`: the pull-down never stays on a command; what the item does.
    public mutating func choose(_ item: Item) -> Choice {
        switch item {
        case .preset(let name):
            guard let preset = presets.first(where: { $0.name == name }) else { return .none }
            currentName = preset.name
            return .load(preset)
        case .separator:
            return .none
        case .save:
            return .startNaming(initialName: current?.name ?? "")
        case .update:
            guard let current else { return .none }
            return .update(current.name)
        case .delete:
            guard let current else { return .none }
            currentName = nil
            return .delete(current.name)
        }
    }

    // MARK: Naming

    /// The longest name a preset takes (`maxLength={80}`).
    public static let maxNameLength = 80

    /// `presetNameTaken`: the typed name, trimmed, is a saved preset's, ignoring case.
    public func isTaken(_ typed: String) -> Bool {
        let wanted = JSString.lowercased(JSString.trimmed(typed))
        return presets.contains { JSString.lowercased($0.name) == wanted }
    }

    /// The naming's default button: "Replace" for a name saved already, else "Save".
    public func saveTitle(_ typed: String) -> String { isTaken(typed) ? "Replace" : "Save" }

    /// Save can't be pressed for a blank name.
    public static func canSave(_ typed: String) -> Bool { !JSString.trimmed(typed).isEmpty }

    /// `savePreset` of the sheet: the name trimmed, nothing for a blank one; it becomes the current preset.
    public mutating func named(_ typed: String) -> String? {
        let name = JSString.trimmed(typed)
        guard !name.isEmpty else { return nil }
        currentName = name
        return name
    }
}

/// The saved presets, as the sheet's state changes them (`savePreset`, `deletePreset` of `useBatchRename`).
public enum BatchRenamePresetList {
    /// Saves `settings` under `name`, trimmed: a preset of that name ignoring case leaves its place and the new one
    /// goes to the end under the spelling typed; the newest 50 are kept. Nil for a blank name.
    public static func saving(_ name: String, settings: BatchRenameSettings, in presets: [BatchRenamePreset])
        -> [BatchRenamePreset]?
    {
        let trimmed = JSString.trimmed(name)
        guard !trimmed.isEmpty else { return nil }
        let key = JSString.lowercased(trimmed)
        let others = presets.filter { JSString.lowercased($0.name) != key }
        return Array((others + [BatchRenamePreset(name: trimmed, settings: settings)]).suffix(BatchRename.maxPresets))
    }

    /// Removes the preset of exactly that name.
    public static func deleting(_ name: String, from presets: [BatchRenamePreset]) -> [BatchRenamePreset] {
        presets.filter { $0.name != name }
    }

    /// The presets as the saved state holds them.
    public static func node(of presets: [BatchRenamePreset]) -> JSONNode {
        (try? JSONNode.of(presets)) ?? .array([])
    }

    /// The settings as the saved state holds them.
    public static func node(of settings: BatchRenameSettings) -> JSONNode {
        BatchRename.node(of: settings)
    }
}
