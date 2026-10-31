// Port of the words and the choice handling of apps/desktop/src/renderer/components/CopyPasteReviewDialog.tsx
// (title, message, primaryLabel, the footer note, the single-conflict alert and setChoice)
import Foundation

/// What the review sheet says for its choices.
public struct ReviewSheetText: Equatable, Sendable {
    public var title: String
    public var message: String
    /// "Paste", or "Replace 2 and Paste" once something is replaced.
    public var primaryLabel: String
    /// Something is replaced: the primary button is red, Return doesn't start, and the note warns.
    public var replacing: Bool
    /// A folder is merged into one already there, which can't be undone.
    public var merging: Bool
    /// The footer note.
    public var note: String
    /// Whether the note is the warning, with its glyph.
    public var noteIsWarning: Bool
    /// "Adds", or "Moves" for a move: what a new row says on its right.
    public var addsLabel: String
    /// The new top-level items, for "Show N new items".
    public var showNewItemsLabel: String?
    /// The sheet lists conflicts and has the "For all conflicts" bar.
    public var hasConflicts: Bool

    public init(_ report: ReviewReport, action: CopyLikeAction, summary: ReviewSummary) {
        let verb = CopyPasteReview.actionVerb(action, mode: report.mode)
        let destination = CopyPasteReview.leafName(report.destinationDirectoryPath)
        let hasConflicts = summary.conflictTopLevelCount > 0
        self.hasConflicts = hasConflicts
        let conflicts = summary.conflictTopLevelCount
        if hasConflicts {
            if summary.topLevelCount == 1 {
                let name = CopyPasteReview.leafName(report.nodes.first?.sourcePath ?? "")
                title = "\u{201C}\(name)\u{201D} already exists in \u{201C}\(destination)\u{201D}"
            } else {
                let items = ReviewCount.pluralize(summary.topLevelCount, "item")
                let exist = conflicts == 1 ? "exists" : "exist"
                title =
                    "\(ReviewCount.format(conflicts)) of \(items) already \(exist) in \u{201C}\(destination)\u{201D}"
            }
        } else {
            title =
                "\(verb) \(ReviewCount.pluralize(summary.topLevelCount, "item")) into \u{201C}\(destination)\u{201D}?"
        }
        let addedVerb = verb == "Move" ? "moved" : "added"
        if hasConflicts {
            let lead = "Nothing is replaced unless you choose Replace."
            if summary.newTopLevelCount > 0 {
                let other =
                    summary.newTopLevelCount == 1
                    ? "The other item will be \(addedVerb)."
                    : "The other \(ReviewCount.pluralize(summary.newTopLevelCount, "item")) will be \(addedVerb)."
                message = "\(lead) \(other)"
            } else {
                message = lead
            }
        } else {
            message =
                "This is a large operation (\(ReviewCount.pluralize(report.summary.totalNodeCount, "item")) in total)."
        }
        replacing = summary.replaced > 0
        merging = summary.merged > 0
        primaryLabel = replacing ? "Replace \(ReviewCount.format(summary.replaced)) and \(verb)" : verb
        noteIsWarning = replacing || merging
        if noteIsWarning {
            let lead =
                replacing
                ? "\(ReviewCount.pluralize(summary.replaced, "existing item")) will be moved to the Trash"
                : CopyPasteReview.formatSummary(summary, verb: verb)
            note = ([lead] + (merging ? ["Merging can\u{2019}t be undone"] : [])).filter { !$0.isEmpty }
                .joined(separator: ". ")
        } else {
            note = CopyPasteReview.formatSummary(summary, verb: verb)
        }
        addsLabel = verb == "Move" ? "Moves" : "Adds"
        showNewItemsLabel =
            summary.newTopLevelCount > 0 ? "Show \(ReviewCount.pluralize(summary.newTopLevelCount, "new item"))" : nil
    }

    /// "Hide new items", once they are shown.
    public static let hideNewItems = "Hide new items"
    /// "For all conflicts:".
    public static let allConflictsLabel = "For all conflicts:"

    /// "Show all 1,200": the row after the first rows.
    public static func showAll(_ count: Int) -> String { "Show all \(ReviewCount.format(count))" }

    /// The one item that already exists is asked about in a plain alert, as Finder does, unless it is a folder: the
    /// sheet shows what adding to it would replace inside, item by item.
    public static func singleConflict(_ report: ReviewReport, summary: ReviewSummary) -> ReviewNode? {
        guard summary.conflictTopLevelCount > 0, summary.topLevelCount == 1, let node = report.nodes.first,
            let conflictClass = node.conflictClass, conflictClass != .directoryConflict
        else { return nil }
        return node
    }

    /// The single-conflict alert's message: nil where Replace can't be done.
    public static func singleConflictMessage(_ node: ReviewNode) -> String? {
        node.replaceBlockedReason == nil ? "Replace moves the item there to the Trash." : nil
    }

    /// A row's popup items: "Replace (reason)" where Replace can't be done, which is then disabled.
    public static func choiceTitle(_ choice: CopyPasteChoice, blockedReason: String?) -> String {
        if choice == .overwrite, let blockedReason { return "\(CopyPasteReview.label(choice)) (\(blockedReason))" }
        return CopyPasteReview.label(choice)
    }

    /// "in a/b/c": where a row deeper than the indent goes is.
    public static func folderHint(_ row: ReviewRow, maxIndentDepth: Int) -> String? {
        guard row.depth > maxIndentDepth else { return nil }
        let folder = CopyPasteReview.dirname("/\(row.relativePath)")
        return "in \(JSString.string(Array(folder.utf16).dropFirst()))"
    }
}

extension CopyPasteReview {
    /// `setChoice`: a row's choice. One that matches "For all conflicts" isn't a separate choice for the item; one made
    /// for an item Replace can't take is always kept, as "For all" may only match it because the safe choice stands in
    /// for Replace there.
    public static func overrides(
        setting choice: CopyPasteChoice, for node: ReviewNode, policy: CopyPastePolicy, overrides: ReviewOverrides
    ) -> ReviewOverrides {
        var next = overrides
        if node.replaceBlockedReason == nil, effectiveChoice(node, policy, [:]) == choice {
            next[node.id] = nil
        } else {
            next[node.id] = choice
        }
        return next
    }
}
