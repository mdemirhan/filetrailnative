// Port of apps/desktop/src/renderer/components/CopyPasteResultDialog.tsx (the words, summarizeResultItems,
// displayPath, findAncestor) and collectRetrySourcePaths (apps/desktop/src/renderer/lib/explorerAppUtils.ts:146)
import Foundation

/// An item of a finished operation, as the result sheet reads it.
public struct ResultItem: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case completed, skipped, failed, cancelled
    }

    public var sourcePath: String?
    public var destinationPath: String?
    public var status: Status
    public var error: String?
    /// "runtime_conflict_resolution" for an item skipped after it changed during the operation.
    public var skippedAfterChange: Bool
    public var childFailureCount: Int?
    public var note: Bool

    public init(
        sourcePath: String?, destinationPath: String?, status: Status, error: String? = nil,
        skippedAfterChange: Bool = false, childFailureCount: Int? = nil, note: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.status = status
        self.error = error
        self.skippedAfterChange = skippedAfterChange
        self.childFailureCount = childFailureCount
        self.note = note
    }

    /// `isFolderWithFailuresInside`: a folder whose only problem is that some items inside it failed. It was copied,
    /// just not completely, and the items inside are listed (and counted) on their own.
    var isFolderWithFailuresInside: Bool {
        status == .failed && error == nil && (childFailureCount ?? 0) > 0
    }
}

/// A section of the result sheet (`ResultSection`): its title, and its rows (the first 200, then "and N more").
public struct ResultSectionText: Equatable, Sendable {
    public enum Tone: String, Sendable {
        case danger, muted
    }

    public struct Row: Equatable, Sendable {
        public var path: String
        public var detail: String
    }

    public var label: String
    public var tone: Tone
    public var rows: [Row]
    /// "and N more", when more than the rows shown.
    public var more: String?
}

/// What the result sheet says.
public struct CopyPasteResultText: Equatable, Sendable {
    /// `SECTION_ROW_LIMIT`: a result with tens of thousands of problems lists the first ones and says how many more.
    public static let sectionRowLimit = 200

    public var title: String
    public var message: String
    public var sections: [ResultSectionText]
    /// "Retry 2 Items" or "Try Again…"; nil when there is nothing to retry.
    public var retryLabel: String?

