// Port of the toMenuAccelerator use in apps/desktop/src/main/appMenu.ts, written for NSMenuItem instead of Electron
import AppKit
import FTFoundation

/// A key as `NSMenuItem` takes it: the character and the modifier mask.
struct MenuKeyEquivalent: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    /// The key equivalent of a shortcut written as "Cmd+Shift+G"; nil for a key a menu cannot listen for ("?").
    static func parse(_ shortcut: String) -> MenuKeyEquivalent? {
        guard let accelerator = Shortcuts.menuAccelerator(shortcut) else { return nil }
        var parts = accelerator.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), let key = character(for: name) else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "Control": modifiers.insert(.control)
            case "Command": modifiers.insert(.command)
            case "Alt": modifiers.insert(.option)
            case "Shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        return MenuKeyEquivalent(key: key, modifiers: modifiers)
    }

    private static func functionKey(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt32(key)) ?? " "))
    }

    private static let namedKeys: [String: String] = [
        "Up": functionKey(NSUpArrowFunctionKey), "Down": functionKey(NSDownArrowFunctionKey),
        "Left": functionKey(NSLeftArrowFunctionKey), "Right": functionKey(NSRightArrowFunctionKey),
        "Home": functionKey(NSHomeFunctionKey), "End": functionKey(NSEndFunctionKey),
        "PageUp": functionKey(NSPageUpFunctionKey), "PageDown": functionKey(NSPageDownFunctionKey),
        // ⌘⌫ is the Backspace character, as Finder's Move to Trash has it; Delete is the forward delete key.
        "Backspace": "\u{8}", "Delete": functionKey(NSDeleteFunctionKey),
        "Return": "\r", "Tab": "\t", "Escape": "\u{1b}", "Space": " ", "Plus": "+",
    ]

    private static func character(for name: String) -> String? {
        if let named = namedKeys[name] { return named }
        if name.count == 1 { return name.lowercased() }
        // F1 to F20.
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number) {
            return functionKey(NSF1FunctionKey + number - 1)
        }
        return nil
    }
}
