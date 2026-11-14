import Foundation

/// The measures of what this package draws on top of the file list.
public enum SelectionLayout {
    /// The filter pill: floats over the foot of the list it narrows.
    public enum FilterPill {
        /// 14 above the list's bottom edge.
        public static let bottom = 14.0
        /// The gap between the label, the text, the count and the clear button.
        public static let gap = 8.0
        public static let paddingTop = 4.0
        public static let paddingRight = 6.0
        public static let paddingBottom = 4.0
        public static let paddingLeft = 12.0
        public static let borderWidth = 1.0
        /// At least 32 narrower than the list.
        public static let maxWidthInset = 32.0
        /// The filter symbol before the mode chip.
        public static let symbolSize = 13.0
        /// The mode chip (Fuzzy or Contains): a capsule of the accent around its word.
        public static let chipPaddingHorizontal = 7.0
        public static let chipPaddingVertical = 1.0
        public static let chipFillAlpha = 0.14
        public static let chipHoverFillAlpha = 0.24
        /// The pill's own shadow, lighter than a menu's: it sits low over the list.
        public static let shadowOpacity = 0.14
        public static let shadowRadius = 6.0
        public static let shadowOffset = 2.0
        /// How far below its place the pill starts as it springs up, and drops to as it goes.
        public static let travel = 14.0
        /// The shake when nothing matches: how far it goes each way, and for how long.
        public static let shakeDistance = 5.0
        public static let shakeDuration = 0.32
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
