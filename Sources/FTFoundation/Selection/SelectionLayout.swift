import Foundation

/// The measures of what this package draws on top of the file list.
public enum SelectionLayout {
    /// The filter bar: across the foot of the list it narrows, which ends above it.
    public enum FilterBar {
        /// 30 tall, its 1 pt top edge included.
        public static let height = 30.0
        public static let edgeWidth = 1.0
        /// The gap between the symbol, the text, the count, the modes, the pin and the clear button.
        public static let gap = 8.0
        public static let paddingLeft = 12.0
        public static let paddingRight = 8.0
        /// The filter symbol before the text, and the pin.
        public static let symbolSize = 13.0
        /// The red wash over the bar while nothing matches.
        public static let dangerWashAlpha = 0.1
        /// The width of the filter's text kept before ⇧Space's hint gives way to it.
        public static let textKeptBesideHint = 80.0
    }

    /// The mode chip in the search results' filter field (Fuzzy or Contains): a rounded rectangle of the accent
    /// around its word, with the small radius.
    public enum FilterChip {
        public static let chipPaddingHorizontal = 7.0
        public static let chipPaddingVertical = 1.0
        public static let chipFillAlpha = 0.14
        public static let chipHoverFillAlpha = 0.24
    }

    /// The marquee: a grey tint with a grey edge, mixed from the text colour.
    public enum Marquee {
        public static let borderAlpha = 0.38
        public static let fillAlpha = 0.12
        public static let borderWidth = 1.0
    }

    /// The inline rename field and the reason box under it.
    public enum Rename {
        public static let height = 20.0
        /// 5 to the left and 3 in from the right: lines the text up with the label it replaces; the right edge stays
        /// inside the cell.
        public static let marginLeft = -5.0
        public static let marginRight = 3.0
        /// The text's inset at the sides.
        public static let paddingInline = 5.0
        /// The field's focus ring is the keyboard ring: 3 pt of the accent at 50% over a 0.5 pt edge.
        public static let ringWidth = 3.0
        public static let edgeWidth = 0.5
        /// A refused name is ringed in the `danger` colour at 40%.
        public static let invalidRingAlpha = 0.4

        /// The reason box: 4 pt under the field, at most 320 wide.
        public static let errorMaxWidth = 320.0
        public static let errorGap = 4.0
        public static let errorPaddingVertical = 4.0
        public static let errorPaddingHorizontal = 8.0
        public static let errorBorderWidth = 0.5
        public static let errorBorderAlpha = 0.5
        public static let errorLineHeight = 1.35
        /// A rename draft is kept for at most this many renames.
        public static let maxKeptDrafts = 8
    }
}
