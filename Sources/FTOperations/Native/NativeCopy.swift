// Port of packages/native-fs/src/native_copyfile.c (nativeCopyFile, nativeCopyMetadata) and applyDirectoryMetadata,
// preserveModeIfSupported and preserveTimestampsIfSupported (packages/core/src/fs/copyPasteExecution.ts)
import CFileTrail
import Darwin
import Foundation

/// The native calls of the write engine. Each blocks the thread it is called on, which is never the main
/// thread: network volumes can be slow to answer.
public enum NativeFS {}

/// The stop flag of one copy and the bytes it has copied so far (the original's `Int32Array` stop flag with
/// its 64-bit count). Shared between the copy's thread and those that stop it or read its progress.
public final class CopyControl: @unchecked Sendable {
    // Atomic fields in C, set and read from any thread.
    private let pointer: OpaquePointer

    public init() {
        guard let pointer = ft_copy_control_create() else { fatalError("out of memory for a copy's stop flag") }
        self.pointer = pointer
    }

    deinit { ft_copy_control_free(pointer) }

    /// Stops the copy: it quits at its next chunk of data, or doesn't start.
    public func stop() { ft_copy_control_stop(pointer) }

    public var isStopped: Bool { ft_copy_control_is_stopped(pointer) != 0 }

    /// The bytes of the file's data copied so far.
    public var copiedBytes: Int64 {
        get { ft_copy_control_copied(pointer) }
        set { ft_copy_control_set_copied(pointer, newValue) }
    }

    fileprivate var raw: OpaquePointer { pointer }
}

extension NativeFS {
    /// `nativeCopyFile(source, destination, stopFlag?)`: copyfile(3) with `COPYFILE_ALL | CLONE | NOFOLLOW_SRC |
    /// EXCL | DATA_SPARSE`. With a `control` it can be stopped part way (ECANCELED) and counts its bytes;
    /// a stop set before it begins keeps it from starting. Errors name the syscall `copyfile`, the source and
    /// the destination.
    public static func copyFile(_ source: String, _ destination: String, control: CopyControl? = nil) throws {
        let errnum = withExtendedLifetime(control) { ft_copyfile(source, destination, control?.raw) }
        if errnum != 0 {
            throw NativeError.errno(errnum, syscall: "copyfile", path: source, dest: destination)
        }
    }

    /// `nativeCopyMetadata(source, destination)`: a folder's own metadata (mode, flags, dates, extended
    /// attributes such as tags and the custom-icon flag, ACLs) onto an existing folder, without its items.
    public static func copyMetadata(_ source: String, _ destination: String) throws {
        let errnum = ft_copy_metadata(source, destination)
        if errnum != 0 {
            throw NativeError.errno(errnum, syscall: "copyfile", path: source, dest: destination)
        }
    }

    /// Node's `chmod(path, mode)`.
    public static func chmod(_ path: String, _ mode: UInt32) throws {
        if Darwin.chmod(path, mode_t(mode & 0o7777)) != 0 {
            throw NativeError.errno(Darwin.errno, syscall: "chmod", path: path)
        }
    }

    /// Node's `utimes(path, atime, mtime)`, times in milliseconds (a symlink is followed).
    public static func utimes(_ path: String, atimeMs: Double, mtimeMs: Double) throws {
        var times = [timespec(milliseconds: atimeMs), timespec(milliseconds: mtimeMs)]
        if utimensat(AT_FDCWD, path, &times, 0) != 0 {
            throw NativeError.errno(Darwin.errno, syscall: "utime", path: path)
        }
    }
}

extension timespec {
    /// libuv's `uv__fs_to_timespec` of the seconds Node passes it.
    fileprivate init(milliseconds: Double) {
        let seconds = milliseconds / 1000
        var whole = seconds.rounded(.towardZero)
        var fraction = seconds - whole
        if fraction < 0 {
            whole -= 1
            fraction += 1
        }
        self.init(tv_sec: Int(whole), tv_nsec: Int(fraction * 1e9))
    }
}

/// The metadata a folder copy carries over once its items are in (a read-only or locked folder can't be
/// written into afterwards).
public enum FolderMetadata {
    /// `applyDirectoryMetadata`: copies the folder's own metadata from `source` (copyfile), and on a move
    /// puts back the date `sourceMtimeMs` it had before its items went out (only the date is lost if that
    /// fails). When copyfile fails (a volume that refuses some attribute), a move first reports it through
    /// `onNotCopied` (its original folder is then kept with what its copy couldn't take), and then the mode and
    /// the date alone are carried over (`chmod` + `utimes`, each skipped on ENOTSUP). The report comes before
    /// the fallback, so it stands even when the fallback throws.
    public static func apply(
        source: String, destination: String, sourceMode: UInt32?, sourceMtimeMs: Double?, moving: Bool,
        onNotCopied: () -> Void,
        copyMetadata: (String, String) throws -> Void = NativeFS.copyMetadata,
        chmod: (String, UInt32) throws -> Void = NativeFS.chmod,
        utimes: (String, Double, Double) throws -> Void = { try NativeFS.utimes($0, atimeMs: $1, mtimeMs: $2) }
    ) throws {
        do {
            try copyMetadata(source, destination)
            if moving {
                try? preserveTimestamps(destination, sourceMtimeMs, utimes)
            }
            return
        } catch {
            if moving {
                onNotCopied()
            }
        }
        try preserveMode(destination, sourceMode, chmod)
        try preserveTimestamps(destination, sourceMtimeMs, utimes)
    }

    /// `preserveModeIfSupported`.
    static func preserveMode(_ path: String, _ mode: UInt32?, _ chmod: (String, UInt32) throws -> Void) throws {
        guard let mode else { return }
        do {
            try chmod(path, mode)
        } catch  where isUnsupported(error) {}
    }

    /// `preserveTimestampsIfSupported`.
    static func preserveTimestamps(
        _ path: String, _ mtimeMs: Double?, _ utimes: (String, Double, Double) throws -> Void
    ) throws {
        guard let mtimeMs else { return }
        do {
            try utimes(path, mtimeMs, mtimeMs)
        } catch  where isUnsupported(error) {}
    }

    private static func isUnsupported(_ error: any Error) -> Bool {
        let code = errorCode(error)
        return code == "ENOTSUP" || code == "EOPNOTSUPP"
    }
}
