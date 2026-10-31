// Port of apps/desktop/src/renderer/lib/copyPasteReview.ts
import Foundation

/// What is at a path (`CopyPasteNodeKind`).
public enum ReviewNodeKind: String, Codable, Equatable, Sendable {
    case missing, file, directory, symlink
}

/// What the review reads of an item's fingerprint.
public struct ReviewFingerprint: Codable, Equatable, Sendable {
    public var exists: Bool
    public var kind: ReviewNodeKind
    public var size: Int64?
    public var mtimeMs: Double?

    public init(exists: Bool, kind: ReviewNodeKind, size: Int64? = nil, mtimeMs: Double? = nil) {
        self.exists = exists
        self.kind = kind
        self.size = size
        self.mtimeMs = mtimeMs
    }
}

/// What exists only in the existing folder: kept by Merge, removed by Replace.
public struct ReviewDestinationOnly: Codable, Equatable, Sendable {
    public var count: Int
    public var samplePaths: [String]

    public init(count: Int, samplePaths: [String]) {
        self.count = count
        self.samplePaths = samplePaths
    }
}

/// An item of the analysis, as the review reads it (`CopyPasteAnalysisNode`). It decodes from the analysis report's
/// own JSON.
public struct ReviewNode: Codable, Equatable, Sendable {
    public var id: String
    public var sourcePath: String
    public var destinationPath: String
    public var sourceKind: ReviewNodeKind
    public var destinationKind: ReviewNodeKind
    public var conflictClass: ConflictClass?
    public var sourceFingerprint: ReviewFingerprint
    public var destinationFingerprint: ReviewFingerprint
    public var children: [ReviewNode]
    public var totalNodeCount: Int
    public var conflictNodeCount: Int
    public var destinationTotalNodeCount: Int?
    public var keepBothDestinationPath: String?
    public var destinationOnly: ReviewDestinationOnly?
    public var replaceBlockedReason: String?
    public var renameOnly: Bool

    public init(
        id: String, sourcePath: String, destinationPath: String, sourceKind: ReviewNodeKind,
        destinationKind: ReviewNodeKind, conflictClass: ConflictClass?, sourceFingerprint: ReviewFingerprint,
        destinationFingerprint: ReviewFingerprint, children: [ReviewNode] = [], totalNodeCount: Int,
        conflictNodeCount: Int, destinationTotalNodeCount: Int? = nil, keepBothDestinationPath: String? = nil,
        destinationOnly: ReviewDestinationOnly? = nil, replaceBlockedReason: String? = nil, renameOnly: Bool = false
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceKind = sourceKind
        self.destinationKind = destinationKind
        self.conflictClass = conflictClass
        self.sourceFingerprint = sourceFingerprint
        self.destinationFingerprint = destinationFingerprint
        self.children = children
        self.totalNodeCount = totalNodeCount
        self.conflictNodeCount = conflictNodeCount
        self.destinationTotalNodeCount = destinationTotalNodeCount
        self.keepBothDestinationPath = keepBothDestinationPath
        self.destinationOnly = destinationOnly
        self.replaceBlockedReason = replaceBlockedReason
        self.renameOnly = renameOnly
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            sourcePath: try values.decode(String.self, forKey: .sourcePath),
            destinationPath: try values.decode(String.self, forKey: .destinationPath),
            sourceKind: try values.decode(ReviewNodeKind.self, forKey: .sourceKind),
            destinationKind: try values.decode(ReviewNodeKind.self, forKey: .destinationKind),
            conflictClass: try values.decodeIfPresent(ConflictClass.self, forKey: .conflictClass),
            sourceFingerprint: try values.decode(ReviewFingerprint.self, forKey: .sourceFingerprint),
            destinationFingerprint: try values.decode(ReviewFingerprint.self, forKey: .destinationFingerprint),
            children: try values.decode([ReviewNode].self, forKey: .children),
            totalNodeCount: try values.decode(Int.self, forKey: .totalNodeCount),
            conflictNodeCount: try values.decode(Int.self, forKey: .conflictNodeCount),
            destinationTotalNodeCount: try values.decodeIfPresent(Int.self, forKey: .destinationTotalNodeCount),
            keepBothDestinationPath: try values.decodeIfPresent(String.self, forKey: .keepBothDestinationPath),
            destinationOnly: try values.decodeIfPresent(ReviewDestinationOnly.self, forKey: .destinationOnly),
            replaceBlockedReason: try values.decodeIfPresent(String.self, forKey: .replaceBlockedReason),
            renameOnly: try values.decodeIfPresent(Bool.self, forKey: .renameOnly) ?? false)
    }
}

