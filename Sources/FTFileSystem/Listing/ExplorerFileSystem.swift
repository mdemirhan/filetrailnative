// Port of the ExplorerFileSystem seam of packages/core/src/fs/explorerService.ts, read with getattrlistbulk
import CFileTrail
import Darwin
import Foundation

/// What a path is on disk.
public enum FileType: Sendable, Hashable {
    case directory
    case file
    case symlink
    case other
}

/// What `stat` or `lstat` says. Times are milliseconds since 1970 (nil when the disk has none).
public struct FileStats: Sendable, Hashable {
    public var type: FileType
    public var size: Int64
    public var birthtimeMs: Int64?
    public var mtimeMs: Int64?
    public var mode: UInt32

    public init(type: FileType, size: Int64 = 0, birthtimeMs: Int64? = nil, mtimeMs: Int64? = nil, mode: UInt32 = 0) {
        self.type = type
        self.size = size
        self.birthtimeMs = birthtimeMs
        self.mtimeMs = mtimeMs
        self.mode = mode
    }

    public var isDirectory: Bool { type == .directory }
    public var isFile: Bool { type == .file }
    public var isSymbolicLink: Bool { type == .symlink }
}

/// One entry of a folder as a directory read gives it: its name and type, and, when the read could give it
/// at no cost (getattrlistbulk does), what `lstat` would say.
public struct DirectoryRecord: Sendable, Hashable {
    public var name: String
    public var type: FileType
    public var lstat: FileStats?

    public init(name: String, type: FileType, lstat: FileStats? = nil) {
        self.name = name
        self.type = type
        self.lstat = lstat
    }
}

/// The disk as the listing sees it. Tests stand in for it with a fake; the app uses `NativeFileSystem`.
public protocol ExplorerFileSystem: Sendable {
    func readDirectory(_ path: String) throws -> [DirectoryRecord]
    func stat(_ path: String) throws -> FileStats
    func lstat(_ path: String) throws -> FileStats
    func realpath(_ path: String) throws -> String
}

public struct NativeFileSystem: ExplorerFileSystem {
    public init() {}

    public func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        var listing = FTDirListing()
        // Each attribute costs next to nothing beside the read itself (an entry costs APFS about 2.4 us),
        // so every one is asked for and the sort modes that need a size or a time have it at once.
        let code = ft_read_directory(
            path, UInt32(FT_READ_MODE | FT_READ_SIZE | FT_READ_MODIFIED | FT_READ_CREATED),
            &listing)
        guard code == 0 else { throw ExplorerError.system(code: code, path: path) }
        defer { ft_free_listing(&listing) }
        var records: [DirectoryRecord] = []
        records.reserveCapacity(listing.count)
        let names = UnsafeRawBufferPointer(start: listing.names, count: listing.names_length)
        for index in 0..<listing.count {
            let entry = listing.entries[index]
            let start = Int(entry.name_offset)
            let bytes = UnsafeRawBufferPointer(rebasing: names[start..<(start + Int(entry.name_length))])
            let type = Self.fileType(entry.type)
            records.append(
                DirectoryRecord(
                    name: String(decoding: bytes, as: UTF8.self),
                    type: type,
                    lstat: Self.knownStats(entry, type: type)))
        }
        return records
    }

    /// What the read says of an entry, or nil when the disk left out something the listing sorts or decides by: the
    /// listing then asks `lstat`, as the original does for every entry that needs stats. No creation time is no matter:
    /// nothing sorts by it. A folder never has a size from the read.
    static func knownStats(_ entry: FTDirEntry, type: FileType) -> FileStats? {
        guard entry.mode_valid != 0, entry.mtime_valid != 0, type == .directory || entry.size_valid != 0 else {
            return nil
        }
        return FileStats(
            type: type, size: entry.size,
            birthtimeMs: entry.crtime_valid != 0 ? milliseconds(entry.crtime_sec, entry.crtime_nsec) : nil,
            mtimeMs: milliseconds(entry.mtime_sec, entry.mtime_nsec), mode: entry.mode)
    }

    public func stat(_ path: String) throws -> FileStats {
        var info = SystemStat()
        guard systemStat(path, &info) == 0 else { throw ExplorerError.system(code: errno, path: path, call: "stat") }
        return Self.stats(info)
    }

    public func lstat(_ path: String) throws -> FileStats {
        var info = SystemStat()
        guard systemLstat(path, &info) == 0 else { throw ExplorerError.system(code: errno, path: path, call: "lstat") }
        return Self.stats(info)
    }

    public func realpath(_ path: String) throws -> String {
        guard let resolved = systemRealpath(path, nil) else {
            throw ExplorerError.system(code: errno, path: path, call: "realpath")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func fileType(_ raw: Int32) -> FileType {
        switch raw {
        case Int32(FT_ENTRY_DIRECTORY.rawValue): .directory
        case Int32(FT_ENTRY_FILE.rawValue): .file
        case Int32(FT_ENTRY_SYMLINK.rawValue): .symlink
        default: .other
        }
    }

    private static func fileType(mode: mode_t) -> FileType {
        switch mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
    }

    /// A Date in JavaScript is whole milliseconds, cut towards zero.
    private static func milliseconds(_ seconds: Int64, _ nanoseconds: Int32) -> Int64 {
        seconds * 1000 + Int64(nanoseconds) / 1_000_000
    }

    private static func stats(_ info: SystemStat) -> FileStats {
        FileStats(
            type: fileType(mode: info.st_mode), size: Int64(info.st_size),
            birthtimeMs: milliseconds(Int64(info.st_birthtimespec.tv_sec), Int32(info.st_birthtimespec.tv_nsec)),
            mtimeMs: milliseconds(Int64(info.st_mtimespec.tv_sec), Int32(info.st_mtimespec.tv_nsec)),
            mode: UInt32(info.st_mode))
    }
}

typealias SystemStat = stat

// The system calls, under names the methods above don't shadow.
private func systemStat(_ path: String, _ info: inout SystemStat) -> Int32 { stat(path, &info) }
private func systemLstat(_ path: String, _ info: inout SystemStat) -> Int32 { lstat(path, &info) }
private func systemRealpath(_ path: String, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    realpath(path, resolved)
}
