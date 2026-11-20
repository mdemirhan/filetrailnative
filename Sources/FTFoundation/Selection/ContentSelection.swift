import Foundation

/// What is selected in the file list: the paths in the order the list shows them, the anchor a ⇧-range extends from, the
/// lead the keyboard moves from, and, when everything selected left the list, where it stood. A path is told from
/// another by its bytes (`DiskPath`): a folder can hold a name spelled with a composed accent beside the same name
/// spelled with a decomposed one, and they are two items, each selected on its own.
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

    public static let empty = ContentSelection()

    public var isEmpty: Bool { paths.isEmpty }

    /// The same paths in the same order, the same anchor and lead, each spelled the same byte for byte.
    public static func == (left: ContentSelection, right: ContentSelection) -> Bool {
        left.gapIndex == right.gapIndex && left.paths.count == right.paths.count
            && left.anchorPath.map(DiskPath.init) == right.anchorPath.map(DiskPath.init)
            && left.leadPath.map(DiskPath.init) == right.leadPath.map(DiskPath.init)
            && zip(left.paths, right.paths).allSatisfy { DiskPath($0) == DiskPath($1) }
    }

    /// `paths` selected: the first is the anchor and the last the lead (what a paste, a duplicate or a new folder
    /// selects).
    public static func of(_ paths: [String]) -> ContentSelection {
        guard !paths.isEmpty else { return .empty }
        return ContentSelection(paths: paths, anchorPath: paths.first, leadPath: paths.last)
    }

    public static func single(_ path: String) -> ContentSelection {
        ContentSelection(paths: [path], anchorPath: path, leadPath: path)
    }

    // MARK: Keeping the selection valid

    /// The selection stored apart from the folder's contents is cleaned each time the
    /// visible entries change (navigation, sorting, filtering, search). `previousPaths`, the list the selection was
    /// made in, lets a selection whose items have all gone keep their place (`gapIndex`).
    public func sanitized(entryPaths: [String], previousPaths: [String] = []) -> ContentSelection {
        let available = Set(entryPaths.lazy.map(DiskPath.init))
        let nextPaths = paths.filter { available.contains(DiskPath($0)) }
        if nextPaths.isEmpty {
            let gap = paths.isEmpty ? gapIndex : Self.gapIndex(of: self, available: available, previous: previousPaths)
            guard let gap else { return .empty }
            return ContentSelection(gapIndex: min(gap, entryPaths.count))
        }
        let lead = leadPath.flatMap { available.contains(DiskPath($0)) ? $0 : nil } ?? nextPaths.last
        let anchor = anchorPath.flatMap { available.contains(DiskPath($0)) ? $0 : nil } ?? lead
        return ContentSelection(paths: nextPaths, anchorPath: anchor, leadPath: lead)
    }

    /// Where the lead item stood among the items that are still there.
    private static func gapIndex(of selection: ContentSelection, available: Set<DiskPath>, previous: [String]) -> Int? {
        guard let lead = (selection.leadPath ?? selection.paths.first).map(DiskPath.init),
            let leadIndex = previous.firstIndex(where: { DiskPath($0) == lead })
        else { return nil }
        var count = 0
        for index in 0..<leadIndex where available.contains(DiskPath(previous[index])) { count += 1 }
        return count
    }

    // MARK: Building a selection

    /// A range is in visual order, not path order.
    public static func rangePaths(entryPaths: [String], anchor: String, target: String) -> [String] {
        let (from, to) = (DiskPath(anchor), DiskPath(target))
        guard let anchorIndex = entryPaths.firstIndex(where: { DiskPath($0) == from }),
            let targetIndex = entryPaths.firstIndex(where: { DiskPath($0) == to })
        else { return target.isEmpty ? [] : [target] }
        let (start, end) = anchorIndex <= targetIndex ? (anchorIndex, targetIndex) : (targetIndex, anchorIndex)
        return Array(entryPaths[start...end])
    }

    /// A merge is put back in the order of the entries, so keyboard navigation,
    /// clipboard actions and context menus all see a stable ordering.
    public static func merged(entryPaths: [String], current: [String], next: [String]) -> [String] {
        let wanted = Set(current.lazy.map(DiskPath.init)).union(next.lazy.map(DiskPath.init))
        return entryPaths.filter { wanted.contains(DiskPath($0)) }
    }

    /// ⌘-click. Keeps the existing anchor when it can, so a following ⇧-range still behaves
    /// like a desktop file manager.
    public func toggled(entryPaths: [String], path: String) -> ContentSelection {
        let toggled = DiskPath(path)
        if paths.contains(where: { DiskPath($0) == toggled }) {
            let next = paths.filter { DiskPath($0) != toggled }
            if next.isEmpty { return .empty }
            let nextLead = leadPath.map(DiskPath.init) == toggled ? next.last : leadPath
            return ContentSelection(
                paths: next,
                anchorPath: anchorPath.map(DiskPath.init) == toggled ? nextLead : (anchorPath ?? nextLead),
                leadPath: nextLead)
        }
        return ContentSelection(
            paths: Self.merged(entryPaths: entryPaths, current: paths, next: [path]), anchorPath: path, leadPath: path)
    }

    /// A range either replaces the selection (⇧-click, ⇧-arrow) or adds to it (⌘⇧-click).
    public func extended(entryPaths: [String], to path: String, additive: Bool = false) -> ContentSelection {
        let anchor = anchorPath ?? leadPath ?? path
        let range = Self.rangePaths(entryPaths: entryPaths, anchor: anchor, target: path)
        return ContentSelection(
            paths: additive ? Self.merged(entryPaths: entryPaths, current: paths, next: range) : range,
            anchorPath: anchor, leadPath: path)
    }

    public static func all(entryPaths: [String]) -> ContentSelection {
        guard let first = entryPaths.first else { return .empty }
        return ContentSelection(paths: entryPaths, anchorPath: first, leadPath: entryPaths.last)
    }

    /// Invert Selection: the entries not selected, in list order, with the first the anchor and the last the lead.
    /// What is selected but not in `entryPaths` (hidden by a filter) is left out too.
    public func inverted(entryPaths: [String]) -> ContentSelection {
        let selected = Set(paths.lazy.map(DiskPath.init))
        return .of(entryPaths.filter { !selected.contains(DiskPath($0)) })
    }

    /// The marquee's selection: the touched paths in list order, the lead the anchor.
    public static func marquee(entryPaths: [String], picked: [String], lead: String?) -> ContentSelection {
        let wanted = Set(picked.lazy.map(DiskPath.init))
        let ordered = entryPaths.filter { wanted.contains(DiskPath($0)) }
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

    /// ⌘⇧ adds a range, ⇧ makes one, ⌘ flips one item, a plain press selects one.
    public func afterGesture(entryPaths: [String], path: String, meta: Bool, shift: Bool) -> ContentSelection {
        if meta, shift { return extended(entryPaths: entryPaths, to: path, additive: true) }
        if shift { return extended(entryPaths: entryPaths, to: path) }
        if meta { return toggled(entryPaths: entryPaths, path: path) }
        return .single(path)
    }

    /// Pointer down on an item: a press on a selected item with no ⌘ and no ⇧
    /// changes nothing, so the whole selection can still be dragged out; any other press makes the gesture at once.
    public func afterPress(entryPaths: [String], path: String, selected: Bool, modifiers: Modifiers)
        -> ContentSelection?
    {
        guard modifiers.meta || modifiers.shift || !selected else { return nil }
        return afterGesture(entryPaths: entryPaths, path: path, meta: modifiers.meta, shift: modifiers.shift)
    }

    /// A plain click on one of several selected items narrows the selection to that item.
    /// Rows act on the click rather than on pointer down, so pressing a selected item can still start a drag of the
    /// whole selection. `detail` is 0 for keyboard-generated clicks.
    public static func isNarrowingClick(
        button: Int, detail: Int, modifiers: Modifiers, selectedCount: Int, isSelected: Bool
    ) -> Bool {
        isSelected && selectedCount > 1 && button == 0 && detail > 0 && !modifiers.meta && !modifiers.shift
            && !modifiers.control
    }
}
