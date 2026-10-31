// Port of the .batch-rename-* rules of apps/desktop/src/renderer/styles.css (6696-7170), the segmented control (1405-1450)
// and the glyphs of the copy sheet it uses (7303-7330, 7395-7420)
import Foundation

/// The metrics the Rename sheet for several items is drawn with. Type sizes, radii and control heights come from the
/// design tokens; what is here is each rule's own number.
public enum BatchRenameSheetLayout {
    /// `.batch-rename-sheet`: `width: min(680px, calc(100vw - 48px)); max-height: calc(100vh - 60px - 24px)`.
    public static let width = 680.0
    public static let viewportInset = 48.0
    public static let heightInset = DialogLayout.sheetTop + 24.0
    public static var radius: Double { DesignTokens.radii.dialog }
    public static var controlHeight: Double { DesignTokens.controlHeights.regular }

    /// `.batch-rename-header`: `gap: 8px; padding: 20px 20px 14px`.
    public enum Header {
        public static let paddingTop = 20.0
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
        public static let gap = 8.0
        /// `.batch-rename-preset-save`: `gap: 8px`, its field 180 wide.
        public static let presetSaveGap = 8.0
        public static let presetFieldWidth = 180.0
        /// `.batch-rename-presets select`: `min-width: 120px`.
        public static let presetsMinWidth = 120.0
    }

    /// `.batch-rename-modes` (`padding: 0 20px 14px`) and `.segmented` / `.segmented-item`.
    public enum Modes {
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
        public static let trackPadding = 2.0
        public static let segmentGap = 2.0
        public static let segmentPadding = 12.0
    }

    /// `.batch-rename-options`: `gap: 10px; padding: 0 20px 14px`.
    public enum Options {
        public static let gap = 10.0
        public static let paddingHorizontal = 20.0
        public static let paddingBottom = 14.0
    }

    /// `.batch-rename-grid`: `grid-template-columns: 112px minmax(0, 1fr) 132px minmax(0, 1fr); gap: 8px`.
    public enum Grid {
        public static let firstLabelWidth = 112.0
        public static let secondLabelWidth = 132.0
        public static let gap = 8.0
        /// `.batch-rename-label.is-second`: `margin-left: 12px`.
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

    /// `.batch-rename-field`: `padding: 0 8px`; `.is-number`: 72 wide; `.batch-rename-field-message`: `margin: -2px 0 0`.
    public enum Field {
        public static let paddingHorizontal = 8.0
        public static let numberWidth = 72.0
        public static let messageMarginTop = -2.0
        /// `[aria-invalid="true"]`: `inset 0 0 0 1px var(--danger)`.
        public static let invalidEdge = 1.0
    }

    /// `.batch-rename-popup select` (`padding: 0 26px 0 8px`) and `.batch-rename-popup-chevron` (11 by 11, 8 from the
    /// right, stroked 2.4 in a 24 box).
    public enum Popup {
        public static let paddingLeft = 8.0
        public static let paddingRight = 26.0
        public static let chevronSize = 11.0
        public static let chevronRight = 8.0
        public static let chevronViewBox = 24.0
        public static let chevronStroke = 2.4
    }

    /// `.batch-rename-checks` (`gap: 6px 16px`) and `.batch-rename-check` (`gap: 6px`, a 14 by 14 box).
    public enum Check {
        public static let rowGap = 6.0
        public static let columnGap = 16.0
        public static let gap = 6.0
        public static let boxSize = 14.0
        /// The check drawn in a 14 box, stroked 1.8.
        public static let markStroke = 1.8
        /// `box-shadow: inset 0 0 0 0.5px var(--check-border)`.
        public static let edge = 0.5
    }

    /// `.batch-rename-advice`: `gap: 6px`, the warning glyph 16 by 16.
    public enum Advice {
        public static let gap = 6.0
        public static let glyphSize = 16.0
        public static let glyphViewBox = 16.0
        public static let markStroke = 1.5
    }

    /// `.batch-rename-pattern` (`gap: 6px`), `.batch-rename-tokens` (`gap: 4px`) and `.batch-rename-token`
    /// (20 tall, `padding: 0 7px`).
    public enum Tokens {
        public static let patternGap = 6.0
        public static let gap = 4.0
        public static let height = 20.0
        public static let paddingHorizontal = 7.0
    }

    /// `.batch-rename-preview` and its rows.
    public enum Preview {
        /// `margin: 0 20px; border-radius: 8px; box-shadow: inset 0 0 0 0.5px var(--border-active)`.
        public static let marginHorizontal = 20.0
        public static let radius = 8.0
        public static let edge = 0.5
        /// `grid-template-columns: 18px minmax(0, 1fr) 14px minmax(0, 1.25fr); column-gap: 8px; padding: 0 12px`.
        public static let glyphColumn = 18.0
        public static let arrowColumn = 14.0
        public static let newNameShare = 1.25
        public static let columnGap = 8.0
        public static let paddingHorizontal = 12.0
        /// `.batch-rename-preview-head`: `min-height: 22px; border-bottom: 1px`.
        public static let headHeight = 22.0
        public static let headBorder = 1.0
        /// `.batch-rename-rows`: `max-height: calc(8 * 28px)`.
        public static let maxRowsHeight = 8 * 28.0
        /// `.batch-rename-row`: `min-height: 26px; padding-top: 3px; padding-bottom: 3px`.
        public static let rowMinHeight = 26.0
        public static let rowPaddingVertical = 3.0
        /// `.batch-rename-glyph` 16 by 16 in an 18 box; `.batch-rename-arrow` 12 by 12, stroked 1.4.
        public static let glyphSize = 16.0
        public static let glyphViewBox = 18.0
        public static let arrowSize = 12.0
        public static let arrowStroke = 1.4
        /// `.batch-rename-changed`: `margin: 0 -1px; padding: 0 1px; border-radius: 3px`.
        public static let markPadding = 1.0
        public static let markRadius = 3.0
        /// The stripe of every second row, the tint of a row to fix and of its marks (`color-mix` percentages).
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

    /// `.batch-rename-footer`: `gap: 8px; padding: 12px 20px 16px; border-top: 1px`.
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
        /// The sheet, its labels, fields, pop-ups and names: `--font-size-body`.
        public static var body: Double { DesignTokens.typeScale.body }
        /// Notes, messages, the preview's header and the row notes: `--font-size-small`.
        public static var small: Double { DesignTokens.typeScale.small }
        /// The summary: `--font-size-callout`.
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
