// Its rows, the row the keys are on, the keys, the rows drawn for a scroll position and the folder heading pinned over
// them
import Foundation

/// A row of the clipboard's list (`ClipboardMenuRow`).
public enum ClipboardMenuRow: Equatable, Sendable {
    /// What ⌘V does with the items under it, on a clipboard holding both: "Cut", "Copied", with their count.
    case section(mode: ClipboardMode, count: Int)
    case heading(label: String, parentPath: String)
    case item(ClipboardItem, itemIndex: Int)
}

/// What a key does in the open clipboard menu.
public enum ClipboardMenuKeyResult: Equatable, Sendable {
    /// The key was the menu's; nothing else happens.
    case handled
    /// The menu closes, and the key is not the menu's (⌘V still pastes).
    case closeAndPass
    case close
    /// The menu closes, and the item is shown in its folder.
    case reveal(String)
    case remove(String)
    case clear
    case putBack
}

/// The keys of the menu.
public enum ClipboardMenuKey: Equatable, Sendable {
    case escape, tab, down, up, home, end, enter, space, backspace, delete
    case other
}

/// The clipboard's list as the menu shows it.
public struct ClipboardMenuModel: Equatable, Sendable {
    public private(set) var rows: [ClipboardMenuRow] = []
    /// The items in the order the list shows them, which the arrow keys go through.
    public private(set) var orderedItems: [ClipboardItem] = []
    /// The row the keys are on: an item's index, `clearIndex` for Clear Clipboard, `putBackIndex` for Put Back, -1
    /// for none.
    public var activeIndex = -1
    /// How far the list is scrolled.
    public var scrollTop = 0.0
    /// A clipboard built with Add that a Copy or Cut replaced can be put back: how many items it held, or nil.
    public private(set) var putBackCount: Int?

    public init(items: [ClipboardItem] = [], putBackCount: Int? = nil) {
        setItems(items, putBackCount: putBackCount)
    }

    /// Clear Clipboard's index, after the last item.
    public var clearIndex: Int { orderedItems.count }

    /// Put Back's index, after Clear Clipboard, while there is one to put back.
    public var putBackIndex: Int? { putBackCount == nil ? nil : clearIndex + 1 }

    /// The last row the keys can be on.
    private var lastIndex: Int { putBackIndex ?? clearIndex }

    /// The items changed: the active row keeps its index, so the next item moves up under the keys (clamped). On a
    /// clipboard holding both, the cut items come first under "Cut", then the copied ones under "Copied", each part's
    /// items under their folders, as ⌘V will run.
    ///
    /// The same items with another intent (a click on an item's mark) stay on the rows they are on, each showing its
    /// own mark, and the parts' counts say what ⌘V will do: an item that went to the other part as it was clicked put
    /// another under the pointer, and a second click, to switch it back, switched that one. The list is in its parts
    /// again the next time it opens.
    public mutating func setItems(_ items: [ClipboardItem], putBackCount: Int? = nil) {
        if keepPlaces(items) {
            self.putBackCount = putBackCount
            if activeIndex > lastIndex { activeIndex = lastIndex }
            return
        }
        var rows: [ClipboardMenuRow] = []
        var ordered: [ClipboardItem] = []
        func add(_ groups: [ClipboardItemGroup]) {
            for group in groups {
                rows.append(.heading(label: group.label, parentPath: group.parentPath))
                for item in group.items {
                    rows.append(.item(item, itemIndex: ordered.count))
                    ordered.append(item)
                }
            }
        }
        let parts = ClipboardRules.groupByIntent(items)
        if parts.count > 1 {
            for part in parts {
                rows.append(.section(mode: part.mode, count: part.groups.reduce(0) { $0 + $1.items.count }))
                add(part.groups)
            }
        } else {
            add(ClipboardRules.groupByFolder(items))
        }
        self.rows = rows
        orderedItems = ordered
        self.putBackCount = putBackCount
        if activeIndex > lastIndex { activeIndex = lastIndex }
    }

    /// Puts `items` on the rows the same items are on now; false when they are other items, or none are shown.
    private mutating func keepPlaces(_ items: [ClipboardItem]) -> Bool {
        guard !orderedItems.isEmpty, items.count == orderedItems.count else { return false }
        var byPath: [[UInt8]: ClipboardItem] = [:]
        for item in items { byPath[Array(item.path.utf8)] = item }
        guard byPath.count == items.count, orderedItems.allSatisfy({ byPath[Array($0.path.utf8)] != nil }) else {
            return false
        }
        let cutCount = items.filter { $0.mode == .cut }.count
        rows = rows.map { row in
            switch row {
            case .section(let mode, _): .section(mode: mode, count: mode == .cut ? cutCount : items.count - cutCount)
            case .heading: row
            case .item(let item, let itemIndex): .item(byPath[Array(item.path.utf8)] ?? item, itemIndex: itemIndex)
            }
        }
        orderedItems = orderedItems.map { byPath[Array($0.path.utf8)] ?? $0 }
        return true
    }

