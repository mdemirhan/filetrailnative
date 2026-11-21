import Foundation

/// Rules for the name of a file or folder typed by a person.
public enum ItemNames {
    /// The longest name the Mac's disks take (APFS, HFS+, exFAT, FAT), in UTF-16 units: "日" is one, an emoji two.
    /// A name typed by a person is refused past it. A disk that takes less (a server that counts bytes, HFS+ for
    /// accents it stores apart) says so itself when the name is given to it.
    public static let maxUnits = 255
    /// The length the app keeps to in names it makes up itself (a number added, " copy", a hidden name), in UTF-8
    /// bytes ("é" takes two, "日" three): within every disk's limit, also one that counts bytes.
    public static let maxBytes = 255

    /// Whether a name is a hidden one: it starts with a dot, as `.gitignore` and Finder's `.DS_Store`. The one test of
    /// it by name, for a folder's listing, the templates New File lists, and Save as Template.
    public static func isHidden(_ name: String) -> Bool { name.utf8.first == UInt8(ascii: ".") }

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
        if trimmed.utf16.count > maxUnits {
            return "The name is too long."
        }
        return nil
    }

    /// Folders macOS shows as a single item, as far as their extension tells: listings show them as one item without
    /// asking, and naming keeps their extension at the end. Any other package is known by asking the system
    /// (`isPackageFolder`).
    public static let packageExtensions: Set<String> = [
        ".action", ".app", ".appex", ".band", ".bundle", ".component", ".docset", ".fcpbundle",
        ".fcpxbundle", ".framework", ".imovielibrary", ".kext", ".key", ".logicx", ".mdimporter",
        ".mlmodelc", ".mlpackage", ".mpkg", ".musiclibrary", ".numbers", ".pages", ".photoslibrary",
        ".pkg", ".playground", ".plugin", ".prefpane", ".qlgenerator", ".rtfd", ".saver", ".scriv",
        ".sparsebundle", ".textbundle", ".workflow", ".xcarchive", ".xcodeproj", ".xcworkspace", ".xpc",
    ]

    public static func isMacOSPackageName(_ name: String) -> Bool {
        let units = Array(name.utf16)
        guard let dot = units.lastIndex(of: 0x2E), dot > 0 else { return false }
        let ext = String(decoding: units[dot...], as: UTF16.self)
        return packageExtensions.contains(JSText.lowercased(ext))
    }

    /// Whether a folder named `name` is a package. One of `packageExtensions` is, without asking. A name with any other
    /// extension is what `askSystem` says (macOS knows a package by its bundle bit or by a type an app declares, as
    /// UTM's `.utm` or Parallels' `.pvm`), and only such a name is asked about: a folder with a dot in its name is
    /// rare. A name without an extension is a plain folder.
    public static func isPackageFolder(named name: String, askSystem: () -> Bool?) -> Bool {
        if isMacOSPackageName(name) { return true }
        guard hasExtension(name) else { return false }
        return askSystem() ?? false
    }

    /// Whether a name has an extension: a dot after its first character with something after it.
    public static func hasExtension(_ name: String) -> Bool {
        let units = name.utf16
        guard let dot = units.lastIndex(of: 0x2E), dot > units.startIndex else { return false }
        return units.index(after: dot) < units.endIndex
    }
}
