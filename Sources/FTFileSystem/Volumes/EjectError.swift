// Port of the error shape of packages/native-fs/src/native_eject.c and native_errno_code in native_errors.c
import Darwin
import Foundation

/// An eject that failed: the errno, the volume (or disk, "/dev/disk4") that failed, which with `wholeDisk`
/// may be another volume of the disk, and Disk Arbitration's own sentence when it gave one.
public struct EjectError: Error, Equatable, Sendable {
    public var errnum: Int32
    public var path: String
    public var reason: String?

    public init(errnum: Int32, path: String, reason: String? = nil) {
        self.errnum = errnum
        self.path = path
        self.reason = reason
    }

    /// The errno name ("EBUSY"), as the original's errors carry in `code`.
    public var code: String { ErrnoName.name(of: errnum) }
}

/// `native_errno_code`: the name of an errno, "UNKNOWN" for any not listed.
enum ErrnoName {
    static func name(of errnum: Int32) -> String { table[errnum] ?? "UNKNOWN" }

    private static let table: [Int32: String] = {
        let entries: [(Int32, String)] = [
            (EPERM, "EPERM"), (ENOENT, "ENOENT"), (ESRCH, "ESRCH"), (EINTR, "EINTR"), (EIO, "EIO"),
            (ENXIO, "ENXIO"), (E2BIG, "E2BIG"), (ENOEXEC, "ENOEXEC"), (EBADF, "EBADF"), (ECHILD, "ECHILD"),
            (EDEADLK, "EDEADLK"), (ENOMEM, "ENOMEM"), (EACCES, "EACCES"), (EFAULT, "EFAULT"),
            (EBUSY, "EBUSY"), (EEXIST, "EEXIST"), (EXDEV, "EXDEV"), (ENODEV, "ENODEV"),
            (ENOTDIR, "ENOTDIR"), (EISDIR, "EISDIR"), (EINVAL, "EINVAL"), (ENFILE, "ENFILE"),
            (EMFILE, "EMFILE"), (ENOTTY, "ENOTTY"), (ETXTBSY, "ETXTBSY"), (EFBIG, "EFBIG"),
            (ENOSPC, "ENOSPC"), (ESPIPE, "ESPIPE"), (EROFS, "EROFS"), (EMLINK, "EMLINK"),
            (EPIPE, "EPIPE"), (EDOM, "EDOM"), (ERANGE, "ERANGE"), (EAGAIN, "EAGAIN"),
            (EINPROGRESS, "EINPROGRESS"), (EALREADY, "EALREADY"), (ENOTSOCK, "ENOTSOCK"),
            (EDESTADDRREQ, "EDESTADDRREQ"), (EMSGSIZE, "EMSGSIZE"), (EPROTOTYPE, "EPROTOTYPE"),
            (ENOPROTOOPT, "ENOPROTOOPT"), (EPROTONOSUPPORT, "EPROTONOSUPPORT"), (ENOTSUP, "ENOTSUP"),
            (EAFNOSUPPORT, "EAFNOSUPPORT"), (EADDRINUSE, "EADDRINUSE"), (EADDRNOTAVAIL, "EADDRNOTAVAIL"),
            (ENETDOWN, "ENETDOWN"), (ENETUNREACH, "ENETUNREACH"), (ENETRESET, "ENETRESET"),
            (ECONNABORTED, "ECONNABORTED"), (ECONNRESET, "ECONNRESET"), (ENOBUFS, "ENOBUFS"),
            (EISCONN, "EISCONN"), (ENOTCONN, "ENOTCONN"), (ETIMEDOUT, "ETIMEDOUT"),
            (ECONNREFUSED, "ECONNREFUSED"), (ELOOP, "ELOOP"), (ENAMETOOLONG, "ENAMETOOLONG"),
            (EHOSTDOWN, "EHOSTDOWN"), (EHOSTUNREACH, "EHOSTUNREACH"), (ENOTEMPTY, "ENOTEMPTY"),
            (EUSERS, "EUSERS"), (EDQUOT, "EDQUOT"), (ESTALE, "ESTALE"), (EREMOTE, "EREMOTE"),
            (ENOLCK, "ENOLCK"), (ENOSYS, "ENOSYS"), (EOVERFLOW, "EOVERFLOW"), (ECANCELED, "ECANCELED"),
            (EIDRM, "EIDRM"), (ENOMSG, "ENOMSG"), (EILSEQ, "EILSEQ"), (EBADMSG, "EBADMSG"),
            (ENOLINK, "ENOLINK"), (EPROTO, "EPROTO"), (EOPNOTSUPP, "EOPNOTSUPP"), (ENOTBLK, "ENOTBLK"),
            (ESOCKTNOSUPPORT, "ESOCKTNOSUPPORT"), (EPFNOSUPPORT, "EPFNOSUPPORT"), (ESHUTDOWN, "ESHUTDOWN"),
            (ETOOMANYREFS, "ETOOMANYREFS"), (EPROCLIM, "EPROCLIM"), (EBADRPC, "EBADRPC"),
            (ERPCMISMATCH, "ERPCMISMATCH"), (EPROGUNAVAIL, "EPROGUNAVAIL"), (EPROGMISMATCH, "EPROGMISMATCH"),
            (EPROCUNAVAIL, "EPROCUNAVAIL"), (EFTYPE, "EFTYPE"), (EAUTH, "EAUTH"), (ENEEDAUTH, "ENEEDAUTH"),
            (EPWROFF, "EPWROFF"), (EDEVERR, "EDEVERR"), (EBADEXEC, "EBADEXEC"), (EBADARCH, "EBADARCH"),
            (ESHLIBVERS, "ESHLIBVERS"), (EBADMACHO, "EBADMACHO"), (ENOATTR, "ENOATTR"),
            (EMULTIHOP, "EMULTIHOP"), (ENODATA, "ENODATA"), (ENOSR, "ENOSR"), (ENOSTR, "ENOSTR"),
            (ETIME, "ETIME"), (ENOPOLICY, "ENOPOLICY"), (ENOTRECOVERABLE, "ENOTRECOVERABLE"),
            (EOWNERDEAD, "EOWNERDEAD"), (EQFULL, "EQFULL"),
        ]
        // Like the C switch, the first name of a number wins.
        var table: [Int32: String] = [:]
        for (number, name) in entries where table[number] == nil { table[number] = name }
        return table
    }()
}
