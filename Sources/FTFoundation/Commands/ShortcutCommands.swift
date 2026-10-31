// Port of the command table and the key resolution of apps/desktop/src/shared/shortcuts.ts
import Foundation

/// A command's place in the shortcut table.
public struct ShortcutCommandDefinition: Sendable, Equatable {
    public var id: ShortcutCommandID
    /// Named as the menus name it.
    public var label: String
    public var group: ShortcutGroup
    public var defaults: [String]
    /// Where the command is in the menus, for text that has no key to name.
    public var menuPath: String?
    /// Never changed in Settings: the key is shared with text fields, or is macOS's own.
    public var fixed: Bool

    init(
        id: ShortcutCommandID, label: String, group: ShortcutGroup, defaults: [String], menuPath: String? = nil,
        fixed: Bool = false
    ) {
        self.id = id
        self.label = label
        self.group = group
        self.defaults = defaults
        self.menuPath = menuPath
        self.fixed = fixed
    }
}

/// The keys of every command, main first.
public typealias ShortcutBindings = [ShortcutCommandID: [String]]

public struct ResolvedShortcuts: Sendable, Equatable {
    public var bindings: ShortcutBindings
    /// The command a key press runs. Fixed commands are not in it; they have handlers of their own.
    public var commandByShortcut: [String: ShortcutCommandID]
    /// The keys of `commandByShortcut` in the order the original's map holds them.
    public var shortcutOrder: [String]
}

/// The one table of keyboard shortcuts. The application menu, the window's key handler, the context menus, tooltips,
/// Help and Settings all read it, so a shortcut changed in Settings changes everywhere at once. The table itself
/// (`all`) is in ShortcutCommandTable.swift.
public enum ShortcutCommands {
    /// SHORTCUTS_PER_COMMAND.
    public static let perCommand = 2