    /// `canRetry`: false for Undo and Redo, which are chosen again from the menu.
    public init(
        action: WriteOperationAction, targetPath: String?, error: String?, items: [ResultItem], canRetry: Bool
    ) {
        let renaming = action == .batchRename
        // An Undo's items are each on their own, each with what was found about it.
        let undoing = action == .undo || action == .redo
        let destinationName = CopyPasteReview.leafName(targetPath ?? "")
        let pastTense = Self.pastTense(action)
        let presentVerb =
            undoing
            ? (action == .undo ? "undone" : "redone") : renaming ? "renamed" : action == .moveTo ? "moved" : "copied"
        // Renamed items stay in their folder; copies and moves go into one.
        let place = destinationName.isEmpty ? "" : " \(renaming ? "in" : "into") \u{201C}\(destinationName)\u{201D}"
        let outcome = Outcome(items, eachOnItsOwn: renaming || undoing, namedByDestination: undoing)
        let retryCount = canRetry ? outcome.retryCount : 0
        // A folder copied without some of its items counts as copied here; the message says what is missing.
        let copiedTopLevel = outcome.completedTopLevel + outcome.partialTopLevel.count
        if outcome.topLevelCount == 0 || (undoing && copiedTopLevel == 0) {
            title = Self.failedTitle(action)
        } else {
            title =
                "\(pastTense) \(ReviewCount.format(copiedTopLevel)) of \(ReviewCount.pluralize(outcome.topLevelCount, "item"))\(place)"
        }
        let onlyPartial = outcome.partialTopLevel.count == 1 ? outcome.partialTopLevel.first : nil
        let failedCount = outcome.failedOutside + outcome.failedInside
        let notStartedCount = outcome.notStarted.count
        let stoppedCount = outcome.stoppedPartWay.count
        let onlyStopped = stoppedCount == 1 ? outcome.stoppedPartWay.first.map { outcome.items[$0] } : nil
        let skippedCount = outcome.skipped.count
        var sentences: [String] = []
        if outcome.failedOutside > 0 {
            sentences.append(
                "\(ReviewCount.pluralize(outcome.failedOutside, "item")) couldn\u{2019}t be \(presentVerb).")
        }
        if outcome.failedInside > 0 {
            let inside =
                onlyPartial?.sourcePath.map { "\u{201C}\(CopyPasteReview.leafName($0))\u{201D}" } ?? "folders"
            sentences.append(
                "\(ReviewCount.pluralize(outcome.failedInside, "item")) inside \(inside) couldn\u{2019}t be \(presentVerb)."
            )
        }
        // A folder stopped part way isn't "not started": some of it is at the destination.
        if stoppedCount > 0 {
            let subject =
                onlyStopped?.sourcePath.map { "\u{201C}\(CopyPasteReview.leafName($0))\u{201D} was" }
                ?? "\(ReviewCount.pluralize(stoppedCount, "folder")) were"
            let into = destinationName.isEmpty ? "" : " into \u{201C}\(destinationName)\u{201D}"
            sentences.append(
                "\(subject) stopped part way: some of what is inside was \(presentVerb)\(into), the rest wasn't.")
        }
        if notStartedCount > 0 {
            let were = notStartedCount == 1 ? "wasn't" : "weren't"
            sentences.append(
                "\(ReviewCount.pluralize(notStartedCount, "item")) \(were) started because the operation was stopped.")
        }
        if skippedCount > 0 {
            sentences.append(
                "\(ReviewCount.pluralize(skippedCount, "item")) \(skippedCount == 1 ? "was" : "were") skipped.")
        }
        if action == .moveTo, failedCount + notStartedCount + stoppedCount > 0 {
            sentences.append("Items that weren't moved are still in their original folder.")
        }
        // An Undo says what it left, and that the part it did can be taken back. What failed is still on the list,
        // and the same command tries it again.
        if undoing {
            sentences = []
            let leftCount = outcome.failed.count + skippedCount
            let shortcuts = ShortcutDisplay.defaults
            if leftCount > 0 {
                let left = leftCount == 1 ? "was left as it is" : "were left as they are"
                sentences.append("\(ReviewCount.pluralize(leftCount, "item")) \(left).")
            }
            if leftCount > 0, copiedTopLevel > 0 {
                sentences.append(
                    action == .undo
                        ? "\(shortcuts.mention(.redo)) redoes what was undone."
                        : "\(shortcuts.mention(.undo)) undoes what was redone.")
            }
            if !outcome.failed.isEmpty {
                sentences.append(
                    action == .undo
                        ? "\(shortcuts.mention(.undo)) tries again what couldn\u{2019}t be undone."
                        : "\(shortcuts.mention(.redo)) tries again what couldn\u{2019}t be redone.")
            }
        }
        message = sentences.isEmpty ? (error ?? "The operation has finished.") : sentences.joined(separator: " ")

        let failedVerb =
            undoing ? action.rawValue : renaming ? "rename" : action == .moveTo ? "move" : "copy"
        func section(
            _ label: String, _ indexes: [Int], _ tone: ResultSectionText.Tone, _ describe: (ResultItem) -> String
        ) -> ResultSectionText? {
            guard !indexes.isEmpty else { return nil }
            let shown = indexes.prefix(Self.sectionRowLimit)
            let more = indexes.count - shown.count
            return ResultSectionText(
                label: label, tone: tone,
                rows: shown.map {
                    ResultSectionText.Row(path: outcome.displayPath($0), detail: describe(outcome.items[$0]))
                },
                more: more > 0 ? "and \(ReviewCount.format(more)) more" : nil)
        }
        sections = [
            section("Couldn\u{2019}t \(failedVerb)", outcome.failed, .danger) { item in
                item.isFolderWithFailuresInside
                    ? "\(ReviewCount.pluralize(item.childFailureCount ?? 0, "item")) inside couldn\u{2019}t be \(presentVerb)"
                    : (item.error ?? "Unknown error.")
            },
            section("Stopped part way", outcome.stoppedPartWay, .muted) { _ in
                "Some of what is inside was \(presentVerb) before the stop."
            },
            // A rename's item put back under another name says which.
            section("Not started", outcome.notStarted, .muted) { item in
                if renaming, item.destinationPath != nil, let error = item.error, !error.isEmpty { return error }
                return "The operation was stopped first."
            },
            section("Note", outcome.notes, .muted) { $0.error ?? "" },
            section(undoing ? "Left as it is" : "Skipped", outcome.skipped, .muted) { item in
                if undoing { return item.error ?? "Left as it is" }
                if renaming { return item.error ?? "Its new name was taken" }
                return item.skippedAfterChange
                    ? "Skipped after it changed during the operation" : "Already existed \u{B7} you chose Skip"
            },
        ].compactMap { $0 }
        // A rename is tried again from the sheet, with its names worked out anew.
        if retryCount > 0 || (renaming && !outcome.skipped.isEmpty && canRetry) {
            retryLabel = renaming ? "Try Again\u{2026}" : "Retry \(ReviewCount.pluralize(retryCount, "Item"))"
        } else {
            retryLabel = nil
        }
    }

