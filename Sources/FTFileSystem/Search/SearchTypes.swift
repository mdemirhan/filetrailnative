import FTFoundation
import Foundation

/// What `search:start` takes. The defaults are the contract's.
public struct SearchRequest: Codable, Sendable, Equatable {
    public var rootPath: String
    public var query: String
    public var patternMode: SearchPatternModePreference
    public var matchScope: SearchMatchScopePreference
    public var recursive: Bool
    public var includeHidden: Bool
    /// Leave out `.git` folders.
    public var skipGitFolders: Bool
    /// Leave out anything Git ignores (.gitignore and friends).
    public var skipGitIgnored: Bool

    public init(
        rootPath: String, query: String, patternMode: SearchPatternModePreference = .text,
        matchScope: SearchMatchScopePreference = .name, recursive: Bool = true, includeHidden: Bool = false,
        skipGitFolders: Bool = true, skipGitIgnored: Bool = false
    ) {
        self.rootPath = rootPath
        self.query = query
        self.patternMode = patternMode
        self.matchScope = matchScope
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.skipGitFolders = skipGitFolders
        self.skipGitIgnored = skipGitIgnored
    }
}

public enum SearchJobStatus: String, Codable, Sendable, Equatable {
    case running, complete, cancelled, truncated, error
}

/// One result.
public struct SearchResultItem: Codable, Sendable, Equatable {
    public var path: String
    public var name: String
    /// Lowercased, without the dot; "" when the name has none.
    public var fileExtension: String
    public var kind: EntryKind
    public var isHidden: Bool
    public var isSymlink: Bool
    /// The absolute parent folder.
    public var parentPath: String
    /// The parent relative to the search root ("." for the root itself), computed once so rows need no slicing.
    public var relativeParentPath: String

    public init(
        path: String, name: String, fileExtension: String, kind: EntryKind, isHidden: Bool, isSymlink: Bool = false,
        parentPath: String, relativeParentPath: String
    ) {
        self.path = path
        self.name = name
        self.fileExtension = fileExtension
        self.kind = kind
        self.isHidden = isHidden
        self.isSymlink = isSymlink
        self.parentPath = parentPath
        self.relativeParentPath = relativeParentPath
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, kind, isHidden, isSymlink, parentPath, relativeParentPath
        case fileExtension = "extension"
    }
}

/// `search:start`'s answer.
public struct SearchStartResponse: Sendable, Equatable {
    public var jobId: String
    public var status: SearchJobStatus
}

/// What a search says when asked how it is doing: the results from the cursor on, and where the job stands.
public struct SearchUpdate: Sendable, Equatable {
    public var jobId: String
    public var status: SearchJobStatus
    public var items: [SearchResultItem]
    public var nextCursor: Int
    public var done: Bool
    public var truncated: Bool
    public var error: String?

    public init(
        jobId: String, status: SearchJobStatus, items: [SearchResultItem], nextCursor: Int, done: Bool,
        truncated: Bool, error: String?
    ) {
        self.jobId = jobId
        self.status = status
        self.items = items
        self.nextCursor = nextCursor
        self.done = done
        self.truncated = truncated
        self.error = error
    }
}

public struct UnknownSearchJob: Error, Equatable, CustomStringConvertible {
    public let jobId: String
    public var description: String { "Unknown search job: \(jobId)" }
}
