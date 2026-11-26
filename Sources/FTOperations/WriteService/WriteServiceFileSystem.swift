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
    /// The item's ACL as text, nil for none (a symlink not followed).
    func getAcl(_ path: String) throws -> String?
    /// The item's extended attributes by name (its tags, Finder's information; a symlink's own): what a folder a move
    /// emptied and removed is made again with by Undo.
    func extendedAttributes(_ path: String) throws -> [String: Data]
    /// Sets the item's extended attribute `name` (a symlink's own).
    func setExtendedAttribute(_ path: String, _ name: String, _ value: Data) throws
    /// Moves an item to the Trash and returns the path it has there (nil when the Trash didn't say). When it fails
    /// because the disk has no Trash (the code `.noTrash`), the person is asked before anything is
    /// deleted for good.
    func trash(_ path: String) throws -> String?
    /// Whether items can be added to or removed from a folder (access(2) with W_OK; throws when not). A move to
    /// another disk asks before copying anything, so it never copies what it then can't remove.
    func canModifyFolder(_ path: String) throws
    /// Has the disk write out what a move copied to it, the drive's own cache too, before the original is deleted:
    /// until then the copy may be only in memory, and a power cut would leave neither. For a file, the file at
    /// `path` (`F_FULLFSYNC`); `wholeDisk`, for a folder put in place or the files a paste moved one by one into the
    /// folder `path`, everything waiting for the disk `path` is on, in one go. A disk that can't be told to (some network disks) is left to itself; any other failure throws.
    func flushToDisk(_ path: String, wholeDisk: Bool) throws
    /// Throws when items can be added to a folder but not renamed or removed there (an access rule against it, as
    /// on a drop box): what a paste builds there under a hidden name could then be neither put in place nor cleared
    /// away. A folder nothing can be added to passes: writing to it fails with its own reason.
    func assertItemsCanLeave(_ folder: String) throws
}

extension WriteServiceFileSystem {
    public func assertItemsCanLeave(_ folder: String) throws {}
    public func getAcl(_ path: String) throws -> String? { try NativeFS.getAcl(path) }
    public func extendedAttributes(_ path: String) throws -> [String: Data] {
        try NativeFS.extendedAttributes(path)
    }
    public func setExtendedAttribute(_ path: String, _ name: String, _ value: Data) throws {
        try NativeFS.setExtendedAttribute(path, name, value)
    }
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
    private let flushCalls: FlushCalls

    public init(trash: (@Sendable (String) throws -> String?)? = nil, copier: StoppableCopy = StoppableCopy()) {
        self.init(trash: trash, copier: copier, flushCalls: FlushCalls())
    }