    /// `PAST_TENSE`.
    private static func pastTense(_ action: WriteOperationAction) -> String {
        switch action {
        case .undo: "Undid"
        case .redo: "Redid"
        case .paste: "Pasted"
        case .copyTo: "Copied"
        case .moveTo: "Moved"
        case .duplicate: "Duplicated"
        case .batchRename: "Renamed"
        default: "Finished"
        }
    }

    /// `FAILED_TITLE`.
    private static func failedTitle(_ action: WriteOperationAction) -> String {
        switch action {
        case .undo: "Couldn\u{2019}t Undo"
        case .redo: "Couldn\u{2019}t Redo"
        case .paste: "Paste failed"
        case .copyTo: "Copy failed"
        case .moveTo: "Move failed"
        case .duplicate: "Duplicate failed"
        case .batchRename: "Rename failed"
        default: "Failed"
        }
    }

    /// `collectRetrySourcePaths`: failures and items that never started, top-level only; an item inside a folder is
    /// retried by retrying that folder, never pasted on its own at the destination root.
    public static func retrySourcePaths(_ items: [ResultItem]) -> [String] {
        var seen = Set<[UInt16]>()
        var paths: [String] = []
        for item in PasteDestination.topLevelItems(items, path: \.sourcePath) {
            guard let path = item.sourcePath, item.status == .failed || item.status == .cancelled else { continue }
            if seen.insert(Array(path.utf16)).inserted { paths.append(path) }
        }
        return paths
    }
}

/// `summarizeResultItems`: what became of the items, by top-level item, each item by its position. Top-level items
/// come from a set lookup of each item's ancestors, so results with tens of thousands of items stay fast. With
/// `eachOnItsOwn` (a rename of several, an Undo) every item is one of those asked for.
private struct Outcome {
    let items: [ResultItem]
    var topLevelCount = 0
    var completedTopLevel = 0
    /// Top-level folders copied without some of the items inside.
    var partialTopLevel: [ResultItem] = []
    /// Items that failed themselves, outside / inside folders with failures inside.
    var failedOutside = 0
    var failedInside = 0
    var failed: [Int] = []
    /// Top-level folders stopped with some of what is inside already done.
    var stoppedPartWay: [Int] = []
    var notStarted: [Int] = []
    var skipped: [Int] = []
    /// Items done, with something to know about them.
    var notes: [Int] = []
    var retryCount = 0
    private var paths: [String] = []

