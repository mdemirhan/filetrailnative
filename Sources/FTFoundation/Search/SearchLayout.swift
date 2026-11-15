// The results bar, the push button's small size, the segmented control, the rounded search field, the toolbar capsule
// and the match mark
import Foundation

/// The metrics of search's own pieces.
public struct SearchLayout: Equatable, Sendable {
    // MARK: Results bar

    /// The scope bar, and the Trash bar built like it: its tallest control starts at the pane's content top
    /// (`DesignTokens.paneContentTop`), clear of the active pane's line and its glow, with 6 under it, 12 at the sides
    /// and 6 between its parts.
    public var scopeBarPaddingBottom: Double
    public var scopeBarPaddingHorizontal: Double
    public var scopeBarGap: Double
    /// The gap after the scope label.
    public var scopeLabelMarginTrailing: Double
    /// The line under the results header.
    public var headerBorderWidth: Double

    /// The segmented control: the control height, a 2 pt track around segments 2 apart; a segment: padding 0 12,
    /// 20 high, at most 220 wide.
    public var segmentedTrackPadding: Double
    public var segmentedGap: Double
    public var segmentPaddingHorizontal: Double
    public var segmentHeight: Double
    public var segmentMaxWidth: Double

    /// The results filter: 280 wide, and at least 200 beside the scope segments: a bar with less room shows the scopes
    /// as one pop-up button and the filter takes the rest. The pop-up is `scopeMenuMaxWidth` at most, and where it
    /// would leave the filter less than its 200 its name is cut short, down to `scopeMenuMinWidth` (its icon, a few
    /// letters and its arrows); only then does the filter give up more. Its field: the control height,
    /// padding 0 4, 6 between the chip, the text and the clear button. It has no icon: the chip and the placeholder say
    /// what it is.
    public var filterWidth: Double
    public var filterMinWidth: Double
    public var scopeMenuMaxWidth: Double
    public var scopeMenuMinWidth: Double
    public var fieldHeight: Double
    public var fieldPaddingLeading: Double
    public var fieldPaddingTrailing: Double
    public var fieldGap: Double
    public var clearButtonSize: Double

    /// A push button of the bar: the control height, as the scopes and the filter are, padding 0 10, no minimum width, the callout size; a 6 pt
    /// gap before the label; its spinner 10 across, stroked 1.5.
    public var smallButtonHeight: Double
    public var smallButtonPaddingHorizontal: Double
    public var smallButtonGap: Double
    public var spinnerSize: Double
    public var spinnerLineWidth: Double

    /// The results banner: margin 0 6 12, padding 10 12, a 1 pt edge, the menu radius, the callout size; the
    /// accent at 22% over the border for its edge and at 6% for its fill.
    public var bannerMarginHorizontal: Double
    public var bannerMarginBottom: Double
    public var bannerPaddingVertical: Double
    public var bannerPaddingHorizontal: Double
    public var bannerBorderWidth: Double
    public var bannerBorderAccentShare: Double
    public var bannerFillAccentAlpha: Double

    // MARK: The match in names

    /// The match mark: rgba(255, 214, 10, 0.45), radius xs, padding 0 1 (none under an icon); on a selected
    /// row an underline 1.5 thick, 2 below.
    public var markRed: Double
    public var markGreen: Double
    public var markBlue: Double
    public var markAlpha: Double
    public var markPaddingHorizontal: Double
    public var underlineThickness: Double
    public var underlineOffset: Double

    /// The tab's magnifier: 12 across.
    public var tabMagnifierSize: Double

    public static let standard = SearchLayout(
        scopeBarPaddingBottom: 6, scopeBarPaddingHorizontal: 12, scopeBarGap: 6,
        scopeLabelMarginTrailing: 2, headerBorderWidth: 1, segmentedTrackPadding: 2, segmentedGap: 2,
        segmentPaddingHorizontal: 12, segmentHeight: 20, segmentMaxWidth: 220,
        filterWidth: 280, filterMinWidth: 200, scopeMenuMaxWidth: 220, scopeMenuMinWidth: 72,
        fieldHeight: 24,
        fieldPaddingLeading: 4, fieldPaddingTrailing: 4, fieldGap: 6, clearButtonSize: 16, smallButtonHeight: 24,
        smallButtonPaddingHorizontal: 10, smallButtonGap: 6,
        spinnerSize: 10, spinnerLineWidth: 1.5, bannerMarginHorizontal: 6, bannerMarginBottom: 12,
        bannerPaddingVertical: 10, bannerPaddingHorizontal: 12, bannerBorderWidth: 1, bannerBorderAccentShare: 0.22,
        bannerFillAccentAlpha: 0.06,

        markRed: 255, markGreen: 214, markBlue: 10, markAlpha: 0.45,
        markPaddingHorizontal: 1, underlineThickness: 1.5, underlineOffset: 2, tabMagnifierSize: 12)
}
