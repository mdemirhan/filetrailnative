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
    /// Skipped by an answer given while the operation ran, after the item changed (not by the review's plan).
    public var skippedAfterChange: Bool
    /// Skipped by Replace Older: the item there was as new or newer.
    public var skippedAsNotNewer: Bool
    /// Skipped by Replace Older: a package clashing with one there, which it doesn't compare.
    public var skippedAsPackageNotCompared: Bool
    /// Skipped by Replace Older: a clash of kinds, a file where a folder of that name is or the other way round.
    public var skippedAsDifferentKind: Bool
    /// Skipped by Add Missing: it was already there.
    public var leftByAddMissing: Bool
    public var childFailureCount: Int?
    public var note: Bool

    public init(
        sourcePath: String?, destinationPath: String?, status: Status, error: String? = nil,
        skippedAfterChange: Bool = false, skippedAsNotNewer: Bool = false,
        skippedAsPackageNotCompared: Bool = false, skippedAsDifferentKind: Bool = false,
        leftByAddMissing: Bool = false, childFailureCount: Int? = nil, note: Bool = false
    ) {
        self.leftByAddMissing = leftByAddMissing
        self.skippedAsNotNewer = skippedAsNotNewer
        self.skippedAsPackageNotCompared = skippedAsPackageNotCompared
        self.skippedAsDifferentKind = skippedAsDifferentKind
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

/// A section of the result sheet: its title, and its rows (the first 200, then "and N more").
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
    /// A result with tens of thousands of problems lists the first ones and says how many more.
    public static let sectionRowLimit = 200
    /// The reason an item carries when its paste ended before it because the destination disk was full. The write
    /// engine gives it to each such item, and the sheet knows them by it: a result has no code for why an item
    /// wasn't started.
    public static let notStartedDiskFull = "Not started because the destination disk is full."

    public var title: String
    public var message: String
    public var sections: [ResultSectionText]
    /// "Retry 2 Items" or "Try Again…"; nil when there is nothing to retry.
    public var retryLabel: String?

    /// `canRetry`: false for Undo and Redo, which are chosen again from the menu. `moves`: a paste that moves some
    /// or all of its items, whose items are said to be pasted, as a cut item isn't copied.
    public init(
        action: WriteOperationAction, targetPath: String?, error: String?, items: [ResultItem], canRetry: Bool,
        moves: Bool = false
    ) {
        let renaming = action == .batchRename
        // An Undo's items are each on their own, each with what was found about it.
        let undoing = action == .undo || action == .redo
        let destinationName = CopyPasteReview.leafName(targetPath ?? "")
        let pastTense = Self.pastTense(action)
        let pasteMoves = action == .paste && moves
        let presentVerb =
            undoing
            ? (action == .undo ? "undone" : "redone")
            : renaming ? "renamed" : action == .moveTo ? "moved" : pasteMoves ? "pasted" : "copied"
        // What the person chose, as a stop or an end names it: "the paste was stopped", "The Undo has finished".
        let actionName = Self.actionName(action)
        let sentenceActionName = actionName.prefix(1).uppercased() + actionName.dropFirst()
        // Renamed items stay in their folder; copies and moves go into one.
        let place = destinationName.isEmpty ? "" : " \(renaming ? "in" : "into") “\(destinationName)”"
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
                "\(ReviewCount.pluralize(outcome.failedOutside, "item")) couldn’t be \(presentVerb).")
        }
        if outcome.failedInside > 0 {
            let inside =
                onlyPartial?.sourcePath.map { "“\(CopyPasteReview.leafName($0))”" } ?? "folders"
            sentences.append(
                "\(ReviewCount.pluralize(outcome.failedInside, "item")) inside \(inside) couldn’t be \(presentVerb)."
            )
        }
        // A folder stopped part way isn't "not started": some of it is at the destination.
        if stoppedCount > 0 {
            let subject =
                onlyStopped?.sourcePath.map { "“\(CopyPasteReview.leafName($0))” was" }
                ?? "\(ReviewCount.pluralize(stoppedCount, "folder")) were"
            let into = destinationName.isEmpty ? "" : " into “\(destinationName)”"
            sentences.append(
                "\(subject) stopped part way: some of what is inside was \(presentVerb)\(into), the rest wasn’t.")
        }
        // What a full disk left is told apart from what a Stop left: a paste the disk ended wasn't stopped by anyone.
        let diskFullCount = outcome.notStarted.filter { outcome.items[$0].error == Self.notStartedDiskFull }.count
        for (count, reason) in [
            (notStartedCount - diskFullCount, "\(actionName) was stopped"), (diskFullCount, "the disk is full"),
        ] where count > 0 {
            let were = count == 1 ? "wasn’t" : "weren’t"
            sentences.append("\(ReviewCount.pluralize(count, "item")) \(were) started because \(reason).")
        }
        if skippedCount > 0 {
            sentences.append(
                "\(ReviewCount.pluralize(skippedCount, "item")) \(skippedCount == 1 ? "was" : "were") skipped.")
        }
        if action == .moveTo, failedCount + notStartedCount + stoppedCount > 0 {
            sentences.append("Items that weren’t moved are still in their original folder.")
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
                        ? "\(shortcuts.mention(.undo)) tries again what couldn’t be undone."
                        : "\(shortcuts.mention(.redo)) tries again what couldn’t be redone.")
            }
        }
        message =
            sentences.isEmpty ? (error ?? "\(sentenceActionName) has finished.") : sentences.joined(separator: " ")

        let failedVerb =
            undoing ? action.rawValue : renaming ? "rename" : action == .moveTo ? "move" : pasteMoves ? "paste" : "copy"
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
            section("Couldn’t \(failedVerb)", outcome.failed, .danger) { item in
                item.isFolderWithFailuresInside
                    ? "\(ReviewCount.pluralize(item.childFailureCount ?? 0, "item")) inside couldn’t be \(presentVerb)"
                    : (item.error ?? "Unknown error.")
            },
            section("Stopped part way", outcome.stoppedPartWay, .muted) { _ in
                "Some of what is inside was \(presentVerb) before the stop."
            },
            // A rename's item put back under another name says which, and an item a full disk left says so.
            section("Not started", outcome.notStarted, .muted) { item in
                if renaming, item.destinationPath != nil, let error = item.error, !error.isEmpty { return error }
                if let error = item.error, error == Self.notStartedDiskFull { return error }
                return "\(sentenceActionName) was stopped first."
            },
            section("Note", outcome.notes, .muted) { $0.error ?? "" },
            section(undoing ? "Left as it is" : "Skipped", outcome.skipped, .muted) { item in
                if undoing { return item.error ?? "Left as it is" }
                if renaming { return item.error ?? "Its new name was taken" }
                if item.skippedAsNotNewer { return "Already there, as new or newer \u{B7} Replace Older left it" }
                if item.skippedAsPackageNotCompared {
                    return "Already there, a package, not compared \u{B7} Replace Older left it"
                }
                // Left by the answer for all conflicts, not by a Skip of the row's own: the person chose none.
                if item.skippedAsDifferentKind {
                    return "Already there, a different kind of item \u{B7} Replace Older left it"
                }
                // The person chose Add Missing, not Skip.
                if item.leftByAddMissing { return "Already there \u{B7} Add Missing left it" }
                return item.skippedAfterChange
                    ? "Skipped after it changed during \(actionName)" : "Already existed \u{B7} you chose Skip"
            },
        ].compactMap { $0 }
        // A rename is tried again from the sheet, with its names worked out anew.
        if retryCount > 0 || (renaming && !outcome.skipped.isEmpty && canRetry) {
            retryLabel = renaming ? "Try Again\u{2026}" : "Retry \(ReviewCount.pluralize(retryCount, "Item"))"
        } else {
            retryLabel = nil
        }
    }

    /// The action as a stop or an end names it, with its article: "the paste", "the Undo", "Duplicate".
    private static func actionName(_ action: WriteOperationAction) -> String {
        switch action {
        case .undo: "the Undo"
        case .redo: "the Redo"
        case .rename, .batchRename: "the rename"
        case .moveTo: "the move"
        case .copyTo: "the copy"
        case .duplicate: "Duplicate"
        case .convertImages: "the conversion"
        case .makeAlias: "Make Alias"
        default: "the paste"
        }
    }

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

    private static func failedTitle(_ action: WriteOperationAction) -> String {
        switch action {
        case .undo: "Couldn’t Undo"
        case .redo: "Couldn’t Redo"
        case .paste: "Paste failed"
        case .copyTo: "Copy failed"
        case .moveTo: "Move failed"
        case .duplicate: "Duplicate failed"
        case .batchRename: "Rename failed"
        default: "Failed"
        }
    }

    /// Failures and items that never started, top-level only; an item inside a folder is
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

/// What became of the items, by top-level item, each item by its position. Top-level items
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

    /// The nearest folder above `path` that is in `candidates`.
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
