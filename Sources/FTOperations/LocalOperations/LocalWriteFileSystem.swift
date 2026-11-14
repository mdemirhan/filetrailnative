import CFileTrail
import Darwin
import FTFileSystem
import FTFoundation
import Foundation

/// What rename, New Folder, Paste as File, Trash and Delete Immediately ask of the disk, on top of what a paste does.
public protocol LocalWriteFileSystem: WriteServiceFileSystem {
    /// rename(2), which replaces an item at `to`. Only a rename that changes nothing but the case of a name (or how
    /// an accented letter is encoded) on a disk that ignores that goes through it: there the new name already
    /// "exists", because it is the item itself. Every other rename is `renameExclusive`.
    func rename(_ from: String, _ to: String) throws
    /// An item as a folder's measurement counts it, read just before a delete removes it, so the
    /// measured folders that held it can have it taken off their sizes. When it can't be read, they are measured
    /// again.
    func itemSize(_ path: String) throws -> ItemSize
    /// Makes a file at `path` holding `contents`, never over an item there. A file it couldn't fill is removed.
    func writeNewFile(_ path: String, _ contents: Data) throws
}

extension NativeWriteFileSystem: LocalWriteFileSystem {
    public func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: from, dest: to)
        }
    }

    public func itemSize(_ path: String) throws -> ItemSize { try NativeItemSize.of(path) }

    public func writeNewFile(_ path: String, _ contents: Data) throws {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        if descriptor < 0 {
            throw NativeError.errno(errno, syscall: "open", path: path)
        }
        var failure: Int32 = 0
        contents.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, start + written, bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                written += count
            }
        }
        // A full disk may only be told when the file is closed.
        if Darwin.close(descriptor) != 0, failure == 0 { failure = errno }
        if failure != 0 {
            Darwin.unlink(path)
            throw NativeError.errno(failure, syscall: "write", path: path)
        }
    }
}

/// Called where it is asked (the local operations ask it off the main thread).
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
