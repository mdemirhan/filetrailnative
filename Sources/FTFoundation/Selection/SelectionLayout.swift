// Port of the rules of apps/desktop/src/renderer/styles.css for the filter pill (:1895-1934), the marquee box (:2273-2283)
// and the inline rename field (:7846-7896)
import Foundation

/// The measures of what this package draws on top of the file list.
public enum SelectionLayout {
    /// `.list-filter-pill`: floats over the foot of the list it narrows.
    public enum FilterPill {
        /// `bottom: 14px`.
        public static let bottom = 14.0
        /// `gap: 8px` between the label, the text, the count and the clear button.
        public static let gap = 8.0
        public static let paddingTop = 4.0
        public static let paddingRight = 6.0
        public static let paddingBottom = 4.0
        public static let paddingLeft = 12.0
        public static let borderWidth = 1.0
        /// `max-width: calc(100% - 32px)`.
        public static let maxWidthInset = 32.0
        /// The pill is the `--bg-elevated` at 94%.
        public static let backgroundAlpha = 0.94
        /// The value is semibold.
        public static let valueWeight = 600
    }

    /// `.drag-select-box`: a grey tint with a grey edge, mixed from the text colour.
    public enum Marquee {
        public static let borderAlpha = 0.38
        public static let fillAlpha = 0.12
        public static let borderWidth = 1.0
    }

    /// `.inline-rename-input` and `.inline-rename-error`.
    public enum Rename {
        public static let height = 20.0
        /// `margin: 0 3px 0 -5px`: lines the text up with the label it replaces; the right edge stays inside the cell.
        public static let marginLeft = -5.0
        public static let marginRight = 3.0
        /// `padding: 0 5px`.
        public static let paddingInline = 5.0
        /// The field's focus ring is the keyboard ring: 3 pt of the accent at 50% over a 0.5 pt edge.
        public static let ringWidth = 3.0
        public static let edgeWidth = 0.5
        /// A refused name is ringed in `--danger` at 40%.
        public static let invalidRingAlpha = 0.4

        /// The reason box: 4 pt under the field, at most 320 wide.
        public static let errorMaxWidth = 320.0
        public static let errorGap = 4.0
        public static let errorPaddingVertical = 4.0
        public static let errorPaddingHorizontal = 8.0
        public static let errorBorderWidth = 0.5
        public static let errorBorderAlpha = 0.5
        public static let errorLineHeight = 1.35
        /// A rename draft is kept for at most this many renames (`MAX_KEPT_DRAFTS`).
        public static let maxKeptDrafts = 8
    }
}
