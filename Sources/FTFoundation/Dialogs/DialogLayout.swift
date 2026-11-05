import Foundation

/// The metrics the in-window alert, the text prompt and the Go To / Move To box are drawn with. Type sizes, radii and
/// control heights come from the design tokens; what is here is each rule's own number.
public enum DialogLayout {
    /// A sheet, and the Go To box, drop in 60 below the window's top.
    public static let sheetTop = 60.0

    /// The alert and its parts.
    public enum Alert {
        /// 272 wide, and at least 32 narrower than the window.
        public static let width = 272.0
        public static let viewportInset = 32.0
        /// Padding: 20 on top, 16 at the sides and below.
        public static let paddingTop = 20.0
        public static let paddingHorizontal = 16.0
        public static let paddingBottom = 16.0
        /// The title: bold, lines 1.3 times the text size.
        public static let titleLineHeight = 1.3
        /// The message: 6 under the title, lines 1.4 times the text size.
        public static let messageGap = 6.0
        public static let messageLineHeight = 1.4
        /// The accessory: 12 under the message.
        public static let accessoryGap = 12.0
        /// The buttons: 8 apart, 16 under what is above them.
        public static let buttonSpacing = 8.0
        public static let buttonsGap = 16.0
        /// A wide alert: 520 wide, at least 48 narrower than the window, padded 20 all round.
        public static let wideWidth = 520.0
        public static let wideViewportInset = 48.0
        public static let widePadding = 20.0
        /// A wide alert's accessory: its parts 12 apart, 14 under the message.
        public static let wideAccessorySpacing = 12.0
        public static let wideAccessoryGap = 14.0
    }

    /// What an alert lists under its message.
    public enum DetailList {
        /// Padding: 8 above and below, 10 at the sides.
        public static let paddingVertical = 8.0
        public static let paddingHorizontal = 10.0
        /// Lines 1.4 times the text size.
        public static let lineHeight = 1.4
        /// The gap between two rows.
        public static let rowGap = 2.0
    }

    /// The text prompt's field and the error under it.
    public enum TextPrompt {
        /// The error sits 6 under the field.
        public static let errorGap = 6.0
        /// The field's text is inset 8 at the sides.
        public static let fieldPaddingHorizontal = 8.0
        /// The error's lines are 1.4 times the text size.
        public static let errorLineHeight = 1.4
    }

    /// The Go To / Move To box.
    public enum GoTo {
        /// 560 wide, at least 32 narrower and 84 shorter than the window, 12 of padding on top.
        public static let width = 560.0
        public static let viewportInset = 32.0
        public static let heightInset = 84.0
        public static let paddingTop = 12.0
        /// The title: 2 on top, 16 at the sides, 10 below.
        public static let titleTop = 2.0
        public static let titleHorizontal = 16.0
        public static let titleBottom = 10.0
        /// The field's section is inset 12 at the sides.
        public static let inputSectionHorizontal = 12.0
        /// The field: its icon and text 8 apart, inset 8 at the sides.
        public static let fieldGap = 8.0
        public static let fieldPaddingHorizontal = 8.0
        /// The field's icon: 14 by 14, stroked 1.5.
        public static let fieldIconSize = 14.0
        public static let fieldIconStroke = 1.5
        /// The error: 6 under the field, inset 4 at the sides.
        public static let errorTop = 6.0
        public static let errorHorizontal = 4.0
        /// The suggestions' section: padding 10 on top, 6 at the sides and below.
        public static let sectionTop = 10.0
        public static let sectionHorizontal = 6.0
        public static let sectionBottom = 6.0
        /// The suggestions' label: its parts 12 apart, inset 10 at the sides and 4 below.
        public static let labelGap = 12.0
        public static let labelHorizontal = 10.0
        public static let labelBottom = 4.0
        /// The list shows at most 8 rows of the large control height.
        public static let visibleRows = 8
        /// The empty state: padding 18 on top, 16 at the sides, 22 below.
        public static let emptyTop = 18.0
        public static let emptyHorizontal = 16.0
        public static let emptyBottom = 22.0
        /// A suggestion row: its parts 8 apart, inset 10 at the sides.
        public static let rowGap = 8.0
        public static let rowPaddingHorizontal = 10.0
        /// A suggestion's glyph: 14 by 14, stroked 1.3.
        public static let rowGlyphSize = 14.0
        public static let rowGlyphStroke = 1.3
        /// A suggestion's name takes at most 55% of the row.
        public static let nameMaxFraction = 0.55
        /// A selected suggestion's path: the text on the accent at 80%.
        public static let selectedPathAlpha = 0.8
        /// The footer: its parts 8 apart, padding 10 on top and 12 at the sides and below, a 1 pt line on top.
        public static let footerGap = 8.0
        public static let footerTop = 10.0
        public static let footerHorizontal = 12.0
        public static let footerBottom = 12.0
        public static let footerBorder = 1.0
    }
}
