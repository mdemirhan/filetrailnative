import FTFoundation
import Foundation

/// Whether a paste copies an item or moves it: the clipboard's own Copy or Cut, one type for both.
public typealias CopyPasteMode = ClipboardMode

public enum CopyPasteOperationStatus: String, Codable, Sendable {
    case queued, running
    case awaitingResolution = "awaiting_resolution"
    case completed, failed, cancelled, partial
}

public enum CopyPastePlanIssueCode: String, Codable, Sendable {
    case destinationMissing = "destination_missing"
    case destinationNotDirectory = "destination_not_directory"
    case sourceMissing = "source_missing"
    case samePath = "same_path"
    case parentIntoChild = "parent_into_child"
    case duplicateDestinationName = "duplicate_destination_name"
    /// A folder whose contents can't be read: it is reported as failed, the rest still pastes.
    case sourceUnreadable = "source_unreadable"
}

public struct CopyPasteAnalysisRequest: Codable, Equatable, Sendable {
    /// What every item does, but those in `cutSourcePaths`.
    public var mode: CopyPasteMode
    public var sourcePaths: [String]
    public var destinationDirectoryPath: String
    /// In a paste of items put on the clipboard some to copy and some to move (`mode` is `.copy`): the ones moved.
    /// Nil when every item goes as `mode` says.
    public var cutSourcePaths: [String]?
    /// Items that take a name of their own ("a copy.txt", as Keep Both names one) when another item of this paste
    /// has their name: two items of one name on the clipboard that the person chose to keep both of. Nil for none.
    public var renamedIfSharedSourcePaths: [String]?

    public init(
        mode: CopyPasteMode, sourcePaths: [String], destinationDirectoryPath: String, cutSourcePaths: [String]? = nil,
        renamedIfSharedSourcePaths: [String]? = nil
    ) {
        self.mode = mode
        self.sourcePaths = sourcePaths
        self.destinationDirectoryPath = destinationDirectoryPath
        self.cutSourcePaths = cutSourcePaths
        self.renamedIfSharedSourcePaths = renamedIfSharedSourcePaths
    }

    /// Whether some items are copied and others moved.
    public var isMixed: Bool { mode == .copy && !(cutSourcePaths ?? []).isEmpty }

    /// The items moved: all of them after Cut, those in `cutSourcePaths` in a mixed paste, none after Copy.
    public var movedSourcePaths: [String] {
        if mode == .cut { return sourcePaths }
        guard let cutSourcePaths, !cutSourcePaths.isEmpty else { return [] }
        // As the review matches them: a path spelled another way is the same item, and is guarded as one moved.
        let cut = Set(cutSourcePaths.map { NameKeys.Exact(NodePath.resolve($0)) })
        return sourcePaths.filter { cut.contains(NameKeys.Exact(NodePath.resolve($0))) }
    }
}

/// What each item of a paste does, looked up by its path as the disk spells it (`NameKeys.Exact`): two paths that
/// differ only in how an accented letter is stored are two items.
struct CopyPasteItemModes: Sendable {
    let mode: CopyPasteMode
    private let cut: Set<NameKeys.Exact>
    private let renamedIfShared: Set<NameKeys.Exact>

    init(mode: CopyPasteMode, cutSourcePaths: [String]?, renamedIfSharedSourcePaths: [String]?) {
        self.mode = mode
        cut = Set((cutSourcePaths ?? []).map(NameKeys.Exact.init))
        renamedIfShared = Set((renamedIfSharedSourcePaths ?? []).map(NameKeys.Exact.init))
    }

    init(_ request: CopyPasteAnalysisRequest) {
        self.init(
            mode: request.mode, cutSourcePaths: request.cutSourcePaths,
            renamedIfSharedSourcePaths: request.renamedIfSharedSourcePaths)
    }

    var isMixed: Bool { mode == .copy && !cut.isEmpty }

