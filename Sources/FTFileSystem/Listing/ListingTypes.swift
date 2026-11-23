import Foundation

/// What an entry of a folder is, as the listing classifies it.
public enum EntryKind: String, Sendable, Hashable, Codable, CaseIterable {
    case directory
    case file
    case symlinkDirectory = "symlink_directory"
    case symlinkFile = "symlink_file"
    /// A Finder alias: a file holding where its original is. Of a file, or of an original that couldn't be found.
    case alias
    /// A Finder alias of a folder: still a file, listed with the folders as Finder lists it.
    case aliasDirectory = "alias_directory"
    case bundle
    case other

    /// Folders, links and aliases of folders: what "folders first" puts ahead. A bundle counts as a file.
    public var isDirectoryKind: Bool { self == .directory || self == .symlinkDirectory || self == .aliasDirectory }

    /// A Finder alias, of a folder or not.
    public var isAlias: Bool { self == .alias || self == .aliasDirectory }
}

public enum DirectorySortKey: String, Sendable, Hashable, Codable, CaseIterable {
    case name
    case modified
    case kind
    case size
    /// When each item was put in the folder (Date Added), as the folder read gives it.
    case added
    /// When each item was last opened (Date Last Opened), read for each item.
    case lastOpened
    /// When each item was made (Date Created), as the folder read gives it.
    case created
}

/// What a listing reads besides what its order needs, for the groups the items are shown in: a date of each item, its
/// size, or its first tag. Groups by name or kind need nothing more.
public enum DirectoryGroupRead: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case modified
    case created
    case added
    case lastOpened
    case size
    case tags
}

public enum SortDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case ascending = "asc"
    case descending = "desc"
}

public enum SizeStatus: String, Sendable, Hashable, Codable {
    case ready
    case deferred
    case unavailable
}

public struct TreeChild: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var kind: EntryKind
    public var isHidden: Bool
    public var isSymlink: Bool
}

public struct TreeChildren: Sendable, Hashable, Codable {
    public var path: String
    public var children: [TreeChild]
}

public struct DirectoryEntry: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var isHidden: Bool
    public var isSymlink: Bool
    /// Only for a file without an extension: whether it can be run. macOS draws such files with one of
    /// two icons, and this says which.
    public var isExecutable: Bool?
    /// A file's size, as the folder read gave it, or as it was asked for when listed sorted or grouped by size (a
    /// link's is its target's). Nil for a folder, and where neither gave it.
    public var sizeBytes: Int64?
    /// When the item was last modified and created, in milliseconds since 1970, and its permission bits, as the folder
    /// read gave them: shown until the item's own details are read. Nil for a link, whose are its target's, and where
    /// the read didn't give them.
    public var modifiedMs: Int64?
    public var createdMs: Int64?
    public var permissionMode: Int?
    /// Only for a folder Finder has given its own icon (Customize Folder, or a pasted picture).
    public var hasCustomIcon: Bool?
    /// Only for a folder with a colored tag: the color Finder draws it in, its last tag's.
    public var tagColor: FinderTagColor?
    /// Only for a folder known to hold nothing when listed; Finder draws one without the sheet of paper.
    public var isEmptyFolder: Bool?
    /// Only for an item with a Finder label, which macOS gives every item with a colored tag: the colors of its
    /// tags, read with the folder so they show with it.
    public var tagColors: [FinderTagColor]?
    /// When the item was put in its folder (Date Added), in milliseconds since 1970, as the folder read gave it: the
    /// date a listing sorted by Date Added is ordered by. Nil on a disk that doesn't keep it, and for an entry no
    /// folder read gave (a search result).
    public var addedMs: Int64?
    /// Only when listed for groups of a date: that date of the item, in milliseconds since 1970; nil for an item
    /// without it (never opened, a disk that doesn't keep when items were added).
    public var groupTimeMs: Int64?
    /// Only when listed for groups of tags: the name of the item's first tag; nil for one without tags.
    public var firstTag: String?
}

