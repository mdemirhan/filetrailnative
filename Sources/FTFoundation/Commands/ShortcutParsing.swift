// Port of the parsing half of apps/desktop/src/shared/shortcuts.ts
import Foundation

/// A shortcut taken apart. It is written "Cmd+Shift+G": modifiers in the order Ctrl, Cmd, Option, Shift, then one key.
struct ParsedShortcut: Equatable {
    var ctrl = false
    var cmd = false
    var option = false
    var shift = false
    var key: String
}

/// The keyboard event the original's window key handler sees (`ShortcutKeyEvent`): `key` is the character the
/// press types, `code` the position of the key.
public struct ShortcutKeyEvent: Equatable, Sendable {
    public var key: String
    public var code: String
    public var metaKey: Bool
    public var ctrlKey: Bool
    public var altKey: Bool
    public var shiftKey: Bool

    public init(
        key: String, code: String, metaKey: Bool = false, ctrlKey: Bool = false, altKey: Bool = false,
        shiftKey: Bool = false
    ) {
        self.key = key
        self.code = code
        self.metaKey = metaKey
        self.ctrlKey = ctrlKey
        self.altKey = altKey
        self.shiftKey = shiftKey
    }
}

public enum Shortcuts {
    // MARK: Parsing

    private enum Modifier {
        case ctrl, cmd, option, shift
        /// A name JavaScript finds on any object (`MODIFIER_NAMES["constructor"]`): it names no modifier but is
        /// not refused either.
        case inherited
    }

    private static func modifier(named lowercased: String) -> Modifier? {
        switch lowercased {
        case "ctrl", "control": .ctrl
        case "cmd", "command", "commandorcontrol": .cmd
        case "option", "alt": .option
        case "shift": .shift
        case "constructor", "__proto__": .inherited
        default: nil
        }
    }

    /// Keys that have a name rather than a character.
    private static let namedKeys = [
        "Up", "Down", "Left", "Right", "Backspace", "Delete", "Return", "Tab", "Space", "Esc", "Home", "End", "PageUp",
        "PageDown", "Plus",
    ]
    private static let namedKeyByLowercase: [String: String] = Dictionary(
        uniqueKeysWithValues: namedKeys.map { ($0.lowercased(), $0) })
    private static let punctuationKeys: Set<UInt16> = Set("-=[]\\;',./`".utf16)

    /// Keys that move around or edit a list on their own, so they need a modifier.
    static let motionKeys: Set<String> = [
        "Up", "Down", "Left", "Right", "Home", "End", "Tab", "Return", "Esc", "Backspace",
    ]

