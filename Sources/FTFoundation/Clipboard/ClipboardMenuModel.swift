// Port of the list logic of apps/desktop/src/renderer/components/ClipboardButton.tsx: its rows, the row the keys are
// on, the keys, the rows drawn for a scroll position and the folder heading pinned over them
import Foundation

/// A row of the clipboard's list (`ClipboardMenuRow`).
public enum ClipboardMenuRow: Equatable, Sendable {
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
}

/// The keys of the menu, as `KeyboardEvent.key` names them.
public enum ClipboardMenuKey: Equatable, Sendable {
    case escape, tab, down, up, home, end, enter, space, backspace, delete
    case other
}

/// The clipboard's list as the menu shows it (`ClipboardButton`).
public struct ClipboardMenuModel: Equatable, Sendable {
    public private(set) var rows: [ClipboardMenuRow] = []
    /// The items in the order the list shows them, which the arrow keys go through.
    public private(set) var orderedItems: [ClipboardItem] = []
    /// The row the keys are on: an item's index, `clearIndex` for Clear Clipboard, -1 for none.
    public var activeIndex = -1
    /// How far the list is scrolled.
    public var scrollTop = 0.0

    public init(items: [ClipboardItem] = []) {
        setItems(items)
    }

    /// Clear Clipboard's index, after the last item.
    public var clearIndex: Int { orderedItems.count }

    /// The items changed: the active row keeps its index, so the next item moves up under the keys (clamped).
    public mutating func setItems(_ items: [ClipboardItem]) {
        var rows: [ClipboardMenuRow] = []
        var ordered: [ClipboardItem] = []
        for group in ClipboardRules.groupByFolder(items) {
            rows.append(.heading(label: group.label, parentPath: group.parentPath))
            for item in group.items {
                rows.append(.item(item, itemIndex: ordered.count))
                ordered.append(item)
            }
        }
        self.rows = rows
        orderedItems = ordered
        if activeIndex > clearIndex { activeIndex = clearIndex }
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

    /// The folder of whatever is at the top of the list, kept in view while its items scroll (`findHeading`).
    public var pinnedHeading: (label: String, parentPath: String)? {
        guard !rows.isEmpty else { return nil }
        var index = min(firstVisibleRow, rows.count - 1)
        while index >= 0 {
            if case .heading(let label, let parentPath) = rows[index] { return (label, parentPath) }
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
            activeIndex = max(0, min(clearIndex, activeIndex + (key == .down ? 1 : -1)))
            revealActiveRow()
            return .handled
        case .home, .end:
            activeIndex = key == .home ? 0 : clearIndex
            revealActiveRow()
            return .handled
        case .enter, .space:
            if activeIndex == clearIndex { return .clear }
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
