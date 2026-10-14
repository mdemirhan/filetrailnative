// Port of packages/core/src/fs/copyPasteErrors.ts
import Darwin
import Foundation

// Readable reasons for what went wrong, without paths: the item is always shown next to them.

public enum CopyPasteErrors {
    public static let codeMessages: [String: String] = [
        "ENOSPC": "There isn't enough free space on the destination disk.",
        "EDQUOT": "The destination's storage quota is full.",
        "EACCES": "You don't have permission to access this item.",
        "EPERM": "You don't have permission to access this item.",
        "EROFS": "The destination is read-only.",
        "ENAMETOOLONG": "The name is too long.",
        "ENOENT": "The item no longer exists.",
        "EEXIST": "An item with this name already exists.",
        "ENOTEMPTY": "The folder isn't empty.",
        "EBUSY": "The item is in use.",
        "EIO": "A disk error occurred.",
        "EXDEV": "The item can't be moved directly to a different disk.",
        "EISDIR": "A folder is in the way where a file was expected.",
        // Node's own code for removing a folder as if it were a file.
        "ERR_FS_EISDIR": "A folder is in the way where a file was expected.",
        "ENOTDIR": "Part of the path isn't a folder any more.",
        "ENOTSUP": "This volume doesn't support this operation.",
        "EOPNOTSUPP": "This volume doesn't support this operation.",
        "EINVAL": "This volume doesn't accept this name or operation.",
        "ELOOP": "The item's location loops back on itself through symbolic links.",
        "EFBIG": "The file is too large for this volume.",
        "EMFILE": "Too many files are open. Close some apps and try again.",
        "ENFILE": "Too many files are open. Close some apps and try again.",
        "ETIMEDOUT": "The volume took too long to respond.",
        "EINTR": "The operation was interrupted. Try again.",
        "EAGAIN": "The item is temporarily unavailable. Try again.",
        "ENXIO": "The disk isn't available.",
        "ENODEV": "The disk isn't available.",
        "ENOMEM": "There isn't enough memory to finish this.",
        "ESTALE": "The network volume went away. Reconnect it and try again.",
    ]

    /// The code on a Trash failure on a disk that may have no Trash (a network share, some USB drives): there,
    /// and only there, deleting the item for good may be offered instead.
    public static let noTrashErrorCode = "ENOTRASH"

    // BSD flags that stop an item from being renamed, moved, changed or deleted. UF_IMMUTABLE is Finder's
    // "Locked"; the others are rarer but refuse the same things.
    public static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
    /// The ones the item's owner may clear (the SF_ ones need root).
    public static let userLockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
}

/// A readable, path-free reason for a failed item (the item itself is shown next to it).
public func describeCopyPasteError(_ error: any Error) -> String {
    if let code = errorCode(error), let message = CopyPasteErrors.codeMessages[code] {
        return message
    }
    return errorMessage(error)
}

/// Whether the item is locked (Finder's "Locked", or a flag that refuses the same things). False when it can't be
/// told: the item is then treated as unlocked.
public func isLocked(_ getFlags: ((String) throws -> UInt32)?, _ path: String) -> Bool {
    guard let getFlags, let flags = try? getFlags(path) else { return false }
    return flags & CopyPasteErrors.lockFlags != 0
}

/// A refusal (EPERM/EACCES) explained by one of `paths` being locked: an error naming the locked item, or nil when
/// none of them is.
public func findLockedRefusal(_ getFlags: ((String) throws -> UInt32)?, _ error: any Error, _ paths: [String])
    -> OperationError?
{
    let code = errorCode(error)
    guard code == "EPERM" || code == "EACCES" else { return nil }
    for path in paths where isLocked(getFlags, path) {
        return OperationError(lockedMessage(path))
    }
    return nil
}

public func lockedMessage(_ path: String) -> String {
    let scalars = Array(path.unicodeScalars)
    let name = scalars.lastIndex(of: "/").map { String(String.UnicodeScalarView(scalars[($0 + 1)...])) } ?? path
    return "“\(name.isEmpty ? path : name)” is locked. Unlock it in Finder's Get Info and try again."
}
