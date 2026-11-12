import Foundation

/// The parts of a list item's look that `FlowListLayout` does not hold.
public struct FlowItemStyle: Equatable, Sendable {
    /// 10 of padding at the sides, inside a clear 2 pt border that counts in the item's width.
    public var paddingInline: Double
    public var borderWidth: Double
    /// The control radius.
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
    /// How many rows a column holds in a pane this tall. A height of zero or less (not measured yet) gives one row.
    public func rowsPerColumn(containerHeight: Double) -> Int {
        guard containerHeight > 0 else { return 1 }
        let content = containerHeight - paddingTop - paddingBottom + rowGap
        let rows = (max(content, rowHeight) / rowHeight).rounded(.down)
        guard rows.isFinite else { return Int.max / 4 }
        return max(1, Int(min(1e15, rows)))
    }

    public func columnCount(itemCount: Int, rowsPerColumn: Int) -> Int {
        max(1, (itemCount + max(1, rowsPerColumn) - 1) / max(1, rowsPerColumn))
    }

    /// The width of the scrolling content: every column and the gaps between them, inside the list's padding.
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

    /// An item is as wide as its icon and name, at most its column, while it isn't being renamed.
    public func itemWidth(nameWidth: Double, style: FlowItemStyle) -> Double {
        min(itemWidth, nameWidth + style.chromeWidth(layout: self))
    }

    /// The horizontal offset that shows the item's column whole. The list is
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

    // MARK: Resizing the columns

    /// The column at the left of a view scrolled to `scrollLeft`: the one whose step (the column and its gap) holds it.
    public func column(atScrollLeft scrollLeft: Double) -> Int {
        let column = ((scrollLeft - paddingInline) / columnStep).rounded(.down)
        guard column.isFinite, column > 0 else { return 0 }
        return Int(min(column, 1e9))
    }

    /// The scroll offset that keeps `column`'s left edge where it was on screen when the columns were `startWidth`
    /// wide and scrolled to `startScrollLeft`: the columns before it grew or shrank by as much each.
    public func anchoredScrollLeft(column: Int, startWidth: Double, startScrollLeft: Double) -> Double {
        startScrollLeft + Double(column) * (itemWidth - startWidth)
    }

    /// What a page is made of: the columns that fit in the viewport (its width less the padding, plus the gap after
    /// the last column), each a column and its gap.
    public func pageViewport(viewportWidth: Double) -> Double {
        viewportWidth - paddingInline * 2 + columnGap
    }
}
