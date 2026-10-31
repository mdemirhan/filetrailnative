// Port of getSizeBarFraction (apps/desktop/src/renderer/components/ContentPane.tsx:2135-2144), the bar rules of
// styles.css:2894-2948 and the sizeBars memo of App.tsx:513-528
import Foundation

public enum SizeBars {
    /// An item's size as a share of the largest in the folder, for the bar behind it; nil when bars are off (no
    /// largest size) or the size is not known.
    public static func fraction(bytes: Int64?, maxBytes: Int64) -> Double? {
        guard maxBytes > 0, let bytes else { return nil }
        return max(0, min(1, Double(bytes) / Double(maxBytes)))
    }

    /// The largest of the known sizes, or nil when there is none above zero (no bars at all).
    public static func maxBytes(_ sizes: some Sequence<Int64?>) -> Int64? {
        var largest: Int64 = 0
        for size in sizes { largest = max(largest, size ?? 0) }
        return largest > 0 ? largest : nil
    }

    /// Where a bar is drawn in a Size cell: anchored at the right edge, `overhang` past it, as wide as its share of
    /// the cell with a least width, and never wider than the cell plus the overhang. Nil when it shows nothing.
    public static func span(fraction: Double?, cellWidth: Double, layout: DetailsLayout) -> (x: Double, width: Double)?
    {
        guard let fraction, fraction > 0 else { return nil }
        let width = min(max(fraction * cellWidth, layout.sizeBarMinWidth), cellWidth + layout.sizeBarOverhang)
        return (cellWidth + layout.sizeBarOverhang - width, width)
    }
}