    init(
        trash: (@Sendable (String) throws -> String?)? = nil, copier: StoppableCopy = StoppableCopy(),
        flushCalls: FlushCalls
    ) {
        trashItem = trash
        self.copier = copier
        self.flushCalls = flushCalls
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
    public func fileSystemType(_ path: String) -> String? { disk.fileSystemType(path) }

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

    public func flushToDisk(_ path: String, wholeDisk: Bool) throws {
        if wholeDisk {
            let errnum = flushCalls.syncVolume(path)
            if errnum == 0 { return }
            // Only a disk with no call for the whole of it is flushed another way. Any other failure (a disk error,
            // a disk going away) is told: what the disk was given may not be on it.
            guard FlushCalls.noSuchCall.contains(errnum) else {
                throw NativeError.errno(errnum, syscall: "sync_volume_np", path: path)
            }
            // Every disk is asked to write out what waits, and the folder is flushed after it, which is as much as
            // such a disk can be told.
            flushCalls.syncAll()
        }
        // A link has nothing of its own to write out: the folder it is in is flushed, as is a folder whose disk has no
        // call for the whole of it. (A pipe or a device is opened as it is, and answers for itself.)
        var descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { descriptor = open(NodePath.dirname(path), O_RDONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NativeError.errno(errno, syscall: "open", path: path) }
        defer { close(descriptor) }
        let fullSync = flushCalls.fullSync(descriptor)
        if fullSync == 0 { return }
        // Only where there is no full sync is the item flushed the lesser way, which hands the drive what waits and
        // doesn't ask it to write out its own cache. Any other failure (the drive failed to write out its cache, the
        // disk went away) is told, though the lesser flush would then work: the copy may not be on the disk.
        guard FlushCalls.noFullSync.contains(fullSync) else {
            throw NativeError.errno(fullSync, syscall: "fcntl", path: path)
        }
        let errnum = flushCalls.fsync(descriptor)
        // Not something this disk does: it keeps what it was given as it sees fit.
        if errnum == 0 || FlushCalls.noSuchCall.contains(errnum) { return }
        throw NativeError.errno(errnum, syscall: "fsync", path: path)
    }
}

/// The system calls `flushToDisk` makes, replaceable to fail any of them on any disk. Each gives 0, or the errno it
/// failed with.
struct FlushCalls: Sendable {
    /// Everything waiting for the disk `path` is on, the drive's own cache too. `sync_volume_np` returns its error
    /// and leaves `errno` as it was.
    var syncVolume: @Sendable (String) -> Int32 = { sync_volume_np($0, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT) }
    var syncAll: @Sendable () -> Void = { sync() }
    var fullSync: @Sendable (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) == 0 ? 0 : errno }
    var fsync: @Sendable (Int32) -> Int32 = { Darwin.fsync($0) == 0 ? 0 : errno }

    /// What a disk answers that has no such call. The system flushes a whole disk by asking the disk's own code for
    /// `F_FULLFSYNC`, and code that doesn't know it says ENOTSUP (SMB shares, `/dev`) or ENOTTY; EINVAL is what
    /// `fsync` says of an item that has nothing to flush.
    static let noSuchCall: Set<Int32> = [ENOTSUP, EINVAL, ENOTTY]

    /// What the full sync of one item answers where there is none to make: a disk with no such call, or a device
    /// (`/dev/null` says ENODEV), which has nothing of its own to write out. APFS, HFS+, exFAT and FAT32 answer 0 for
    /// a file, an empty file and a folder alike, and for a pipe where they have them, so no other answer is that of a
    /// disk that did what it was asked.
    static let noFullSync: Set<Int32> = noSuchCall.union([ENODEV])
}

/// `rm` and `rmdir` on the disk.
enum NativeRemoval {
    /// `unlockingFolders`, for a folder of the app's own making that is being cleared away: a folder its owner
    /// can't list or change (an archive's read-only folder, extracted) is first made so, as otherwise nothing in
    /// it could be removed. Never for a delete someone asked for, which stops at such a folder.
    static func rm(
        _ path: String, recursive: Bool, force: Bool, unlockingFolders: Bool = false,
        calls: RemovalCalls = RemovalCalls()
    ) throws {
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
        try emptyTree(path, mode: unlockingFolders ? info.st_mode : nil, calls)
        try rmdir(path)
    }

    /// A folder the removal is inside of: what tells it from every other folder, and what is still to go from it.
    private struct Level {
        let path: String
        /// Its name in the folder it is in.
        let name: String
        let dev: dev_t
        let ino: ino_t
        /// The names still to be removed, the next one last.
        var names: [String]
    }

    /// A folder opened and listed.
    private struct OpenFolder {
        let descriptor: Int32
        let info: stat
        let names: [String]
    }