    /// `/^F([1-9]|1[0-9]|20)$/`.
    static func isFunctionKey(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard units.count == 2 || units.count == 3, units[0] == 0x46 else { return false }
        let digits = units.dropFirst()
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        guard let number = Int(String(decoding: digits, as: UTF16.self)) else { return false }
        return digits.first != 0x30 && (1...20).contains(number)
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    /// `normalizeKeyName`.
    static func normalizeKeyName(_ value: String) -> String? {
        let units = Array(value.utf16)
        if units.count == 1 {
            let unit = units[0]
            if isASCIILetter(unit) {
                return value.uppercased()
            }
            if (unit >= 0x30 && unit <= 0x39) || punctuationKeys.contains(unit) || unit == 0x3F {
                return value
            }
            return unit == 0x2B ? "Plus" : nil
        }
        let upper = value.uppercased()
        if isFunctionKey(upper) {
            return upper
        }
        let lower = JSString.lowercased(value)
        if lower == "escape" {
            return "Esc"
        }
        if lower == "enter" {
            return "Return"
        }
        return namedKeyByLowercase[lower]
    }

    /// `parseShortcut`.
    static func parse(_ value: String) -> ParsedShortcut? {
        // "Cmd++" and "+" name the plus key.
        let text = JSString.trimmed(value)
        let endsWithPlusKey = text == "+" || JSString.hasSuffix(text, "++")
        var units = Array(text.utf16)
        if endsWithPlusKey {
            units.removeLast()
            units.append(contentsOf: "Plus".utf16)
        }
        var parts = units.split(separator: 0x2B, omittingEmptySubsequences: false).map {
            JSString.trimmed(JSString.string($0))
        }
        guard let keyPart = parts.popLast(), !parts.contains(where: \.isEmpty) else { return nil }
        guard let key = normalizeKeyName(keyPart) else { return nil }
        var parsed = ParsedShortcut(key: key)
        for part in parts {
            switch modifier(named: JSString.lowercased(part)) {
            case .ctrl: parsed.ctrl = true
            case .cmd: parsed.cmd = true
            case .option: parsed.option = true
            case .shift: parsed.shift = true
            case .inherited: break
            case nil: return nil
            }
        }
        if key == "?" {
            // "?" is the character, however it is typed; it only stands on its own.
            if parsed.ctrl || parsed.cmd || parsed.option {
                return nil
            }
            parsed.shift = false
        }
        return parsed
    }

    /// `writeShortcut`.
    static func write(_ parsed: ParsedShortcut) -> String {
        var parts: [String] = []
        if parsed.ctrl { parts.append("Ctrl") }
        if parsed.cmd { parts.append("Cmd") }
        if parsed.option { parts.append("Option") }
        if parsed.shift { parts.append("Shift") }
        parts.append(parsed.key)
        return parts.joined(separator: "+")
    }

    /// `normalizeShortcut`: the one way a shortcut is written, or nil when the text does not name one.
    public static func normalize(_ value: String) -> String? {
        parse(value).map(write)
    }

    /// `withoutShift`: the shortcut with ⇧ let go ("Ctrl+Shift+D" is "Ctrl+D"), or nil when it has no ⇧.
    public static func withoutShift(_ shortcut: String) -> String? {
        guard var parsed = parse(shortcut), parsed.shift else { return nil }
        parsed.shift = false
        return write(parsed)
    }

    // MARK: Keyboard events

    private static let keyByEventKey: [String: String] = [
        "ArrowUp": "Up", "ArrowDown": "Down", "ArrowLeft": "Left", "ArrowRight": "Right", "Backspace": "Backspace",
        "Delete": "Delete", "Enter": "Return", "Tab": "Tab", "Escape": "Esc", "Home": "Home", "End": "End",
        "PageUp": "PageUp", "PageDown": "PageDown",
    ]

    /// The key at a position of the keyboard, for when a modifier changes the character the key types (Option always
    /// does; Shift does for everything but letters).
    private static let keyByEventCode: [String: String] = [
        "Space": "Space", "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]", "Backslash": "\\",
        "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/", "Backquote": "`",
    ]

    private static func keyFromEventCode(_ code: String) -> String? {
        let units = Array(code.utf16)
        if units.count == 4, JSString.hasPrefix(code, "Key"), units[3] >= 0x41, units[3] <= 0x5A {
            return String(decoding: [units[3]], as: UTF16.self)
        }
        if units.count == 6, JSString.hasPrefix(code, "Digit"), units[5] >= 0x30, units[5] <= 0x39 {
            return String(decoding: [units[5]], as: UTF16.self)
        }
        return keyByEventCode[code]
    }

    /// `shortcutFromKeyboardEvent`: the shortcut a key press spells, or nil while only modifiers are down. Characters
    /// follow the keyboard layout, as menus do.
    public static func fromKeyboardEvent(_ event: ShortcutKeyEvent) -> String? {
        let key = event.key
        let code = event.code
        if key == "?", !event.metaKey, !event.ctrlKey, !event.altKey {
            return "?"
        }
        var name: String?
        let keyUnits = Array(key.utf16)
        if code == "Space" || key == " " {
            name = "Space"
        } else if let mapped = keyByEventKey[key] {
            name = mapped
        } else if isFunctionKey(key) {
            name = key
        } else if !event.altKey, keyUnits.count == 1, isASCIILetter(keyUnits[0]) {
            name = key.uppercased()
        } else if event.altKey {
            name = keyFromEventCode(code)
        } else {
            let character = keyUnits.count == 1 ? normalizeKeyName(key) : nil
            name = event.shiftKey ? (keyFromEventCode(code) ?? character) : (character ?? keyFromEventCode(code))
        }
        guard let name, !name.isEmpty, name != "?" else { return nil }
        return write(
            ParsedShortcut(
                ctrl: event.ctrlKey, cmd: event.metaKey, option: event.altKey, shift: event.shiftKey, key: name))
    }

    // MARK: Text fields

    private static let textEditingKeys: Set<String> = ["Up", "Down", "Left", "Right", "Home", "End", "Backspace"]
    private static let textEditingControlKeys: Set<String> = ["A", "B", "D", "E", "F", "H", "K", "N", "P", "T"]

    /// `isTextEditingShortcut`: the keys a text field uses for itself.
    public static func isTextEditingShortcut(_ shortcut: String) -> Bool {
        guard let parsed = parse(shortcut) else { return false }
        if textEditingKeys.contains(parsed.key) || parsed.key == "Delete" {
            return true
        }
        return parsed.ctrl && !parsed.cmd && textEditingControlKeys.contains(parsed.key)
    }

    // MARK: Menus

    private static func hasCommandOrControl(_ shortcut: String) -> Bool {
        guard let parsed = parse(shortcut) else { return false }
        return parsed.cmd || parsed.ctrl
    }

    /// `getMenuShortcut`: the key the application menu shows and listens for. A key without ⌘ or ⌃ (Space, F2) is left
    /// to the window: as a menu key it would be taken from text fields and dialogs.
    public static func menuShortcut(_ shortcuts: [String]) -> String? {
        shortcuts.first(where: hasCommandOrControl)
    }

    /// `toMenuAccelerator`: a shortcut as Electron's menus write it, "Command+Shift+G".
    public static func menuAccelerator(_ shortcut: String) -> String? {
        guard let parsed = parse(shortcut), parsed.key != "?" else { return nil }
        var parts: [String] = []
        if parsed.ctrl { parts.append("Control") }
        if parsed.cmd { parts.append("Command") }
        if parsed.option { parts.append("Alt") }
        if parsed.shift { parts.append("Shift") }
        parts.append(parsed.key == "Esc" ? "Escape" : parsed.key)
        return parts.joined(separator: "+")
    }
}
