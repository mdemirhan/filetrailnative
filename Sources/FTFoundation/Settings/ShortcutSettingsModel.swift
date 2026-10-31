// Port of the logic of apps/desktop/src/renderer/components/ShortcutSettings.tsx: the rows, the search, the recorder and
// the notes under a row
import Foundation

/// A place for a key: a command and its main (0) or alternate (1) key.
public struct ShortcutSlot: Equatable, Sendable, Hashable {
    public var id: ShortcutCommandID
    public var index: Int

    public init(id: ShortcutCommandID, index: Int) {
        self.id = id
        self.index = index
    }
}

/// What is said under a row: why a key was refused, something to know about the key just given, or whether to take a
/// key from the command that has it.
public enum ShortcutRowNote: Equatable, Sendable {
    case refused(ShortcutCommandID, String)
    case info(ShortcutCommandID, String)
    case conflict(ShortcutCommandID, index: Int, shortcut: String, other: String)

    public var commandID: ShortcutCommandID {
        switch self {
        case .refused(let id, _), .info(let id, _), .conflict(let id, _, _, _): id
        }
    }

    /// The sentence of the note.
    public var text: String {
        switch self {
        case .refused(_, let text), .info(_, let text): text
        case .conflict(_, _, let shortcut, let other): "\(ShortcutLabels.format(shortcut)) is used by \(other)."
        }
    }
}

/// The texts of Settings › Shortcuts.
public enum ShortcutSettingsText {
    public static let intro = "Click a key and press the new one. Esc cancels, and ⌫ removes the key."
    public static let standardGroupNote =
        "The same in every Mac app, or shared with text fields. They can not be changed here."
    public static let searchPlaceholder = "Search commands or keys"

    /// `ROW_HINTS`, and Rename's while Return renames.
    public static func hint(_ id: ShortcutCommandID, returnKeyAction: ReturnKeyAction) -> String? {
        switch id {
        case .renameSelection: returnKeyAction == .rename ? "Return renames too: Settings → Files." : nil
        case .openSelectedItem: "Does what a double-click does."
        case .toggleFavorite: "Removes the folder when it is a favorite already."
        default: nil
        }
    }

    /// The group's title above its card.
    public static func groupTitle(_ group: ShortcutGroup) -> String {
        group == .standard ? "Standard shortcuts" : group.label
    }

    /// The label without a trailing "…".
    public static func withoutEllipsis(_ label: String) -> String {
        label.hasSuffix("…") ? String(label.dropLast()) : label
    }

    public static func label(_ id: ShortcutCommandID) -> String {
        withoutEllipsis(ShortcutCommands.definition(id).label)
    }

    /// `describeRefusal`.
    public static func refusal(_ refusal: ShortcutCommands.Refusal, _ shortcut: String) -> String {
        let keys = ShortcutLabels.format(shortcut)
        switch refusal {
        case .needsCommandOrControl: return "\(keys) on its own types into the file list. Add ⌘ or ⌃."
        case .needsModifier: return "\(keys) on its own moves around the list. Add ⌘, ⌃ or ⌥."
        case .fixedCommand(let command): return "\(keys) is \(label(command)), which can not be changed."
        case .cancelsDialogs: return "\(keys) cancels a dialog, as Esc does."
        case .macOS: return "macOS keeps \(keys) for itself."
        }
    }

    public static func missionControl(_ shortcut: String) -> String {
        "macOS may use \(ShortcutLabels.format(shortcut)) itself, for Mission Control. It works here once that is "
            + "switched off in System Settings → Keyboard → Keyboard Shortcuts."
    }

    public static func takenBack(_ commands: [ShortcutCommandID]) -> String {
        "Taken back from \(commands.map(label).joined(separator: " and "))."
    }

    public static func noMatch(_ query: String) -> String {
        "No command or key matches “\(JSString.trimmed(query))”."
    }
}

/// Settings › Shortcuts as it stands: the keys, the place being recorded, the note and the search. Each change returns
/// the overrides to save, or nil when nothing is saved.
public struct ShortcutSettingsModel: Equatable, Sendable {
    public private(set) var bindings: ShortcutBindings
    public var recording: ShortcutSlot?
    public var note: ShortcutRowNote?
    public var query = ""

    public init(overrides: ShortcutOverrides) {
        bindings = ShortcutCommands.resolve(overrides).bindings
    }

