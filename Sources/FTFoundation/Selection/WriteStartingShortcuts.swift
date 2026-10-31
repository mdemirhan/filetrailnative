// Port of WRITE_STARTING_SHORTCUTS (apps/desktop/src/renderer/hooks/useExplorerShortcuts.ts:215-224)

/// The shortcuts that start a file operation (or its sheet), which a held key must not repeat (B-SEL-114).
public enum WriteStartingShortcuts {
    private static let names: Set<String> = [
        "pasteSelection", "duplicateSelection", "trashSelection", "renameSelection", "moveSelection", "newFolder",
        "emptyTrash", "ejectVolume",
        // ⌘V is the Edit menu's Paste here; the original's window hears it first, as `pasteSelection`.
        "editPaste",
    ]

    /// Whether the command (a shortcut id or renderer command name) starts a write.
    public static func contains(_ command: String) -> Bool { names.contains(command) }

    /// Whether a key press runs the command: a key repeat does not run one that starts a write.
    public static func runs(_ command: String, isRepeat: Bool) -> Bool { !(isRepeat && contains(command)) }
}