    init(_ items: [ResultItem], eachOnItsOwn: Bool, namedByDestination: Bool) {
        self.items = items
        let indexed = items.enumerated().map { (index: $0.offset, item: $0.element) }
        let topLevel = eachOnItsOwn ? indexed : PasteDestination.topLevelItems(indexed, path: \.item.sourcePath)
        let topLevelIndexes = Set(topLevel.map(\.index))
        let topLevelPaths = Set(topLevel.compactMap { $0.item.sourcePath.map { Array($0.utf16) } })
        let partialPaths = Set(
            items.filter(\.isFolderWithFailuresInside).compactMap { $0.sourcePath.map { Array($0.utf16) } })
        topLevelCount = topLevel.count
        retryCount = CopyPasteResultText.retrySourcePaths(items).count
        // Top-level folders with something done inside them (by the items listed from inside).
        var startedFolders = Set<[UInt16]>()
        if !eachOnItsOwn {
            for item in items where item.status == .completed {
                if let path = item.sourcePath, let folder = Self.ancestor(of: path, in: topLevelPaths) {
                    startedFolders.insert(folder)
                }
            }
        }
        var stopped = Set<Int>()
        for (index, item) in topLevel {
            if item.status == .completed {
                completedTopLevel += 1
            } else if item.isFolderWithFailuresInside {
                partialTopLevel.append(item)
            } else if item.status == .cancelled, let path = item.sourcePath,
                startedFolders.contains(Array(path.utf16))
            {
                stopped.insert(index)
                stoppedPartWay.append(index)
            }
        }
        for (index, item) in indexed {
            let path = item.sourcePath
            if eachOnItsOwn {
                let named = (namedByDestination ? item.destinationPath : nil) ?? path ?? item.destinationPath ?? ""
                paths.append(CopyPasteReview.leafName(named))
            } else {
                paths.append(Self.displayPath(item, isTopLevel: topLevelIndexes.contains(index), topLevelPaths))
            }
            if item.status == .completed && item.note {
                notes.append(index)
            } else if item.status == .failed {
                failed.append(index)
                if !item.isFolderWithFailuresInside {
                    if let path, Self.ancestor(of: path, in: partialPaths) != nil {
                        failedInside += 1
                    } else {
                        failedOutside += 1
                    }
                }
            } else if item.status == .cancelled && !stopped.contains(index) {
                notStarted.append(index)
            } else if item.status == .skipped {
                skipped.append(index)
            }
        }
        // When the failed items inside aren't listed, the folders' own counts say how many.
        if failedInside == 0 {
            for folder in partialTopLevel { failedInside += folder.childFailureCount ?? 0 }
        }
    }

    func displayPath(_ index: Int) -> String { paths[index] }

    /// `displayPath`: "photos/raw/IMG_2041.dng", the path below the folder the operation started from.
    private static func displayPath(_ item: ResultItem, isTopLevel: Bool, _ topLevelPaths: Set<[UInt16]>) -> String {
        guard let path = item.sourcePath else { return CopyPasteReview.leafName(item.destinationPath ?? "") }
        guard !isTopLevel, let ancestor = ancestor(of: path, in: topLevelPaths) else {
            return CopyPasteReview.leafName(path)
        }
        var base = Array(CopyPasteReview.dirname(JSString.string(ancestor)).utf16)
        if base.last == 0x2F { base.removeLast() }
        return JSString.string(Array(path.utf16).dropFirst(base.count + 1))
    }

    /// `findAncestor`: the nearest folder above `path` that is in `candidates`.
    private static func ancestor(of path: String, in candidates: Set<[UInt16]>) -> [UInt16]? {
        var current = path
        var parent = CopyPasteReview.dirname(current)
        while !JSString.equals(parent, current) {
            let units = Array(parent.utf16)
            if candidates.contains(units) { return units }
            current = parent
            parent = CopyPasteReview.dirname(current)
        }
        return nil
    }
}
