// Port of apps/desktop/src/renderer/lib/contentSelection.ts
import Foundation

/// What is selected in the file list: the paths in the order the list shows them, the anchor a ⇧-range extends from, the
/// lead the keyboard moves from, and, when everything selected left the list, where it stood.
public struct ContentSelection: Equatable, Sendable, Codable {
    public var paths: [String]
    /// The fixed origin for ⇧-range extension.
    public var anchorPath: String?
    /// The most recent focus target: what the arrow keys, paging, Quick Look and the reveal start from.
    public var leadPath: String?
    /// Set only when nothing is selected because the selected items left the list (moved to the Trash, say): how many
    /// of the items still shown came before them. The arrow keys carry on from there instead of from the top.
    public var gapIndex: Int?

    public init(paths: [String] = [], anchorPath: String? = nil, leadPath: String? = nil, gapIndex: Int? = nil) {
        self.paths = paths
        self.anchorPath = anchorPath
        self.leadPath = leadPath
        self.gapIndex = gapIndex
    }

    /// `EMPTY_CONTENT_SELECTION`.
    public static let empty = ContentSelection()

    public var isEmpty: Bool { paths.isEmpty }

    /// `paths` selected: the first is the anchor and the last the lead (what a paste, a duplicate or a new folder
    /// selects).
    public static func of(_ paths: [String]) -> ContentSelection {
        guard !paths.isEmpty else { return .empty }
        return ContentSelection(paths: paths, anchorPath: paths.first, leadPath: paths.last)
    }

    /// `setSingleContentSelection`.
    public static func single(_ path: String) -> ContentSelection {
        ContentSelection(paths: [path], anchorPath: path, leadPath: path)
    }

    // MARK: Keeping the selection valid

    /// `sanitizeContentSelection`: the selection stored apart from the folder's contents is cleaned each time the
    /// visible entries change (navigation, sorting, filtering, search). `previousPaths`, the list the selection was
    /// made in, lets a selection whose items have all gone keep their place (`gapIndex`).
    public func sanitized(entryPaths: [String], previousPaths: [String] = []) -> ContentSelection {
        let available = Set(entryPaths)
        let nextPaths = paths.filter { available.contains($0) }
        if nextPaths.isEmpty {
            let gap = paths.isEmpty ? gapIndex : Self.gapIndex(of: self, available: available, previous: previousPaths)
            guard let gap else { return .empty }
            return ContentSelection(gapIndex: min(gap, entryPaths.count))
        }
        let lead = leadPath.flatMap { available.contains($0) ? $0 : nil } ?? nextPaths.last
        let anchor = anchorPath.flatMap { available.contains($0) ? $0 : nil } ?? lead
        return ContentSelection(paths: nextPaths, anchorPath: anchor, leadPath: lead)
    }

    /// Where the lead item stood among the items that are still there.
    private static func gapIndex(of selection: ContentSelection, available: Set<String>, previous: [String]) -> Int? {
        guard let lead = selection.leadPath ?? selection.paths.first,
            let leadIndex = previous.firstIndex(of: lead)
        else { return nil }
        var count = 0
        for index in 0..<leadIndex where available.contains(previous[index]) { count += 1 }
        return count
    }

    // MARK: Building a selection

    /// `getSelectionRangePaths`: a range is in visual order, not path order.
    public static func rangePaths(entryPaths: [String], anchor: String, target: String) -> [String] {
        guard let anchorIndex = entryPaths.firstIndex(of: anchor), let targetIndex = entryPaths.firstIndex(of: target)
        else { return target.isEmpty ? [] : [target] }
        let (start, end) = anchorIndex <= targetIndex ? (anchorIndex, targetIndex) : (targetIndex, anchorIndex)
        return Array(entryPaths[start...end])
    }

    /// `mergeSelectionPathsInEntryOrder`: a merge is put back in the order of the entries, so keyboard navigation,
    /// clipboard actions and context menus all see a stable ordering.
    public static func merged(entryPaths: [String], current: [String], next: [String]) -> [String] {
        let wanted = Set(current).union(next)
        return entryPaths.filter { wanted.contains($0) }
    }

