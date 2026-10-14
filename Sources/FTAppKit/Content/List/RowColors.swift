// Port of the row colors of apps/desktop/src/renderer/styles.css:2890-2950 and 4455-4500 (stripes, the selection of a
// focused and an unfocused list, the window in the background)
import FTFoundation

/// The colors a List row is drawn in.
struct RowColors: Equatable {
    /// The bar behind the row; nil for an even row that is not selected.
    var background: RGBA?
    var name: RGBA
    var cell: RGBA
    /// The muted "--" of a folder whose size is not calculated.
    var placeholder: RGBA
    /// The size bar: the accent, or the selection text on a row selected in the focused list.
    var sizeBar: RGBA
    var sizeBarAlpha: Double

    /// - `odd`: the row's absolute index is odd (even rows have no stripe).
    /// - `paneFocused`: the list has the keyboard (a selected row is `inactive` otherwise).
    /// - `windowActive`: the window is in front (`body.window-inactive` turns the selection tokens grey).
    static func make(
        theme: Theme, layout: DetailsLayout, selected: Bool, odd: Bool, paneFocused: Bool, windowActive: Bool
    ) -> RowColors {
        let palette = theme.palette
        let accent = theme.accent
        let stripe = odd ? palette.neutralInk.withAlpha(DesignTokens.stripeInkAlpha) : nil
        guard selected else {
            return RowColors(
                background: stripe, name: palette.textPrimary, cell: palette.textSecondary,
                placeholder: palette.textSecondary, sizeBar: accent.solid, sizeBarAlpha: layout.sizeBarAlpha)
        }
        guard paneFocused else {
            // Selected in a list that doesn't have the keyboard: grey, with the ordinary text.
            return RowColors(
                background: palette.bgActiveInactive, name: palette.textPrimary, cell: palette.textSecondary,
                placeholder: palette.textSecondary, sizeBar: accent.solid, sizeBarAlpha: layout.sizeBarAlpha)
        }
        if windowActive {
            return RowColors(
                background: accent.selectionBg, name: accent.onSelection, cell: accent.onSelection,
                placeholder: accent.onSelectionSoft, sizeBar: accent.onSelection,
                sizeBarAlpha: layout.sizeBarSelectedAlpha)
        }
        // The window in the background draws every selection as an unfocused one, in the selection tokens' grey.
        return RowColors(
            background: palette.bgActiveInactive, name: palette.textPrimary, cell: palette.textPrimary,
            placeholder: palette.textSecondary, sizeBar: palette.textPrimary, sizeBarAlpha: layout.sizeBarSelectedAlpha)
    }
}
