import Foundation

public enum Typeahead {
    /// Printable, non-whitespace characters start or extend the list filter and the sidebar's
    /// type-to-select. Navigation and modifier shortcuts are handled elsewhere. `key` is one
    /// UTF-16 unit for a character, a name ("ArrowDown") otherwise.
    public static func isCharacterKey(_ key: String) -> Bool {
        key.utf16.count == 1 && !JSString.trimmed(key).isEmpty
    }
}
