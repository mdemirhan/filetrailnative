import Darwin
import FTFileSystem
import Foundation

/// An error with a `message`, and the `code` the code branches on ("ENOENT", "ERR_FS_EISDIR", "ENOTRASH"), nil for
/// an error without one.
public protocol CodedError: Error {
    var code: String? { get }
    var message: String { get }
}

/// What the native calls throw:
/// `"<CODE>: <strerror>, <syscall> '<path>'[ -> '<dest>']"` with `code`, `errno`, `syscall`, `path` and `dest`.
/// The Trash's failures carry its own sentence instead, and `cocoaCode` (see `NativeFS.trashItem`).
public struct NativeError: CodedError, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var code: String?
    /// The errno, positive.
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

    /// The error of a failed system call: `errnum`'s name and description, the call, and the paths.
    public static func errno(_ errnum: Int32, syscall: String, path: String, dest: String? = nil) -> NativeError {
        let code = Errno.nameOrUnknown(of: errnum)
        let description = Errno.description(of: errnum)
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
        return Errno.nameOrUnknown(of: posix.code.rawValue)
    }
    return nil
}

/// The error's message.
public func errorMessage(_ error: any Error) -> String {
    if let coded = error as? any CodedError {
        return coded.message
    }
    if let posix = error as? POSIXError {
        return Errno.description(of: posix.code.rawValue)
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
