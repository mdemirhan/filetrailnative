/// The shortcuts that start a file operation (or its sheet), which a held key must not repeat.
public enum WriteStartingShortcuts {
    private static let names: Set<String> = [
        "pasteSelection", "duplicateSelection", "trashSelection", "renameSelection", "moveSelection", "newFolder",
        "emptyTrash", "ejectVolume",
        // ⌘V is the Edit menu's Paste.
        "editPaste",
    ]

    /// Whether the command (a shortcut id, or the name of a `RendererCommand`) starts a write.
    public static func contains(_ command: String) -> Bool { names.contains(command) }

    /// Whether a key press runs the command: a key repeat does not run one that starts a write.
    public static func runs(_ command: String, isRepeat: Bool) -> Bool { !(isRepeat && contains(command)) }
}
