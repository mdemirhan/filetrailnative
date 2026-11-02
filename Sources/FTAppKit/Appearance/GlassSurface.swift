// No TypeScript source: the system's Liquid Glass for what floats briefly over a window
import AppKit
import FTFoundation

/// Liquid Glass behind a view's own subviews, from macOS 26. On earlier systems the views keep the surfaces they draw
/// for themselves. A sheet to fill in stays opaque, as the system's own do; it only takes their corners.
@MainActor
enum GlassSurface {
    static var isAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// The corners of the system's alert.
    static let alertRadius: CGFloat = 26
    /// The corners of the progress card.
    static let cardRadius: CGFloat = 20

    /// The corners of a sheet: the system's where sheets have them, the original's before that.
    static var sheetRadius: CGFloat {
        isAvailable ? 20 : CGFloat(DesignTokens.radii.dialog)
    }

    /// Text that would be secondary on an opaque surface is the primary color on glass: a translucent color is flattened
    /// onto an opaque background (`TextStyle`), which reads too light over what shows through.
    static func text(_ theme: Theme) -> RGBA {
        isAvailable ? theme.palette.textPrimary : theme.palette.textSecondary
    }

    /// Puts glass behind `view`'s subviews in place of the fill of its layer.
    static func install(in view: NSView, radius: CGFloat) {
        guard #available(macOS 26, *) else { return }
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.cornerRadius = radius
        let glass = view.subviews.lazy.compactMap { $0 as? PassiveGlass }.first ?? newGlass(in: view)
        glass.cornerRadius = radius
    }

    /// As `install`, for a card over the panes: plain glass has no edge over a white pane, so the layer's edge and shadow
    /// stay. A clear layer takes its shadow from what it holds unless it is told the shape.
    static func installFloating(in view: NSView, radius: CGFloat) {
        guard isAvailable else { return }
        install(in: view, radius: radius)
        view.layer?.shadowPath = CGPath(
            roundedRect: view.bounds, cornerWidth: min(radius, view.bounds.height / 2),
            cornerHeight: min(radius, view.bounds.height / 2), transform: nil)
    }

    /// Whether `view` lies on glass.
    static func holds(_ view: NSView) -> Bool {
        guard #available(macOS 26, *) else { return false }
        return view.subviews.contains { $0 is PassiveGlass }
    }

    @available(macOS 26, *)
    private static func newGlass(in view: NSView) -> PassiveGlass {
        let glass = PassiveGlass(frame: view.bounds)
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass, positioned: .below, relativeTo: nil)
        return glass
    }
}

/// The glass of a surface: a press on it belongs to the surface.
@available(macOS 26, *)
private final class PassiveGlass: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
