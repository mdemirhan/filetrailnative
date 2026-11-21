import FTFoundation
import Foundation

/// Finder aliases and symbolic links: what each is, and where it leads.
///
/// An alias is a file that holds where its original is, found again after the original is moved or renamed; a
/// symbolic link holds a path. Opening either, or looking at what is in it, reaches the original; everything else
/// (Rename, Copy, Compress, Show Info) acts on the alias or the link itself, as in Finder.
public enum Links {
    /// Whether the file at `path` is a Finder alias. A symbolic link isn't one, though the system's own check says it
    /// is.
    public static func isFinderAlias(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return values?.isAliasFile == true && values?.isSymbolicLink != true
    }

    /// Where `path` leads: a symbolic link or an alias followed to its original, through any number of either, as a
    /// real path. Anything else is its own real path. Nil when the original can't be found, or is on a disk or a
    /// server not connected: nothing is mounted and nothing asked to find it.
    public static func original(of path: String) -> String? {
        var current = path
        for _ in 0..<16 {
            guard let real = realPath(current) else { return nil }
            guard isFinderAlias(real) else { return real }
            guard
                let next = try? URL(
                    resolvingAliasFileAt: URL(fileURLWithPath: real), options: [.withoutUI, .withoutMounting])
            else { return nil }
            current = next.path
        }
        return nil
    }

    /// `original(of:)`, and whether it is a folder to open in place: not a package, which opens as a file does.
    public static func originalItem(of path: String) -> (path: String, isFolder: Bool)? {
        guard let original = original(of: path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original, isDirectory: &isDirectory) else { return nil }
        return (original, isDirectory.boolValue && !ItemNames.isMacOSPackageName(NodePath.basename(original)))
    }

    /// Each path, or an alias's original in its place; nil for an alias whose original can't be found. Looked up away
    /// from the main thread. A symbolic link stays as it is: whatever opens it follows it.
    public static func originalsOfAliases(_ paths: [String]) async -> [String?] {
        await BlockingWork.run { paths.map { isFinderAlias($0) ? original(of: $0) : $0 } }
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Writes a Finder alias of `original` at `aliasPath`, as Finder's Make Alias does: a file holding where the
    /// original is, marked as an alias, that finds it again after it is moved or renamed.
    public static func writeAlias(of original: String, at aliasPath: String) throws {
        let data = try URL(fileURLWithPath: original).bookmarkData(
            options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: URL(fileURLWithPath: aliasPath))
    }
}