    /// `toggleContentSelection`: ⌘-click. Keeps the existing anchor when it can, so a following ⇧-range still behaves
    /// like a desktop file manager.
    public func toggled(entryPaths: [String], path: String) -> ContentSelection {
        if paths.contains(path) {
            let next = paths.filter { $0 != path }
            if next.isEmpty { return .empty }
            let nextLead = leadPath == path ? next.last : leadPath
            return ContentSelection(
                paths: next, anchorPath: anchorPath == path ? nextLead : (anchorPath ?? nextLead), leadPath: nextLead)
        }
        return ContentSelection(
            paths: Self.merged(entryPaths: entryPaths, current: paths, next: [path]), anchorPath: path, leadPath: path)
    }

    /// `extendContentSelectionToPath`: a range either replaces the selection (⇧-click, ⇧-arrow) or adds to it (⌘⇧-click).
    public func extended(entryPaths: [String], to path: String, additive: Bool = false) -> ContentSelection {
        let anchor = anchorPath ?? leadPath ?? path
        let range = Self.rangePaths(entryPaths: entryPaths, anchor: anchor, target: path)
        return ContentSelection(
            paths: additive ? Self.merged(entryPaths: entryPaths, current: paths, next: range) : range,
            anchorPath: anchor, leadPath: path)
    }

    /// `selectAllContentEntries`.
    public static func all(entryPaths: [String]) -> ContentSelection {
        guard let first = entryPaths.first else { return .empty }
        return ContentSelection(paths: entryPaths, anchorPath: first, leadPath: entryPaths.last)
    }

    /// The marquee's selection (`selectContentPaths`): the touched paths in list order, the lead the anchor.
    public static func marquee(entryPaths: [String], picked: [String], lead: String?) -> ContentSelection {
        let wanted = Set(picked)
        let ordered = entryPaths.filter { wanted.contains($0) }
        return ordered.isEmpty ? .empty : ContentSelection(paths: ordered, anchorPath: lead, leadPath: lead)
    }

    // MARK: Pointer gestures

    /// The modifiers a click carries.
    public struct Modifiers: Equatable, Sendable, Codable {
        public var meta: Bool
        public var shift: Bool
        public var control: Bool

        public init(meta: Bool = false, shift: Bool = false, control: Bool = false) {
            self.meta = meta
            self.shift = shift
            self.control = control
        }

        public static let none = Modifiers()
    }

    /// `handleContentSelectionGesture`: ⌘⇧ adds a range, ⇧ makes one, ⌘ flips one item, a plain press selects one.
    public func afterGesture(entryPaths: [String], path: String, meta: Bool, shift: Bool) -> ContentSelection {
        if meta, shift { return extended(entryPaths: entryPaths, to: path, additive: true) }
        if shift { return extended(entryPaths: entryPaths, to: path) }
        if meta { return toggled(entryPaths: entryPaths, path: path) }
        return .single(path)
    }

    /// Pointer down on an item (`pointerDown` of `entryItemEvents.ts`): a press on a selected item with no ⌘ and no ⇧
    /// changes nothing, so the whole selection can still be dragged out; any other press makes the gesture at once.
    public func afterPress(entryPaths: [String], path: String, selected: Bool, modifiers: Modifiers)
        -> ContentSelection?
    {
        guard modifiers.meta || modifiers.shift || !selected else { return nil }
        return afterGesture(entryPaths: entryPaths, path: path, meta: modifiers.meta, shift: modifiers.shift)
    }

    /// `isSelectionNarrowingClick`: a plain click on one of several selected items narrows the selection to that item.
    /// Rows act on the click rather than on pointer down, so pressing a selected item can still start a drag of the
    /// whole selection. `detail` is 0 for keyboard-generated clicks.
    public static func isNarrowingClick(
        button: Int, detail: Int, modifiers: Modifiers, selectedCount: Int, isSelected: Bool
    ) -> Bool {
        isSelected && selectedCount > 1 && button == 0 && detail > 0 && !modifiers.meta && !modifiers.shift
            && !modifiers.control
    }
}
