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
    /// The flag that hides an item whatever its name (UF_HIDDEN).
    public var hasHiddenFlag: Bool

    public init(
        type: FileType, size: Int64 = 0, birthtimeMs: Int64? = nil, mtimeMs: Int64? = nil, mode: UInt32 = 0,
        hasHiddenFlag: Bool = false
    ) {
        self.hasHiddenFlag = hasHiddenFlag
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
    /// Finder's flags say it has a custom icon, as a folder made with Customize Folder does.
    public var hasCustomIcon: Bool
    /// Finder's label: the color of the item's last colored tag, which a folder is drawn in.
    public var tagColor: FinderTagColor?
    /// A folder the disk says holds nothing, hidden items included. Only APFS and HFS+ say so.
    public var isEmptyFolder: Bool
    /// The flag that hides an item whatever its name, as Finder goes by. Folders, files and links can all have it.
    public var hasHiddenFlag: Bool
    /// Finder's flags say it is an alias: a file that holds where its original is, as Make Alias makes.
    public var isAlias: Bool
    /// When the item was put in the folder (Date Added), in milliseconds since 1970; nil on a disk that doesn't keep
    /// it.
    public var addedMs: Int64?
    /// Finder's flags say it is a package (the bundle bit): a folder the system shows as one item, whatever its name.
    public var hasBundleBit: Bool

    public init(
        name: String, type: FileType, lstat: FileStats? = nil, hasCustomIcon: Bool = false,
        tagColor: FinderTagColor? = nil, isEmptyFolder: Bool = false, hasHiddenFlag: Bool = false,
        addedMs: Int64? = nil, isAlias: Bool = false, hasBundleBit: Bool = false
    ) {
        self.hasBundleBit = hasBundleBit
        self.isAlias = isAlias
        self.addedMs = addedMs
        self.hasHiddenFlag = hasHiddenFlag
        self.name = name
        self.type = type
        self.lstat = lstat
        self.hasCustomIcon = hasCustomIcon
        self.tagColor = tagColor
        self.isEmptyFolder = isEmptyFolder
    }
}

/// The disk as the listing sees it. Tests stand in for it with a fake; the app uses `NativeFileSystem`.
public protocol ExplorerFileSystem: Sendable {
    func readDirectory(_ path: String) throws -> [DirectoryRecord]
    func stat(_ path: String) throws -> FileStats
    func lstat(_ path: String) throws -> FileStats
    func realpath(_ path: String) throws -> String
    /// The colors of an item's Finder tags, in their order; none for an item that can't be read.
    func tagColors(_ path: String) -> [FinderTagColor]
    /// The name of an item's first tag; nil for one without tags or that can't be read.
    func firstTagName(_ path: String) -> String?
    /// The names of an item's tags in their order; none for one without tags or that can't be read.
    func tagNames(_ path: String) -> [String]
    /// When the item at `path` (a link itself) was put in its folder, in milliseconds since 1970; nil when the disk
    /// doesn't keep it or the item can't be read.
    func addedMs(_ path: String) -> Int64?
    /// When the item at `path` (a link itself) was last opened, in milliseconds since 1970; nil for one never opened.
    func lastOpenedMs(_ path: String) -> Int64?
    /// `lastOpenedMs` for every item of one folder read, asked for once before its items are gone through: what each
    /// item's read needs and no item changes (the home folder's path) is taken once, not once for each item.
    func lastOpenedReader() -> @Sendable (String) -> Int64?
    /// Whether the file at `path` is a Finder alias (`Links.isFinderAlias`).
    func isFinderAlias(_ path: String) -> Bool
    /// Whether the alias at `path` leads to a folder to open in place (`Links.originalItem`).
    func aliasLeadsToFolder(_ path: String) -> Bool
    /// Whether the system declares folders with this extension (lowercased, without its dot) packages
    /// (`SystemPackages.isPackageType`). A listing asks it only of folders whose name has an extension that isn't one
    /// of `ItemNames.packageExtensions`, and that lack the bundle bit.
    func isPackageType(_ fileExtension: String) -> Bool
    /// What the system says of whether the folder at `path` is a package (`SystemPackages.answer`), for one item that
    /// no folder read gave; nil when it can't be asked.
    func isPackage(_ path: String) -> Bool?
}

