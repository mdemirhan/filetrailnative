import CFileTrail
import Darwin
import FTFoundation
import Foundation

/// Finder aliases and symbolic links: what each is, and where it leads.
///
/// An alias is a file that holds where its original is, found again after the original is moved or renamed; a
/// symbolic link holds a path. Opening either, or looking at what is in it, reaches the original; everything else
/// (Rename, Copy, Compress, Get Info) acts on the alias or the link itself, as in Finder.
public enum Links {
    /// Whether the file at `path` is a Finder alias. A symbolic link isn't one, though the system's own check says it
    /// is. Told from Finder's flag in one `getattrlist` (1 to 2 µs, where the system's check through a URL took 7);
    /// an item that can't be read that way is asked through the URL.
    public static func isFinderAlias(_ path: String) -> Bool {
        switch ft_has_alias_flag(path) {
        case 1: return true
        case 0: return false
        default: return isFinderAliasByURL(path)
        }
    }

    /// The system's own check, by the item's URL.
    static func isFinderAliasByURL(_ path: String) -> Bool {
        let values = try? DiskPath(path).url(isDirectory: false).resourceValues(
            forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return values?.isAliasFile == true && values?.isSymbolicLink != true
    }

    /// Whether the symbolic link or alias at `path` leads nowhere: its original is gone. One whose original is on a
    /// disk or a server not connected isn't counted, as the original may still be there: nothing is mounted to look,
    /// and nothing asked. Nor is one whose original can't be reached (a folder on the way that can't be entered), or
    /// an alias kept only in a cloud. Anything else isn't broken.
    public static func isBroken(_ path: String, isLink: Bool) -> Bool {
        if isLink {
            var info = stat()
            if fstatat(AT_FDCWD, path, &info, 0) == 0 { return false }
            // Gone only when the system says so: an original in a folder that can't be entered may well be there.
            guard [ENOENT, ENOTDIR, ELOOP].contains(errno) else { return false }
            guard let target = linkTarget(path) else { return true }
            return !isOnDiskNotConnected(target)
        }
        guard isFinderAlias(path) else { return false }
        // An alias whose own data is only in a cloud would be downloaded to be resolved: it isn't, and isn't counted.
        var own = stat()
        if lstat(path, &own) == 0, own.st_flags & UInt32(SF_DATALESS) != 0 { return false }
        let url = DiskPath(path).url(isDirectory: false)
        if (try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) != nil { return false }
        guard let data = try? URL.bookmarkData(withContentsOf: url),
            let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: data)?.volume
        else { return true }
        return FileManager.default.fileExists(atPath: volume.path)
    }

    /// What the symbolic link at `path` holds, made whole from its folder when it is relative, its `..` taken out
    /// (`../../Volumes/Disk/a` from a folder two deep is on that disk).
    private static func linkTarget(_ path: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        if target.hasPrefix("/") { return target }
        var parts: [Substring] = []
        for part in ((path as NSString).deletingLastPathComponent + "/" + target).split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Whether `path` is on a disk that would be under /Volumes and isn't there.
    private static func isOnDiskNotConnected(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
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
                    resolvingAliasFileAt: DiskPath(real).url(isDirectory: false),
                    options: [.withoutUI, .withoutMounting]),
                let spelled = DiskPath(urlSpelling: next)
            else { return nil }
            // In the URL's spelling, which `realpath` above spells as the disk does on the next turn.
            current = spelled.string
        }
        return nil
    }

    /// `original(of:)`, and whether it is a folder to open in place: not a package, which opens as a file does.
    public static func originalItem(of path: String) -> (path: String, isFolder: Bool)? {
        guard let original = original(of: path) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: original, isDirectory: &isDirectory) else { return nil }
        return (original, isDirectory.boolValue && !SystemPackages.isPackageFolder(at: original))
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
    /// original is, marked as an alias, that finds it again after it is moved or renamed. Like Finder's, it also holds
    /// where the original is from the alias, which the system looks at first: an alias copied with its original leads
    /// to the copy beside it, and to the original again once that copy is gone, as it is never written again.
    ///
    /// The system writes where the original is from the alias only when the alias's file is there as it is asked, so
    /// the file is made empty first, and taken away again if the alias can't be written. An item already at
    /// `aliasPath` is never replaced.
    public static func writeAlias(of original: String, at aliasPath: String) throws {
        let descriptor = open(aliasPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        do {
            let alias = DiskPath(aliasPath).url(isDirectory: false)
            let data = try DiskPath(original).fileURL().bookmarkData(
                options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: alias)
            try URL.writeBookmarkData(data, to: alias)
        } catch {
            unlink(aliasPath)
            throw error
        }
    }
}
