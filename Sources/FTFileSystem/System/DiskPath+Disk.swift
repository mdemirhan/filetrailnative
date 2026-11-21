import CFileTrail
import Darwin
import FTFoundation
import Foundation

/// A path respelled as its disk has it, for one that didn't come from a listing: typed, picked in a panel, dropped,
/// given at launch, or saved by an earlier run. The disk is asked, so this is not for the main thread's hot paths.
/// The rest of the path's dealings with `URL` are in FTFoundation (`url(isDirectory:)`, `init(urlSpelling:)`);
/// `fileURL()` here is `url(isDirectory:)` with the disk asked.
extension DiskPath {
    /// The path as the disk spells it, which is how a listing spells it: every link followed, "." and ".." and
    /// doubled slashes resolved, and each part named as its folder holds it, accents and letter case included
    /// (`realpath`). A link at the end is followed too: the answer is where it leads. When nothing is at the path
    /// yet (a name to save under, a folder about to be made), the folder it would be in as the disk spells it, and
    /// the name as given. The path unchanged when that folder can't be found either.
    public func asOnDisk() -> DiskPath {
        if let real = Self.realPath(string) { return DiskPath(real) }
        let name = name
        guard !name.isEmpty, let folder = Self.realPath(parent.string) else { return self }
        return DiskPath(folder).appending(name)
    }

    /// The item at the path named as its disk has it, a link at the end not followed: the folder it is in as the disk
    /// spells it (`asOnDisk()`), then its own name as that folder holds it. For an item rather than a place to go
    /// to (dropped, opened by another app, picked in a panel): `asOnDisk()` would answer with where a link leads.
    /// The name as given when nothing is there, or when the disk names it otherwise than by another spelling of
    /// the same name (a disk's own folder is named after the disk).
    public func itemAsOnDisk() -> DiskPath {
        let name = name
        guard !name.isEmpty else { return asOnDisk() }
        return parent.asOnDisk().appending(name).namedAsOnDisk()
    }

    /// The path with the item's own name as its folder holds it, the folders above it left as they are spelled: the
    /// last step of `itemAsOnDisk()`, for the items of a folder whose own path the disk was asked for once (a drop
    /// of many files). The path unchanged when nothing is there, or when the disk names the item otherwise than by
    /// another spelling of the same name.
    public func namedAsOnDisk() -> DiskPath {
        let name = name
        guard !name.isEmpty, let onDisk = Self.nameOnDisk(string),
            onDisk.precomposedStringWithCanonicalMapping.lowercased()
                == name.precomposedStringWithCanonicalMapping.lowercased()
        else { return self }
        return parent.appending(onDisk)
    }

    /// The path as a file URL that keeps its bytes (`url(isDirectory:)`), the disk asked whether a folder is there,
    /// as `URL(fileURLWithPath:)` finds out for a path alone: a link to a folder is not one (`lstat`). The URL of a
    /// link then names the link, where one ending in a slash would name the folder it leads to: what is shown in
    /// Finder, shared, dragged out or given a label is the link itself.
    public func fileURL() -> URL {
        var info = stat()
        return url(isDirectory: lstat(string, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR)
    }

    /// The name the item at `path` has on its disk, a symlink not followed (`getattrlist` `ATTR_CMN_NAME`): on a disk
    /// that ignores case, `path` may spell it otherwise. nil when it can't be read.
    public static func nameOnDisk(_ path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_NAME)
        // u_int32_t length, then attrreference_t, then the name and its NUL.
        let headerSize = 4 + MemoryLayout<attrreference_t>.size
        var buffer = [UInt8](repeating: 0, count: headerSize + 4 * Int(NAME_MAX) + 1)
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(path, &request, bytes.baseAddress, bytes.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            let reference = bytes.loadUnaligned(fromByteOffset: 4, as: attrreference_t.self)
            let start = 4 + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length) - 1
            guard length > 0, start + length <= bytes.count else { return nil }
            return String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        }
    }

    /// Whether the disk holding the folder at the path lists a name otherwise than it answers to it (FAT and exFAT:
    /// `ft_listing_respells_names`). The app's own listings name each item there as the disk holds it; names read
    /// from such a folder by anything else (a search) go through `namedAsOnDisk()`. False when the folder can't be
    /// opened.
    public var isListedRespelled: Bool {
        let folder = open(string, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { return false }
        defer { close(folder) }
        return ft_listing_respells_names(folder) != 0
    }

    /// The home folder as the disk spells it, read once.
    public static let home = DiskPath(NSHomeDirectory()).asOnDisk()

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