    /// The saved keys changed (here, or in another window).
    public mutating func setOverrides(_ overrides: ShortcutOverrides) {
        bindings = ShortcutCommands.resolve(overrides).bindings
    }

    public func shortcuts(_ id: ShortcutCommandID) -> [String] { bindings[id] ?? [] }

    public func isCustomized(_ id: ShortcutCommandID) -> Bool { ShortcutCommands.isCustomized(bindings, id) }

    public var anyCustomized: Bool { ShortcutCommands.all.contains { isCustomized($0.id) } }

    /// The keys the command has, then one empty place while there is room for another.
    public func slotCount(_ id: ShortcutCommandID) -> Int {
        min(shortcuts(id).count + 1, ShortcutCommands.perCommand)
    }

    // MARK: Search

    /// The groups with the commands whose label, group name or keys (as written or as shown) contain the text.
    public var groups: [(group: ShortcutGroup, commands: [ShortcutCommandDefinition])] {
        let needle = JSString.trimmed(query).lowercased()
        return ShortcutGroup.allCases.compactMap { group in
            let commands = ShortcutCommands.all.filter { command in
                guard command.group == group else { return false }
                guard !needle.isEmpty else { return true }
                let texts =
                    [command.label, group.label]
                    + shortcuts(command.id).flatMap { [$0, ShortcutLabels.format($0)] }
                return texts.contains { $0.lowercased().contains(needle) }
            }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    // MARK: Recording

    /// Starts recording on `slot`, or stops with nil; the row's note goes.
    public mutating func record(_ slot: ShortcutSlot?) {
        recording = slot
        note = nil
    }

    private mutating func save(_ next: ShortcutBindings) -> ShortcutOverrides {
        bindings = next
        return ShortcutCommands.overrides(for: next)
    }

    /// `give`: the key goes into the place, from whichever command had it.
    public mutating func give(_ slot: ShortcutSlot, _ shortcut: String) -> ShortcutOverrides {
        let saved = save(ShortcutCommands.assign(bindings, slot.id, slot: slot.index, shortcut))
        recording = nil
        note =
            ShortcutCommands.isUsedByMacOSByDefault(shortcut)
            ? .info(slot.id, ShortcutSettingsText.missionControl(shortcut)) : nil
        return saved
    }

    /// `press`: a key pressed while recording.
    public mutating func press(_ slot: ShortcutSlot, _ shortcut: String) -> ShortcutOverrides? {
        switch ShortcutCommands.checkAssignment(bindings, slot.id, shortcut) {
        case .unchanged:
            recording = nil
            note = nil
            return nil
        case .refused(let refusal):
            // Recording goes on, so another key can be tried straight away.
            note = .refused(slot.id, ShortcutSettingsText.refusal(refusal, shortcut))
            return nil
        case .conflict(let other):
            recording = nil
            note = .conflict(
                slot.id, index: slot.index, shortcut: shortcut, other: ShortcutSettingsText.label(other))
            return nil
        case .ok:
            return give(slot, shortcut)
        }
    }

    public mutating func remove(_ slot: ShortcutSlot) -> ShortcutOverrides {
        let saved = save(ShortcutCommands.remove(bindings, slot.id, slot: slot.index))
        recording = nil
        note = nil
        return saved
    }

    public mutating func reset(_ id: ShortcutCommandID) -> ShortcutOverrides {
        let result = ShortcutCommands.reset(bindings, id)
        let saved = save(result.bindings)
        recording = nil
        note = result.takenFrom.isEmpty ? nil : .info(id, ShortcutSettingsText.takenBack(result.takenFrom))
        return saved
    }

    /// Restore Defaults at the bottom of the tab.
    public mutating func resetAll() -> ShortcutOverrides {
        bindings = ShortcutCommands.defaultBindings
        recording = nil
        note = nil
        return [:]
    }

    /// What a key press while recording `slot` does (B-DLG-214 to 217): nil keeps waiting (only modifiers down).
    public enum RecorderAction: Equatable, Sendable {
        case cancel
        case remove
        case press(String)
    }

    public func recorderAction(_ pressed: String?, slot: ShortcutSlot) -> RecorderAction? {
        guard let pressed else { return nil }
        if pressed == "Esc" { return .cancel }
        if pressed == "Backspace" {
            return shortcuts(slot.id).indices.contains(slot.index) ? .remove : .cancel
        }
        return .press(pressed)
    }
}