    /// Removes what is inside the folder at `path`, deepest first. Only what is on the folder's own disk: a folder
    /// inside that another disk is mounted on stops the delete before anything on that disk is touched (its items
    /// are someone's other disk, not part of what was asked to be deleted).
    ///
    /// Nothing is reached by its path: each item is looked at, opened and removed by its name in the open folder it
    /// is in, and a folder is opened only as a folder, never through a link. So a folder swapped for a link to
    /// another one while the removal runs is not gone into, the disk a folder is on is read from the open folder
    /// itself, and a tree whose paths pass the longest a path can be is removed like any other.
    ///
    /// One folder is open at a time, however deep the tree (a folder for each level would run out of descriptors
    /// some hundreds of levels down): going into a folder closes the one around it, which is opened again through
    /// ".." once the inner one is empty, and checked to be the folder the removal came from.
    /// `mode`: the folder's permissions when folders are to be unlocked, nil when not.
    private static func emptyTree(_ path: String, mode: mode_t?, _ calls: RemovalCalls) throws {
        let top = try openFolder(path, in: AT_FDCWD, path: path, dev: nil, mode: mode, calls)
        var folder = top.descriptor
        defer { close(folder) }
        let dev = top.info.st_dev
        var levels = [Level(path: path, name: path, dev: dev, ino: top.info.st_ino, names: top.names.reversed())]
        while true {
            let innermost = levels.count - 1
            guard let name = levels[innermost].names.popLast() else {
                // Nothing is left in it: back to the folder it is in, which it is removed from.
                let emptied = levels.removeLast()
                guard innermost > 0 else { return }
                let around = calls.openFolder(folder, "..")
                guard around >= 0 else { throw NativeError.errno(errno, syscall: "rm", path: emptied.path) }
                close(folder)
                folder = around
                var info = Darwin.stat()
                guard fstat(folder, &info) == 0, info.st_dev == levels[innermost - 1].dev,
                    info.st_ino == levels[innermost - 1].ino
                else {
                    throw NativeError(
                        message:
                            "\u{201C}\(emptied.name)\u{201D} was moved while it was being deleted, so the delete stopped there.",
                        path: emptied.path)
                }
                try removeFolder(emptied.name, in: folder, path: emptied.path)
                continue
            }
            let child = levels[innermost].path + "/" + name
            var info = Darwin.stat()
            if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw NativeError.errno(errno, syscall: "rm", path: child)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                if unlinkat(folder, name, 0) != 0 && errno != ENOENT {
                    throw NativeError.errno(errno, syscall: "rm", path: child)
                }
                continue
            }
            // Before anything is asked of it: a folder being unlocked is changed before it is opened.
            if info.st_dev != dev { throw anotherDisk(name, child) }
            let inside = try openFolder(
                name, in: folder, path: child, dev: dev, mode: mode == nil ? nil : info.st_mode, calls)
            if inside.names.isEmpty {
                // Removed from here, without going in: an empty folder that can be listed but not gone into goes
                // too, and nothing is opened again for it.
                close(inside.descriptor)
                try removeFolder(name, in: folder, path: child)
                continue
            }
            close(folder)
            folder = inside.descriptor
            levels.append(
                Level(
                    path: child, name: name, dev: inside.info.st_dev, ino: inside.info.st_ino,
                    names: inside.names.reversed()))
        }
    }

    /// Opens the folder `name` in the open folder `parent` (`AT_FDCWD` for a path) and lists it. A link there is
    /// not followed, and a folder on another disk than `dev` is not listed: the delete stops at it.
    private static func openFolder(
        _ name: String, in parent: Int32, path: String, dev: dev_t?, mode: mode_t?, _ calls: RemovalCalls
    ) throws -> OpenFolder {
        if let mode, mode & S_IRWXU != S_IRWXU {
            // When this fails, what follows fails with the reason.
            _ = fchmodat(parent, name, (mode & 0o7777) | S_IRWXU, AT_SYMLINK_NOFOLLOW)
        }
        let descriptor = calls.openFolder(parent, name)
        guard descriptor >= 0 else { throw NativeError.errno(errno, syscall: "scandir", path: path) }
        do {
            var info = Darwin.stat()
            guard fstat(descriptor, &info) == 0 else { throw NativeError.errno(errno, syscall: "scandir", path: path) }
            if let dev, info.st_dev != dev { throw anotherDisk(name, path) }
            // The listing reads through a descriptor of its own, closed with it.
            let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw NativeError.errno(errno, syscall: "scandir", path: path) }
            guard let listing = fdopendir(copy) else {
                let errnum = errno
                close(copy)
                throw NativeError.errno(errnum, syscall: "scandir", path: path)
            }
            defer { closedir(listing) }
            return OpenFolder(
                descriptor: descriptor, info: info, names: try PosixFileSystem.names(in: listing, path: path))
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func anotherDisk(_ name: String, _ path: String) -> NativeError {
        NativeError(
            message:
                "\u{201C}\(name)\u{201D} is another disk, mounted inside the folder being deleted, so the delete stopped there. Eject it and try again.",
            path: path)
    }

    /// Removes the empty folder `name` from the open folder `parent`.
    private static func removeFolder(_ name: String, in parent: Int32, path: String) throws {
        if unlinkat(parent, name, AT_REMOVEDIR) != 0 {
            throw NativeError.errno(errno, syscall: "rmdir", path: path)
        }
    }

    static func rmdir(_ path: String) throws {
        if Darwin.rmdir(path) != 0 {
            throw NativeError.errno(errno, syscall: "rmdir", path: path)
        }
    }
}

/// The system call `rm` opens folders with, replaceable to change what is on the disk between the look at a folder
/// and its opening.
struct RemovalCalls {
    /// Opens the folder `name` in the open folder `parent` (`AT_FDCWD` for a path), as a folder only: a link there
    /// is not followed.
    var openFolder: (Int32, String) -> Int32 = { openat($0, $1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
}
