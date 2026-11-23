import Foundation

public enum SizeStatus: String, Codable, Sendable {
    case ready
    case deferred
    case unavailable
}

public struct FolderSizeDetail: Equatable, Sendable {
    public var size: String
    public var disk: String?
    public var items: String
}

public enum SizeText {
    /// "1.5 MB": steps of 1,000, as Finder and the rest of macOS count, so a size reads the same here
    /// as in Finder's Get Info. The decimal mark is the region's ("1,5 MB" in Germany).
    public static func size(_ bytes: Int64?, status: SizeStatus = .ready, locale: Locale = FormatLocale.current)
        -> String
    {
        // Callers that need `-` for directories or an empty loading state layer that on top.
        if status == .deferred {
            return "Not yet available"
        }
        guard status == .ready, let bytes else {
            return "Unavailable"
        }
        if bytes < 1000 {
            return "\(bytes) B"
        }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes) / 1000
        var unitIndex = 0
        // Steps up once the shown number would reach 1000 ("999.7 KB" rounds to "1000 KB").
        while value.rounded(.toNearestOrAwayFromZero) >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        let number = JSString.toFixed(value, value >= 9.95 ? 0 : 1)
        let mark = locale.decimalSeparator ?? "."
        return "\(mark == "." ? number : number.replacingOccurrences(of: ".", with: mark)) \(units[unitIndex])"
    }

    public static func folderDetail(
        sizeBytes: Int64, diskBytes: Int64, fileCount: Int, folderCount: Int, locale: Locale = FormatLocale.current
    ) -> FolderSizeDetail {
        let sizeText = size(sizeBytes, locale: locale)
        let diskText = size(diskBytes, locale: locale)
        return FolderSizeDetail(
            size: sizeText,
            disk: diskText != sizeText ? "\(diskText) on disk" : nil,
            items: describeContents(fileCount: fileCount, folderCount: folderCount, locale: locale))
    }

    // "48,611 files, 2,765 folders", "153 files", "Empty": what a folder holds at any depth.
    private static func describeContents(fileCount: Int, folderCount: Int, locale: Locale) -> String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(FormatLocale.count(value, locale: locale)) \(value == 1 ? one : many)"
        }
        var parts: [String] = []
        if fileCount > 0 { parts.append(count(fileCount, "file", "files")) }
        if folderCount > 0 { parts.append(count(folderCount, "folder", "folders")) }
        return parts.isEmpty ? "Empty" : parts.joined(separator: ", ")
    }
}

public struct PermissionParts: Equatable, Sendable {
    public var symbolic: String
    public var octal: String
}

public enum PermissionText {
    /// The mode as its code ("755"). The letters (rwxr-xr-x) say the same thing at three times the
    /// width, so views show the code and keep the letters for the tooltip.
    public static func mode(_ permissionMode: Int?) -> String {
        split(permissionMode)?.octal ?? "Unavailable"
    }

    /// Exposes the symbolic/octal split so views can choose whether they want one combined string or
    /// separate parts.
    public static func split(_ permissionMode: Int?) -> PermissionParts? {
        guard let permissionMode, permissionMode >= 0 else { return nil }
        let normalized = permissionMode & 0o777
        let groups: [[Int]] = [[0o400, 0o200, 0o100], [0o040, 0o020, 0o010], [0o004, 0o002, 0o001]]
        let symbols = ["r", "w", "x"]
        let symbolic = groups.map { group in
            group.enumerated().map { index, bit in normalized & bit != 0 ? symbols[index] : "-" }.joined()
        }.joined()
        let octal = String(normalized, radix: 8)
        return PermissionParts(
            symbolic: symbolic, octal: String(repeating: "0", count: max(0, 3 - octal.count)) + octal)
    }

    /// The owner's access, said to be the owner's ("Owner: Read & Write"): the person looking may not be the owner.
    /// The octal code stays visible beside it.
    public static func ownerAccess(symbolic: String) -> String {
        let units = Array(symbolic.utf16)
        let owner =
            units.count >= 9
            ? units[(units.count - 9)..<(units.count - 6)] : units[0..<min(units.count, max(0, units.count - 6))]
        let ownerText = JSString.string(owner)
        let canRead = ownerText.contains("r")
        let canWrite = ownerText.contains("w")
        if canRead && canWrite { return "Owner: Read & Write" }
        if canRead { return "Owner: Read only" }
        if canWrite { return "Owner: Write only" }
        return "Owner: No access"
    }
}

public enum PathText {

    /// The last name of a path with the trailing slashes dropped; the path itself when there is none.
    public static func leafName(_ path: String) -> String {
        var units = Array(path.utf16)
        while units.last == 0x2F { units.removeLast() }
        let trimmed = JSString.string(units)
        return JSString.components(trimmed, separator: 0x2F).last ?? path
    }
}

public struct DisplayNameParts: Equatable, Sendable {
    public var stem: String
    public var extensionSuffix: String
}

public enum DisplayName {
    /// Splits the visible filename into stem + extension suffix without assuming the stored
    /// `extension` is always trustworthy or even present in the display name. Both parts are the name's own
    /// letters: the stored extension is lowercased, and `IMG.JPG` is drawn as it is spelled.
    public static func split(_ name: String, extension fileExtension: String) -> DisplayNameParts {
        let whole = DisplayNameParts(stem: name, extensionSuffix: "")
        if fileExtension.isEmpty {
            return whole
        }
        let suffix = ".\(fileExtension)"
        let suffixLength = suffix.utf16.count
        let units = Array(name.utf16)
        if !JSString.hasSuffix(JSString.lowercased(name), JSString.lowercased(suffix)) || units.count <= suffixLength {
            return whole
        }
        let cut = units.count - suffixLength
        return DisplayNameParts(stem: JSString.string(units[..<cut]), extensionSuffix: JSString.string(units[cut...]))
    }
}
