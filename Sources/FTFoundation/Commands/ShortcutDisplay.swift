// Port of apps/desktop/src/renderer/lib/shortcutLabels.ts and shortcutDisplay.ts
import Foundation

/// Shortcuts are written as "Cmd+Shift+G" in the app's data (Help, the toolbar buttons) and shown the macOS way:
/// symbols in the standard modifier order (⌃⌥⇧⌘) followed by the key.
public enum ShortcutLabels {
    private static let glyphs: [String: String] = [
        "Cmd": "⌘", "Shift": "⇧", "Option": "⌥", "Alt": "⌥", "Ctrl": "⌃", "Backspace": "⌫", "Delete": "⌦",
        "Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Return": "↩", "Enter": "↩", "Esc": "esc", "Tab": "⇥",
        "Home": "↖", "End": "↘", "PageUp": "⇞", "PageDown": "⇟", "Plus": "+",
    ]
    private static let modifierOrder = ["⌃", "⌥", "⇧", "⌘"]

    /// `shortcutParts`: one entry for each key, for Help's keycaps: ["⇧", "⌘", "G"].
    public static func parts(_ shortcut: String) -> [String] {
        var units = Array(shortcut.utf16)
        if JSString.hasSuffix(shortcut, "++") {
            units.removeLast(2)
            units.append(contentsOf: "+Plus".utf16)
        }
        let parts =
            units.split(separator: 0x2B, omittingEmptySubsequences: false)
            .map { JSString.trimmed(JSString.string($0)) }
            .filter { !$0.isEmpty }
            .map { glyphs[$0] ?? $0 }
        // Sorted by the modifier's place; the sort is stable, as JavaScript's.
        let modifiers = parts.enumerated().filter { modifierOrder.contains($0.element) }
            .sorted {
                let left = modifierOrder.firstIndex(of: $0.element) ?? 0
                let right = modifierOrder.firstIndex(of: $1.element) ?? 0
                return left != right ? left < right : $0.offset < $1.offset
            }
            .map(\.element)
        return modifiers + parts.filter { !modifierOrder.contains($0) }
    }

    /// `formatShortcut`: as one piece of text, the way a menu writes it: "⇧⌘G". Escape is spelled out, as "Esc".
    public static func format(_ shortcut: String) -> String {
        parts(shortcut).map { $0 == "esc" ? "Esc" : $0 }.joined()
    }
}

/// What the window shows for a command's shortcut: in a tooltip, beside a menu item, in Help. It follows the keys
/// chosen in Settings.
public struct ShortcutDisplay: Sendable {
    public var shortcuts: ResolvedShortcuts
    public var returnKeyAction: ReturnKeyAction

    public init(shortcuts: ResolvedShortcuts, returnKeyAction: ReturnKeyAction = .rename) {
        self.shortcuts = shortcuts
        self.returnKeyAction = returnKeyAction
    }

    /// DEFAULT_SHORTCUT_DISPLAY.
    public static let defaults = ShortcutDisplay(shortcuts: ShortcutCommands.defaultResolved)

    /// Return renames while Settings → Files says so; it then comes before the keys Rename was given.
    private func keys(of id: ShortcutCommandID) -> [String] {
        let bound = shortcuts.bindings[id] ?? []
        return id == .renameSelection && returnKeyAction == .rename ? ["Return"] + bound : bound
    }

    /// The key shown for a command, written as "Cmd+D"; nil when it has none.
    public func written(_ id: ShortcutCommandID) -> String? {
        keys(of: id).first
    }

    /// The same key as symbols ("⌘D"), or nil.
    public func label(_ id: ShortcutCommandID) -> String? {
        // `shortcut ? formatShortcut(shortcut) : null`: an empty text is no shortcut either.
        guard let shortcut = written(id), !shortcut.isEmpty else { return nil }
        return ShortcutLabels.format(shortcut)
    }

    /// The command's other key, written as "Cmd+Left".
    public func alternate(_ id: ShortcutCommandID) -> String? {
        let keys = keys(of: id)
        return keys.count > 1 ? keys[1] : nil
    }

    /// For a sentence: the key as symbols, or where the command is in the menus when it has no key ("File > New Tab").
    public func mention(_ id: ShortcutCommandID) -> String {
        let command = ShortcutCommands.definition(id)
        return label(id) ?? command.menuPath ?? command.label
    }
}
