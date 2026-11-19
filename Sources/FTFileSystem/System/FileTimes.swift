// The dates of an item that a folder read and `stat` don't give
import CFileTrail
import Darwin
import Foundation

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

    /// Where macOS keeps when an item was last opened: a `timespec`, the seconds and then the nanoseconds.
    static let lastUsedAttribute = "com.apple.lastuseddate#PS"

    /// When the item at `path` (a link itself) was last opened, as Finder's Date Last Opened, in milliseconds since
    /// 1970; nil for one never opened, or that can't be read. The home folder's Desktop, Documents and Downloads aren't
    /// read: macOS would ask for permission first (`FinderTags.asksPermission`). `homePath` is the home folder's: a
    /// read of a whole folder's items takes it once and gives it for each (`lastOpenedReader`), as asking the system
    /// for it item by item was a seventh of the time a folder of 100,000 took to sort by this date.
    public static func lastOpenedMs(_ path: String, homePath: String = NSHomeDirectory()) -> Int64? {
        guard !FinderTags.asksPermission(path, homePath: homePath) else { return nil }
        var value = (Int64(0), Int64(0))
        let size = MemoryLayout.size(ofValue: value)
        let read = withUnsafeMutableBytes(of: &value) {
            getxattr(path, lastUsedAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { return nil }
        return NativeFileSystem.milliseconds(
            Int64(littleEndian: value.0), Int32(truncatingIfNeeded: Int64(littleEndian: value.1)))
    }

    /// `lastOpenedMs` for the items of one folder read: the home folder's path is taken here, once, and the same
    /// folders are left unread as when each item asks for it.
    public static func lastOpenedReader(homePath: String = NSHomeDirectory()) -> @Sendable (String) -> Int64? {
        { lastOpenedMs($0, homePath: homePath) }
    }
}