    /// The menu opened: no active row, scrolled to the top.
    public mutating func opened() {
        activeIndex = -1
        scrollTop = 0
    }

    /// Whether the list is long enough to scroll (`clipboard-menu-list-scrolls`).
    public var scrolls: Bool { rows.count > ClipboardLayout.Menu.visibleRows }

    /// The list's height: at most ten rows.
    public var listHeight: Double {
        Double(min(rows.count, ClipboardLayout.Menu.visibleRows)) * ClipboardLayout.Menu.rowHeight
    }

    public var contentHeight: Double { Double(rows.count) * ClipboardLayout.Menu.rowHeight }

    /// The row at the top of the list for the scroll position.
    public var firstVisibleRow: Int {
        max(0, min(rows.count - 1, Int((scrollTop / ClipboardLayout.Menu.rowHeight).rounded(.down))))
    }

    /// The rows drawn: those in view and four on each side.
    public var drawnRows: Range<Int> {
        let first = firstVisibleRow
        let start = max(0, first - ClipboardLayout.Menu.overscanRows)
        let end = min(rows.count, first + ClipboardLayout.Menu.visibleRows + ClipboardLayout.Menu.overscanRows)
        return start..<max(start, end)
    }

    /// The heading of whatever is at the top of the list, kept in view while its items scroll: its folder, or on a
    /// clipboard holding both, the title of a part ("Cut", "Copied") while that is at the top.
    public var pinnedRow: ClipboardMenuRow? {
        guard !rows.isEmpty else { return nil }
        var index = min(firstVisibleRow, rows.count - 1)
        while index >= 0 {
            switch rows[index] {
            case .heading, .section: return rows[index]
            case .item: index -= 1
            }
        }
        return nil
    }

    /// The folder pinned over the top of the list, when a folder is.
    public var pinnedHeading: (label: String, parentPath: String)? {
        if case .heading(let label, let parentPath)? = pinnedRow { return (label, parentPath) }
        return nil
    }

    /// On a clipboard holding both, what ⌘V does with the items of the folder pinned: the part it is in.
    public var pinnedMode: ClipboardMode? {
        var index = min(firstVisibleRow, rows.count - 1)
        while index >= 0 {
            if case .section(let mode, _) = rows[index] { return mode }
            index -= 1
        }
        return nil
    }

    /// The row of item `itemIndex`.
    public func rowIndex(ofItem itemIndex: Int) -> Int? {
        rows.firstIndex {
            if case .item(_, let index) = $0 { return index == itemIndex }
            return false
        }
    }

    /// Brings the active row into view, as the keys do (the pointer never scrolls the list). The pinned heading
    /// covers one row.
    public mutating func revealActiveRow() {
        guard activeIndex >= 0, activeIndex < clearIndex, let row = rowIndex(ofItem: activeIndex) else { return }
        let height = ClipboardLayout.Menu.rowHeight
        let top = Double(row - 1) * height
        let bottom = Double(row + 1) * height
        if top < scrollTop {
            scrollTop = max(0, top)
        } else if bottom > scrollTop + listHeight {
            scrollTop = bottom - listHeight
        }
    }

    /// A key while the menu is open: the menu takes the keyboard first.
    public mutating func key(_ key: ClipboardMenuKey, command: Bool, control: Bool, option: Bool)
        -> ClipboardMenuKeyResult
    {
        if command || control || option { return .closeAndPass }
        switch key {
        case .escape, .tab:
            return .close
        case .down, .up:
            activeIndex = max(0, min(lastIndex, activeIndex + (key == .down ? 1 : -1)))
            revealActiveRow()
            return .handled
        case .home, .end:
            activeIndex = key == .home ? 0 : lastIndex
            revealActiveRow()
            return .handled
        case .enter, .space:
            if activeIndex == clearIndex { return .clear }
            if activeIndex == putBackIndex { return .putBack }
            if orderedItems.indices.contains(activeIndex) { return .reveal(orderedItems[activeIndex].path) }
            return .handled
        case .backspace, .delete:
            if orderedItems.indices.contains(activeIndex) { return .remove(orderedItems[activeIndex].path) }
            return .handled
        case .other:
            return .handled
        }
    }
}
