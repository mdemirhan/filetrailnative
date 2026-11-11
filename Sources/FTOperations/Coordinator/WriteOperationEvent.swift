import FTFoundation
import Foundation

/// A write operation's status: the same as a paste's.
public typealias WriteOperationStatus = CopyPasteOperationStatus

extension CopyPasteOperationStatus {
    /// It finished, failed, stopped or partly worked.
    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled || self == .partial
    }
}

/// An item of a finished operation, as a window hears of it.
public struct WriteOperationItem: WrittenItem, Equatable, Sendable {
    public var sourcePath: String?
    public var destinationPath: String?
    public var status: CopyPasteItemResult.Status
    public var error: String?
    public var skipReason: CopyPasteItemResult.SkipReason?
    /// It couldn't go to the Trash because its disk has none: it can only be deleted immediately.
    public var noTrash: Bool
    /// For a folder: how many items inside it failed.
    public var childFailureCount: Int?
    /// A completed item with something to know about it: `error` says what.
    public var note: Bool

    public init(
        sourcePath: String?, destinationPath: String?, status: CopyPasteItemResult.Status, error: String? = nil,
        skipReason: CopyPasteItemResult.SkipReason? = nil, noTrash: Bool = false, childFailureCount: Int? = nil,
        note: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.error = error
        self.skipReason = skipReason
        self.noTrash = noTrash
        self.childFailureCount = childFailureCount
        self.note = note
    }

    /// A paste's item, without what only the copy engine uses.
    public init(_ item: CopyPasteItemResult) {
        self.init(
            sourcePath: item.sourcePath, destinationPath: item.destinationPath, status: item.status, error: item.error,
            skipReason: item.skipReason, childFailureCount: item.childFailureCount)
    }

    /// The item as `WriteEffects` looks at it.
    public var effect: WriteEffectItem {
        WriteEffectItem(sourcePath: sourcePath, destinationPath: destinationPath, status: status)
    }
}

/// How an operation ended, as a window hears of it (`WriteOperationResult`).
public struct WriteOperationResult: Equatable, Sendable {
    public var operationId: String
    public var action: WriteOperationAction
    /// A paste's: whether it copied the items or moved them (a paste after Cut).
    public var mode: CopyPasteMode?
    public var status: WriteOperationStatus
    public var targetPath: String?
    public var startedAt: Date
    public var finishedAt: Date
    public var summary: CopyPasteOperationSummary
    public var items: [WriteOperationItem]
    /// Where the items a Replace moved out of the way went in the Trash.
    public var trashedPaths: [String]?
    /// Where the items a Replace removed were: another item is at each path now.
    public var replacedPaths: [String]?
    public var error: String?

    public init(
        operationId: String, action: WriteOperationAction, mode: CopyPasteMode? = nil, status: WriteOperationStatus,
        targetPath: String?, startedAt: Date, finishedAt: Date, summary: CopyPasteOperationSummary,
        items: [WriteOperationItem], trashedPaths: [String]? = nil, replacedPaths: [String]? = nil, error: String?
    ) {
        self.operationId = operationId
        self.action = action
        self.mode = mode
        self.status = status
        self.targetPath = targetPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.items = items
        self.trashedPaths = trashedPaths
        self.replacedPaths = replacedPaths
        self.error = error
    }

    /// `pathsChangedByWrite`: what the operation changed, outermost paths only.
    public var changedPaths: [String] {
        WriteEffects.pathsChangedByWrite(
            targetPath: targetPath, items: items.map { ($0.sourcePath, $0.destinationPath) },
            trashedPaths: trashedPaths ?? [])
    }

    /// The items the windows other than the operation's own need (`itemsForOtherWindows`).
    public var itemsForOtherWindows: [WriteOperationItem] {
        let indexed = items.enumerated().map { IndexedItem(index: $0.offset, item: $0.element) }
        return WriteEffects.itemsForOtherWindows(action: action, targetPath: targetPath, items: indexed)
            .map { items[$0.index] }
    }

    private struct IndexedItem: WrittenItem {
        var index: Int
        var item: WriteOperationItem
        var sourcePath: String? { item.sourcePath }
        var destinationPath: String? { item.destinationPath }
        var status: WriteItemEndStatus { item.status }
    }
}

/// How a running operation is doing, as every window hears it.
public struct WriteOperationEvent: Equatable, Sendable {
    public var operationId: String
    public var action: WriteOperationAction
    public var status: WriteOperationStatus
    public var completedItemCount: Int
    public var totalItemCount: Int
    public var completedByteCount: Int64
    public var totalBytes: Int64?
    public var currentSourcePath: String?
    public var currentDestinationPath: String?
    /// The question the operation waits on (`awaiting_resolution`).
    public var runtimeConflict: CopyPasteRuntimeConflict?
    /// How it ended, with its last event.
    public var result: WriteOperationResult?

    public init(
        operationId: String, action: WriteOperationAction, status: WriteOperationStatus, completedItemCount: Int = 0,
        totalItemCount: Int = 0, completedByteCount: Int64 = 0, totalBytes: Int64? = nil,
        currentSourcePath: String? = nil, currentDestinationPath: String? = nil,
        runtimeConflict: CopyPasteRuntimeConflict? = nil, result: WriteOperationResult? = nil
    ) {
        self.operationId = operationId
        self.action = action
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

    /// The window's view of a write service event.
    public static func of(_ event: CopyPasteProgressEvent, action: WriteOperationAction) -> WriteOperationEvent {
        let result = event.result.map { result in
            WriteOperationResult(
                operationId: result.operationId, action: action, mode: result.mode, status: result.status,
                targetPath: result.destinationDirectoryPath, startedAt: result.startedAt, finishedAt: result.finishedAt,
                summary: result.summary, items: result.items.map(WriteOperationItem.init),
                trashedPaths: result.trashedPaths, replacedPaths: result.replacedPaths, error: result.error)
        }
        return WriteOperationEvent(
            operationId: event.operationId, action: action, status: event.status,
            completedItemCount: event.completedItemCount, totalItemCount: event.totalItemCount,
            completedByteCount: event.completedByteCount, totalBytes: event.totalBytes,
            currentSourcePath: event.currentSourcePath, currentDestinationPath: event.currentDestinationPath,
            runtimeConflict: event.runtimeConflict, result: result)
    }

    /// `forOtherWindows`: all of it but the result's items those windows don't need.
    public var forOtherWindows: WriteOperationEvent {
        guard var result else { return self }
        result.items = result.itemsForOtherWindows
        var event = self
        event.result = result
        return event
    }
}

/// An operation handed to a window because the one that started it closed (`WriteOperationAdoption`): its latest
/// progress (nil before any was reported; its end, when it ended before the window heard of it), and the cut it
/// clears from the clipboard when it is done.
public struct WriteOperationAdoption: Equatable, Sendable {
    public var operationId: String
    public var event: WriteOperationEvent?
    public var clearsCutClipboard: String?

    public init(operationId: String, event: WriteOperationEvent?, clearsCutClipboard: String? = nil) {
        self.operationId = operationId
        self.event = event
        self.clearsCutClipboard = clearsCutClipboard
    }
}