    func mode(of sourcePath: String) -> CopyPasteMode {
        mode == .copy && cut.contains(NameKeys.Exact(sourcePath)) ? .cut : mode
    }

    func isRenamedIfShared(_ sourcePath: String) -> Bool {
        renamedIfShared.contains(NameKeys.Exact(sourcePath))
    }
}

/// A choice made for one item in the review, overriding the policy for its kind.
public struct CopyPasteNodeOverride: Codable, Equatable, Sendable {
    public var nodeId: String
    public var action: CopyPasteChoice

    public init(nodeId: String, action: CopyPasteChoice) {
        self.nodeId = nodeId
        self.action = action
    }
}

public struct CopyPasteAnalysisIssue: Codable, Equatable, Sendable {
    public var code: CopyPastePlanIssueCode
    public var message: String
    public var sourcePath: String?
    public var destinationPath: String?

    public init(code: CopyPastePlanIssueCode, message: String, sourcePath: String?, destinationPath: String?) {
        self.code = code
        self.message = message
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public struct CopyPasteDestinationOnlySummary: Codable, Equatable, Sendable {
    /// Items (files and folders, nested ones included) found only at the destination.
    public var count: Int
    /// A few of them, relative to the existing item, top-most entries first.
    public var samplePaths: [String]

    public init(count: Int, samplePaths: [String]) {
        self.count = count
        self.samplePaths = samplePaths
    }
}

public struct CopyPasteAnalysisNode: Codable, Equatable, Sendable {
    public var id: String
    public var sourcePath: String
    public var destinationPath: String
    /// Never `.missing`.
    public var sourceKind: CopyPasteNodeKind
    public var destinationKind: CopyPasteNodeKind
    public var conflictClass: ConflictClass?
    public var sourceFingerprint: NodeFingerprint
    public var destinationFingerprint: NodeFingerprint
    public var children: [CopyPasteAnalysisNode]
    public var issueCode: CopyPastePlanIssueCode?
    public var issueMessage: String?
    public var totalNodeCount: Int
    public var conflictNodeCount: Int
    public var destinationTotalNodeCount: Int?
    /// The name "Keep Both" would give this item (conflicts only).
    public var keepBothDestinationPath: String?
    /// What exists only in the existing folder: kept by Merge, removed by Replace.
    public var destinationOnly: CopyPasteDestinationOnlySummary?
    /// Why this item can't be replaced, when Replace would destroy the item being pasted.
    public var replaceBlockedReason: String?
    /// A folder moved on its own disk to a name nothing has: renamed whole, so what is in it wasn't read
    /// (`children` is empty whatever it holds). It is never copied or merged.
    public var renameOnly: Bool
    /// A picked item of a paste that copies some items and moves others: what this one does, and everything in
    /// it. Nil when the whole paste goes as its report's `mode` says (`CopyPasteAnalysisReport.mode(of:)`).
    public var mode: CopyPasteMode?

    public init(
        id: String, sourcePath: String, destinationPath: String, sourceKind: CopyPasteNodeKind,
        destinationKind: CopyPasteNodeKind, conflictClass: ConflictClass?,
        sourceFingerprint: NodeFingerprint, destinationFingerprint: NodeFingerprint, children: [CopyPasteAnalysisNode],
        issueCode: CopyPastePlanIssueCode? = nil, issueMessage: String? = nil, totalNodeCount: Int,
        conflictNodeCount: Int, destinationTotalNodeCount: Int? = nil, keepBothDestinationPath: String? = nil,
        destinationOnly: CopyPasteDestinationOnlySummary? = nil, replaceBlockedReason: String? = nil,
        renameOnly: Bool = false, mode: CopyPasteMode? = nil
    ) {
        self.mode = mode
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.destinationKind = destinationKind
        self.conflictClass = conflictClass
        self.sourceFingerprint = sourceFingerprint
        self.destinationFingerprint = destinationFingerprint
        self.children = children
        self.issueCode = issueCode
        self.issueMessage = issueMessage
        self.totalNodeCount = totalNodeCount
        self.conflictNodeCount = conflictNodeCount
        self.destinationTotalNodeCount = destinationTotalNodeCount
        self.keepBothDestinationPath = keepBothDestinationPath
        self.destinationOnly = destinationOnly
        self.replaceBlockedReason = replaceBlockedReason
        self.renameOnly = renameOnly
    }
}

public struct CopyPasteAnalysisSummary: Codable, Equatable, Sendable {
    public var topLevelItemCount: Int
    public var totalNodeCount: Int
    /// nil when a folder renamed whole wasn't read.
    public var totalBytes: Int64?
    public var fileConflictCount: Int
    public var directoryConflictCount: Int
    public var mismatchConflictCount: Int

    public init(
        topLevelItemCount: Int, totalNodeCount: Int, totalBytes: Int64?, fileConflictCount: Int,
        directoryConflictCount: Int, mismatchConflictCount: Int
    ) {
        self.topLevelItemCount = topLevelItemCount
        self.totalNodeCount = totalNodeCount
        self.totalBytes = totalBytes
        self.fileConflictCount = fileConflictCount
        self.directoryConflictCount = directoryConflictCount
        self.mismatchConflictCount = mismatchConflictCount
    }
}

public struct CopyPasteAnalysisReport: Codable, Equatable, Sendable {
    public var analysisId: String
    public var mode: CopyPasteMode
    public var sourcePaths: [String]
    public var destinationDirectoryPath: String
    public var nodes: [CopyPasteAnalysisNode]
    public var issues: [CopyPasteAnalysisIssue]
    public var summary: CopyPasteAnalysisSummary
    /// Whether the destination volume tells names apart by letter case (default: no).
    public var destinationCaseSensitive: Bool
    /// How far apart two dates of one file can be on the disks of the items and the destination, for Replace Older
    /// (`CopyPasteChoices.newerToleranceMs`); nil when they can't be compared.
    public var newerToleranceMs: Double?
    /// In a paste that copies some items and moves others (`mode` is `.copy`): the ones moved, as the request
    /// named them. Nil when every item goes as `mode` says.
    public var cutSourcePaths: [String]?

    public init(
        analysisId: String, mode: CopyPasteMode, sourcePaths: [String], destinationDirectoryPath: String,
        nodes: [CopyPasteAnalysisNode], issues: [CopyPasteAnalysisIssue], summary: CopyPasteAnalysisSummary,
        destinationCaseSensitive: Bool = false, newerToleranceMs: Double? = nil, cutSourcePaths: [String]? = nil
    ) {
        self.newerToleranceMs = newerToleranceMs
        self.cutSourcePaths = cutSourcePaths
        self.analysisId = analysisId
        self.mode = mode
        self.sourcePaths = sourcePaths
        self.destinationDirectoryPath = destinationDirectoryPath
        self.nodes = nodes
        self.issues = issues
        self.summary = summary
        self.destinationCaseSensitive = destinationCaseSensitive
    }

    /// Whether some items are copied and others moved.
    public var isMixed: Bool { mode == .copy && !(cutSourcePaths ?? []).isEmpty }

    /// What a picked item does (its own mode in a mixed paste), and everything inside it.
    public func mode(of node: CopyPasteAnalysisNode) -> CopyPasteMode {
        node.mode ?? mode
    }

    /// What the item picked at `sourcePath` does: for an issue, which has no node.
    public func mode(ofSourcePath sourcePath: String) -> CopyPasteMode {
        CopyPasteItemModes(mode: mode, cutSourcePaths: cutSourcePaths, renamedIfSharedSourcePaths: nil)
            .mode(of: sourcePath)
    }
}

public struct CopyPasteRuntimeConflict: Codable, Equatable, Sendable {
    public var conflictId: String
    public var analysisId: String
    public var sourcePath: String
    public var destinationPath: String
    /// Never `.missing`.
    public var sourceKind: CopyPasteNodeKind
    public var destinationKind: CopyPasteNodeKind
    public var conflictClass: ConflictClass
    /// `.trashUnavailable`: Replace couldn't move the existing item to the Trash; "overwrite" deletes it
    /// permanently instead.
    public var reason: RuntimeConflictReason
    public var sourceFingerprint: NodeFingerprint
    public var destinationFingerprint: NodeFingerprint
    public var currentSourceFingerprint: NodeFingerprint
    public var currentDestinationFingerprint: NodeFingerprint

    public init(
        conflictId: String, analysisId: String, sourcePath: String, destinationPath: String,
        sourceKind: CopyPasteNodeKind, destinationKind: CopyPasteNodeKind, conflictClass: ConflictClass,
        reason: RuntimeConflictReason, sourceFingerprint: NodeFingerprint, destinationFingerprint: NodeFingerprint,
        currentSourceFingerprint: NodeFingerprint, currentDestinationFingerprint: NodeFingerprint
    ) {
        self.conflictId = conflictId
        self.analysisId = analysisId
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.destinationKind = destinationKind
        self.conflictClass = conflictClass
        self.reason = reason
        self.sourceFingerprint = sourceFingerprint
        self.destinationFingerprint = destinationFingerprint
        self.currentSourceFingerprint = currentSourceFingerprint
        self.currentDestinationFingerprint = currentDestinationFingerprint
    }
}

public struct CopyPasteItemResult: Codable, Equatable, Sendable {
    /// Completed, skipped, failed or cancelled, as every window and the clipboard hear of it.
    public typealias Status = WriteItemEndStatus

    public enum SkipReason: String, Codable, Sendable {
        case plannedConflictPolicy = "planned_conflict_policy"
        case runtimeConflictResolution = "runtime_conflict_resolution"
        /// Replace Older left the item there: it wasn't newer.
        case notNewer = "not_newer"
        /// Replace Older left the package there: it doesn't compare packages.
        case packageNotCompared = "package_not_compared"
        /// Replace Older left the item there: a clash of kinds, which it doesn't replace.
        case differentKind = "different_kind"
        /// Add Missing left the item there: it was already there.
        case addMissing = "add_missing"
    }

    public var sourcePath: String
    public var destinationPath: String
    /// Never `.missing`.
    public var sourceKind: CopyPasteNodeKind
    public var status: Status
    public var error: String?
    public var skipReason: SkipReason?
    /// For a folder: how many items inside it failed. A folder whose only problem is failures inside it has
    /// status "failed" and a nil error.
    public var childFailureCount: Int?
    /// In a paste that copies some items and moves others: what this item did (or was to do). Nil when the whole
    /// paste goes as its result's `mode` says.
    public var mode: CopyPasteMode?

    public init(
        sourcePath: String, destinationPath: String, sourceKind: CopyPasteNodeKind, status: Status,
        error: String?, skipReason: SkipReason? = nil, childFailureCount: Int? = nil, mode: CopyPasteMode? = nil
    ) {
        self.mode = mode
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.status = status
        self.error = error
        self.skipReason = skipReason
        self.childFailureCount = childFailureCount
    }
}

public struct CopyPasteOperationSummary: Codable, Equatable, Sendable {
    public var topLevelItemCount: Int
    public var totalItemCount: Int
    public var completedItemCount: Int
    public var failedItemCount: Int
    public var skippedItemCount: Int
    public var cancelledItemCount: Int
    public var completedByteCount: Int64
    public var totalBytes: Int64?

    public init(
        topLevelItemCount: Int, totalItemCount: Int, completedItemCount: Int, failedItemCount: Int,
        skippedItemCount: Int, cancelledItemCount: Int, completedByteCount: Int64, totalBytes: Int64?
    ) {
        self.topLevelItemCount = topLevelItemCount
        self.totalItemCount = totalItemCount
        self.completedItemCount = completedItemCount
        self.failedItemCount = failedItemCount
        self.skippedItemCount = skippedItemCount
        self.cancelledItemCount = cancelledItemCount
        self.completedByteCount = completedByteCount
        self.totalBytes = totalBytes
    }
}

public struct CopyPasteOperationResult: Equatable, Sendable {
    public var operationId: String
    public var mode: CopyPasteMode
    /// Never `.queued`, `.running` or `.awaitingResolution`.
    public var status: CopyPasteOperationStatus
    public var destinationDirectoryPath: String
    public var startedAt: Date
    public var finishedAt: Date
    public var summary: CopyPasteOperationSummary
    public var items: [CopyPasteItemResult]
    /// Where the items a Replace moved out of the way went in the Trash, which they changed.
    public var trashedPaths: [String]?
    /// Where the items a Replace removed (to the Trash or for good) were: another item is at each path now,
    /// so whatever pointed at the old one there no longer does.
    public var replacedPaths: [String]?
    public var error: String?
    /// What the paste did, for Undo.
    public var undoLog: UndoLog?

    public init(
        operationId: String, mode: CopyPasteMode, status: CopyPasteOperationStatus, destinationDirectoryPath: String,
        startedAt: Date, finishedAt: Date, summary: CopyPasteOperationSummary, items: [CopyPasteItemResult],
        trashedPaths: [String]? = nil, replacedPaths: [String]? = nil, error: String?, undoLog: UndoLog? = nil
    ) {
        self.operationId = operationId
        self.mode = mode
        self.status = status
        self.destinationDirectoryPath = destinationDirectoryPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.items = items
        self.trashedPaths = trashedPaths
        self.replacedPaths = replacedPaths
        self.error = error
        self.undoLog = undoLog
    }
}

public struct CopyPasteProgressEvent: Equatable, Sendable {
    public var operationId: String
    public var analysisId: String?
    public var mode: CopyPasteMode
    public var status: CopyPasteOperationStatus
    public var completedItemCount: Int
    public var totalItemCount: Int
    public var completedByteCount: Int64
    public var totalBytes: Int64?
    public var currentSourcePath: String?
    public var currentDestinationPath: String?
    public var runtimeConflict: CopyPasteRuntimeConflict?
    public var result: CopyPasteOperationResult?
    /// The paste has copied all it will and is still running: it writes the copies of a move to another disk out to
    /// that disk, then removes their originals (see removeOriginalsLeftToTheEnd). Sent once, before that begins.
    public var finishing: Bool

    public init(
        operationId: String, analysisId: String?, mode: CopyPasteMode, status: CopyPasteOperationStatus,
        completedItemCount: Int, totalItemCount: Int, completedByteCount: Int64, totalBytes: Int64?,
        currentSourcePath: String?, currentDestinationPath: String?, runtimeConflict: CopyPasteRuntimeConflict?,
        result: CopyPasteOperationResult?, finishing: Bool = false
    ) {
        self.finishing = finishing
        self.operationId = operationId
        self.analysisId = analysisId
        self.mode = mode
        self.status = status
        self.completedItemCount = completedItemCount
        self.totalItemCount = totalItemCount
        self.completedByteCount = completedByteCount
        self.totalBytes = totalBytes
        self.currentSourcePath = currentSourcePath
        self.currentDestinationPath = currentDestinationPath
        self.runtimeConflict = runtimeConflict
        self.result = result
    }
}

public struct CopyPasteOperationHandle: Codable, Equatable, Sendable {
    public var operationId: String
    /// Always `.queued`.
    public var status: CopyPasteOperationStatus
}

public enum WriteServiceMessages {
    public static let writeOperationBusy = "Another write operation is already running."
    /// A copy, move or drop refused while another window's is still being checked.
    public static let analysisBusy = "Another window is checking items to copy or move. Try again when it has finished."
}

extension CopyPastePolicy {
    /// What a paste does without a review: whatever is already at the destination is left alone.
    public static let defaultCopyPaste = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
}
