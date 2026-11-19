// The dates of an item that a folder read and `stat` don't give
import CFileTrail
import Darwin

public enum FileTimes {
    /// When the item at `path` (a link itself, not what it points to) was put in its folder: Finder's Date Added, in
    /// milliseconds since 1970. Nil on a disk that doesn't keep it (FAT, exFAT, most shares) or for an item that can't
    /// be read.
    public static func addedMs(_ path: String) -> Int64? {
        var seconds: Int64 = 0
        var nanoseconds: Int32 = 0
        guard ft_added_time(path, &seconds, &nanoseconds) == 0 else { return nil }
        return NativeFileSystem.milliseconds(seconds, nanoseconds)
    }
}
