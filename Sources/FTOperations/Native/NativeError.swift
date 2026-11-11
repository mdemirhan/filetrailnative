import Darwin
import FTFileSystem
import Foundation

/// An error with a `message`, and the `code` the code branches on (an errno, or "the disk may have no Trash"), nil
/// for an error without one.
public protocol CodedError: Error {
    var code: ErrorCode? { get }
    var message: String { get }
}

/// What the native calls throw:
/// `"<NAME>: <strerror>, <syscall> '<path>'[ -> '<dest>']"` with `code`, `errno`, `syscall`, `path` and `dest`.
/// The Trash's failures carry its own sentence instead, and `cocoaCode` (see `NativeFS.trashItem`).
public struct NativeError: CodedError, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var code: ErrorCode?
    /// The errno, positive.
    public var errnum: Int32?
    public var syscall: String?
    public var path: String?
    public var dest: String?
    /// The `NSCocoaErrorDomain` code of a Trash failure that was one.
    public var cocoaCode: Int?

    public init(
        message: String, code: ErrorCode? = nil, errnum: Int32? = nil, syscall: String? = nil, path: String? = nil,
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
        let name = Errno.nameOrUnknown(of: errnum)
        let description = Errno.description(of: errnum)
        var message = "\(name): \(description), \(syscall) '\(path)'"
        if let dest {
            message += " -> '\(dest)'"
        }
        return NativeError(
            message: message, code: .errno(errnum), errnum: errnum, syscall: syscall, path: path, dest: dest)
    }

    public var description: String { message }
}

/// What an error is, for the code that acts on it: the errno of a system call that failed, or the app's own
/// "the disk may have no Trash".
public enum ErrorCode: Hashable, Sendable {
    case errno(Int32)
    /// A Trash failure on a disk that may have no Trash (a network share, some USB drives): there, and only there,
    /// deleting the item for good may be offered instead.
    case noTrash
}

/// The error's code: a `CodedError`'s, a `POSIXError`'s errno.
public func errorCode(_ error: any Error) -> ErrorCode? {
    if let coded = error as? any CodedError {
        return coded.code
    }
    if let posix = error as? POSIXError {
        return .errno(posix.code.rawValue)
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

/// An error the engine makes itself: its message, a `code` when it has one, and the error it stands for in `cause`.
public struct OperationError: CodedError, Sendable, CustomStringConvertible {
    public var message: String
    public var code: ErrorCode?
    public var cause: (any Error)?

    public init(_ message: String, code: ErrorCode? = nil, cause: (any Error)? = nil) {
        self.message = message
        self.code = code
        self.cause = cause
    }

    public var description: String { message }
}
