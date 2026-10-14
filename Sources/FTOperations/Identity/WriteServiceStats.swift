// Port of WriteServiceStats and the reading half of WriteServiceFileSystem (packages/core/src/fs/writeServiceTypes.ts)
import Darwin
import Foundation

/// What `lstat` or `stat` says of an item, as Node's `Stats` gives it to the write engine.
public struct WriteServiceStats: Equatable, Sendable {
    public enum FileType: Sendable {
        case file, directory, symlink, other
    }

    public var type: FileType
    public var size: Int64
    /// The whole `st_mode`, file type bits included.
    public var mode: UInt32
    public var mtimeMs: Double?
    /// When the item was made, which its disk keeps for it.
    public var birthtimeMs: Double?
    public var ino: UInt64?
    public var dev: Int64?

    public init(
        type: FileType, size: Int64 = 0, mode: UInt32 = 0, mtimeMs: Double? = nil, birthtimeMs: Double? = nil,
        ino: UInt64? = nil, dev: Int64? = nil
    ) {
        self.type = type
        self.size = size
        self.mode = mode
        self.mtimeMs = mtimeMs
        self.birthtimeMs = birthtimeMs
        self.ino = ino
        self.dev = dev
    }

    public var isFile: Bool { type == .file }
    public var isDirectory: Bool { type == .directory }
    public var isSymbolicLink: Bool { type == .symlink }

    /// Node's `Stats` of a `stat` structure.
    public init(_ info: stat) {
        let format = info.st_mode & S_IFMT
        type =
            switch format {
            case S_IFREG: .file
            case S_IFDIR: .directory
            case S_IFLNK: .symlink
            default: .other
            }
        size = Int64(info.st_size)
        mode = UInt32(info.st_mode)
        mtimeMs = Self.milliseconds(info.st_mtimespec)
        birthtimeMs = Self.milliseconds(info.st_birthtimespec)
        ino = UInt64(info.st_ino)
        dev = Int64(info.st_dev)
    }

    /// Node's `sec * 1e3 + nsec / 1e6`.
    private static func milliseconds(_ time: timespec) -> Double {
        Double(time.tv_sec) * 1e3 + Double(time.tv_nsec) / 1e6
    }
}

/// What reading items for fingerprints, ids and stamps needs of the disk. The write service's file system
/// adds the writing calls to it.
public protocol IdentityFileSystem: Sendable {
    func lstat(_ path: String) throws -> WriteServiceStats
    func stat(_ path: String) throws -> WriteServiceStats
    func realpath(_ path: String) throws -> String
    func readdir(_ path: String) throws -> [String]
    func readlink(_ path: String) throws -> String
}

/// The disk itself, through the system calls Node's fs makes; errors carry Node's syscall names.
public struct PosixFileSystem: IdentityFileSystem {
    public init() {}

    public func lstat(_ path: String) throws -> WriteServiceStats {
        var info = Darwin.stat()
        if Darwin.lstat(path, &info) != 0 {
            throw NativeError.errno(errno, syscall: "lstat", path: path)
        }
        return WriteServiceStats(info)
    }

    public func stat(_ path: String) throws -> WriteServiceStats {
        var info = Darwin.stat()
        if statFollowingLinks(path, &info) != 0 {
            throw NativeError.errno(errno, syscall: "stat", path: path)
        }
        return WriteServiceStats(info)
    }

    public func realpath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else {
            throw NativeError.errno(errno, syscall: "realpath", path: path)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The names in the folder, as the disk stores them, without "." and "..".
    public func readdir(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else {
            throw NativeError.errno(errno, syscall: "scandir", path: path)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 {
                    throw NativeError.errno(errno, syscall: "scandir", path: path)
                }
                return names
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
    }

    public func readlink(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = Darwin.readlink(path, &buffer, buffer.count - 1)
        if length < 0 {
            throw NativeError.errno(errno, syscall: "readlink", path: path)
        }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// `stat(2)`, which a method named `stat` can't call by its own name.
private func statFollowingLinks(_ path: String, _ info: UnsafeMutablePointer<stat>) -> Int32 {
    stat(path, info)
}
