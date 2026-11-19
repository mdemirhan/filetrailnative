import Darwin
import Foundation

/// What says which folder a folder's view is for: its canonical path, its disk and its file ID.
public enum FolderIdentity {
    /// The path with links and `..` resolved (`/tmp` is `/private/tmp`), as listings give it; the path as it is when it
    /// can't be resolved.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The disk's volume UUID; nil where it has none (most shares) or it can't be read.
    public static func volume(of path: String) -> String? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    /// The folder's file ID (its inode number), which stays through a rename or a move on the same disk.
    public static func fileID(of path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    /// Whether a folder is at `path`.
    public static func isFolder(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
