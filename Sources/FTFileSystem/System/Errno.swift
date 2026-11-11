import Darwin

/// The names of system error numbers ("ENOENT") and the system's words for each: what every error that names its
/// number is shown with.
public enum Errno {
    /// The number's name, nil for a number without one.
    public static func name(of errnum: Int32) -> String? { table[errnum] }

    /// The number's name, "UNKNOWN" for a number without one.
    public static func nameOrUnknown(of errnum: Int32) -> String { table[errnum] ?? "UNKNOWN" }

    /// The system's words for the number (`strerror`): "No such file or directory".
    public static func description(of errnum: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = strerror_r(errnum, &buffer, buffer.count)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every number with a name, in a fixed order (the first name of a number wins).
    public static let names: [(Int32, String)] = [
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

    private static let table: [Int32: String] = {
        var table: [Int32: String] = [:]
        for (number, name) in names where table[number] == nil {
            table[number] = name
        }
        return table
    }()
}