/// Whether the paste copies the items or moves them (a cut).
public enum ReviewMode: String, Codable, Equatable, Sendable {
    case copy, cut
}

/// The analysis report, as the review reads it (`CopyPasteReport`).
public struct ReviewReport: Codable, Equatable, Sendable {
    public struct Summary: Codable, Equatable, Sendable {
        public var totalNodeCount: Int
        public var directoryConflictCount: Int

        public init(totalNodeCount: Int, directoryConflictCount: Int) {
            self.totalNodeCount = totalNodeCount
            self.directoryConflictCount = directoryConflictCount
        }
    }

    public var analysisId: String
    public var mode: ReviewMode
    public var destinationDirectoryPath: String
    public var nodes: [ReviewNode]
    public var summary: Summary

    public init(
        analysisId: String, mode: ReviewMode, destinationDirectoryPath: String, nodes: [ReviewNode], summary: Summary
    ) {
        self.analysisId = analysisId
        self.mode = mode
        self.destinationDirectoryPath = destinationDirectoryPath
        self.nodes = nodes
        self.summary = summary
    }
}

/// The review's choices per item, by node id (`CopyPasteOverrides`).
public typealias ReviewOverrides = [String: CopyPasteChoice]

/// How a row is drawn (`ReviewTone`).
public enum ReviewTone: String, Codable, Equatable, Sendable {
    case normal, danger, muted
}

/// One row of the review sheet (`ReviewRow`).
public struct ReviewRow: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, folder
    }

    public var id: String
    public var node: ReviewNode
    public var depth: Int
    public var kind: Kind
    public var name: String
    /// "photos/raw/IMG_2041.dng": the path below the folder the item is copied from.
    public var relativePath: String
    /// The item's current choice; nil for an item that is simply added.
    public var choice: CopyPasteChoice?
    public var choices: [CopyPasteChoice]
    /// The name the item gets when kept next to the existing one.
    public var keepBothName: String?
    public var detail: String
    public var tone: ReviewTone
    public var replaceBlockedReason: String?
}

/// What the choices will do, counted (`ReviewSummary`).
public struct ReviewSummary: Codable, Equatable, Sendable {
    public var topLevelCount = 0
    public var conflictTopLevelCount = 0
    public var newTopLevelCount = 0
    public var added = 0
    public var keptBoth = 0
    public var merged = 0
    public var replaced = 0
    public var skipped = 0

    public init(
        topLevelCount: Int = 0, conflictTopLevelCount: Int = 0, newTopLevelCount: Int = 0, added: Int = 0,
        keptBoth: Int = 0, merged: Int = 0, replaced: Int = 0, skipped: Int = 0
    ) {
        self.topLevelCount = topLevelCount
        self.conflictTopLevelCount = conflictTopLevelCount
        self.newTopLevelCount = newTopLevelCount
        self.added = added
        self.keptBoth = keptBoth
        self.merged = merged
        self.replaced = replaced
        self.skipped = skipped
    }
}

/// The "For all conflicts" buttons (`AllConflictsChoice`).
public enum AllConflictsChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case skip
    case addMissing = "add_missing"
    case keepAll = "keep_all"
    case overwrite

    /// `ALL_CONFLICTS_LABELS`.
    public var label: String {
        switch self {
        case .skip: "Skip"
        case .addMissing: "Add Missing"
        case .keepAll: "Keep All"
        case .overwrite: "Replace"
        }
    }
}

/// A copy-like action (`CopyLikeAction`).
public enum CopyLikeAction: String, Codable, Equatable, Sendable {
    case paste
    case copyTo = "copy_to"
    case moveTo = "move_to"
    case duplicate

    public init?(_ action: WriteOperationAction) {
        self.init(rawValue: action.rawValue)
    }
}

