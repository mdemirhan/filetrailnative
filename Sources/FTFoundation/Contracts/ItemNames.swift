// Port of packages/contracts/src/itemName.ts
import Foundation

/// Rules for the name of a file or folder typed by a person.
public enum ItemNames {
    /// The longest name macOS disks take, in UTF-8 bytes (not characters: "é" takes two, "日" three).
    public static let maxBytes = 255

    /// A user-supplied file or folder name must name a single entry inside its parent directory.
    /// Separators or dot segments would let "rename" or "new folder" write somewhere else entirely.
    /// Returns the message to show, or nil when the name is fine.
    public static func error(for name: String) -> String? {
        let trimmed = JSText.trimmed(name)
        if trimmed.isEmpty {
            return "Enter a name."
        }
        let scalars = Array(trimmed.unicodeScalars)
        if scalars == ["."] || scalars == [".", "."] {
            return "\"\(trimmed)\" is not a valid name."
        }
        // "\" is an ordinary character on macOS (Finder allows it): only "/" separates folders.
        if scalars.contains(where: { $0 == "/" || $0 == "\0" }) {
            return "Names can\u{2019}t contain \u{201C}/\u{201D}."
        }
        if trimmed.utf8.count > maxBytes {
            return "The name is too long."
        }
        return nil
    }

    /// macOS treats folders with these extensions as opaque "packages": they behave like files.
    private static let packageExtensions: Set<String> = [
        ".app", ".framework", ".bundle", ".plugin", ".kext", ".xpc", ".xcodeproj", ".playground",
        ".prefpane", ".appex",
    ]

    public static func isMacOSPackageName(_ name: String) -> Bool {
        let units = Array(name.utf16)
        guard let dot = units.lastIndex(of: 0x2E), dot > 0 else { return false }
        let ext = String(decoding: units[dot...], as: UTF16.self)
        return packageExtensions.contains(JSText.lowercased(ext))
    }
}
