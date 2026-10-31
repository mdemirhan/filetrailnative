// Port of apps/desktop/src/renderer/lib/iconGridLayout.ts (the reveal) and the item rules of styles.css:7899-8111
// (where an item, its tile and its name sit)
import Foundation

/// The rules of `.icon-item` and its parts that `IconGridLayout` does not hold.
public struct IconItemStyle: Equatable, Sendable {
    /// `.icon-item` is `padding: 5px 1px 0` (compact 3px on top): its sides.
    public var paddingInline: Double
    /// `.icon-item` is 2 px shorter than its row.
    public var heightInset: Double
    /// `.icon-item-image`'s corners (`--radius-control`).
    public var tileRadius: Double
    /// The tile of a selected item: the text colour at this share.
    public var selectedTileAlpha: Double
    /// The name field while an item is renamed (`.icon-item.renaming .inline-rename-input`).
    public var renameHeight: Double
    public var renameFontSize: Double
    /// `.file-thumbnail-img.framed`: corners, a hairline of the text colour around it, and a soft shadow under it.
    public var thumbnailRadius: Double
    public var thumbnailHairlineWidth: Double
    public var thumbnailHairlineAlpha: Double
    public var thumbnailShadowOffsetY: Double
    public var thumbnailShadowBlur: Double
    public var thumbnailShadowAlpha: Double
    /// `.clipboard-mark-badge`: a 1 px edge of the accent at 70%, a glyph 11 px square.
    public var badgeBorderWidth: Double
    public var badgeBorderAlpha: Double
    public var badgeGlyphSize: Double

    public static func make(density: Density) -> IconItemStyle {
        IconItemStyle(
            paddingInline: 1, heightInset: 2, tileRadius: DesignTokens.radii.control, selectedTileAlpha: 0.1,
            renameHeight: density.isCompact ? 19 : 20,
            renameFontSize: density.isCompact ? DesignTokens.typeScale.callout : DesignTokens.typeScale.body,
            thumbnailRadius: 2, thumbnailHairlineWidth: 0.5, thumbnailHairlineAlpha: 0.26, thumbnailShadowOffsetY: 1,
            thumbnailShadowBlur: 2, thumbnailShadowAlpha: 0.16, badgeBorderWidth: 1, badgeBorderAlpha: 0.7,
            badgeGlyphSize: 11)
    }
}

/// A rectangle in points, from the top-left corner of the view that holds the items.
public struct GridRect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

extension IconGridLayout {
    /// `getIconGridRevealScrollTop`: the scroll offset that brings the row holding `itemIndex` whole into view, moving
    /// as little as possible. The first and last rows also bring in the padding next to them.
    public func revealScrollTop(
        currentScrollTop: Double, viewportHeight: Double, itemIndex: Int, itemCount: Int, columns: Int
    ) -> Double {
        let columnCount = max(1, columns)
        let row = max(0, itemIndex) / columnCount
        let lastRow = max(0, (itemCount + columnCount - 1) / columnCount - 1)
        let rowTop = row == 0 ? 0 : paddingTop + Double(row) * rowHeight
        let rowBottom = paddingTop + Double(row + 1) * rowHeight + (row >= lastRow ? paddingBottom : 0)
        if rowTop < currentScrollTop { return rowTop }
        if rowBottom > currentScrollTop + viewportHeight { return max(0, min(rowTop, rowBottom - viewportHeight)) }
        return currentScrollTop
    }

    /// The width the columns share: the pane less its padding on both sides (on the right the scrollbar's gutter is in
    /// it), as `.icon-grid-items` is.
    public func gridWidth(containerWidth: Double) -> Double {
        max(0, containerWidth - paddingInline * 2)
    }

    /// The height of the scrolling content: the rows and the padding above and below them.
    public func contentHeight(itemCount: Int, columns: Int) -> Double {
        let rows = (itemCount + max(1, columns) - 1) / max(1, columns)
        return paddingTop + Double(rows) * rowHeight + paddingBottom
    }

    /// Where the item at `index` sits: centred in its column, `cellMinWidth` wide and 2 px shorter than its row.
    public func itemFrame(index: Int, columns: Int, containerWidth: Double, style: IconItemStyle) -> GridRect {
        let columnCount = max(1, columns)
        let columnWidth = gridWidth(containerWidth: containerWidth) / Double(columnCount)
        let column = index % columnCount
        let row = index / columnCount
        let center = paddingInline + (Double(column) + 0.5) * columnWidth
        return GridRect(
            x: center - cellMinWidth / 2, y: paddingTop + Double(row) * rowHeight, width: cellMinWidth,
            height: rowHeight - style.heightInset)
    }

    /// The tile inside an item (`.icon-item-image`), from the item's top-left corner.
    public func tileFrame(style: IconItemStyle) -> GridRect {
        GridRect(x: (cellMinWidth - iconBoxSize) / 2, y: itemPaddingTop, width: iconBoxSize, height: iconBoxSize)
    }

    /// The icon in the middle of the tile, from the tile's top-left corner.
    public var iconInset: Double { (iconBoxSize - iconSize) / 2 }

    /// The name under the tile, from the item's top-left corner: as wide as its text and its padding, at most
    /// `labelWidth`, and `lines` lines tall.
    public func labelFrame(textWidth: Double, lines: Int) -> GridRect {
        let width = min(labelWidth, textWidth + labelPaddingHorizontal * 2)
        let height = Double(max(1, min(IconLabel.lineCount, lines))) * labelLineHeight + labelPaddingVertical * 2
        return GridRect(
            x: (cellMinWidth - width) / 2, y: itemPaddingTop + iconBoxSize + labelGap, width: width, height: height)
    }

    /// The width a name's text has on a line (`labelWidth` less the label's padding).
    public var labelTextWidth: Double { labelWidth - labelPaddingHorizontal * 2 }

    /// The items whose rows meet the band `top..<bottom` of the scrolling content.
    public func items(top: Double, bottom: Double, itemCount: Int, columns: Int) -> Range<Int> {
        guard itemCount > 0, bottom > top else { return 0..<0 }
        let columnCount = max(1, columns)
        let rows = (itemCount + columnCount - 1) / columnCount
        let first = max(0, Int(((top - paddingTop) / rowHeight).rounded(.down)))
        let last = min(rows - 1, Int(((bottom - paddingTop) / rowHeight).rounded(.up)) - 1)
        guard first <= last else { return 0..<0 }
        return (first * columnCount)..<min(itemCount, (last + 1) * columnCount)
    }

    /// How many rows a page holds: rows of `rowHeight` in the viewport's height.
    public var lineExtent: Double { rowHeight }
}