public struct DirectorySnapshot: Sendable, Hashable, Codable {
    public var path: String
    public var parentPath: String?
    public var entries: [DirectoryEntry]
    /// The folder's modification time, taken before its entries were read (`FolderModifiedTime`): a change made since
    /// shows as another time, however long the listing was kept. Nil when it couldn't be read.
    public var modifiedTime: Double? = nil
}

/// A folder's modification time as its watch compares it: milliseconds, with those of the folders listed along with
/// it added (the Trash of each disk), as a change to any of them changes the total.
public enum FolderModifiedTime {
    public static func read(
        _ path: String, alsoListing: [String] = [], _ fileSystem: any ExplorerFileSystem
    ) -> Double? {
        guard let time = (try? fileSystem.stat(path))?.mtimeMs else { return nil }
        return alsoListing.reduce(Double(time)) { total, other in
            total + Double((try? fileSystem.stat(other))?.mtimeMs ?? 0)
        }
    }
}

public struct EntryMetadata: Sendable, Hashable, Codable {
    public var path: String
    public var kindLabel: String
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?
    /// When the item was put in its folder; nil on a disk that doesn't keep it.
    public var addedAt: Date? = nil
    /// When the item was last opened; nil for one never opened.
    public var lastOpenedAt: Date? = nil
}

public struct MetadataBatch: Sendable, Hashable, Codable {
    public var directoryPath: String
    public var items: [EntryMetadata]
}

public struct ItemProperties: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var fileExtension: String
    public var kind: EntryKind
    public var kindLabel: String
    public var isHidden: Bool
    public var isSymlink: Bool
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?
    /// When the item was put in its folder; nil on a disk that doesn't keep it.
    public var addedAt: Date? = nil
    /// When the item was last opened; nil for one never opened.
    public var lastOpenedAt: Date? = nil
    /// For a symbolic link or an alias, where it leads (`Links.original`); nil when its original can't be found, and
    /// for anything else.
    public var originalPath: String? = nil

    /// A symbolic link or an alias: what Get Info says the original of.
    public var isLink: Bool { isSymlink || kind == .alias }
}

public struct PathSuggestion: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
}

public struct PathSuggestions: Sendable, Hashable, Codable {
    public var inputPath: String
    public var basePath: String?
    public var suggestions: [PathSuggestion]
}

/// A change made to the folder a window watches.
public struct FolderChange: Sendable, Hashable, Codable {
    public var path: String
    /// The items in the folder that changed, or nil when that isn't known (too many, or a change noticed
    /// only by the folder's modification time).
    public var changedPaths: [String]?

    public init(path: String, changedPaths: [String]?) {
        self.path = path
        self.changedPaths = changedPaths
    }
}

/// Why a listing could not be made.
public enum ExplorerError: Error, Equatable, CustomStringConvertible, Sendable {
    case notADirectory(String)
    case outsideDirectory(path: String, directory: String)
    /// A system call refused: `call` is the one the message names (`scandir`, `stat`).
    case system(code: Int32, path: String, call: String = "scandir")

    /// A system error's text, "EACCES: permission denied, scandir '/x'".
    public var description: String {
        switch self {
        case .notADirectory(let path): "Path is not a directory: \(path)"
        case .outsideDirectory(let path, let directory): "Path \(path) is outside \(directory)"
        case .system(let code, let path, let call): "\(Self.nodeText(code)), \(call) '\(path)'"
        }
    }

    /// The start of the message, the code first: the system's description in lower case, but for a few codes with
    /// words of their own ("i/o error", "resource busy or locked").
    private static func nodeText(_ code: Int32) -> String {
        guard let name = Errno.name(of: code) else {
            return "Unknown system error -\(code): Unknown system error -\(code)"
        }
        if let words = libuvWords[code] { return "\(name): \(words)" }
        let reason = Errno.description(of: code)
        return "\(name): \(reason.prefix(1).lowercased())\(reason.dropFirst())"
    }

    private static let libuvWords: [Int32: String] = [
        EIO: "i/o error", ELOOP: "too many symbolic links encountered", EBUSY: "resource busy or locked",
        ENOMEM: "not enough memory", ENAMETOOLONG: "name too long", EMFILE: "too many open files",
        ETIMEDOUT: "connection timed out", ENOTSUP: "operation not supported on socket",
    ]
}
