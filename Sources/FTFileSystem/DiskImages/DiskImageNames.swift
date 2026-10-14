// Port of apps/desktop/src/shared/diskImages.ts
import Foundation

/// The disk images macOS mounts when one is opened: the extensions DiskImageMounter opens. File Trail mounts
/// them itself and opens the disk in a tab, where macOS would open a Finder window on it.
public enum DiskImageNames {
    public static let extensions: Set<String> = [
        "dmg", "udif", "img", "toast", "dvdr", "cdr", "dmgpart", "iso", "sparseimage", "asif", "sparsebundle",
        "backupbundle",
    ]

    public static func isDiskImagePath(_ path: String) -> Bool {
        let name = lastComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(String(name[name.index(after: dot)...]).lowercased())
    }

    /// The alert for a disk image that couldn't be opened, with hdiutil's reason as Finder's alert gives
    /// DiskImageMounter's ("no mountable file systems").
    public static func describeFailure(path: String, reason: String?) -> (title: String, message: String) {
        let last = lastComponent(path)
        let name = last.isEmpty ? path : last
        let title = "The disk image \u{201C}\(name)\u{201D} couldn\u{2019}t be opened."
        var trimmed = jsTrimmed(reason ?? "")
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        guard let first = trimmed.first else {
            return (title, "An unexpected error occurred.")
        }
        return (title, "\(String(first).uppercased())\(trimmed.dropFirst()).")
    }

    /// `path.slice(path.lastIndexOf("/") + 1)`.
    private static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `String.prototype.trim`: ECMAScript white space and line terminators.
    private static func jsTrimmed(_ text: String) -> String {
        func isTrimmed(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x2028, 0x2029, 0xFEFF: return true
            default: return scalar.value > 0x7F && scalar.properties.generalCategory == .spaceSeparator
            }
        }
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isTrimmed(first) { scalars.removeFirst() }
        while let last = scalars.last, isTrimmed(last) { scalars.removeLast() }
        return String(scalars)
    }
}