    private static let definitionByID: [ShortcutCommandID: ShortcutCommandDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// `getShortcutCommand`.
    public static func definition(_ id: ShortcutCommandID) -> ShortcutCommandDefinition {
        definitionByID[id] ?? all[0]
    }

    /// `isShortcutCommandId`.
    public static func isCommandID(_ value: String) -> Bool {
        ShortcutCommandID(rawValue: value) != nil
    }

    private static func normalizeAll(_ shortcuts: [String]) -> [String] {
        shortcuts.compactMap(Shortcuts.normalize)
    }

    /// DEFAULT_SHORTCUT_BINDINGS.
    public static let defaultBindings: ShortcutBindings = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, normalizeAll($0.defaults)) })

    private static let fixedCommandByShortcut: [String: ShortcutCommandID] = {
        var map: [String: ShortcutCommandID] = [:]
        for command in all where command.fixed {
            for shortcut in normalizeAll(command.defaults) {
                map[shortcut] = command.id
            }
        }
        return map
    }()

    /// Keys that never reach the app: macOS acts on them first.
    private static let macOSShortcuts = Set(
        normalizeAll([
            "Cmd+Tab", "Cmd+Shift+Tab", "Cmd+`", "Cmd+Shift+`", "Cmd+Space", "Ctrl+Space", "Ctrl+Cmd+Space",
            "Cmd+Option+Space", "Cmd+Option+Esc", "Ctrl+Cmd+Q", "Cmd+Shift+Q", "Cmd+Option+Shift+Q", "Cmd+Shift+3",
            "Cmd+Shift+4", "Cmd+Shift+5", "Ctrl+Cmd+Shift+3", "Ctrl+Cmd+Shift+4", "Cmd+Option+D", "Cmd+Shift+/",
        ]))

    /// Keys macOS uses unless they were switched off in System Settings.
    private static let macOSOptionalShortcuts = Set(
        normalizeAll(["Ctrl+Up", "Ctrl+Down", "Ctrl+Left", "Ctrl+Right", "F11"]))

    /// ⌘. cancels a dialog, as Escape does.
    private static let cancelShortcut = "Cmd+."

    // MARK: Refusals

    public enum Refusal: Equatable, Sendable {
        /// Letters, digits, punctuation and Space type into the file list.
        case needsCommandOrControl
        /// Arrows, Tab, Return, Esc and Backspace move around or edit the list.
        case needsModifier
        case fixedCommand(ShortcutCommandID)
        case cancelsDialogs
        case macOS

        /// The `reason` the original gives.
        public var reason: String {
            switch self {
            case .needsCommandOrControl: "needsCommandOrControl"
            case .needsModifier: "needsModifier"
            case .fixedCommand: "fixedCommand"
            case .cancelsDialogs: "cancelsDialogs"
            case .macOS: "macOS"
            }
        }
    }

    private static func isTypingKey(_ key: String) -> Bool {
        key.utf16.count == 1 || key == "Plus" || key == "Space"
    }

    /// `getShortcutRefusal`: why a key can not be given to any command, or nil when it can.
    public static func refusal(for shortcut: String) -> Refusal? {
        guard let parsed = Shortcuts.parse(shortcut) else { return .needsCommandOrControl }
        if let fixed = fixedCommandByShortcut[shortcut] {
            return .fixedCommand(fixed)
        }
        if shortcut == cancelShortcut {
            return .cancelsDialogs
        }
        if macOSShortcuts.contains(shortcut) {
            return .macOS
        }
        if isTypingKey(parsed.key), !parsed.cmd, !parsed.ctrl {
            return .needsCommandOrControl
        }
        if Shortcuts.motionKeys.contains(parsed.key), !parsed.cmd, !parsed.ctrl, !parsed.option {
            return .needsModifier
        }
        return nil
    }

    /// `isShortcutUsedByMacOSByDefault`: macOS may take the key before the app sees it; it works once that is
    /// switched off.
    public static func isUsedByMacOSByDefault(_ shortcut: String) -> Bool {
        macOSOptionalShortcuts.contains(shortcut)
    }

    /// A command keeps a key of its own defaults that could not be given out today (Space for Quick Look, ? for Help).
    private static func isAllowed(_ command: ShortcutCommandDefinition, _ shortcut: String) -> Bool {
        if refusal(for: shortcut) == nil {
            return true
        }
        return has(normalizeAll(command.defaults), shortcut)
    }

    // MARK: Resolution

    /// `resolveShortcuts`: the keys every command has, given what was saved. Saved keys are taken as far as they make
    /// sense: an unknown command or an unusable key is dropped, and a key two commands claim goes to the one that was
    /// given it over the one that has it by default.
    public static func resolve(_ overrides: JSONNode?) -> ResolvedShortcuts {
        let saved = overrides?.object ?? [:]
        var taken: [String: ShortcutCommandID] = [:]
        var takenOrder: [String] = []
        var bindings: ShortcutBindings = [:]
        func claim(_ command: ShortcutCommandDefinition, _ shortcuts: [String]) {
            var kept: [String] = []
            for shortcut in shortcuts {
                if kept.count == perCommand || taken[shortcut] != nil {
                    continue
                }
                taken[shortcut] = command.id
                takenOrder.append(shortcut)
                kept.append(shortcut)
            }
            bindings[command.id] = kept
        }
        for command in all where command.fixed {
            claim(command, defaultBindings[command.id] ?? [])
        }
        func customized(_ command: ShortcutCommandDefinition) -> [String]? {
            guard !command.fixed, let value = saved[command.id.rawValue]?.array else { return nil }
            return value.compactMap { candidate in
                guard let text = candidate.string, let shortcut = Shortcuts.normalize(text),
                    isAllowed(command, shortcut)
                else { return nil }
                return shortcut
            }
        }
        for command in all {
            if let shortcuts = customized(command) {
                claim(command, shortcuts)
            }
        }
        for command in all where bindings[command.id] == nil {
            claim(command, defaultBindings[command.id] ?? [])
        }
        var commandByShortcut: [String: ShortcutCommandID] = [:]
        var order: [String] = []
        for shortcut in takenOrder {
            if let id = taken[shortcut], !definition(id).fixed {
                commandByShortcut[shortcut] = id
                order.append(shortcut)
            }
        }
        return ResolvedShortcuts(bindings: bindings, commandByShortcut: commandByShortcut, shortcutOrder: order)
    }

    /// `resolveShortcuts` for overrides held as a dictionary.
    public static func resolve(_ overrides: ShortcutOverrides) -> ResolvedShortcuts {
        resolve(.object(overrides.mapValues { .array($0.map(JSONNode.string)) }))
    }

    /// DEFAULT_SHORTCUTS.
    public static let defaultResolved = resolve(JSONNode.object([:]))

    /// `shortcuts.includes(shortcut)`: strings are equal scalar for scalar, as JavaScript compares them.
    private static func has(_ shortcuts: [String], _ shortcut: String) -> Bool {
        shortcuts.contains { JSString.equals($0, shortcut) }
    }

    private static func same(_ left: [String], _ right: [String]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { JSString.equals($0, $1) }
    }

    /// `toShortcutOverrides`: what to save for a set of keys, the commands that differ from their defaults.
    public static func overrides(for bindings: ShortcutBindings) -> ShortcutOverrides {
        var overrides: ShortcutOverrides = [:]
        for command in all {
            let shortcuts = bindings[command.id] ?? []
            if !same(shortcuts, defaultBindings[command.id] ?? []) {
                overrides[command.id.rawValue] = shortcuts
            }
        }
        return overrides
    }

    /// `sanitizeShortcutOverrides`: saved keys as the app will use them, whatever shape they arrived in.
    public static func sanitizeOverrides(_ value: JSONNode?) -> ShortcutOverrides {
        overrides(for: resolve(value).bindings)
    }

    /// `isShortcutCustomized`.
    public static func isCustomized(_ bindings: ShortcutBindings, _ id: ShortcutCommandID) -> Bool {
        !same(bindings[id] ?? [], defaultBindings[id] ?? [])
    }

    // MARK: Changing keys (Settings)

    public enum Assignment: Equatable, Sendable {
        case ok
        /// The command already has the key.
        case unchanged
        case refused(Refusal)
        /// Another command has the key; it can be moved here.
        case conflict(ShortcutCommandID)
    }

    /// `checkShortcutAssignment`: whether a key can be given to a command, as things stand.
    public static func checkAssignment(_ bindings: ShortcutBindings, _ id: ShortcutCommandID, _ shortcut: String)
        -> Assignment
    {
        let command = definition(id)
        if has(bindings[id] ?? [], shortcut) {
            return .unchanged
        }
        if let refusal = refusal(for: shortcut), !has(normalizeAll(command.defaults), shortcut) {
            return .refused(refusal)
        }
        for other in all where other.id != id && has(bindings[other.id] ?? [], shortcut) {
            return .conflict(other.id)
        }
        return .ok
    }

    /// `assignShortcut`: gives a key to a command in the main (0) or alternate (1) place, taking it away from any
    /// command that had it. A key put in an empty main place stays the only one.
    public static func assign(_ bindings: ShortcutBindings, _ id: ShortcutCommandID, slot: Int, _ shortcut: String)
        -> ShortcutBindings
    {
        var next = bindings
        for command in all where command.id != id && has(next[command.id] ?? [], shortcut) {
            next[command.id] = (next[command.id] ?? []).filter { !JSString.equals($0, shortcut) }
        }
        var own = (next[id] ?? []).filter { !JSString.equals($0, shortcut) }
        if slot < own.count {
            if slot >= 0 {
                own[slot] = shortcut
            }
        } else {
            own.append(shortcut)
        }
        next[id] = Array(own.prefix(perCommand))
        return next
    }

    /// `removeShortcut`: takes a key away from a command; the alternate, if there is one, becomes the main key.
    public static func remove(_ bindings: ShortcutBindings, _ id: ShortcutCommandID, slot: Int) -> ShortcutBindings {
        var next = bindings
        next[id] = (bindings[id] ?? []).enumerated().filter { $0.offset != slot }.map(\.element)
        return next
    }

    /// `resetShortcut`: gives a command its default keys back. A default key another command was given since is taken
    /// back from it; the commands it was taken from are returned.
    public static func reset(_ bindings: ShortcutBindings, _ id: ShortcutCommandID)
        -> (bindings: ShortcutBindings, takenFrom: [ShortcutCommandID])
    {
        let defaults = defaultBindings[id] ?? []
        var next = bindings
        next[id] = defaults
        var takenFrom: [ShortcutCommandID] = []
        for command in all where command.id != id {
            let current = next[command.id] ?? []
            let kept = current.filter { !has(defaults, $0) }
            if kept.count != current.count {
                next[command.id] = kept
                takenFrom.append(command.id)
            }
        }
        return (next, takenFrom)
    }
}