extension ExplorerFileSystem {
    public func tagColors(_ path: String) -> [FinderTagColor] { FinderTags.colors(path) }
    public func firstTagName(_ path: String) -> String? { FinderTags.firstName(path) }
    public func tagNames(_ path: String) -> [String] { FinderTags.shown(path).map(\.name) }
    public func addedMs(_ path: String) -> Int64? { FileTimes.addedMs(path) }
    public func lastOpenedMs(_ path: String) -> Int64? { FileTimes.lastOpenedMs(path) }
    /// Whatever `lastOpenedMs` is: a stand-in for the disk that answers it itself is asked item by item.
    public func lastOpenedReader() -> @Sendable (String) -> Int64? { { lastOpenedMs($0) } }
    public func isFinderAlias(_ path: String) -> Bool { Links.isFinderAlias(path) }
    public func aliasLeadsToFolder(_ path: String) -> Bool { Links.originalItem(of: path)?.isFolder ?? false }
    public func isPackageType(_ fileExtension: String) -> Bool { SystemPackages.isPackageType(fileExtension) }
    public func isPackage(_ path: String) -> Bool? { SystemPackages.answer(path) }
}

public struct NativeFileSystem: ExplorerFileSystem {
    public init() {}

    public func lastOpenedReader() -> @Sendable (String) -> Int64? { FileTimes.lastOpenedReader() }

    public func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        var listing = FTDirListing()
        // Each attribute costs next to nothing beside the read itself (an entry costs APFS about 2.4 us),
        // so every one is asked for and the sort modes that need a size or a time have it at once.
        let code = ft_read_directory(
            path,
            UInt32(
                FT_READ_MODE | FT_READ_SIZE | FT_READ_MODIFIED | FT_READ_CREATED | FT_READ_FINDER_INFO
                    | FT_READ_EMPTY_FOLDERS | FT_READ_HIDDEN_FLAG | FT_READ_ADDED),
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
                    lstat: Self.knownStats(entry, type: type),
                    hasCustomIcon: entry.has_custom_icon != 0,
                    tagColor: FinderTagColor(rawValue: Int(entry.finder_label)),
                    isEmptyFolder: entry.is_empty_folder != 0, hasHiddenFlag: entry.has_hidden_flag != 0,
                    addedMs: entry.added_valid != 0 ? Self.milliseconds(entry.added_sec, entry.added_nsec) : nil,
                    isAlias: entry.is_alias != 0, hasBundleBit: entry.has_bundle_bit != 0))
        }
        return records
    }

    /// What the read says of an entry, or nil when the disk left out something the listing sorts or decides by: the
    /// listing then asks `lstat`. A creation time left out isn't asked for again: sorted by Date Created, an item
    /// with none comes last. A folder never has a size from the read.
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

    /// The most seconds a time keeps, either side of 1970: the difference of any two times in milliseconds still fits.
    static let secondsLimit: Int64 = .max / 2000

    /// Times are whole milliseconds, cut towards zero. A disk can report any number (a FUSE or network disk with a
    /// time far out of range, or a nanosecond field that is no part of a second): the seconds are held to
    /// `secondsLimit` and the nanoseconds to a second, so no time read from a disk stops the app.
    static func milliseconds(_ seconds: Int64, _ nanoseconds: some BinaryInteger) -> Int64 {
        let seconds = min(max(seconds, -secondsLimit), secondsLimit)
        let nanoseconds = min(max(Int64(clamping: nanoseconds), 0), 999_999_999)
        return seconds * 1000 + nanoseconds / 1_000_000
    }

    static func stats(_ info: SystemStat) -> FileStats {
        FileStats(
            type: fileType(mode: info.st_mode), size: Int64(info.st_size),
            birthtimeMs: milliseconds(Int64(info.st_birthtimespec.tv_sec), info.st_birthtimespec.tv_nsec),
            mtimeMs: milliseconds(Int64(info.st_mtimespec.tv_sec), info.st_mtimespec.tv_nsec),
            mode: UInt32(info.st_mode), hasHiddenFlag: info.st_flags & UInt32(UF_HIDDEN) != 0)
    }
}

typealias SystemStat = stat

// The system calls, under names the methods above don't shadow.
private func systemStat(_ path: String, _ info: inout SystemStat) -> Int32 { stat(path, &info) }
private func systemLstat(_ path: String, _ info: inout SystemStat) -> Int32 { lstat(path, &info) }
private func systemRealpath(_ path: String, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    realpath(path, resolved)
}
