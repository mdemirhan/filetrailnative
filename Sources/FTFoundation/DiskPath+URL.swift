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
    /// such a path goes through `asOnDisk()` before it is compared with a listing's. Only a URL made by
    /// `url(isDirectory:)` gives back the bytes it was made from. nil for a URL that isn't a file's.
    public init?(urlSpelling url: URL) {
        guard url.isFileURL else { return nil }
        let spelled = url.withUnsafeFileSystemRepresentation { bytes in bytes.map { String(cString: $0) } }
        guard let spelled else { return nil }
        self.init(spelled)
    }
}
