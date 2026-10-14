// Port of packages/native-fs/src/native_errors.c and native_errors.h
import Darwin
import Foundation

/// An error with JavaScript's shape: a `message`, and the `code` the original's code branches on ("ENOENT",
/// "ERR_FS_EISDIR", "ENOTRASH"), nil for an error without one.
public protocol CodedError: Error {
    var code: String? { get }
    var message: String { get }
}

/// What the native calls throw, as `native_errno_error` builds it:
/// `"<CODE>: <strerror>, <syscall> '<path>'[ -> '<dest>']"` with `code`, `errno`, `syscall`, `path` and `dest`.
/// The Trash's failures carry its own sentence instead, and `cocoaCode` (see `NativeFS.trashItem`).
public struct NativeError: CodedError, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var code: String?
    /// The errno, positive as the addon gives it (Node's own fs errors have it negative).
    public var errnum: Int32?
    public var syscall: String?
    public var path: String?
    public var dest: String?
    /// The `NSCocoaErrorDomain` code of a Trash failure that was one.
    public var cocoaCode: Int?

    public init(
        message: String, code: String? = nil, errnum: Int32? = nil, syscall: String? = nil, path: String? = nil,
        dest: String? = nil, cocoaCode: Int? = nil
    ) {
        self.message = message
        self.code = code
        self.errnum = errnum
        self.syscall = syscall
        self.path = path
        self.dest = dest
        self.cocoaCode = cocoaCode
    }

    /// `native_errno_error(errnum, syscall, path, dest)`.
    public static func errno(_ errnum: Int32, syscall: String, path: String, dest: String? = nil) -> NativeError {
        let code = NativeErrno.name(of: errnum)
        let description = NativeErrno.description(of: errnum)
        var message = "\(code): \(description), \(syscall) '\(path)'"
        if let dest {
            message += " -> '\(dest)'"
        }
        return NativeError(message: message, code: code, errnum: errnum, syscall: syscall, path: path, dest: dest)
    }

    public var description: String { message }
}

/// `error.code` when it is a string: a `CodedError`'s code, a `POSIXError`'s errno name.
public func errorCode(_ error: any Error) -> String? {
    if let coded = error as? any CodedError {
        return coded.code
    }
    if let posix = error as? POSIXError {
        return NativeErrno.name(of: posix.code.rawValue)
    }
    return nil
}

/// `toErrorMessage`: the error's message.
public func errorMessage(_ error: any Error) -> String {
    if let coded = error as? any CodedError {
        return coded.message
    }
    if let posix = error as? POSIXError {
        return NativeErrno.description(of: posix.code.rawValue)
    }
    if let localized = error as? any LocalizedError, let text = localized.errorDescription {
        return text
    }
    return String(describing: error)
}

/// An error the engine makes itself (`new Error(message)`, with a `code` when it has one, and the error it
/// stands for in `cause`).
public struct OperationError: CodedError, Sendable, CustomStringConvertible {
    public var message: String
    public var code: String?
    public var cause: (any Error)?

    public init(_ message: String, code: String? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.code = code
        self.cause = cause
    }

    public var description: String { message }
}

/// `native_errno_code` and `strerror`.
public enum NativeErrno {
    /// The errno's name ("ENOENT"), "UNKNOWN" for a value the original doesn't list.
    public static func name(of errnum: Int32) -> String { table[errnum] ?? "UNKNOWN" }

    /// `strerror(errnum)`.
    public static func description(of errnum: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = strerror_r(errnum, &buffer, buffer.count)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every errno the original names, in its order (the first name of a number wins, as in its switch).
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
