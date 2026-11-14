import Foundation

/// The Previews view's grid: 9, 4, 2 or 1 previews fill the pane at a time, in 3 by 3, 2 by 2, 2 by 1 or 1 by 1, and
/// the pane scrolls down by rows of them. The previews take the size that fits that many in the pane, so a pane half as
/// wide shows as many, smaller.
public enum PreviewGrid {
    /// How many previews fill the pane, from the smallest previews to the largest: Make Bigger goes along it.
    public static let counts = [9, 4, 2, 1]
    public static let defaultCount = 4

    /// The columns and rows `count` previews take: 3 by 3, 2 by 2, 2 by 1, 1 by 1.
    public static func shape(_ count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case 9: (3, 3)
        case 2: (2, 1)
        case 1: (1, 1)
        default: (2, 2)
        }
    }

    /// `count` when it is one of the counts, the default otherwise (a size saved some other way).
    public static func valid(_ count: Int) -> Int { counts.contains(count) ? count : defaultCount }

    /// Where `count` is in `counts`.
    public static func index(of count: Int) -> Int { counts.firstIndex(of: valid(count)) ?? 1 }

    /// What the status bar shows of the size.
    public static func label(_ count: Int) -> String { count == 1 ? "1 at a time" : "\(count) at a time" }

    /// The icon grid that fits `count` previews in a pane `width` by `height` points: exactly the shape's columns
    /// across and rows down, and nothing of the next row, so the pane shows that many and no part of another. The
    /// previews are as large as both allow (at least 32 points), each in the middle of its place.
    public static func layout(base: IconGridLayout, count: Int, width: Double, height: Double) -> IconGridLayout {
        let (columns, rows) = shape(valid(count))
        let gridWidth = max(0, width - base.paddingInline * 2)
        // A column is the tile and 32 more, the tile 8 more than the preview; a row the tile and its two lines of name.
        let besideTile = base.cellMinWidth - base.iconBoxSize
        let aroundPreview = base.iconBoxSize - base.iconSize
        let belowTile = base.rowHeight - base.iconBoxSize
        let byWidth = gridWidth / Double(columns) - besideTile - aroundPreview
        let byHeight = max(0, height) / Double(rows) - belowTile - aroundPreview
        let side = max(32, min(byWidth, byHeight).rounded(.down))
        var sized = base.sized(iconSize: side)
        // The columns share the pane's width, so no more of them fit than the shape has.
        let columnWidth = (gridWidth / Double(columns)).rounded(.down)
        if columnWidth > sized.cellMinWidth {
            sized.labelWidth += columnWidth - sized.cellMinWidth
            sized.cellMinWidth = columnWidth
        }
        // The rows share the pane's height with no padding above or below them, so a row scrolled to the top shows
        // the shape's rows whole and nothing else; the preview and its name sit in the middle of the row.
        let rowHeight = max(sized.rowHeight, max(0, height) / Double(rows))
        sized.itemPaddingTop += ((rowHeight - sized.rowHeight) / 2).rounded(.down)
        sized.rowHeight = rowHeight
        sized.paddingTop = 0
        sized.paddingBottom = 0
        return sized
    }

    /// Where a scroll that ended at `scrollTop` settles: the top of the nearest row, within the content.
    public static func snappedScrollTop(_ scrollTop: Double, rowHeight: Double, maxScrollTop: Double) -> Double {
        guard rowHeight > 0 else { return scrollTop }
        let snapped = (scrollTop / rowHeight).rounded() * rowHeight
        return min(max(0, maxScrollTop), max(0, snapped))
    }
}
