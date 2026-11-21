import Foundation

/// Where a path becomes a file URL and a file URL a path: the one place for both, so that no accent is respelled
/// on the way. `URL(fileURLWithPath:)` and `URL(filePath:)` decompose the accents of a path whatever the disk
/// stores, and `URL.path` hands that spelling back; a disk that keeps a name composed (FAT, as Windows and cameras
/// write it) is then asked for a name it doesn't have, and the path no longer matches its row byte for byte. What
/// needs the disk (`asOnDisk()`, `home`) is beside the disk's other calls, in FTFileSystem.
extension DiskPath {
    /// The file URL of the path, spelled byte for byte as the path is: its file-system representation is the
    /// path's own bytes. The path is absolute; whether it is a folder is said, not asked of the disk.
    public func url(isDirectory: Bool) -> URL {
        string.withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: isDirectory, relativeTo: nil)
        }
    }

    /// The path a file URL stands for, in the URL's spelling, which is not the disk's: a URL the system made (a
    /// picked folder, a drop, a file to open) may spell an accent decomposed where the disk has it composed, so
    /// such a path goes through `asOnDisk()` before it is compared with a listing's. It is read from the URL's
    /// `path`, which holds what the URL was made with: the bytes, for one made by `url(isDirectory:)`, and the
    /// text's own spelling for one the system made from text (a pasteboard's, a panel's), whose file-system
    /// representation would spell every accent decomposed. This is the one place a URL's `path` is read. nil for a
    /// URL that isn't a file's.
    public init?(urlSpelling url: URL) {
        guard url.isFileURL else { return nil }
        self.init(url.path)
    }

    /// The path with its accents taken apart as a `URL` made from it spells them (`URL(fileURLWithPath:).path`). The
    /// app once knew the folder on screen by that spelling, whatever the disk kept, so it is how a launch from then
    /// saved a folder: its view, its visits, a favorite or a tab on it. nil for a path with no accent, which is
    /// spelled one way only, and for one that can't be given so. The system takes fewer accents apart than Unicode's
    /// own decomposition does, so it is the one asked. No disk is.
    public func asAURLSpells() -> DiskPath? {
        guard string.utf8.contains(where: { $0 >= 0x80 }) else { return nil }
        var bytes = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard (string as NSString).getFileSystemRepresentation(&bytes, maxLength: bytes.count) else { return nil }
        return bytes.withUnsafeBufferPointer { $0.baseAddress.map { DiskPath(String(cString: $0)) } }
    }
}
