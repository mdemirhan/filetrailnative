import Darwin
import Foundation

/// What Folder Customizations asks the disk about a listed folder. A folder's view is found by its path alone, so
/// opening a folder asks nothing here.
public enum FolderIdentity {
    /// Whether a folder is at `path`.
    public static func isFolder(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
