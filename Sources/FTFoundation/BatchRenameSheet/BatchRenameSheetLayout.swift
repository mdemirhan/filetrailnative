import Foundation

/// The metrics the Rename sheet for several items is drawn with. Type sizes, radii and control heights come from the
/// design tokens; what is here is each part's own number.
public enum BatchRenameSheetLayout {
    /// The sheet is 680 wide, or the window's width less 48 if that is less, and at most as tall as the window less
    /// the sheet's top inset and 24.
    public static let width = 680.0
    public static let viewportInset = 48.0
    public static let heightInset = DialogLayout.sheetTop + 24.0
    public static var controlHeight: Double { DesignTokens.controlHeights.regular }

    /// The header: 20 above and at the sides, 14 below, its parts 8 apart.
    public enum Header {
        public static let paddingTop = 20.0
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
        public static let gap = 8.0
        /// Saving a preset: the field 180 wide, 8 before its button.
        public static let presetSaveGap = 8.0
        public static let presetFieldWidth = 180.0
        /// The presets pop-up is at least 120 wide.
        public static let presetsMinWidth = 120.0
    }

    /// The mode switch: 20 at the sides and 14 below; its track pads its segments by 2, the segments are 2 apart and
    /// pad their titles by 12.
    public enum Modes {
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
        public static let trackPadding = 2.0
        public static let segmentGap = 2.0
        public static let segmentPadding = 12.0
    }

    /// The options: 20 at the sides and 14 below, 10 apart.
    public enum Options {
        public static let gap = 10.0
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
    }

    /// The options grid: a 112 label, a field, a 132 label and a field, the fields sharing what is left, 8 apart.
    public enum Grid {
        public static let firstLabelWidth = 112.0
        public static let secondLabelWidth = 132.0
        public static let gap = 8.0
        /// The second label of a line sits 12 further right.
        public static let secondLabelMargin = 12.0

        /// The four columns' left edges and widths for a grid `width` wide.
        public static func columns(width: Double) -> [(x: Double, width: Double)] {
            let flexible = max(0, (width - firstLabelWidth - secondLabelWidth - 3 * gap) / 2)
            let widths = [firstLabelWidth, flexible, secondLabelWidth, flexible]
            var x = 0.0
            return widths.map { columnWidth in
                defer { x += columnWidth + gap }
                return (x, columnWidth)
            }
        }
    }

    /// A field pads its text by 8 at the sides, a number field is 72 wide, and a field's message sits 2 closer to it.
    public enum Field {
        public static let paddingHorizontal = 8.0
        public static let numberWidth = 72.0
        public static let messageMarginTop = -2.0
        /// A field with a wrong value has a 1 pt edge inside it in the danger color.
        public static let invalidEdge = 1.0
    }

    /// The checkboxes: 6 between lines and 16 between columns.
    public enum Check {
        public static let rowGap = 6.0
        public static let columnGap = 16.0
    }

    /// The advice: the warning sign 16 by 16, 6 before the text.
    public enum Advice {
        public static let gap = 6.0
        public static let glyphSize = 16.0
    }

    /// The pattern field and its tokens: the tokens 6 below the field and 4 apart, each 20 tall with 7 at the sides.
    public enum Tokens {
        public static let patternGap = 6.0
        public static let gap = 4.0
        public static let height = 20.0
        public static let paddingHorizontal = 7.0
    }

    /// The preview and its rows.
    public enum Preview {
        /// 20 from the sheet's sides, radius 8, a half-point edge inside it in the active border color.
        public static let marginHorizontal = 20.0
        public static let radius = 8.0
        public static let edge = 0.5
        /// The columns: an 18 glyph, the old name, a 14 arrow and the new name, 1.25 times as wide as the old one; 8
        /// apart and 12 from the sides.
        public static let glyphColumn = 18.0
        public static let arrowColumn = 14.0
        public static let newNameShare = 1.25
        public static let columnGap = 8.0
        public static let paddingHorizontal = 12.0
        /// The header is at least 22 tall, with a 1 pt line below.
        public static let headHeight = 22.0
        public static let headBorder = 1.0
        /// The rows show eight 28 pt rows at most before they scroll.
        public static let maxRowsHeight = 8 * 28.0
        /// A row is at least 26 tall, with 3 above and below.
        public static let rowMinHeight = 26.0
        public static let rowPaddingVertical = 3.0
        /// The item's glyph 16 by 16 in an 18 box; the arrow 12 by 12, stroked 1.4.
        public static let glyphSize = 16.0
        public static let glyphViewBox = 18.0
        public static let arrowSize = 12.0
        public static let arrowStroke = 1.4
        /// A changed part of a name is marked 1 past its text on each side, radius 3.
        public static let markPadding = 1.0
        public static let markRadius = 3.0
        /// How much color is mixed in for the stripe of every second row, a row to fix and its marks.
        public static let stripeInk = 0.025
        public static let dangerRowTint = 0.07
        public static let dangerMarkTint = 0.12

        /// The four columns' left edges and widths in a row `width` wide.
        public static func columns(width: Double) -> [(x: Double, width: Double)] {
            let inner = max(0, width - 2 * paddingHorizontal)
            let flexible = max(0, inner - glyphColumn - arrowColumn - 3 * columnGap)
            let old = flexible / (1 + newNameShare)
            let widths = [glyphColumn, old, arrowColumn, flexible - old]
            var x = paddingHorizontal
            return widths.map { columnWidth in
                defer { x += columnWidth + columnGap }
                return (x, columnWidth)
            }
        }
    }

    /// The footer: a 1 pt line above, 12 above the buttons, 20 at the sides, 16 below; the buttons 8 apart.
    public enum Footer {
        public static let gap = 8.0
        public static let paddingTop = 12.0
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 16.0
        public static let border = 1.0

        public static var height: Double { border + paddingTop + controlHeight + paddingBottom }
    }

    /// The type sizes of the sheet's parts.
    public enum Fonts {
        /// The sheet, its labels, fields, pop-ups and names: the body size.
        public static var body: Double { DesignTokens.typeScale.body }
        /// Notes, messages, the preview's header and the row notes: the small size.
        public static var small: Double { DesignTokens.typeScale.small }
        /// The summary: the callout size.
        public static var summary: Double { DesignTokens.typeScale.callout }
    }

    /// The sheet's size in a window content of `width` by `height`, for a natural height of `natural`.
    public static func size(natural: Double, windowWidth: Double, windowHeight: Double) -> (
        width: Double, height: Double
    ) {
        let width = min(Self.width, max(0, windowWidth - viewportInset))
        let height = min(natural, max(0, windowHeight - heightInset))
        return (width, height)
    }
}
