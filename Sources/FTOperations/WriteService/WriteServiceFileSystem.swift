// Port of the writing half of WriteServiceFileSystem and removeEmptyFolder (packages/core/src/fs/writeServiceTypes.ts),
// and of nativeFileSystem (packages/core/src/fs/testNativePaste.ts), the app's file system on node:fs
import Darwin
import FTFoundation
import Foundation

/// What a paste does to the disk, on top of what its review reads. The calls a disk may not have are nil when
/// it hasn't them, as the original's optional methods are left out.
public protocol WriteServiceFileSystem: AnalysisFileSystem {
    /// rename(2) that fails with EEXIST instead of replacing an item at `to` (`renamex_np(RENAME_EXCL)`, checking
    /// first on a volume that can't do that).
    func renameExclusive(_ from: String, _ to: String) throws
    /// Makes one folder; never its parents, and fails (EEXIST) when anything is at `path`.
    func mkdir(_ path: String) throws
    /// Node's `rm(path, { recursive, force })`: `force` ignores an item that isn't there; a folder needs
    /// `recursive`.
    func rm(_ path: String, recursive: Bool, force: Bool) throws
    /// Removes an empty folder; fails (ENOTEMPTY or EEXIST) when anything is inside, "._name" files included
    /// (see `removeEmptyFolder`).
    func rmdir(_ path: String) throws
    /// Copies a file, or a symlink as a link, with its metadata (mode, flags, dates, xattrs), never replacing
    /// an item at `destination` (copyfile(3)). `stop` stops it part way through the file (`StopError`), leaving
    /// no partial file. `onProgress` is told the bytes copied so far, every quarter second or so while a large
    /// file is copied.
    func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws
    /// The item's BSD flags (a symlink not followed); `UF_IMMUTABLE` is Finder's "Locked".
    func getFlags(_ path: String) throws -> UInt32
    /// Sets the item's BSD flags (a symlink not followed).
    func setFlags(_ path: String, _ flags: UInt32) throws

    /// `chmod(path, mode)`.
    var chmod: ((String, UInt32) throws -> Void)? { get }
    /// `utimes(path, atimeMs, mtimeMs)` (follows symlinks): timestamps of folders and files after they are made.
    var utimes: ((String, Double, Double) throws -> Void)? { get }
    /// A folder's own metadata (mode, flags, dates, xattrs such as tags, ACLs) onto an existing folder, without
    /// its contents. Without it, only the mode and dates are carried over.
    var copyMetadata: ((String, String) throws -> Void)? { get }
    /// Gives the item the ACL `acl` (acl_to_text(3) text), or none at all for nil (a symlink not followed).
    var setAcl: ((String, String?) throws -> Void)? { get }
    /// Moves an item to the Trash and returns the path it has there (nil when the Trash didn't say). Without it
    /// (or when it fails), the person is asked before anything is deleted for good.
    var trash: ((String) throws -> String?)? { get }
    /// Whether items can be added to or removed from a folder (access(2) with W_OK; throws when not). A move to
    /// another disk asks before copying anything, so it never copies what it then can't remove.
    var canModifyFolder: ((String) throws -> Void)? { get }
}

extension WriteServiceFileSystem {
    public var chmod: ((String, UInt32) throws -> Void)? { nil }
    public var utimes: ((String, Double, Double) throws -> Void)? { nil }
    public var copyMetadata: ((String, String) throws -> Void)? { nil }
    public var setAcl: ((String, String?) throws -> Void)? { nil }
    public var trash: ((String) throws -> String?)? { nil }
    public var canModifyFolder: ((String) throws -> Void)? { nil }
}

/// `removeEmptyFolder`: rmdir(2) on macOS also removes a folder that holds nothing but "._name" files, deleting
/// them, whatever they hold and on any disk (the kernel takes them for orphaned AppleDouble files). Such a file
/// may be someone's item, so a folder is removed only when it lists nothing at all. One put there between the
/// look and the removal can still go: no call removes a folder only if it is empty of those too.
public func removeEmptyFolder(
    readFolder: (String) throws -> [String], removeFolder: (String) throws -> Void, _ path: String
) throws {
    if try !readFolder(path).isEmpty {
        throw NativeError(
            message: "ENOTEMPTY: directory not empty, rmdir '\(path)'", code: "ENOTEMPTY", errnum: ENOTEMPTY,
            syscall: "rmdir", path: path)
    }
    try removeFolder(path)
}

/// The disk itself, as the app's own file system calls it: the native copy (copyfile(3)), exclusive rename, lock
/// flags and ACLs, with the Trash it is given (none by default).
public struct NativeWriteFileSystem: WriteServiceFileSystem {
    private let disk = PosixFileSystem()
    private let copier: StoppableCopy
    private let trashItem: (@Sendable (String) throws -> String?)?

