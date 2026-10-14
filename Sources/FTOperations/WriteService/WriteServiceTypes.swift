// Port of packages/core/src/fs/writeServiceTypes.ts (the types the review, the policy and the write service share;
// WriteServiceStats and the reading calls are in Identity/WriteServiceStats.swift)
import FTFoundation
import Foundation

public enum CopyPasteMode: String, Codable, Sendable {
    case copy, cut
}

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

public enum CopyPastePlanWarningCode: String, Codable, Sendable {
    case largeBatch = "large_batch"
    case cutRequiresDelete = "cut_requires_delete"
}

public enum CopyPasteAnalysisJobStatus: String, Codable, Sendable {
    case queued, analyzing, complete, cancelled, error
}

public enum CopyPasteAnalysisNodeDisposition: String, Codable, Sendable {
    case new, conflict, blocked
}

public struct CopyPasteAnalysisRequest: Codable, Equatable, Sendable {
    public var mode: CopyPasteMode
    public var sourcePaths: [String]
    public var destinationDirectoryPath: String

    public init(mode: CopyPasteMode, sourcePaths: [String], destinationDirectoryPath: String) {
        self.mode = mode
        self.sourcePaths = sourcePaths
        self.destinationDirectoryPath = destinationDirectoryPath
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

public struct CopyPasteExecutionRequest: Codable, Equatable, Sendable {
    public var analysisId: String
    public var policy: CopyPastePolicy
    public var overrides: [CopyPasteNodeOverride]?

    public init(analysisId: String, policy: CopyPastePolicy, overrides: [CopyPasteNodeOverride]? = nil) {
        self.analysisId = analysisId
        self.policy = policy
        self.overrides = overrides
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

public struct CopyPasteAnalysisWarning: Codable, Equatable, Sendable {
    public var code: CopyPastePlanWarningCode
    public var message: String

    public init(code: CopyPastePlanWarningCode, message: String) {
        self.code = code
        self.message = message
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
    public var disposition: CopyPasteAnalysisNodeDisposition
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

    public init(
        id: String, sourcePath: String, destinationPath: String, sourceKind: CopyPasteNodeKind,
        destinationKind: CopyPasteNodeKind, disposition: CopyPasteAnalysisNodeDisposition, conflictClass: ConflictClass?,
        sourceFingerprint: NodeFingerprint, destinationFingerprint: NodeFingerprint, children: [CopyPasteAnalysisNode],
        issueCode: CopyPastePlanIssueCode? = nil, issueMessage: String? = nil, totalNodeCount: Int,
        conflictNodeCount: Int, destinationTotalNodeCount: Int? = nil, keepBothDestinationPath: String? = nil,
        destinationOnly: CopyPasteDestinationOnlySummary? = nil, replaceBlockedReason: String? = nil,
        renameOnly: Bool = false
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.destinationKind = destinationKind
        self.disposition = disposition
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
    public var blockedCount: Int

    public init(
        topLevelItemCount: Int, totalNodeCount: Int, totalBytes: Int64?, fileConflictCount: Int,
        directoryConflictCount: Int, mismatchConflictCount: Int, blockedCount: Int
    ) {
        self.topLevelItemCount = topLevelItemCount
        self.totalNodeCount = totalNodeCount
        self.totalBytes = totalBytes
        self.fileConflictCount = fileConflictCount
        self.directoryConflictCount = directoryConflictCount
        self.mismatchConflictCount = mismatchConflictCount
        self.blockedCount = blockedCount
    }
}

public struct CopyPasteAnalysisReport: Codable, Equatable, Sendable {
    public var analysisId: String
    public var mode: CopyPasteMode
    public var sourcePaths: [String]
    public var destinationDirectoryPath: String
    public var nodes: [CopyPasteAnalysisNode]
    public var issues: [CopyPasteAnalysisIssue]
    public var warnings: [CopyPasteAnalysisWarning]
    public var summary: CopyPasteAnalysisSummary
    /// Whether the destination volume tells names apart by letter case (default: no).
    public var destinationCaseSensitive: Bool

    public init(
        analysisId: String, mode: CopyPasteMode, sourcePaths: [String], destinationDirectoryPath: String,
        nodes: [CopyPasteAnalysisNode], issues: [CopyPasteAnalysisIssue], warnings: [CopyPasteAnalysisWarning],
        summary: CopyPasteAnalysisSummary, destinationCaseSensitive: Bool = false
    ) {
        self.analysisId = analysisId
        self.mode = mode
        self.sourcePaths = sourcePaths
        self.destinationDirectoryPath = destinationDirectoryPath
        self.nodes = nodes
        self.issues = issues
        self.warnings = warnings
        self.summary = summary
        self.destinationCaseSensitive = destinationCaseSensitive
    }
}

public struct CopyPasteAnalysisStartHandle: Codable, Equatable, Sendable {
    public var analysisId: String
    /// `.queued` or `.analyzing`.
    public var status: CopyPasteAnalysisJobStatus
}

public struct CopyPasteAnalysisUpdate: Codable, Equatable, Sendable {
    public var analysisId: String
    public var status: CopyPasteAnalysisJobStatus
    public var done: Bool
    public var report: CopyPasteAnalysisReport?
    public var error: String?
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
    public enum Status: String, Codable, Sendable {
        case completed, skipped, failed, cancelled
    }

    public enum SkipReason: String, Codable, Sendable {
        case plannedConflictPolicy = "planned_conflict_policy"
        case runtimeConflictResolution = "runtime_conflict_resolution"
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

    public init(
        sourcePath: String, destinationPath: String, sourceKind: CopyPasteNodeKind, status: Status,
        error: String?, skipReason: SkipReason? = nil, childFailureCount: Int? = nil
    ) {
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

    public init(
        operationId: String, analysisId: String?, mode: CopyPasteMode, status: CopyPasteOperationStatus,
        completedItemCount: Int, totalItemCount: Int, completedByteCount: Int64, totalBytes: Int64?,
        currentSourcePath: String?, currentDestinationPath: String?, runtimeConflict: CopyPasteRuntimeConflict?,
        result: CopyPasteOperationResult?
    ) {
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
    public static let analysisBusy = "Another copy/paste analysis is already running."
}

extension CopyPastePolicy {
    /// What a paste does without a review: whatever is already at the destination is left alone.
    public static let defaultCopyPaste = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
}
