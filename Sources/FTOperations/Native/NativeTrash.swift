// Port of packages/native-fs/src/native_trash.m (nativeTrashItem)
import Darwin
import Foundation

extension NativeFS {
    /// `nativeTrashItem(path)`: moves the item to the Trash of its disk, as Finder's Move to Trash does, and
    /// returns the path it has there: the Trash renames it when its name is taken there ("notes 2.txt"), so
    /// the path is the only way to find it again. nil when the item went to the Trash but the Trash didn't say
    /// where. A failure carries the Trash's own sentence as its message and, when it can be told, an errno
    /// `code` ("EACCES", "ENOENT", "ENOSPC", "ENOTSUP" for a disk without a Trash), plus the Cocoa error's
    /// number as `cocoaCode` when it was one; syscall `trash`.
    public static func trashItem(_ path: String) throws -> String? {
        let url = URL(fileURLWithPath: path)
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw trashError(error as NSError, path: path)
        }
        // Moved, even when where to wasn't said: then it can't be found again, but it is in the Trash all
        // the same, which is no failure.
        return resulting?.path
    }

    /// The error a failed Trash call gives: the Trash's sentence, or Node's errno wording without one.
    static func trashError(_ error: NSError?, path: String) -> NativeError {
        var errnum = error.map(trashErrno(of:)) ?? 0
        let cocoaCode = error.flatMap { $0.domain == NSCocoaErrorDomain ? $0.code : nil }
        let message = error?.localizedDescription
        guard let message else {
            if errnum == 0 {
                errnum = EIO
            }
            return NativeError.errno(errnum, syscall: "trash", path: path)
        }
        return NativeError(
            message: message, code: errnum != 0 ? NativeErrno.name(of: errnum) : nil,
            errnum: errnum != 0 ? errnum : nil, syscall: "trash", path: path, cocoaCode: cocoaCode)
    }

    /// The file system's "operation not supported" (errFSOperationNotSupported, MacErrors.h).
    static let fsOperationNotSupported = -1426

    /// `errno_of`: the errno an NSError from the Trash stands for: the POSIX error under it when there is one,
    /// otherwise what its Cocoa code means; 0 when it can't be told.
    /// ENOTSUP says the disk has no Trash, and only what says so positively gives it: the Trash's
    /// NSFeatureUnsupportedError ("the volume doesn't have one"), or a failure resting on the file system's
    /// "not supported". Not every disk without a Trash is told this way: /dev answers the first only until
    /// the process has moved something to the Trash, then a bare NSFileWriteUnknownError. Still, a failure
    /// that can't be told must never pass for a missing Trash, or deleting for good would be offered for it,
    /// with a reason that isn't so.
    public static func trashErrno(of error: NSError) -> Int32 {
        if error.domain == NSPOSIXErrorDomain {
            return Int32(truncatingIfNeeded: error.code)
        }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if let underlying, underlying.domain == NSPOSIXErrorDomain {
            return Int32(truncatingIfNeeded: underlying.code)
        }
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFeatureUnsupportedError: return ENOTSUP
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return ENOENT
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return EACCES
            case NSFileWriteVolumeReadOnlyError: return EROFS
            case NSFileWriteOutOfSpaceError: return ENOSPC
            case NSUserCancelledError: return ECANCELED
            case NSFileWriteFileExistsError: return EEXIST
            case NSFileWriteInvalidFileNameError, NSFileReadInvalidFileNameError: return EINVAL
            case NSFileLockingError: return ENOLCK
            case NSFileReadTooLargeError: return EFBIG
            default: break
            }
        }
        if let underlying, underlying.domain == NSOSStatusErrorDomain, underlying.code == fsOperationNotSupported {
            return ENOTSUP
        }
        return 0
    }
}
