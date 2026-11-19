import Darwin
import Foundation

/// What the folders' views ask the disk: whether a folder listed in Folder Customizations is there, and where a folder
/// that took its view along really is. A folder's view is found by its path alone, so opening a folder asks nothing
/// here.
public enum FolderIdentity {
    /// The path with its links resolved (`/tmp` is `/private/tmp`), as a folder's listing gives it; the path as it is
    /// when nothing is there to resolve.
    public static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a folder is at `path`.
    public static func isFolder(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
