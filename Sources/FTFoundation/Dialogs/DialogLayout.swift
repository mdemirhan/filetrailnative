// Port of the scrim, alert, text prompt, detail list and Go To box rules of apps/desktop/src/renderer/styles.css
// (1229-1243, 1459-1558, 1740-1792, 3437-3666)
import Foundation

/// The metrics the in-window alert, the text prompt and the Go To / Move To box are drawn with. Type sizes, radii and
/// control heights come from the design tokens; what is here is each rule's own number.
public enum DialogLayout {
    /// `.modal-scrim.is-sheet` (1242) and `.go-to-folder-backdrop` (3447): a sheet drops in 60 below the window's top.
    public static let sheetTop = 60.0

    /// `.alert` and its parts.
    public enum Alert {
        /// `width: 272px; max-width: calc(100vw - 32px)` (1473-1474).
        public static let width = 272.0
        public static let viewportInset = 32.0
        /// `padding: 20px 16px 16px` (1477).
        public static let paddingTop = 20.0
        public static let paddingHorizontal = 16.0
        public static let paddingBottom = 16.0
        /// `.alert-title`: bold, `line-height: 1.3` (1493).
        public static let titleLineHeight = 1.3
        /// `.alert-message`: `margin: 6px 0 0`, `line-height: 1.4` (1498, 1501).
        public static let messageGap = 6.0
        public static let messageLineHeight = 1.4
        /// `.alert-accessory`: `margin-top: 12px` (1507).
        public static let accessoryGap = 12.0
        /// `.alert-buttons`: `gap: 8px; margin-top: 16px` (1516, 1518).
        public static let buttonSpacing = 8.0
        public static let buttonsGap = 16.0
        /// `.alert.is-wide`: `width: min(520px, calc(100vw - 48px)); padding: 20px` (1534-1535).
        public static let wideWidth = 520.0
        public static let wideViewportInset = 48.0
        public static let widePadding = 20.0
        /// `.alert.is-wide .alert-accessory`: `gap: 12px; margin-top: 14px` (1551-1552).
        public static let wideAccessorySpacing = 12.0
        public static let wideAccessoryGap = 14.0
    }

    /// `.copy-paste-detail-list` (1779-1792): what an alert lists under its message.
    public enum DetailList {
        /// `padding: 8px 10px` (1781).
        public static let paddingVertical = 8.0
        public static let paddingHorizontal = 10.0
        /// `line-height: 1.4` (1786).
        public static let lineHeight = 1.4
        /// `li + li { margin-top: 2px }` (1790).
        public static let rowGap = 2.0
    }

    /// `.text-prompt-form`, `.text-prompt-input` and `.text-prompt-error` (1740-1765).
    public enum TextPrompt {
        /// `gap: 6px` (1742).
        public static let errorGap = 6.0
        /// `padding: 0 8px` (1749).
        public static let fieldPaddingHorizontal = 8.0
        /// `line-height: 1.4` (1767).
        public static let errorLineHeight = 1.4
    }

    /// `.go-to-folder-*` (3437-3666).
    public enum GoTo {
        /// `width: min(560px, calc(100vw - 32px)); max-height: calc(100vh - 84px); padding: 12px 0 0` (3456-3459).
        public static let width = 560.0
        public static let viewportInset = 32.0
        public static let heightInset = 84.0
        public static let paddingTop = 12.0
        /// `.go-to-folder-title`: `margin: 2px 16px 10px` (3471).
        public static let titleTop = 2.0
        public static let titleHorizontal = 16.0
        public static let titleBottom = 10.0
        /// `.go-to-folder-input-section`: `padding: 0 12px` (3478).
        public static let inputSectionHorizontal = 12.0
        /// `.go-to-folder-input-shell`: `gap: 8px; padding: 0 8px` (3484, 3487).
        public static let fieldGap = 8.0
        public static let fieldPaddingHorizontal = 8.0
        /// `.go-to-folder-input-icon`: 14 by 14, stroked 1.5 (3499-3502).
        public static let fieldIconSize = 14.0
        public static let fieldIconStroke = 1.5
        /// `.go-to-folder-error`: `margin-top: 6px; padding: 0 4px` (3534-3535).
        public static let errorTop = 6.0
        public static let errorHorizontal = 4.0
        /// `.go-to-folder-suggestions-section`: `padding: 10px 6px 6px` (3545).
        public static let sectionTop = 10.0
        public static let sectionHorizontal = 6.0
        public static let sectionBottom = 6.0
        /// `.go-to-folder-suggestions-label`: `gap: 12px; padding: 0 10px 4px` (3554-3555).
        public static let labelGap = 12.0
        public static let labelHorizontal = 10.0
        public static let labelBottom = 4.0
        /// `max-height: calc(8 * var(--control-height-large))` (3569).
        public static let visibleRows = 8
        /// `.go-to-folder-empty-state`: `padding: 18px 16px 22px` (3577).
        public static let emptyTop = 18.0
        public static let emptyHorizontal = 16.0
        public static let emptyBottom = 22.0
        /// `.go-to-folder-suggestion`: `gap: 8px; padding: 0 10px` (3587, 3591).
        public static let rowGap = 8.0
        public static let rowPaddingHorizontal = 10.0
        /// `.go-to-folder-suggestion-icon svg`: 14 by 14, stroked 1.3 (3617-3620).
        public static let rowGlyphSize = 14.0
        public static let rowGlyphStroke = 1.3
        /// `.go-to-folder-suggestion-name`: `max-width: 55%` (3625).
        public static let nameMaxFraction = 0.55
        /// `.go-to-folder-suggestion.is-selected .go-to-folder-suggestion-path`: the text on the accent at 80% (3652).
        public static let selectedPathAlpha = 0.8
        /// `.go-to-folder-footer`: `gap: 8px; padding: 10px 12px 12px; border-top: 1px` (3659-3661).
        public static let footerGap = 8.0
        public static let footerTop = 10.0
        public static let footerHorizontal = 12.0
        public static let footerBottom = 12.0
        public static let footerBorder = 1.0
    }
}
