import Foundation

/// The metrics the review sheet, the result sheet and the runtime conflict alert's cards are drawn with. Type sizes,
/// radii and control heights come from the design tokens; what is here is each part's own number.
public enum CopyPasteSheetLayout {
    /// The sheet is 680 wide, or the window's width less 48 if that is less.
    public static let width = 680.0
    public static let viewportInset = 48.0
    /// Below the sheet's top, it stops 24 from the window's bottom.
    public static let bottomInset = 24.0

    /// The header: 20 above and at the sides, 14 below.
    public static let headerTop = 20.0
    public static let headerHorizontal = 20.0
    public static let headerBottom = 14.0
    /// The title and the message 4 apart.
    public static let headingGap = 4.0
    /// The title is bold, its lines 1.3 times its size apart; the message's lines 1.4.
    public static let titleLineHeight = 1.3
    public static let messageLineHeight = 1.4

    /// The bar: 10 above and below, 24 at the sides, its parts 6 apart down and 10 across, a line above and below,
    /// and the ink at 2.5% under it.
    public static let barRowGap = 6.0
    public static let barColumnGap = 10.0
    public static let barVertical = 10.0
    public static let barHorizontal = 24.0
    public static let barInkAlpha = 0.025
    public static let border = 1.0

    /// A segmented control: its track pads its segments by 2, the segments are 2 apart and pad their titles by 12.
    public static let segmentGap = 2.0
    public static let segmentTrackPadding = 2.0
    public static let segmentPadding = 12.0

    /// The list: 4 above and below.
    public static let listVertical = 4.0
    /// A row: a 20 glyph column, the text and the choice, 12 apart; 8 above and below and 24 at the sides. The line
    /// between rows is the light border at 60%.
    public static let glyphColumn = 20.0
    public static let rowColumnGap = 12.0
    public static let rowVertical = 8.0
    public static let rowHorizontal = 24.0
    public static let rowSeparatorAlpha = 0.6
    /// A row that replaces an item: the danger color at 7%.
    public static let replacingAlpha = 0.07
    /// A row's glyph: 18 by 18.
    public static let glyphSize = 18.0
    /// The lines of a row's text 2 apart.
    public static let rowTextGap = 2.0
    public static let indent = 20.0
    public static let maxIndentDepth = 6
    /// Rows drawn before "Show all".
    public static let initialRowLimit = 300

    /// A row's choice pop-up: at least 112 wide.
    public static let choiceMinWidth = 112.0

    /// The footer: 12 above, 20 at the sides, 16 below; the buttons 8 apart.
    public static let footerGap = 8.0
    public static let footerTop = 12.0
    public static let footerHorizontal = 20.0
    public static let footerBottom = 16.0
    /// The warning glyph: 16 by 16, 8 before the note.
    public static let warningGlyphSize = 16.0
    public static let noteGap = 8.0

    /// The result list: 8 below.
    public static let resultListBottom = 8.0
    /// A section title of the result: 10 above, 20 at the sides, 4 below.
    public static let sectionTitleTop = 10.0
    public static let sectionTitleHorizontal = 20.0
    public static let sectionTitleBottom = 4.0
    /// A row of the result: 6 above and below.
    public static let resultRowVertical = 6.0

    /// The conflict alert's cards: two columns 12 apart; each card 12 inside, its lines 4 apart, a 1 pt light border.
    public static let cardGap = 12.0
    public static let cardInnerGap = 4.0
    public static let cardPadding = 12.0
    /// The conflict alert's checkbox: 8 before its title.
    public static let checkboxGap = 8.0
}
