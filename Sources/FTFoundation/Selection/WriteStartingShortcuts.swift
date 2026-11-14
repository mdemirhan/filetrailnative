/// The shortcuts that start a file operation (or its sheet), which a held key must not repeat.
public enum WriteStartingShortcuts {
    /// Every command a running file operation blocks, so a write command added there is never repeated by a held key;
    /// and Eject, and ⌘V as the Edit menu's Paste.
    private static let names: Set<String> = Set(CommandAvailability.writeLockedCommands.map(\.rawValue)).union([
        AppCommand.ejectVolume.rawValue, AppCommand.editPaste.rawValue,
    ])

    /// Whether the command (a shortcut id, or the name of a `AppCommand`) starts a write.
    public static func contains(_ command: String) -> Bool { names.contains(command) }

    /// Whether a key press runs the command: a key repeat does not run one that starts a write.
    public static func runs(_ command: String, isRepeat: Bool) -> Bool { !(isRepeat && contains(command)) }
}
