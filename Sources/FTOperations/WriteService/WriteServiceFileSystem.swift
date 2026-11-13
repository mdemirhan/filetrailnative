import Darwin
import FTFoundation
import Foundation

/// What a paste does to the disk, on top of what its review reads.
public protocol WriteServiceFileSystem: AnalysisFileSystem {
    /// rename(2) that fails with EEXIST instead of replacing an item at `to` (`renamex_np(RENAME_EXCL)`, checking
    /// first on a volume that can't do that).
    func renameExclusive(_ from: String, _ to: String) throws
    /// Makes one folder; never its parents, and fails (EEXIST) when anything is at `path`.
    func mkdir(_ path: String) throws
    /// Removes the item at `path`: `force` ignores an item that isn't there; a folder needs `recursive`.
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
    func chmod(_ path: String, _ mode: UInt32) throws
    /// `utimes(path, atimeMs, mtimeMs)` (follows symlinks): timestamps of folders and files after they are made.
    func utimes(_ path: String, _ atimeMs: Double, _ mtimeMs: Double) throws
    /// A folder's own metadata (mode, flags, dates, xattrs such as tags, ACLs) onto an existing folder, without
    /// its contents. When it fails, only the mode and dates are carried over.
    func copyMetadata(_ source: String, _ destination: String) throws
    /// `copyMetadata` for the folder of an app copied on its own, which then runs from where it is put even when
    /// it is in quarantine.
    func copyMetadataToRunInPlace(_ source: String, _ destination: String) throws
    /// Gives the item the ACL `acl` (acl_to_text(3) text), or none at all for nil (a symlink not followed).
    func setAcl(_ path: String, _ acl: String?) throws
    /// Moves an item to the Trash and returns the path it has there (nil when the Trash didn't say). When it fails
    /// because the disk has no Trash (the code `.noTrash`), the person is asked before anything is
    /// deleted for good.
    func trash(_ path: String) throws -> String?
    /// Whether items can be added to or removed from a folder (access(2) with W_OK; throws when not). A move to
    /// another disk asks before copying anything, so it never copies what it then can't remove.
    func canModifyFolder(_ path: String) throws
    /// Throws when items can be added to a folder but not renamed or removed there (an access rule against it, as
    /// on a drop box): what a paste builds there under a hidden name could then be neither put in place nor cleared
    /// away. A folder nothing can be added to passes: writing to it fails with its own reason.
    func assertItemsCanLeave(_ folder: String) throws
}

extension WriteServiceFileSystem {
    public func assertItemsCanLeave(_ folder: String) throws {}
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
            message: "ENOTEMPTY: directory not empty, rmdir '\(path)'", code: .errno(ENOTEMPTY), path: path)
    }
    try removeFolder(path)
}

/// The disk itself, as the app's own file system calls it: the native copy (copyfile(3)), exclusive rename, lock
/// flags and ACLs, with the Trash it is given. Without one (the default), it is a disk without a Trash.
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
    public func isQuarantined(_ path: String) -> Bool { disk.isQuarantined(path) }

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

    public func chmod(_ path: String, _ mode: UInt32) throws { try NativeFS.chmod(path, mode) }
    public func utimes(_ path: String, _ atimeMs: Double, _ mtimeMs: Double) throws {
        try NativeFS.utimes(path, atimeMs: atimeMs, mtimeMs: mtimeMs)
    }
    public func copyMetadata(_ source: String, _ destination: String) throws {
        try NativeFS.copyMetadata(source, destination)
    }
    public func copyMetadataToRunInPlace(_ source: String, _ destination: String) throws {
        try NativeFS.copyMetadataToRunInPlace(source, destination)
    }
    public func setAcl(_ path: String, _ acl: String?) throws { try NativeFS.setAcl(path, acl) }

    /// Fails as on a disk without a Trash when it was given none.
    public func trash(_ path: String) throws -> String? {
        guard let trashItem else {
            throw OperationError(
                "\u{201C}\(NodePath.basename(path))\u{201D} couldn\u{2019}t be moved to the Trash. This disk may not have a Trash.",
                code: .noTrash)
        }
        return try trashItem(path)
    }

    public func assertItemsCanLeave(_ folder: String) throws {
        // `_RMFILE_OK`: removing an item from the folder, which a rename of one in it needs too.
        let removeFromFolder: Int32 = 1 << 14
        guard access(folder, W_OK) == 0, access(folder, removeFromFolder) != 0, errno == EACCES || errno == EPERM
        else { return }
        throw NativeError(
            message:
                "Items can be added to \u{201C}\(NodePath.basename(folder))\u{201D} but not renamed or removed there, so nothing was put in it.",
            path: folder)
    }

    public func canModifyFolder(_ path: String) throws {
        if access(path, W_OK) != 0 {
            throw NativeError.errno(errno, syscall: "access", path: path)
        }
    }
}

/// `rm` and `rmdir` on the disk.
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
                message: "Path is a directory: rm returned EISDIR (is a directory) \(path)", code: .errno(EISDIR),
                path: path)
        }
        try removeTree(path, dev: info.st_dev)
    }

    /// What is inside first, deepest first, then the folder. Only what is on the folder's own disk: a folder inside
    /// that another disk is mounted on stops the delete before anything on that disk is touched (its items are
    /// someone's other disk, not part of what was asked to be deleted).
    private static func removeTree(_ path: String, dev: dev_t) throws {
        for name in try PosixFileSystem().readdir(path) {
            let child = path + "/" + name
            var info = Darwin.stat()
            if lstat(child, &info) != 0 {
                if errno == ENOENT { continue }
                throw NativeError.errno(errno, syscall: "rm", path: child)
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                if info.st_dev != dev {
                    throw NativeError(
                        message:
                            "\u{201C}\(name)\u{201D} is another disk, mounted inside the folder being deleted, so the delete stopped there. Eject it and try again.",
                        path: child)
                }
                try removeTree(child, dev: dev)
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
