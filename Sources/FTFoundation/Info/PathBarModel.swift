// Port of the path bar logic of apps/desktop/src/renderer/components/ContentPane.tsx (:861-1080), of
// components/PathbarFolderMenu.tsx and of hooks/usePathSuggestions.ts
import Foundation

/// The metrics of the path bar row, the Info Row and the Info panel, from styles.css (the lines are named per group).
public enum InfoMetrics {
    // `.content-pathbar-row`, `.pathbar-*` (styles.css:2032-2265, 4387-4422, 6233-6247)
    public static let pathRowPaddingInline = 10.0
    public static let pathRowGap = 8.0
    public static let statusMarginLeft = 12.0
    public static let pathMinShare = 0.45
    public static let segmentHeight = 20.0
    public static let segmentPaddingInline = 6.0
    public static let segmentMaxWidth = 220.0
    public static let activeSegmentMaxWidth = 320.0
    public static let separatorHeight = 22.0
    public static let separatorMinWidth = 16.0
    public static let itemGap = 2.0
    public static let widthSafetyMargin = 8.0
    public static let separatorSlotWidth = 20.0
    public static let segmentClickDelay = 0.32
    public static let collapseAfter = 4
    public static let folderMenuMinWidth = 200.0
    public static let folderMenuMaxWidth = 360.0
    public static let folderMenuMaxHeight = 440.0
    public static let folderMenuLimit = 300
    public static let folderMenuLoadingDelay = 0.3
    public static let folderMenuGap = 6.0
    public static let suggestionDebounce = 0.35
    public static let suggestionLimit = 12
    public static let suggestionsMaxHeight = 360.0
    public static let suggestionsGap = 4.0

    // `.info-row` (styles.css:3269-3340)
    public static let infoRowHeight = 30.0
    public static let infoRowPaddingInline = 12.0
    public static let infoRowGap = 8.0
    public static let infoRowIcon = 16.0
    public static let infoRowFactMargin = 6.0
    public static let calculatingDelay = 0.3

    // `.get-info-*` (styles.css:3127-3270, 4555-4850)
    public static let panelInset = 16.0
    public static let panelHeaderHeight = 32.0
    public static let closeButton = 18.0
    public static let closeIcon = 10.0
    public static let heroIconBox = 104.0
    public static let heroIcon = 88.0
    public static let heroStackBox = 96.0
    public static let heroStackIcon = 72.0
    public static let heroGap = 6.0
    public static let openButtonHeight = 24.0
    public static let openChevronWidth = 26.0
    public static let rowPaddingBlock = 8.0
    public static let rowGap = 12.0
    public static let sectionGap = 16.0
    public static let sectionTitleGap = 4.0
    public static let actionWidth = 32.0
    public static let actionHeight = 28.0
    public static let actionIcon = 16.0
    public static let actionGap = 2.0
    public static let copiedDelay = 1.5
    public static let spinnerDelay = 0.3
    public static let fetchDelay = 0.08
    public static let propertiesCacheLimit = 200
    public static let openWithDelay = 0.08
    public static let openWithPatience = 0.25
}

public struct PathbarSegment: Equatable, Sendable {
    public var label: String
    public var path: String

    public init(label: String, path: String) {
        self.label = label
        self.path = path
    }
}

public enum PathBarItem: Equatable, Sendable {
    case segment(PathbarSegment, isActive: Bool, maxWidth: Double?)
    case collapsed(hiddenCount: Int)
}

public enum PathBarModel {
    /// `getPathSegmentLabel`.
    public static func label(_ path: String) -> String {
        path == "/" ? "Macintosh HD" : (path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path)
    }

