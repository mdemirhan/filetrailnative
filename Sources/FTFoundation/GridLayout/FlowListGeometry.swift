// Port of apps/desktop/src/renderer/lib/flowListLayout.ts (the reveal) and the item rules of styles.css:2598-2700
// (`.flow-list`, `.flow-item`)
import Foundation

/// The rules of `.flow-item` that `FlowListLayout` does not hold.
public struct FlowItemStyle: Equatable, Sendable {
    /// `padding: 0 10px` inside a `2px` transparent border (`box-sizing: border-box`).
    public var paddingInline: Double
    public var borderWidth: Double
    /// `--radius-control`.
    public var radius: Double

    public static func make() -> FlowItemStyle {
        FlowItemStyle(paddingInline: 10, borderWidth: 2, radius: DesignTokens.radii.control)
    }

    /// Room an item takes besides its name: the border and padding on both sides, the icon and the gap after it.
    public func chromeWidth(layout: FlowListLayout) -> Double {
        (borderWidth + paddingInline) * 2 + layout.iconSize + layout.iconGap
    }
}

extension FlowListLayout {
    /// What rows per column depend on.
    public var rowsLayout: FlowRowsLayout {
        FlowRowsLayout(rowHeight: rowHeight, rowGap: rowGap, paddingTop: paddingTop, paddingBottom: paddingBottom)
    }

    /// `computeRowsPerColumn` for this layout.
    public func rowsPerColumn(containerHeight: Double) -> Int {
        Virtualization.rowsPerColumn(containerHeight: containerHeight, layout: rowsLayout)
    }

    public func columnCount(itemCount: Int, rowsPerColumn: Int) -> Int {
        max(1, (itemCount + max(1, rowsPerColumn) - 1) / max(1, rowsPerColumn))
    }

    /// The width of the scrolling content: every column and the gaps between them (`.flow-grid-rows`' min-width),
    /// inside the list's padding.
    public func contentWidth(itemCount: Int, rowsPerColumn: Int) -> Double {
        let columns = Double(columnCount(itemCount: itemCount, rowsPerColumn: rowsPerColumn))
        return paddingInline * 2 + columns * itemWidth + max(0, columns - 1) * columnGap
    }

    /// The column an item is in, and its row.
    public func place(index: Int, rowsPerColumn: Int) -> (column: Int, row: Int) {
        let rows = max(1, rowsPerColumn)
        return (max(0, index) / rows, max(0, index) % rows)
    }

    /// Where the item at `index` starts, and the room its column gives it.
    public func cellFrame(index: Int, rowsPerColumn: Int) -> GridRect {
        let (column, row) = place(index: index, rowsPerColumn: rowsPerColumn)
        return GridRect(
            x: paddingInline + Double(column) * columnStep, y: paddingTop + Double(row) * rowHeight, width: itemWidth,
            height: rowHeight)
    }

    /// An item is as wide as its icon and name, at most its column (`.flow-item:not(.renaming)`).
    public func itemWidth(nameWidth: Double, style: FlowItemStyle) -> Double {
        min(itemWidth, nameWidth + style.chromeWidth(layout: self))
    }

    /// `getFlowListRevealScrollLeft`: the horizontal offset that shows the item's column whole. The list is
    /// column-major, so the column depends on the rows per column, not only on the width.
    public func revealScrollLeft(
        currentScrollLeft: Double, viewportWidth: Double, itemIndex: Int, rowsPerColumn: Int,
        maxScrollLeft: Double? = nil
    ) -> Double {
        let column = max(0, max(0, itemIndex) / max(1, rowsPerColumn))
        let itemLeft = Double(column) * columnStep
        let itemRight = itemLeft + itemWidth
        // The width that shows items: the viewport less the padding on both sides.
        let available = max(1, viewportWidth - paddingInline * 2)
        var next = currentScrollLeft
        if itemLeft < currentScrollLeft {
            next = itemLeft
        } else if itemRight > currentScrollLeft + available {
            next = itemRight - available
        }
        let maxOffset = max(0, maxScrollLeft ?? .infinity)
        return max(0, min(maxOffset, next))
    }

    /// The items in the columns that meet the band `left..<right` of the scrolling content.
    public func items(left: Double, right: Double, itemCount: Int, rowsPerColumn: Int) -> Range<Int> {
        guard itemCount > 0, right > left else { return 0..<0 }
        let rows = max(1, rowsPerColumn)
        let columns = columnCount(itemCount: itemCount, rowsPerColumn: rows)
        let first = max(0, Int(((left - paddingInline) / columnStep).rounded(.down)))
        let last = min(columns - 1, Int(((right - paddingInline) / columnStep).rounded(.up)) - 1)
        guard first <= last else { return 0..<0 }
        return (first * rows)..<min(itemCount, (last + 1) * rows)
    }

    /// What a page is made of: the columns that fit in the viewport (its width less the padding, plus the gap after
    /// the last column), each a column and its gap (`getPageStepLineCount` for the Compact List).
    public func pageViewport(viewportWidth: Double) -> Double {
        viewportWidth - paddingInline * 2 + columnGap
    }
}
