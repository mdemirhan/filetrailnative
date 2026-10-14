// Port of apps/desktop/src/renderer/lib/menuPlacement.ts (the dropdown and viewport parts) and
// hooks/useKeepInViewport.ts
import Foundation

/// Where the app's own menus go: under the toolbar item that opens them, then moved back inside the window.
public enum MenuPlacement {
    /// `MENU_VIEWPORT_MARGIN`.
    public static let viewportMargin = 8.0
    /// How far below its button a toolbar menu drops.
    public static let dropGap = 6.0

    /// `getViewportShift`: how far a box spanning `start`..`end` must move along one axis to sit inside
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

    /// `placeDropdownMenu`, resolved to a left edge for a menu `menuWidth` wide: it lines up with the edge of its
    /// button that leaves it the most room, the left edge for a button in the left half of the window, the right
    /// edge for one in the right half; then `useKeepInViewport` holds it inside the window.
    public static func dropdown(
        anchorLeft: Double, anchorRight: Double, anchorBottom: Double, menuWidth: Double, menuHeight: Double,
        viewportWidth: Double, viewportHeight: Double, gap: Double = dropGap, margin: Double = viewportMargin
    ) -> (left: Double, top: Double) {
        let top = anchorBottom + gap
        let left =
            (anchorLeft + anchorRight) / 2 < viewportWidth / 2
            ? max(margin, anchorLeft) : viewportWidth - max(margin, viewportWidth - anchorRight) - menuWidth
        return keepInViewport(
            left: left, top: top, width: menuWidth, height: menuHeight, viewportWidth: viewportWidth,
            viewportHeight: viewportHeight)
    }

    /// `useKeepInViewport`: a box at (`left`, `top`) moved back inside the window.
    public static func keepInViewport(
        left: Double, top: Double, width: Double, height: Double, viewportWidth: Double, viewportHeight: Double
    ) -> (left: Double, top: Double) {
        (
            left + viewportShift(start: left, end: left + width, viewportSize: viewportWidth),
            top + viewportShift(start: top, end: top + height, viewportSize: viewportHeight)
        )
    }
}
