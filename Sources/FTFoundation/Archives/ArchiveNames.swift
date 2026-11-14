import Foundation

/// Which files are archives File Trail takes apart, and what Extract and Compress name what they make.
public enum ArchiveNames {
    /// What an archive holds, as Extract reads it.
    public enum Kind: Equatable, Sendable {
        /// Items, under names of their own (zip, tar, 7z, RAR, xar).
        case items
        /// One file, compressed (`.gz`, `.bz2`, `.xz` not holding a tar): it is written under the archive's name
        /// without its suffix.
        case singleFile
    }

    /// The suffixes of archives holding items, longest first so `.tar.gz` is found before `.gz`. Not `.tar.zst` or
    /// `.tar.lz4`: the system's libarchive reads those only with a `zstd` or `lz4` tool installed. Not `.pkg`, an
    /// installer, nor documents that are zips inside (`.docx`, `.epub`, `.jar`).
    static let itemSuffixes = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".zip", ".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".7z", ".rar", ".xar",
    ]

    /// The suffixes of a single compressed file.
    static let singleFileSuffixes = [".gz", ".bz2", ".xz"]

    /// What `name` holds, or nil when it isn't an archive Extract takes apart. Suffixes are matched ignoring case;
    /// a name that is only a suffix (`.zip`) is a hidden file, not an archive.
    public static func kind(of name: String) -> Kind? {
        if matchedSuffix(name, in: itemSuffixes) != nil { return .items }
        if matchedSuffix(name, in: singleFileSuffixes) != nil { return .singleFile }
        return nil
    }

    public static func isArchive(_ name: String) -> Bool { kind(of: name) != nil }

    /// The archive's name without its suffix: the folder its items go into when there are several ("Photos.zip" →
    /// "Photos", "src.tar.gz" → "src"), or the file a single compressed file becomes ("notes.txt.gz" → "notes.txt").
    /// `.tgz`, `.tbz` and `.txz` drop all of it: what was compressed was a tar, and its items are what come out.
    public static func extractedName(_ name: String) -> String {
        let suffix = matchedSuffix(name, in: itemSuffixes) ?? matchedSuffix(name, in: singleFileSuffixes)
        guard let suffix else { return name }
        return String(name.dropLast(suffix.count))
    }

    /// The zip Compress makes of `names`, the items of one folder, as Finder names it: "Photos.zip" for one item
    /// ("notes.txt.zip" for a file), "Archive.zip" for several.
    public static func zipName(for names: [String]) -> String {
        names.count == 1 ? "\(names[0]).zip" : "Archive.zip"
    }

    /// The menus' words: Compress “Photos” or Compress 3 Items.
    public static func compressTitle(_ names: [String]) -> String {
        compressTitle(count: names.count, firstName: names.first) ?? "Compress"
    }

    /// The same from how many items there are and the first one's name; nil for none.
    public static func compressTitle(count: Int, firstName: String?) -> String? {
        guard count > 0 else { return nil }
        if count == 1, let firstName { return "Compress \u{201C}\(firstName)\u{201D}" }
        return "Compress \(count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) Items"
    }

    /// The suffix of `name` among `suffixes`, ignoring case, when something comes before it.
    private static func matchedSuffix(_ name: String, in suffixes: [String]) -> String? {
        let lowered = name.lowercased()
        return suffixes.first { lowered.hasSuffix($0) && lowered.count > $0.count }
    }
}
