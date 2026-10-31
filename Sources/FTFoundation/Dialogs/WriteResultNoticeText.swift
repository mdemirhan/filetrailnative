// Port of buildCopyPasteResultMessage and buildCopyPasteResultDetailLines (apps/desktop/src/renderer/components/
// AppDialogs.tsx:548-605): the words of the alert a finished operation shows when it is not the result sheet
import Foundation

/// How an operation ended, as far as its result alert says it.
public struct WriteResultNoticeInput: Equatable, Sendable {
    public var error: String?
    public var totalItemCount: Int
    public var completedItemCount: Int
    public var failedItemCount: Int
    public var skippedItemCount: Int
    public var cancelledItemCount: Int
    /// Each item's reason, in order.
    public var itemErrors: [String?]

    public init(
        error: String?, totalItemCount: Int, completedItemCount: Int, failedItemCount: Int, skippedItemCount: Int,
        cancelledItemCount: Int, itemErrors: [String?]
    ) {
        self.error = error
        self.totalItemCount = totalItemCount
        self.completedItemCount = completedItemCount
        self.failedItemCount = failedItemCount
        self.skippedItemCount = skippedItemCount
        self.cancelledItemCount = cancelledItemCount
        self.itemErrors = itemErrors
    }
}

public enum WriteResultNoticeText {
    /// Whether the action's result is the result sheet (`CopyPasteResultDialog`: the copy-like actions, batch rename,
    /// Undo and Redo) rather than this alert.
    public static func hasResultSheet(_ action: WriteOperationAction) -> Bool {
        switch action {
        case .paste, .copyTo, .moveTo, .duplicate, .batchRename, .undo, .redo: true
        case .trash, .deleteImmediately, .rename, .newFolder: false
        }
    }

    /// `buildCopyPasteResultMessage`: the operation's own error, else what became of the items.
    public static func message(_ result: WriteResultNoticeInput?) -> String {
        guard let result else { return "Finished." }
        if let error = result.error, !error.isEmpty { return error }
        // Stopped part way is never told as done.
        if result.cancelledItemCount > 0 { return "Stopped before every item was done." }
        if result.skippedItemCount > 0, result.completedItemCount == 0, result.failedItemCount == 0 {
            return "Nothing was changed: every item was skipped."
        }
        if result.failedItemCount > 0 { return "Some items couldn\u{2019}t be changed." }
        return "Done."
    }

    /// `buildCopyPasteResultDetailLines`: the counts, for several items only, then up to 3 reasons, each once and not
    /// the one the message already gives.
    public static func detailLines(_ result: WriteResultNoticeInput?) -> [String] {
        guard let result else { return [] }
        var lines: [String] = []
        if result.totalItemCount > 1 {
            let done = ContextMenuRules.groupedCount(result.completedItemCount)
            lines.append("\(done) of \(ProgressCardText.items(result.totalItemCount)) done")
            if result.failedItemCount > 0 { lines.append("\(ProgressCardText.items(result.failedItemCount)) failed") }
            if result.skippedItemCount > 0 {
                lines.append("\(ProgressCardText.items(result.skippedItemCount)) skipped")
            }
            if result.cancelledItemCount > 0 {
                lines.append("\(ProgressCardText.items(result.cancelledItemCount)) not done")
            }
        }
        let message = message(result)
        var reasons: [String] = []
        for case let error? in result.itemErrors where !error.isEmpty && error != message && !reasons.contains(error) {
            reasons.append(error)
        }
        lines.append(contentsOf: reasons.prefix(3))
        return lines
    }
}