public enum CopyPasteReview {
    /// `SAFE_COPY_PASTE_POLICY`: pressing the primary button without changing anything never loses data.
    public static let safePolicy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
    /// `RETRY_COPY_PASTE_POLICY`: files that already arrived aren't copied again as "copy" duplicates, and half-copied
    /// folders are completed.
    public static let retryPolicy = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)

    /// `CHOICE_LABELS`.
    public static func label(_ choice: CopyPasteChoice) -> String {
        switch choice {
        case .keepBoth: "Keep Both"
        case .overwrite: "Replace"
        case .skip: "Skip"
        case .merge: "Merge"
        }
    }

    /// `getActionVerb`.
    public static func actionVerb(_ action: CopyLikeAction, mode: ReviewMode) -> String {
        if mode == .cut || action == .moveTo { return "Move" }
        return action == .duplicate ? "Duplicate" : action == .copyTo ? "Copy" : "Paste"
    }

    /// `choicesForNode`.
    public static func choices(for node: ReviewNode) -> [CopyPasteChoice] {
        node.conflictClass == .directoryConflict
            ? [.merge, .keepBoth, .overwrite, .skip] : [.keepBoth, .overwrite, .skip]
    }

    /// `effectiveChoice`: decided as the paste decides it. "For all conflicts: Replace" gives an item that can't be
    /// replaced (the folder that contains what is being pasted) the safe choice instead.
    public static func effectiveChoice(_ node: ReviewNode, _ policy: CopyPastePolicy, _ overrides: ReviewOverrides)
        -> CopyPasteChoice?
    {
        guard let conflictClass = node.conflictClass else { return nil }
        return CopyPasteChoices.choiceForConflict(
            conflictClass: conflictClass, replaceBlockedReason: node.replaceBlockedReason, policy: policy,
            override: overrides[node.id])
    }

    /// `policyForAllConflicts`: Add Missing and Keep All merge folders, so what is inside gets the same treatment; Skip
    /// and Replace apply to the folder as a whole.
    public static func policy(for choice: AllConflictsChoice) -> CopyPastePolicy {
        switch choice {
        case .skip: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
        case .addMissing: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)
        case .keepAll: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)
        case .overwrite: CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .overwrite)
        }
    }

    /// `allConflictsChoicesFor`: Add Missing only differs from Skip when a folder already exists, and a move leaves it
    /// out: it would split the folder between both places.
    public static func allConflictsChoices(_ report: ReviewReport) -> [AllConflictsChoice] {
        report.mode == .cut || report.summary.directoryConflictCount == 0
            ? [.skip, .keepAll, .overwrite] : [.skip, .addMissing, .keepAll, .overwrite]
    }

    /// `describeAllConflictsChoice`: what the selected button does, shown under the buttons.
    public static func describe(_ choice: AllConflictsChoice?, _ report: ReviewReport) -> String {
        let folders = report.summary.directoryConflictCount > 0
        switch choice {
        case nil: return "Set separately for some items below."
        case .skip: return "Existing items stay as they are."
        case .addMissing: return "Folders merge. Only files that aren\u{2019}t there yet are added."
        case .keepAll:
            return folders
                ? "Folders merge. Files that exist are added with a \u{201C}copy\u{201D} name."
                : "Files that exist are added with a \u{201C}copy\u{201D} name."
        case .overwrite: return "Existing items go to the Trash."
        }
    }

    /// `currentAllConflictsChoice`: the "For all conflicts" value, or nil when items were set differently. It comes
    /// from what every listed conflict will actually do, so setting an item back shows the single value again.
    public static func currentAllConflictsChoice(
        _ report: ReviewReport, _ policy: CopyPastePolicy, _ overrides: ReviewOverrides
    ) -> AllConflictsChoice? {
        // The buttons' own value comes first when several match (a stable sort, as `Array.sort` is).
        let offered = allConflictsChoices(report)
        let candidates =
            offered.filter { Self.policy(for: $0) == policy } + offered.filter { Self.policy(for: $0) != policy }
        return candidates.first { sameDecisions(report.nodes, policy, overrides, Self.policy(for: $0)) }
    }

    /// `sameDecisions`: whether the choices do what `expected` does with no per-item choices, inside merged folders too.
    private static func sameDecisions(
        _ nodes: [ReviewNode], _ policy: CopyPastePolicy, _ overrides: ReviewOverrides, _ expected: CopyPastePolicy
    ) -> Bool {
        for node in nodes where node.conflictClass != nil {
            let choice = effectiveChoice(node, policy, overrides)
            if choice != effectiveChoice(node, expected, [:]) { return false }
            if choice == .merge, !sameDecisions(node.children, policy, overrides, expected) { return false }
        }
        return true
    }

    /// `buildReviewRows`: the conflicts (and, on request, the new top-level items), with what is inside merged folders
    /// under them.
    public static func rows(
        _ report: ReviewReport, policy: CopyPastePolicy, overrides: ReviewOverrides, showNewItems: Bool, now: Double,
        dates: ReviewDateText = .shared
    ) -> [ReviewRow] {
        var rows: [ReviewRow] = []
        func visit(_ nodes: [ReviewNode], _ depth: Int, _ basePath: String) {
            for node in nodes {
                let choice = effectiveChoice(node, policy, overrides)
                if choice == nil, !(showNewItems && depth == 0) { continue }
                // Nested paths are shown below the folder the top-level item was copied from.
                let base = depth == 0 ? dirname(node.sourcePath) : basePath
                rows.append(row(node, depth, choice, report.mode, base, now, dates))
                if choice == .merge { visit(node.children, depth + 1, base) }
            }
        }
        visit(report.nodes, 0, "")
        return rows
    }

    /// `summarizeReview`.
    public static func summarize(_ report: ReviewReport, policy: CopyPastePolicy, overrides: ReviewOverrides)
        -> ReviewSummary
    {
        var summary = ReviewSummary(
            topLevelCount: report.nodes.count,
            conflictTopLevelCount: report.nodes.filter { $0.conflictClass != nil }.count,
            newTopLevelCount: report.nodes.filter { $0.conflictClass == nil }.count)
        func visit(_ nodes: [ReviewNode]) {
            for node in nodes {
                switch effectiveChoice(node, policy, overrides) {
                case nil: summary.added += 1
                case .keepBoth: summary.keptBoth += 1
                case .overwrite: summary.replaced += 1
                case .skip: summary.skipped += 1
                case .merge:
                    summary.merged += 1
                    visit(node.children)
                }
            }
        }
        visit(report.nodes)
        return summary
    }

    /// `formatReviewSummary`: what the start button will do, as a sentence: "3 items will be added, 1 skipped"; a move
    /// says "moved" for what it adds.
    public static func formatSummary(_ summary: ReviewSummary, verb: String = "Paste") -> String {
        var parts: [(count: Int, done: String, noun: String?)] = []
        if summary.added > 0 { parts.append((summary.added, verb == "Move" ? "moved" : "added", nil)) }
        if summary.keptBoth > 0 {
            parts.append((summary.keptBoth, summary.keptBoth == 1 ? "kept as a copy" : "kept as copies", nil))
        }
        if summary.merged > 0 { parts.append((summary.merged, "merged", "folder")) }
        if summary.replaced > 0 { parts.append((summary.replaced, "replaced", nil)) }
        if summary.skipped > 0 { parts.append((summary.skipped, "skipped", nil)) }
        guard let first = parts.first else { return "" }
        let lead = "\(ReviewCount.pluralize(first.count, first.noun ?? "item")) will be \(first.done)"
        let rest = parts.dropFirst().map { part in
            part.noun.map { "\(ReviewCount.pluralize(part.count, $0)) \(part.done)" }
                ?? "\(ReviewCount.format(part.count)) \(part.done)"
        }
        return ([lead] + rest).joined(separator: ", ")
    }

    // MARK: Rows

    private static func row(
        _ node: ReviewNode, _ depth: Int, _ choice: CopyPasteChoice?, _ mode: ReviewMode, _ basePath: String,
        _ now: Double, _ dates: ReviewDateText
    ) -> ReviewRow {
        let detail = describeRow(node, choice, mode, now, dates)
        let relativePath: String
        if !basePath.isEmpty, JSString.hasPrefix(node.sourcePath, basePath + "/") {
            relativePath = JSString.string(Array(node.sourcePath.utf16).dropFirst(basePath.utf16.count + 1))
        } else if basePath == "/", JSString.hasPrefix(node.sourcePath, "/") {
            relativePath = JSString.string(Array(node.sourcePath.utf16).dropFirst())
        } else {
            relativePath = leafName(node.sourcePath)
        }
        return ReviewRow(
            id: node.id, node: node, depth: depth, kind: node.sourceKind == .directory ? .folder : .file,
            name: leafName(node.sourcePath), relativePath: relativePath, choice: choice,
            choices: node.conflictClass == nil ? [] : choices(for: node),
            keepBothName: choice == .keepBoth ? node.keepBothDestinationPath.map(leafName) : nil,
            detail: detail.text, tone: detail.tone, replaceBlockedReason: node.replaceBlockedReason)
    }

    private static func describeRow(
        _ node: ReviewNode, _ choice: CopyPasteChoice?, _ mode: ReviewMode, _ now: Double, _ dates: ReviewDateText
    ) -> (text: String, tone: ReviewTone) {
        let described = describeChoice(node, choice, mode, now, dates)
        // Say why Replace isn't offered here, not only inside the disabled menu item.
        if choice != nil, let reason = node.replaceBlockedReason {
            return ("\(described.text) \u{B7} Can't replace: \(reason)", described.tone)
        }
        return described
    }

    private static func describeChoice(
        _ node: ReviewNode, _ choice: CopyPasteChoice?, _ mode: ReviewMode, _ now: Double, _ dates: ReviewDateText
    ) -> (text: String, tone: ReviewTone) {
        let isFolder = node.sourceKind == .directory
        guard let choice else {
            // A folder renamed whole wasn't read inside: what it holds isn't known.
            let text =
                node.renameOnly
                ? "New folder"
                : isFolder
                    ? "New folder \u{B7} \(ReviewCount.pluralize(node.totalNodeCount - 1, "item"))"
                    : "New \u{B7} \(sizeAndDate(node.sourceFingerprint, now, dates))"
            return (text, .normal)
        }
        switch choice {
        case .skip:
            let text =
                mode == .cut ? "Stays in \u{201C}\(leafName(dirname(node.sourcePath)))\u{201D}" : "Left as is"
            return (text, .muted)
        case .overwrite:
            return (describeReplacement(node, now, dates), .danger)
        case .merge:
            let conflictsInside = max(0, node.conflictNodeCount - 1)
            let addedInside = max(0, node.totalNodeCount - node.conflictNodeCount)
            var parts = ["Folder"]
            if conflictsInside > 0 { parts.append("\(ReviewCount.pluralize(conflictsInside, "conflict")) inside") }
            if addedInside > 0 { parts.append("\(ReviewCount.pluralize(addedInside, "item")) added") }
            if let kept = describeKeptDestinationOnly(node) { parts.append(kept) }
            return (parts.joined(separator: " \u{B7} "), .normal)
        case .keepBoth:
            if node.conflictClass == .typeMismatch { return (describeMismatch(node), .normal) }
            if isPackageConflict(node) {
                return ("The existing \u{201C}\(leafName(node.destinationPath))\u{201D} stays", .normal)
            }
            if isFolder {
                let items = ReviewCount.pluralize(node.totalNodeCount - 1, "item")
                return ("Folder \u{B7} \(items) \u{B7} the existing folder stays", .normal)
            }
            return (compareFiles(node, now, dates), .normal)
        }
    }

    /// Two packages (apps, Keynote documents) clash like two files: one replaces the other or both are kept.
    private static func isPackageConflict(_ node: ReviewNode) -> Bool {
        node.sourceKind == .directory && node.conflictClass == .fileConflict
    }

    private static func describeReplacement(_ node: ReviewNode, _ now: Double, _ dates: ReviewDateText) -> String {
        if isPackageConflict(node) {
            let date = node.destinationFingerprint.mtimeMs.map { " from \(dates.format($0, now: now))" } ?? ""
            return "Replaces the existing \u{201C}\(leafName(node.destinationPath))\u{201D}\(date)"
        }
        if node.destinationKind == .directory {
            if let lost = describeDeletedDestinationOnly(node) { return lost }
            if node.destinationOnly == nil {
                return
                    "Replaces the existing folder \u{201C}\(leafName(node.destinationPath))\u{201D} and everything in it"
            }
            return node.sourceKind == .directory
                ? "Replaces the existing folder; everything in it is also in yours"
                : "Replaces the existing empty folder \u{201C}\(leafName(node.destinationPath))\u{201D}"
        }
        let existing = node.destinationFingerprint
        let size = existing.size.map { " \(SizeText.size($0))" } ?? ""
        let date = existing.mtimeMs.map { " from \(dates.format($0, now: now))" } ?? ""
        let kind = node.destinationKind == .symlink ? "alias" : "file"
        return "Replaces the existing\(size) \(kind)\(date)"
    }

    /// Merging keeps what is only in the existing folder: "keeps “d.jpg” and 2 more".
    private static func describeKeptDestinationOnly(_ node: ReviewNode) -> String? {
        guard let only = node.destinationOnly, only.count != 0 else { return nil }
        guard let first = only.samplePaths.first else {
            return "keeps \(ReviewCount.pluralize(only.count, "item")) already there"
        }
        let others = only.count - 1
        return others > 0
            ? "keeps \u{201C}\(first)\u{201D} and \(ReviewCount.format(others)) more" : "keeps \u{201C}\(first)\u{201D}"
    }

    /// Replacing deletes what is only in the existing folder, and says so.
    private static func describeDeletedDestinationOnly(_ node: ReviewNode) -> String? {
        guard let only = node.destinationOnly, only.count != 0 else { return nil }
        let verb = only.count == 1 ? "exists" : "exist"
        guard let first = only.samplePaths.first else {
            return "Deletes \(ReviewCount.pluralize(only.count, "item")) that only \(verb) in the existing folder"
        }
        let others = only.count - 1
        let items =
            others > 0 ? "\u{201C}\(first)\u{201D} and \(ReviewCount.format(others)) more" : "\u{201C}\(first)\u{201D}"
        return "Deletes \(items), which only \(verb) in the existing folder"
    }

    private static func describeMismatch(_ node: ReviewNode) -> String {
        let yours = node.sourceKind == .directory ? "a folder" : "a file"
        let name = leafName(node.destinationPath)
        if node.destinationKind == .directory {
            let contents = node.destinationTotalNodeCount.map { " with \(ReviewCount.pluralize($0, "item"))" } ?? ""
            return "Yours is \(yours) \u{B7} the existing \u{201C}\(name)\u{201D} is a folder\(contents)"
        }
        return "Yours is \(yours) \u{B7} the existing \u{201C}\(name)\u{201D} is a file"
    }

    /// `SAME_TIME_TOLERANCE_MS`: differences of up to a second are the same moment for people (and file systems).
    private static let sameTimeTolerance = 1000.0

    private static func compareFiles(_ node: ReviewNode, _ now: Double, _ dates: ReviewDateText) -> String {
        let yours = node.sourceFingerprint
        let existing = node.destinationFingerprint
        var qualities: [String] = []
        if let mine = yours.mtimeMs, let theirs = existing.mtimeMs {
            let delta = mine - theirs
            if delta > sameTimeTolerance {
                qualities.append("newer")
            } else if delta < -sameTimeTolerance {
                qualities.append("older")
            }
        }
        if let mine = yours.size, let theirs = existing.size, mine != theirs {
            qualities.append(mine > theirs ? "larger" : "smaller")
        }
        if qualities.isEmpty { return "Same size and date \u{B7} \(sizeAndDate(yours, now, dates))" }
        return
            "Yours is \(qualities.joined(separator: " and ")) \u{B7} \(sizeAndDate(yours, now, dates)) vs \(sizeAndDate(existing, now, dates))"
    }

    private static func sizeAndDate(_ fingerprint: ReviewFingerprint, _ now: Double, _ dates: ReviewDateText)
        -> String
    {
        var parts: [String] = []
        if let size = fingerprint.size { parts.append(SizeText.size(size)) }
        if let mtime = fingerprint.mtimeMs { parts.append(dates.format(mtime, now: now)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Paths

    /// `leafName`: the last name of a path, trailing slashes ignored.
    public static func leafName(_ path: String) -> String {
        PathText.leafName(path)
    }

    /// `dirnameOf`: the folder a path is in; "/" at the top.
    public static func dirname(_ path: String) -> String {
        var units = Array(path.utf16)
        while units.last == 0x2F { units.removeLast() }
        guard let index = units.lastIndex(of: 0x2F), index > 0 else { return "/" }
        return JSString.string(units[..<index])
    }
}
