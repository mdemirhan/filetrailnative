import Foundation

/// A name as the menus show it. A menu is as wide as its widest item, so a long file, folder, disk, app, tab, workspace
/// or preset name would widen the whole menu with it. Past `maxWidth` the name loses its middle, as Finder's menus do,
/// keeping its start, its last letters and its extension: “Quarterly repo…final.pdf”.
public enum MenuName {
    /// The widest a name gets, in letters: about 160 points of the menu's font, a little less than the history menu
    /// gives a folder's name. A wide letter (Chinese, Japanese, Korean, most emoji) counts as two.
    public static let maxWidth = 24
    /// The longest extension kept whole; past it, the end of the name is kept as for a name without one.
    public static let maxExtensionWidth = 10

    /// `name`, or its start and end with "…" between when it is wider than `maxWidth`.
    public static func shortened(_ name: String) -> String {
        guard width(name) > maxWidth else { return name }
        let fits = { width($0) <= maxWidth }
        let fileExtension = (name as NSString).pathExtension
        let kept = width(fileExtension) <= maxExtensionWidth ? fileExtension : ""
        return IconLabel.shortenInMiddle(name: name, extension: kept, fits: fits)
    }

    /// The name in curly quotes, as a menu item names what it acts on: Compress “Photos”.
    public static func quoted(_ name: String) -> String {
        "\u{201C}\(shortened(name))\u{201D}"
    }

    /// How wide `text` is, in letters, a wide one counting as two.
    public static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