    public init(trash: (@Sendable (String) throws -> String?)? = nil, copier: StoppableCopy = StoppableCopy()) {
        trashItem = trash
        self.copier = copier
    }

    public func lstat(_ path: String) throws -> WriteServiceStats { try disk.lstat(path) }
    public func stat(_ path: String) throws -> WriteServiceStats { try disk.stat(path) }
    public func realpath(_ path: String) throws -> String { try disk.realpath(path) }
    public func readdir(_ path: String) throws -> [String] { try disk.readdir(path) }
    public func readlink(_ path: String) throws -> String { try disk.readlink(path) }
    public func isCaseSensitive(_ path: String) throws -> Bool? { try disk.isCaseSensitive(path) }
    public func isPackage(_ path: String) throws -> Bool? { try disk.isPackage(path) }
    public func isAppleDouble(_ path: String) -> Bool { disk.isAppleDouble(path) }

    public func renameExclusive(_ from: String, _ to: String) throws {
        try NativeFS.renameExclusive(from, to)
    }

    public func mkdir(_ path: String) throws {
        if Darwin.mkdir(path, 0o777) != 0 {
            throw NativeError.errno(errno, syscall: "mkdir", path: path)
        }
    }

    public func rm(_ path: String, recursive: Bool, force: Bool) throws {
        try NativeRemoval.rm(path, recursive: recursive, force: force)
    }

    public func rmdir(_ path: String) throws {
        try removeEmptyFolder(readFolder: { try disk.readdir($0) }, removeFolder: NativeRemoval.rmdir, path)
    }

    public func copyFile(
        _ source: String, _ destination: String, stop: StopSignal?, onProgress: (@Sendable (Int64) -> Void)?
    ) throws {
        try copier.copyFile(source, to: destination, stop: stop, onProgress: onProgress)
    }

    public func getFlags(_ path: String) throws -> UInt32 { try NativeFS.getFlags(path) }
    public func setFlags(_ path: String, _ flags: UInt32) throws { try NativeFS.setFlags(path, flags) }

    public var chmod: ((String, UInt32) throws -> Void)? { { try NativeFS.chmod($0, $1) } }
    public var utimes: ((String, Double, Double) throws -> Void)? {
        { try NativeFS.utimes($0, atimeMs: $1, mtimeMs: $2) }
    }
    public var copyMetadata: ((String, String) throws -> Void)? { { try NativeFS.copyMetadata($0, $1) } }
    public var setAcl: ((String, String?) throws -> Void)? { { try NativeFS.setAcl($0, $1) } }
    public var trash: ((String) throws -> String?)? { trashItem.map { trash in { try trash($0) } } }
    public var canModifyFolder: ((String) throws -> Void)? {
        { path in
            if access(path, W_OK) != 0 {
                throw NativeError.errno(errno, syscall: "access", path: path)
            }
        }
    }
}

/// Node's `rm` and `rmdir` on the disk.
enum NativeRemoval {
    static func rm(_ path: String, recursive: Bool, force: Bool) throws {
        var info = Darwin.stat()
        if lstat(path, &info) != 0 {
            let errnum = errno
            if force && errnum == ENOENT {
                return
            }
            throw NativeError.errno(errnum, syscall: "rm", path: path)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            if unlink(path) != 0 {
                let errnum = errno
                if force && errnum == ENOENT {
                    return
                }
                throw NativeError.errno(errnum, syscall: "rm", path: path)
            }
            return
        }
        guard recursive else {
            throw NativeError(
                message: "Path is a directory: rm returned EISDIR (is a directory) \(path)", code: "ERR_FS_EISDIR",
                errnum: EISDIR, syscall: "rm", path: path)
        }
        try removeTree(path)
    }

    /// What is inside first, deepest first, then the folder.
    private static func removeTree(_ path: String) throws {
        for name in try PosixFileSystem().readdir(path) {
            let child = path + "/" + name
            var info = Darwin.stat()
            if lstat(child, &info) != 0 {
                if errno == ENOENT { continue }
                throw NativeError.errno(errno, syscall: "rm", path: child)
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                try removeTree(child)
            } else if unlink(child) != 0 && errno != ENOENT {
                throw NativeError.errno(errno, syscall: "rm", path: child)
            }
        }
        try rmdir(path)
    }

    static func rmdir(_ path: String) throws {
        if Darwin.rmdir(path) != 0 {
            throw NativeError.errno(errno, syscall: "rmdir", path: path)
        }
    }
}
