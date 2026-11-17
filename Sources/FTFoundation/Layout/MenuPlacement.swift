import Foundation

/// Where the app's own menus go: under the toolbar item that opens them, then moved back inside the window.
public enum MenuPlacement {
    public static let viewportMargin = 8.0
    /// How far below its button a toolbar menu drops.
    public static let dropGap = 6.0

    /// How far a box spanning `start`..`end` must move along one axis to sit inside
    /// `margin`..`viewportSize - margin`. A box larger than that space is pinned to its start.
    public static func viewportShift(start: Double, end: Double, viewportSize: Double, margin: Double = viewportMargin)
        -> Double
    {
        let lower = margin
        let upper = viewportSize - margin
        if end - start >= upper - lower { return lower - start }
        if start < lower { return lower - start }
        if end > upper { return upper - end }
        return 0
    }

    /// Resolved to a left edge for a menu `menuWidth` wide: its left edge under its button's, as the system's toolbar
    /// menus drop, then moved back inside the window, so a menu near the right edge moves left only as far as it must.
    public static func dropdown(
        anchorLeft: Double, anchorBottom: Double, menuWidth: Double, menuHeight: Double,
        viewportWidth: Double, viewportHeight: Double, gap: Double = dropGap
    ) -> (left: Double, top: Double) {
        keepInViewport(
            left: anchorLeft, top: anchorBottom + gap, width: menuWidth, height: menuHeight,
            viewportWidth: viewportWidth, viewportHeight: viewportHeight)
    }

    /// A box at (`left`, `top`) moved back inside the window.
    public static func keepInViewport(
        left: Double, top: Double, width: Double, height: Double, viewportWidth: Double, viewportHeight: Double
    ) -> (left: Double, top: Double) {
        (
            left + viewportShift(start: left, end: left + width, viewportSize: viewportWidth),
            top + viewportShift(start: top, end: top + height, viewportSize: viewportHeight)
        )
    }
}
