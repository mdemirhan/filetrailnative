// Port of getWriteOperationTitle, getWriteOperationProgressPercent and formatWriteOperationByteLabel
// (apps/desktop/src/renderer/components/AppDialogs.tsx) and the props of CopyPasteProgressCard.tsx
import Foundation

/// `WriteOperationAction`.
public enum WriteOperationAction: String, Sendable, CaseIterable, Equatable {
    case paste
    case copyTo = "copy_to"
    case moveTo = "move_to"
    case duplicate, trash
    case deleteImmediately = "delete_immediately"
    case rename
    case newFolder = "new_folder"
    case batchRename = "batch_rename"
    case undo, redo
}

/// Where a running operation is (`WriteOperationCardState["stage"]`).
public enum WriteOperationStage: String, Sendable, Equatable {
    case starting, queued, running, analyzing
    case awaitingResolution = "awaiting_resolution"
}

/// What the card shows of a running operation (`WriteOperationCardState`).
public struct WriteOperationCardState: Equatable, Sendable {
    public var action: WriteOperationAction
    public var stage: WriteOperationStage
    public var targetPath: String?
    public var completedItemCount: Int
    public var totalItemCount: Int
    public var completedByteCount: Int64
    public var totalBytes: Int64?
    public var currentSourcePath: String?

    public init(
        action: WriteOperationAction, stage: WriteOperationStage, targetPath: String? = nil,
        completedItemCount: Int = 0, totalItemCount: Int = 0, completedByteCount: Int64 = 0, totalBytes: Int64? = nil,
        currentSourcePath: String? = nil
    ) {
        self.action = action
        self.stage = stage
        self.targetPath = targetPath
        self.completedItemCount = completedItemCount
        self.totalItemCount = totalItemCount
        self.completedByteCount = completedByteCount
        self.totalBytes = totalBytes
        self.currentSourcePath = currentSourcePath
    }
}

/// The words of the card: its title, percent, current item and meta line.
public struct ProgressCardText: Equatable, Sendable {
    public var title: String
    public var percent: Double
    public var metaStart: String
    public var metaEnd: String
    public var detailLabel: String
    public var detailValue: String

    /// The title as "100%" is shown: rounded, clamped to 0...100.
    public var percentLabel: String { "\(Int(min(100, max(0, percent)).rounded(.toNearestOrAwayFromZero)))%" }

    /// "Moving to Trash…" while it runs; "Move to Trash" afterwards (`phase` result).
    public static func title(_ action: WriteOperationAction, result: Bool = false) -> String {
        let pair: (String, String)
        switch action {
        case .moveTo: pair = ("Moving…", "Move")
        case .copyTo: pair = ("Copying…", "Copy")
        case .duplicate: pair = ("Duplicating…", "Duplicate")
        case .trash: pair = ("Moving to Trash…", "Move to Trash")
        case .deleteImmediately: pair = ("Deleting…", "Delete Immediately")
        case .rename, .batchRename: pair = ("Renaming…", "Rename")
        case .newFolder: pair = ("Creating Folder…", "New Folder")
        case .undo: pair = ("Undoing…", "Undo")
        case .redo: pair = ("Redoing…", "Redo")
        case .paste: pair = ("Pasting…", "Paste")
        }
        return result ? pair.1 : pair.0
    }

    /// `getWriteOperationProgressPercent`.
    public static func percent(_ state: WriteOperationCardState) -> Double {
        if let total = state.totalBytes, total > 0 {
            return Double(state.completedByteCount) / Double(total) * 100
        }
        if state.totalItemCount <= 0 {
            return state.stage == .starting || state.stage == .analyzing ? 4 : 0
        }
        return Double(state.completedItemCount) / Double(state.totalItemCount) * 100
    }

    /// `formatWriteOperationByteLabel`.
    public static func byteLabel(_ state: WriteOperationCardState) -> String {
        if let total = state.totalBytes {
            return "\(SizeText.size(state.completedByteCount)) of \(SizeText.size(total))"
        }
        switch state.stage {
        case .starting, .analyzing: return "Preparing…"
        case .queued: return "Waiting to start"
        case .awaitingResolution: return "Waiting for your answer"
        case .running: return "Working…"
        }
    }

    /// `pluralize(count, "item")`.
    static func items(_ count: Int) -> String {
        "\(ContextMenuRules.groupedCount(count)) item\(count == 1 ? "" : "s")"
    }

    public init(_ state: WriteOperationCardState, currentPath: String) {
        title = Self.title(state.action)
        percent = Self.percent(state)
        metaStart =
            "\(ContextMenuRules.groupedCount(state.completedItemCount)) of \(Self.items(max(state.totalItemCount, 0)))"
        metaEnd = Self.byteLabel(state)
        detailLabel = state.action == .newFolder ? "Destination" : "Current item"
        let path = state.currentSourcePath ?? state.targetPath ?? currentPath
        detailValue = Self.leafName(path)
    }

    /// `leafName`: the last part of the path, the path itself for the top of the disk.
    public static func leafName(_ path: String) -> String {
        let trimmed = path.count > 1 ? String(path.reversed().drop(while: { $0 == "/" }).reversed()) : path
        guard let slash = trimmed.lastIndex(of: "/"), trimmed.count > 1 else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