    /// The folder a segment is in ("/" for the folders at the top of the disk).
    public static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let index = path.distance(from: path.startIndex, to: slash)
        return String(path.prefix(max(1, index)))
    }

    /// `buildPathSegments`: one per folder from the top of the disk, a path on another volume starting at that volume.
    public static func segments(_ path: String) -> [PathbarSegment] {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [PathbarSegment(label: "No folder selected", path: "")]
        }
        if path == "/" { return [PathbarSegment(label: "Macintosh HD", path: "/")] }
        let root = TreePaths.volumeRootPath(path)
        let rest = path.dropFirst(root == "/" ? 0 : root.count)
        var result = [PathbarSegment(label: label(root), path: root)]
        var current = root == "/" ? "" : root
        for part in rest.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + part
            result.append(PathbarSegment(label: String(part), path: current))
        }
        return result
    }

    /// How wide a segment is: its measured text and its padding, capped unless `uncapped`.
    public typealias Measure = (_ label: String, _ isActive: Bool, _ collapsed: Bool, _ uncapped: Bool) -> Double

    static func width(of items: [PathBarItem], measure: Measure) -> Double {
        items.enumerated().reduce(0) { total, pair in
            let separator = pair.offset > 0 ? InfoMetrics.separatorSlotWidth : 0
            switch pair.element {
            case .collapsed: return total + separator + measure("…", false, true, false)
            case .segment(let segment, let isActive, _):
                return total + separator + measure(segment.label, isActive, false, false)
            }
        }
    }

    private static func collapsedItems(_ segments: [PathbarSegment], includeRoot: Bool, tailCount: Int) -> [PathBarItem] {
        var items: [PathBarItem] = []
        let hiddenStart = includeRoot ? 1 : 0
        let tailStart = max(hiddenStart, segments.count - tailCount)
        let hidden = max(0, tailStart - hiddenStart)
        if includeRoot {
            guard let root = segments.first else { return items }
            items.append(.segment(root, isActive: false, maxWidth: nil))
        }
        if hidden > 0 { items.append(.collapsed(hiddenCount: hidden)) }
        for index in tailStart..<segments.count {
            items.append(.segment(segments[index], isActive: index == segments.count - 1, maxWidth: nil))
        }
        return items
    }

    /// `chooseVisiblePathbarItems`: with more than four segments the middle ones collapse behind "…" when the bar is too
    /// narrow, keeping the tail.
    public static func visibleItems(
        _ segments: [PathbarSegment], availableWidth: Double, expanded: Bool, measure: Measure
    ) -> [PathBarItem] {
        let full = segments.enumerated().map {
            PathBarItem.segment($0.element, isActive: $0.offset == segments.count - 1, maxWidth: nil)
        }
        let effective = max(0, availableWidth - InfoMetrics.widthSafetyMargin)
        if expanded || segments.count <= InfoMetrics.collapseAfter { return full }
        if effective <= 0 { return collapsedItems(segments, includeRoot: false, tailCount: 1) }
        if width(of: full, measure: measure) <= effective { return full }
        for tail in stride(from: segments.count - 2, through: 1, by: -1) {
            let candidate = collapsedItems(segments, includeRoot: true, tailCount: tail)
            if width(of: candidate, measure: measure) <= effective { return candidate }
        }
        for tail in stride(from: segments.count - 1, through: 1, by: -1) {
            let candidate = collapsedItems(segments, includeRoot: false, tailCount: tail)
            if width(of: candidate, measure: measure) <= effective { return candidate }
        }
        return collapsedItems(segments, includeRoot: false, tailCount: 1)
    }

    /// `resolveVisiblePathbarItems`: a long name is cut at the usual width; the room left in the row goes back to those
    /// names, from the current folder backwards.
    public static func resolve(
        _ segments: [PathbarSegment], availableWidth: Double, expanded: Bool, measure: Measure
    ) -> [PathBarItem] {
        let items = visibleItems(segments, availableWidth: availableWidth, expanded: expanded, measure: measure)
        if expanded { return items }
        var room = availableWidth - InfoMetrics.widthSafetyMargin - width(of: items, measure: measure)
        guard room > 0 else { return items }
        var widened = items
        for index in stride(from: widened.count - 1, through: 0, by: -1) where room > 0 {
            guard case .segment(let segment, let isActive, _) = widened[index] else { continue }
            let capped = measure(segment.label, isActive, false, false)
            let natural = measure(segment.label, isActive, false, true)
            if natural <= capped { continue }
            let width = min(natural, capped + room)
            room -= width - capped
            widened[index] = .segment(segment, isActive: isActive, maxWidth: width)
        }
        return widened
    }

    /// "Show 2 More Folders".
    public static func showHiddenLabel(_ count: Int) -> String {
        "Show \(count) More \(count == 1 ? "Folder" : "Folders")"
    }

    /// The path bar's and the status text's widths in the row (`flex: 1 1 0; min-width: 45%` and `flex: 0 1 auto`).
    public static func rowLayout(contentWidth: Double, statusWidth: Double?) -> (path: Double, status: Double) {
        guard let statusWidth, statusWidth > 0 else { return (contentWidth, 0) }
        let spacing = InfoMetrics.pathRowGap + InfoMetrics.statusMarginLeft
        let path = max(InfoMetrics.pathMinShare * contentWidth, contentWidth - spacing - statusWidth)
        let status = max(0, min(statusWidth, contentWidth - path - spacing))
        return (path, status)
    }
}

