// The results bar, the push button's small size, the segmented control, the rounded search field, the toolbar capsule
// and the match mark
import Foundation

/// The metrics of search's own pieces.
public struct SearchLayout: Equatable, Sendable {
    // MARK: Results bar

    /// The scope bar: padding 6 12, at least 36 tall, 6 between its parts.
    public var scopeBarPaddingVertical: Double
    public var scopeBarPaddingHorizontal: Double
    public var scopeBarMinHeight: Double
    public var scopeBarGap: Double
    /// The gap after the scope label.
    public var scopeLabelMarginTrailing: Double
    /// The line under the results header.
    public var headerBorderWidth: Double

    /// The segmented control: a 2 pt track around segments 2 apart; a segment: padding 0 12, the control height,
    /// at most 220 wide.
    public var segmentedTrackPadding: Double
    public var segmentedGap: Double
    public var segmentPaddingHorizontal: Double
    public var segmentHeight: Double
    public var segmentMaxWidth: Double

    /// The results filter: 280 wide, at least 150, so the mode chip leaves room for the text; its field: the control
    /// height, padding 0 4 0 8, 6 between the icon, the chip, the text and the clear button; a 13 pt icon stroked 2.
    public var filterWidth: Double
    public var filterMinWidth: Double
    public var fieldHeight: Double
    public var fieldPaddingLeading: Double
    public var fieldPaddingTrailing: Double
    public var fieldGap: Double
    public var fieldIconSize: Double
    public var fieldIconStrokeWidth: Double
    public var clearButtonSize: Double

    /// A small push button: the small control height, padding 0 10, no minimum width, the callout size; a 6 pt
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
        scopeBarPaddingVertical: 6, scopeBarPaddingHorizontal: 12, scopeBarMinHeight: 36, scopeBarGap: 6,
        scopeLabelMarginTrailing: 2, headerBorderWidth: 1, segmentedTrackPadding: 2, segmentedGap: 2,
        segmentPaddingHorizontal: 12, segmentHeight: 24, segmentMaxWidth: 220,
        filterWidth: 280, filterMinWidth: 150, fieldHeight: 24,
        fieldPaddingLeading: 8, fieldPaddingTrailing: 4, fieldGap: 6, fieldIconSize: 13, fieldIconStrokeWidth: 2,
        clearButtonSize: 16, smallButtonHeight: 22, smallButtonPaddingHorizontal: 10, smallButtonGap: 6,
        spinnerSize: 10, spinnerLineWidth: 1.5, bannerMarginHorizontal: 6, bannerMarginBottom: 12,
        bannerPaddingVertical: 10, bannerPaddingHorizontal: 12, bannerBorderWidth: 1, bannerBorderAccentShare: 0.22,
        bannerFillAccentAlpha: 0.06,

        markRed: 255, markGreen: 214, markBlue: 10, markAlpha: 0.45,
        markPaddingHorizontal: 1, underlineThickness: 1.5, underlineOffset: 2, tabMagnifierSize: 12)
}
