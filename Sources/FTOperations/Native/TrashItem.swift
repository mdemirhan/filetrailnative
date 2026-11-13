import FTFileSystem
import FTFoundation
import Foundation

/// Moves an item to the Trash and returns the path it has there (nil when the Trash didn't
/// say), with a failure that says why.
/// The Trash gives its reason as a sentence, with the errno it stands for when that can be told (see
/// `NativeFS.trashItem`). A locked item says so. A disk without a Trash (a network share, some USB drives)
/// answers ENOTSUP, or, once the app has trashed something, often no errno at all (NSFileWriteUnknownError):
/// ENOTSUP, or no errno on a disk `diskHasTrash` takes to have none (a network share), is marked on a disk other
/// than the startup disk with the code `.noTrash`, so callers can offer to delete instead. Any other
/// reason (no permission, a read-only or full disk, an item that is gone, a failure the Trash gives no errno for)
/// is the Trash's own sentence, and nothing is offered for permanent deletion; nor is anything on the startup
/// disk ever. A disk that can only be read answers as one without a Trash does (a disk image, a write-protected
/// card): it is told apart first (`isReadOnly`), and says so, with nothing offered: a delete would fail there too.
public struct TrashItem: Sendable {
    public typealias Trash = @Sendable (String) throws -> String?

    private let trash: Trash
    private let lstat: @Sendable (String) throws -> WriteServiceStats
    private let getFlags: (@Sendable (String) throws -> UInt32)?
    private let homePath: String
    private let diskHasTrash: (@Sendable (String) -> Bool)?
    private let isReadOnly: (@Sendable (String) -> Bool)?

    public init(
        trash: @escaping Trash, lstat: @escaping @Sendable (String) throws -> WriteServiceStats,
        getFlags: (@Sendable (String) throws -> UInt32)?, homePath: String,
        diskHasTrash: (@Sendable (String) -> Bool)? = nil, isReadOnly: (@Sendable (String) -> Bool)? = nil
    ) {
        self.isReadOnly = isReadOnly
        self.trash = trash
        self.lstat = lstat
        self.getFlags = getFlags
        self.homePath = homePath
        self.diskHasTrash = diskHasTrash
    }

    /// The app's Trash: `NativeFS.trashItem`, with the disk's flags and the mount table's idea of which disks
    /// have a Trash (`makeDiskHasTrash`).
    public static func live(homePath: String = NSHomeDirectory()) -> TrashItem {
        let fileSystem = PosixFileSystem()
        return TrashItem(
            trash: NativeFS.trashItem, lstat: { try fileSystem.lstat($0) }, getFlags: NativeFS.getFlags,
            homePath: homePath, diskHasTrash: makeDiskHasTrash(), isReadOnly: Self.isOnReadOnlyDisk)
    }

    /// Whether the disk holding `path` is mounted to be read only (`statfs`); false when it can't be told.
    public static func isOnReadOnlyDisk(_ path: String) -> Bool {
        var info = statfs()
        return statfs(path, &info) == 0 && info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    public func callAsFunction(_ path: String) throws -> String? {
        do {
            return try trash(path)
        } catch {
            if isLocked(getFlags, path) {
                throw OperationError(lockedMessage(path))
            }
            let message = errorMessage(error)
            let reason = message.isEmpty ? nil : message
            let item = try? lstat(path)
            let home = try? lstat(homePath)
            let onStartupDisk = item?.dev != nil && home?.dev != nil && item?.dev == home?.dev
            let code = errorCode(error)
            let mayHaveNoTrash =
                code == .errno(ENOTSUP) || code == .errno(EOPNOTSUPP) || (code == nil && diskHasTrash?(path) == false)
            let name = NodePath.basename(path)
            if item != nil, isReadOnly?(path) == true {
                throw OperationError(
                    "“\(name)” couldn’t be moved to the Trash because its disk can only be read.", cause: error)
            }
            if onStartupDisk || item == nil || !mayHaveNoTrash {
                throw OperationError(reason ?? "“\(name)” couldn’t be moved to the Trash.")
            }
            throw OperationError(
                "“\(name)” couldn’t be moved to the Trash. This disk may not have a Trash.",
                code: .noTrash, cause: error)
        }
    }
}
