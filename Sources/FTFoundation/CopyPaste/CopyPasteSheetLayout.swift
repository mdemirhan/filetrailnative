// Port of the .copy-paste-sheet, .copy-paste-* and .segmented rules of apps/desktop/src/renderer/styles.css
// (1405-1458, 7171-7495) and the row limits of components/CopyPasteReviewDialog.tsx
import Foundation

/// The metrics the review sheet, the result sheet and the runtime conflict alert's cards are drawn with. Type sizes,
/// radii and control heights come from the design tokens; what is here is each rule's own number.
public enum CopyPasteSheetLayout {
    /// `width: min(680px, calc(100vw - 48px))` (7177).
    public static let width = 680.0
    public static let viewportInset = 48.0
    /// `max-height: calc(100vh - 60px - 24px)` (7178): below the sheet's top, 24 from the window's bottom.
    public static let bottomInset = 24.0

    /// `.copy-paste-sheet-header`: `padding: 20px 20px 14px` (7195).
    public static let headerTop = 20.0
    public static let headerHorizontal = 20.0
    public static let headerBottom = 14.0
    /// `.copy-paste-sheet-heading`: `gap: 4px` (7201).
    public static let headingGap = 4.0
    /// `.copy-paste-sheet-title`: bold, `line-height: 1.3` (7208); `.copy-paste-sheet-message`: `line-height: 1.4`.
    public static let titleLineHeight = 1.3
    public static let messageLineHeight = 1.4

    /// `.copy-paste-sheet-bar`: `gap: 6px 10px; padding: 10px 24px`, a line above and below (7221-7228); the ink at
    /// 2.5% under it (7229).
    public static let barRowGap = 6.0
    public static let barColumnGap = 10.0
    public static let barVertical = 10.0
    public static let barHorizontal = 24.0
    public static let barInkAlpha = 0.025
    public static let border = 1.0

    /// `.segmented`: `gap: 2px; padding: 2px` (1421-1422); `.segmented-item`: `padding: 0 12px` (1431).
    public static let segmentGap = 2.0
    public static let segmentTrackPadding = 2.0
    public static let segmentPadding = 12.0

    /// `.copy-paste-sheet-list`: `padding: 4px 0` (7289).
    public static let listVertical = 4.0
    /// `.copy-paste-sheet-row`: `grid-template-columns: 20px minmax(0, 1fr) auto; column-gap: 12px; padding: 8px 24px`
    /// (7296-7299); the line between rows is the light border at 60% (7303).
    public static let glyphColumn = 20.0
    public static let rowColumnGap = 12.0
    public static let rowVertical = 8.0
    public static let rowHorizontal = 24.0
    public static let rowSeparatorAlpha = 0.6
    /// `.copy-paste-sheet-row.is-replacing`: the danger color at 7% (7307).
    public static let replacingAlpha = 0.07
    /// `.copy-paste-row-glyph`: 18 by 18 (7311-7312).
    public static let glyphSize = 18.0
    /// `.copy-paste-sheet-row-text`: `gap: 2px` (7334).
    public static let rowTextGap = 2.0
    /// `INDENT_PX` and `MAX_INDENT_DEPTH` (CopyPasteReviewDialog.tsx:36-37).
    public static let indent = 20.0
    public static let maxIndentDepth = 6
    /// `INITIAL_ROW_LIMIT` (CopyPasteReviewDialog.tsx:34): rows drawn before "Show all".
    public static let initialRowLimit = 300

    /// `.copy-paste-choice`: `min-width: 112px; padding: 0 8px` (7277-7278).
    public static let choiceMinWidth = 112.0
    public static let choicePadding = 8.0

    /// `.copy-paste-sheet-footer`: `gap: 8px; padding: 12px 20px 16px` (7391-7392).
    public static let footerGap = 8.0
    public static let footerTop = 12.0
    public static let footerHorizontal = 20.0
    public static let footerBottom = 16.0
    /// `.copy-paste-warning-glyph`: 16 by 16, 8 before the note (7404, 7414-7415).
    public static let warningGlyphSize = 16.0
    public static let noteGap = 8.0

    /// `.copy-paste-result-list`: `padding: 0 0 8px` (7474).
    public static let resultListBottom = 8.0
    /// `.copy-paste-result-section-title`: `padding: 10px 20px 4px` (7479).
    public static let sectionTitleTop = 10.0
    public static let sectionTitleHorizontal = 20.0
    public static let sectionTitleBottom = 4.0
    /// `.copy-paste-result-items .copy-paste-sheet-row`: `padding: 6px 24px` (7495).
    public static let resultRowVertical = 6.0

    /// `.copy-paste-conflict-alert-cards`: two columns, `gap: 12px` (7432); `.copy-paste-conflict-card`: `gap: 4px;
    /// padding: 12px`, a 1 px light border (7436-7441).
    public static let cardGap = 12.0
    public static let cardInnerGap = 4.0
    public static let cardPadding = 12.0
    /// `.copy-paste-conflict-alert-apply`: `gap: 8px` (7461).
    public static let checkboxGap = 8.0
}
