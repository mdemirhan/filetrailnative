// Port of the rename and itemSize members of WriteOperationFs (apps/desktop/src/main/bootstrap/writeOperations.ts) and
// of createOriginalWriteOperationFs (apps/desktop/src/main/originalFileSystem.ts), which give them on the disk
import CFileTrail
import Darwin
import FTFileSystem
import FTFoundation
import Foundation

/// What rename, New Folder, Trash and Delete Immediately ask of the disk, on top of what a paste does
/// (`WriteOperationFs`).
public protocol LocalWriteFileSystem: WriteServiceFileSystem {
    /// rename(2), which replaces an item at `to`. Only a rename that changes nothing but the case of a name (or how
    /// an accented letter is encoded) on a disk that ignores that goes through it: there the new name already
    /// "exists", because it is the item itself. Every other rename is `renameExclusive`.
    func rename(_ from: String, _ to: String) throws
    /// An item as a folder's measurement counts it (`nativeItemSize`), read just before a delete removes it, so the
    /// measured folders that held it can have it taken off their sizes. Without it, they are measured again.
    var itemSize: ((String) throws -> ItemSize)? { get }
}

extension LocalWriteFileSystem {
    public var itemSize: ((String) throws -> ItemSize)? { nil }
}

extension NativeWriteFileSystem: LocalWriteFileSystem {
    public func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: from, dest: to)
        }
    }

    public var itemSize: ((String) throws -> ItemSize)? {
        { path in try NativeItemSize.of(path) }
    }
}

/// `nativeItemSize`, called where it is asked (the local operations ask it off the main thread).
public enum NativeItemSize {
    public static func of(_ path: String) throws -> ItemSize {
        var item = ft_item_size()
        let errnum = ft_item_size_of(path, &item)
        if errnum != 0 {
            throw NativeError.errno(errnum, syscall: "item size", path: path)
        }
        let kind: ItemSize.Kind =
            switch item.kind {
            case FT_ITEM_FILE: .file
            case FT_ITEM_FOLDER: .folder
            default: .other
            }
        return ItemSize(kind: kind, sizeBytes: item.size_bytes, diskBytes: item.disk_bytes, dev: item.dev)
    }
}
