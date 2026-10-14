// Port of the response shapes of packages/contracts/src/ipc.ts for tree:getChildren, directory:getSnapshot,
// directory:getMetadataBatch, item:getProperties, path:getSuggestions and path:resolve
import Foundation

/// What an entry of a folder is, as the listing classifies it (`classifyEntry` in explorerService.ts).
public enum EntryKind: String, Sendable, Hashable, Codable, CaseIterable {
    case directory
    case file
    case symlinkDirectory = "symlink_directory"
    case symlinkFile = "symlink_file"
    case bundle
    case other

    /// Folders and links to folders: what "folders first" puts ahead. A bundle counts as a file.
    public var isDirectoryKind: Bool { self == .directory || self == .symlinkDirectory }
}

public enum DirectorySortKey: String, Sendable, Hashable, Codable, CaseIterable {
    case name
    case modified
    case kind
    case size
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
    /// Only when listed sorted by size, and only for files (nil for the rest).
    public var sizeBytes: Int64?
}

public struct DirectorySnapshot: Sendable, Hashable, Codable {
    public var path: String
    public var parentPath: String?
    public var entries: [DirectoryEntry]
}

public struct EntryMetadata: Sendable, Hashable, Codable {
    public var path: String
    public var kindLabel: String
    public var createdAt: String?
    public var modifiedAt: String?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?
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
    public var createdAt: String?
    public var modifiedAt: String?
    public var sizeBytes: Int64?
    public var sizeStatus: SizeStatus
    public var permissionMode: Int?
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

public struct ResolvedPath: Sendable, Hashable, Codable {
    public var inputPath: String
    public var resolvedPath: String?
}

/// A change made to the folder a window watches (`folderChangeSchema`).
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
    case system(code: Int32, path: String)

    public var description: String {
        switch self {
        case .notADirectory(let path): "Path is not a directory: \(path)"
        case .outsideDirectory(let path, let directory): "Path \(path) is outside \(directory)"
        case .system(let code, let path): "\(String(cString: strerror(code))): \(path)"
        }
    }
}
