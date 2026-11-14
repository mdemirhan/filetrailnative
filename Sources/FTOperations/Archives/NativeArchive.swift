import CFileTrail
import Darwin
import FTFoundation
import Foundation

/// An archive's own trouble, as a sentence naming it.
public struct ArchiveError: CodedError, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unreadable, needsPassword, empty
    }

    public var reason: Reason
    public var message: String
    public var code: ErrorCode? { nil }

    init(_ reason: Reason, archivePath: String) {
        self.reason = reason
        let name = NodePath.basename(archivePath)
        message =
            switch reason {
            case .unreadable:
                "\u{201C}\(name)\u{201D} can\u{2019}t be read. It may be damaged, or of a kind File Trail doesn\u{2019}t take apart."
            case .needsPassword:
                "\u{201C}\(name)\u{201D} is protected with a password. File Trail can\u{2019}t open protected archives yet; Archive Utility can."
            case .empty:
                "\u{201C}\(name)\u{201D} holds nothing to extract."
            }
    }
}

/// libarchive's work, as `archive.c` does it, on the calling thread (never the main thread).
enum NativeArchive {
    /// One archive's stop flag and progress, read from any thread while the work runs on another.
    final class Control: @unchecked Sendable {
        // Only read and set through the C functions, which are atomic.
        private let pointer: OpaquePointer

        init() {
            guard let made = ft_archive_control_create() else { fatalError("out of memory") }
            pointer = made
        }

        deinit { ft_archive_control_free(pointer) }

        func stop() { ft_archive_control_stop(pointer) }
        /// Bytes done: of the archive read, when extracting; of the items' data read, when compressing.
        var done: Int64 { ft_archive_control_done(pointer) }
        var total: Int64 { ft_archive_control_total(pointer) }
        var skipped: Int64 { ft_archive_control_skipped(pointer) }

        fileprivate var raw: OpaquePointer { pointer }
    }

    /// Takes `archivePath` apart into `folder`, empty and existing. `rawName`: the name a single compressed file is
    /// written as. Throws `StopError` when stopped, `ArchiveError` for the archive's own trouble, and the disk's
    /// errors as `NativeError`.
    static func extract(
        _ archivePath: String, into folder: String, rawName: String?, quarantine: Bool, control: Control
    ) throws {
        var message = [CChar](repeating: 0, count: 512)
        let code = ft_archive_extract(archivePath, folder, rawName, quarantine ? 1 : 0, control.raw, &message, 512)
        try throwIfFailed(code, path: archivePath, syscall: "extract")
    }

    /// Makes the zip `zipPath` (which must not exist) of the items `names` of `folder`, as Finder's Compress does.
    /// A zip left partly written by a failure or a stop is the caller's to remove.
    static func compressZip(_ names: [String], in folder: String, to zipPath: String, control: Control) throws {
        var message = [CChar](repeating: 0, count: 512)
        let pointers = names.map { strdup($0) }
        defer {
            for pointer in pointers { free(pointer) }
        }
        let code = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { buffer in
            ft_archive_compress_zip(folder, buffer.baseAddress, buffer.count, zipPath, control.raw, &message, 512)
        }
        try throwIfFailed(code, path: zipPath, syscall: "compress")
    }

    private static func throwIfFailed(_ code: Int32, path: String, syscall: String) throws {
        switch code {
        case 0: return
        case ECANCELED: throw StopError()
        case Int32(FT_ARCHIVE_UNREADABLE): throw ArchiveError(.unreadable, archivePath: path)
        case Int32(FT_ARCHIVE_NEEDS_PASSWORD): throw ArchiveError(.needsPassword, archivePath: path)
        case Int32(FT_ARCHIVE_EMPTY): throw ArchiveError(.empty, archivePath: path)
        default: throw NativeError.errno(code, syscall: syscall, path: path)
        }
    }
}
