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

    /// A count read from a file, where a number of any size can stand: one that is no count gives the default.
    public static func valid(read count: Double) -> Int {
        Int(exactly: count.rounded()).map(valid) ?? defaultCount
    }

    /// Where `count` is in `counts`.
    public static func index(of count: Int) -> Int { counts.firstIndex(of: valid(count)) ?? 1 }

    /// The count View ▸ Show Previews' item puts the pane in Previews at; nil for any other command.
    public static func count(of command: AppCommand) -> Int? {
        switch command {
        case .showPreviews9: 9
        case .showPreviews4: 4
        case .showPreviews2: 2
        case .showPreviews1: 1
        default: nil
        }
    }

    /// What the status bar shows of the size.
    public static func label(_ count: Int) -> String { count == 1 ? "1 at a time" : "\(count) at a time" }

    /// The space between a preview's place and the next one's, and at the pane's sides.
    public static let margin = 6.0
    public static let paddingInline = 8.0

    /// The icon grid that fits `count` previews in a pane `width` by `height` points: exactly the shape's columns
    /// across and rows down, with no padding above or below, so a row scrolled to the top shows the shape's rows whole
    /// and nothing of another.
    public static func layout(base: IconGridLayout, count: Int, width: Double, height: Double) -> IconGridLayout {
        let (columns, rows) = shape(valid(count))
        var grid = base
        grid.paddingInline = paddingInline
        grid.paddingTop = 0
        grid.paddingBottom = 0
        let columnWidth = max(1, (max(0, width - paddingInline * 2) / Double(columns)).rounded(.down))
        grid.cellMinWidth = columnWidth
        grid.labelWidth = max(1, columnWidth - margin * 2)
        grid.rowHeight = max(1, max(0, height) / Double(rows))
        let box = pictureBox(grid)
        // The side the Icons view's parts would take; the picture itself fills `pictureBox`.
        grid.iconSize = max(16, min(box.width, box.height))
        grid.iconBoxSize = grid.iconSize
        grid.itemPaddingTop = margin
        return grid
    }

    /// The room a preview's picture has in its place: the place less the margins and the two lines of name under it.
    public static func pictureBox(_ grid: IconGridLayout) -> (width: Double, height: Double) {
        let name = Double(IconLabel.lineCount) * grid.labelLineHeight + grid.labelPaddingVertical * 2
        return (
            max(16, grid.cellMinWidth - margin * 2),
            max(16, grid.rowHeight - 2 - margin * 2 - grid.labelGap - name)
        )
    }

    /// A picture `size` fitted into `box`, as large as fits and never stretched.
    public static func fitted(_ size: (width: Double, height: Double), in box: (width: Double, height: Double)) -> (
        width: Double, height: Double
    ) {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return (size.width * scale, size.height * scale)
    }

    /// The tile around a picture reaches this far past it on every side.
    public static let tileInset = 4.0

    /// The size a preview is drawn at in its place: its picture (`shape`, in any unit) as large as the place allows,
    /// or an icon two thirds of the place's shorter side when it has no picture.
    public static func pictureSize(_ grid: IconGridLayout, shape: (width: Double, height: Double)?) -> (
        width: Double, height: Double
    ) {
        let box = pictureBox(grid)
        if let shape, shape.width > 0, shape.height > 0 { return fitted(shape, in: box) }
        let side = min(box.width, box.height) * 2 / 3
        return (side, side)
    }

    /// The name's size when it isn't known: as wide as a name may be and two lines tall.
    public static func largestName(_ grid: IconGridLayout) -> (width: Double, height: Double) {
        (grid.labelWidth, Double(IconLabel.lineCount) * grid.labelLineHeight + grid.labelPaddingVertical * 2)
    }

    /// Where a preview's tile and name are in its place, from the place's top left corner: the tile hugs the picture,
    /// the name is right under it, and the two together sit in the middle of the place, which is `heightInset`
    /// shorter than its row. What draws a preview and what a drag-to-select touches both come from here.
    public static func parts(
        _ grid: IconGridLayout, picture: (width: Double, height: Double), name: (width: Double, height: Double),
        heightInset: Double
    ) -> (tile: GridRect, name: GridRect) {
        let placeHeight = grid.rowHeight - heightInset
        let together = picture.height + tileInset * 2 + grid.labelGap + name.height
        let top = max(0, (placeHeight - together) / 2)
        let tile = GridRect(
            x: (grid.cellMinWidth - picture.width) / 2 - tileInset, y: top, width: picture.width + tileInset * 2,
            height: picture.height + tileInset * 2)
        let label = GridRect(
            x: (grid.cellMinWidth - name.width) / 2, y: tile.maxY + grid.labelGap, width: name.width,
            height: name.height)
        return (tile, label)
    }

    /// How far of a row a swipe goes before it settles on the next row and not back.
    public static let swipeShare = 1.0 / 6
    /// The same for a mouse wheel, whose one notch moves the view only a little: any notch goes on to the next row.
    public static let wheelShare = 1.0 / 100

    /// Where a scroll from `start` that ended at `end` settles: the top of a row, the next one along in the direction
    /// it went once it went `share` of a row (a sixth), otherwise back where it started.
    public static func snappedScrollTop(
        from start: Double, to end: Double, rowHeight: Double, maxScrollTop: Double, share: Double = swipeShare
    ) -> Double {
        guard rowHeight > 0 else { return end }
        let startRow = (start / rowHeight).rounded()
        let moved = (end - start) / rowHeight
        let rows = moved > 0 ? (moved - share).rounded(.up) : (moved + share).rounded(.down)
        let snapped = (startRow + rows) * rowHeight
        return min(max(0, maxScrollTop), max(0, snapped))
    }
}
