import FTFoundation
import Foundation

/// What a search looks for, and where.
public struct SearchRequest: Sendable, Equatable {
    public var rootPath: String
    public var query: String
    public var patternMode: SearchPatternModePreference
    public var matchScope: SearchMatchScopePreference
    public var recursive: Bool
    public var includeHidden: Bool
    /// Leave out `.git` folders.
    public var skipGitFolders: Bool
    /// What an item must be besides its name: every one of them.
    public var conditions: [SearchCondition]

    public init(
        rootPath: String, query: String, patternMode: SearchPatternModePreference = .text,
        matchScope: SearchMatchScopePreference = .name, recursive: Bool = true, includeHidden: Bool = false,
        skipGitFolders: Bool = true, conditions: [SearchCondition] = []
    ) {
        self.rootPath = rootPath
        self.query = query
        self.patternMode = patternMode
        self.matchScope = matchScope
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.skipGitFolders = skipGitFolders
        self.conditions = conditions
    }
}

public enum SearchJobStatus: String, Sendable, Equatable {
    case running, complete, cancelled, truncated, error
}

/// One result.
public struct SearchResultItem: Sendable, Equatable {
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
}

/// What starting a search answers: the job's id, to ask how it is doing.
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
    /// The search met folders it couldn't read (no permission, a disk error): what is in them isn't among the results.
    /// Kept and not shown, as Finder says nothing of them.
    public var unreadableFolders: Bool
    /// How many items its conditions have read so far, beyond what their folders list; 0 for a search with none that
    /// read.
    public var itemsRead: Int

    public init(
        jobId: String, status: SearchJobStatus, items: [SearchResultItem], nextCursor: Int, done: Bool,
        truncated: Bool, error: String?, unreadableFolders: Bool = false, itemsRead: Int = 0
    ) {
        self.jobId = jobId
        self.status = status
        self.items = items
        self.nextCursor = nextCursor
        self.done = done
        self.truncated = truncated
        self.error = error
        self.unreadableFolders = unreadableFolders
        self.itemsRead = itemsRead
    }
}

public struct UnknownSearchJob: Error, Equatable, CustomStringConvertible {
    public let jobId: String
    public var description: String { "Unknown search job: \(jobId)" }
}
