// Port of the search rules of apps/desktop/src/renderer/styles.css: the results bar (.search-results-header,
// .search-scope-bar, .search-scope-segmented, .search-results-filter, .search-results-banner, :3021-3040, 4502-4527,
// 6556-6583), the push button's small size (:1293-1299, .push-button .spinner :3383-3388), the segmented control
// (:1395-1440), the rounded search field (:1353-1395), the toolbar capsule (:903-972, 6371-6393) and the match mark
// (.search-result-match, :6605-6627)
import Foundation

/// The metrics of search's own pieces, as the stylesheet sets them.
public struct SearchLayout: Equatable, Sendable {
    // MARK: Results bar

    /// `.search-scope-bar`: padding 6 12, at least 36 tall, 6 between its parts.
    public var scopeBarPaddingVertical: Double
    public var scopeBarPaddingHorizontal: Double
    public var scopeBarMinHeight: Double
    public var scopeBarGap: Double
    /// `.search-scope-label { margin-right: 2px }`.
    public var scopeLabelMarginTrailing: Double
    /// `.search-results-header { border-bottom: 1px }`.
    public var headerBorderWidth: Double

    /// `.segmented`: a 2 pt track around segments 2 apart; `.segmented-item`: padding 0 12, the control height;
    /// `.search-scope-button { max-width: 220px }`.
    public var segmentedTrackPadding: Double
    public var segmentedGap: Double
    public var segmentPaddingHorizontal: Double
    public var segmentHeight: Double
    public var segmentMaxWidth: Double
    /// `--segmented-selected-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.2)`.
    public var segmentShadowOffsetY: Double
    public var segmentShadowBlur: Double
    public var segmentShadowAlpha: Double

    /// `.search-results-filter`: 200 wide, at least 90 (`flex: 0 1 200px`); `.search-field`: the control height,
    /// padding 0 4 0 8, 6 between the icon, the text and the clear button; a 13 pt icon stroked 2.
    public var filterWidth: Double
    public var filterMinWidth: Double
    public var fieldHeight: Double
    public var fieldPaddingLeading: Double
    public var fieldPaddingTrailing: Double
    public var fieldGap: Double
    public var fieldIconSize: Double
    public var fieldIconStrokeWidth: Double
    public var clearButtonSize: Double

    /// `.push-button.is-small`: the small control height, padding 0 10, no minimum width, the callout size; a 6 pt
    /// gap before the label; its spinner 10 across, stroked 1.5.
    public var smallButtonHeight: Double
    public var smallButtonPaddingHorizontal: Double
    public var smallButtonGap: Double
    public var spinnerSize: Double
    public var spinnerLineWidth: Double

    /// `.search-results-banner`: margin 0 6 12, padding 10 12, a 1 pt edge, the menu radius, the callout size; the
    /// accent at 22% over the border for its edge and at 6% for its fill.
    public var bannerMarginHorizontal: Double
    public var bannerMarginBottom: Double
    public var bannerPaddingVertical: Double
    public var bannerPaddingHorizontal: Double
    public var bannerBorderWidth: Double
    public var bannerBorderAccentShare: Double
    public var bannerFillAccentAlpha: Double

    // MARK: Toolbar capsule

    /// `.window-toolbar .toolbar-search-shell.active .toolbar-search`: a 1 pt edge of the accent at 70%, and the focus
    /// ring.
    public var capsuleActiveBorderWidth: Double
    public var capsuleActiveBorderAlpha: Double
    /// `.toolbar-search-options-button`: 20 tall, padding 0 3 (margins −3), radius xs; the chevron 8 across,
    /// stroked 1.4, 1 after the magnifier.
    public var optionsButtonHeight: Double
    public var optionsButtonPadding: Double
    public var optionsChevronSize: Double
    public var optionsChevronStrokeWidth: Double
    public var optionsChevronGap: Double
    /// The options menu hangs 12 in from the window's edges at most (`placeDropdownMenu`'s margin).
    public var optionsMenuMargin: Double

    // MARK: The match in names

    /// `.search-result-match`: rgba(255, 214, 10, 0.45), radius xs, padding 0 1 (none under an icon); on a selected
    /// row an underline 1.5 thick, 2 below.
    public var markRed: Double
    public var markGreen: Double
    public var markBlue: Double
    public var markAlpha: Double
    public var markPaddingHorizontal: Double
    public var underlineThickness: Double
    public var underlineOffset: Double

    /// The tab's magnifier (`.tab-strip-search`): 12 across.
    public var tabMagnifierSize: Double

    public static let standard = SearchLayout(
        scopeBarPaddingVertical: 6, scopeBarPaddingHorizontal: 12, scopeBarMinHeight: 36, scopeBarGap: 6,
        scopeLabelMarginTrailing: 2, headerBorderWidth: 1, segmentedTrackPadding: 2, segmentedGap: 2,
        segmentPaddingHorizontal: 12, segmentHeight: 24, segmentMaxWidth: 220, segmentShadowOffsetY: 0.5,
        segmentShadowBlur: 1.5, segmentShadowAlpha: 0.2, filterWidth: 200, filterMinWidth: 90, fieldHeight: 24,
        fieldPaddingLeading: 8, fieldPaddingTrailing: 4, fieldGap: 6, fieldIconSize: 13, fieldIconStrokeWidth: 2,
        clearButtonSize: 16, smallButtonHeight: 22, smallButtonPaddingHorizontal: 10, smallButtonGap: 6,
        spinnerSize: 10, spinnerLineWidth: 1.5, bannerMarginHorizontal: 6, bannerMarginBottom: 12,
        bannerPaddingVertical: 10, bannerPaddingHorizontal: 12, bannerBorderWidth: 1, bannerBorderAccentShare: 0.22,
        bannerFillAccentAlpha: 0.06, capsuleActiveBorderWidth: 1, capsuleActiveBorderAlpha: 0.7,
        optionsButtonHeight: 20, optionsButtonPadding: 3, optionsChevronSize: 8, optionsChevronStrokeWidth: 1.4,
        optionsChevronGap: 1, optionsMenuMargin: 12, markRed: 255, markGreen: 214, markBlue: 10, markAlpha: 0.45,
        markPaddingHorizontal: 1, underlineThickness: 1.5, underlineOffset: 2, tabMagnifierSize: 12)
}