/// A subfolder of the path bar's folder menu.
public struct PathbarFolder: Equatable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public enum PathbarFolderMenuModel {
    public struct Limited: Equatable, Sendable {
        public var shown: [PathbarFolder]
        public var hiddenBefore: Int
        public var hiddenAfter: Int

        public init(shown: [PathbarFolder], hiddenBefore: Int, hiddenAfter: Int) {
            self.shown = shown
            self.hiddenBefore = hiddenBefore
            self.hiddenAfter = hiddenAfter
        }
    }

    /// `limitFolders`: at most 300, centered on the ticked folder.
    public static func limit(_ folders: [PathbarFolder], activePath: String) -> Limited {
        let max = InfoMetrics.folderMenuLimit
        if folders.count <= max { return Limited(shown: folders, hiddenBefore: 0, hiddenAfter: 0) }
        let active = Swift.max(0, folders.firstIndex { $0.path == activePath } ?? 0)
        let start = Swift.max(0, Swift.min(folders.count - max, active - max / 2))
        return Limited(
            shown: Array(folders[start..<(start + max)]), hiddenBefore: start, hiddenAfter: folders.count - start - max)
    }

    public static func hiddenLabel(_ count: Int) -> String { "\(count) more \(count == 1 ? "folder" : "folders")" }

    /// The row a letter jumps to: the next folder starting with it after `current`, wrapping to the first.
    public static func jump(letter: String, from current: Int, in folders: [PathbarFolder]) -> Int? {
        let key = letter.lowercased()
        func starts(_ folder: PathbarFolder) -> Bool { folder.name.lowercased().hasPrefix(key) }
        if let after = folders.indices.first(where: { $0 > current && starts(folders[$0]) }) { return after }
        return folders.firstIndex(where: starts)
    }
}

/// The path editor's draft and suggestions (`usePathSuggestions`).
public struct PathSuggestionState: Equatable, Sendable {
    public var draft: String
    public var preview: String?
    public var suggestions: [PathSuggestionRow] = []
    public var highlighted = -1

    public init(draft: String) { self.draft = draft }

    public var displayed: String { preview ?? draft }

    public mutating func setDraft(_ value: String) {
        preview = nil
        suggestions = []
        highlighted = -1
        draft = value
    }

    /// The answer to the latest request.
    public mutating func receive(_ rows: [PathSuggestionRow]) {
        preview = nil
        highlighted = -1
        suggestions = rows
    }

    public mutating func clear() {
        preview = nil
        suggestions = []
        highlighted = -1
    }

    public static func slashed(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    public mutating func previewSuggestion(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        highlighted = index
        preview = Self.slashed(suggestions[index].path)
    }

    public mutating func accept(_ row: PathSuggestionRow) {
        draft = Self.slashed(row.path)
        preview = nil
        suggestions = []
        highlighted = -1
    }

    /// ↓ and ↑ in the field: the next or previous suggestion, wrapping; from none ↓ starts at the first, ↑ at the last.
    public func nextIndex(down: Bool) -> Int? {
        guard !suggestions.isEmpty else { return nil }
        if highlighted < 0 { return down ? 0 : suggestions.count - 1 }
        return down ? (highlighted + 1) % suggestions.count : (highlighted - 1 + suggestions.count) % suggestions.count
    }

    /// The characters of the preview past what was typed, which are shown selected.
    public var previewSelection: NSRange? {
        guard let preview else { return nil }
        let typed = Array(draft.utf16)
        let shown = Array(preview.utf16)
        var shared = 0
        while shared < min(typed.count, shown.count), typed[shared] == shown[shared] { shared += 1 }
        return NSRange(location: shared, length: shown.count - shared)
    }

    /// Return: the highlighted suggestion's path, else the trimmed text; nil for an empty text.
    public var submission: String? {
        let text = highlighted >= 0 && suggestions.indices.contains(highlighted)
            ? suggestions[highlighted].path : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public struct PathSuggestionRow: Equatable, Sendable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public enum PathText2 {
    /// `expandHomeShortcut`.
    public static func expandHome(_ path: String, homePath: String) -> String {
        if homePath.isEmpty { return path }
        if path == "~" { return homePath }
        if path.hasPrefix("~/") { return homePath + "/" + path.dropFirst(2) }
        return path
    }
}
