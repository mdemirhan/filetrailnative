import AppKit
import FTFoundation

/// The line along the top of the active pane, with one pane as with two. It says where the keyboard is, as the
/// selection's color does, but also with nothing selected: the accent with a narrow glow under it while the pane has
/// the keyboard, the accent dimmed while the keyboard is elsewhere in the window (the sidebar, a field), and grey while
/// the window is in the background. The glow fades out toward the line's ends and down into the pane. It takes no
/// clicks: the column header and the items under it get them.
final class ActivePaneLine: NSView {
    enum Look: Equatable {
        /// The pane has the keyboard.
        case lit
        /// The keyboard is elsewhere in the window.
        case dimmed
        /// The window is in the background.
        case background
    }

    /// The line's thickness.
    static let lineHeight = 2.0
    /// How far the glow reaches into the pane under the line.
    static let glowHeight = 14.0
    /// The space between the line's ends and the pane's sides.
    static let inset = 8.0
    /// The line's accent while the keyboard is elsewhere in the window.
    static let dimmedAlpha = 0.45
    /// The glow's strength just under the line, on a light and a dark theme; it fades to nothing at `glowHeight`.
    static let glowAlpha = (light: 0.26, dark: 0.45)
    /// The share of the width at each end over which the glow fades in.
    static let glowEdgeFade = 0.12
    /// The glow down from the line, in steps along `(1 - t)^1.6`: soft at its foot, without a visible edge.
    static let glowStops: [(location: Double, strength: Double)] = [
        (0, 1), (0.25, 0.63), (0.5, 0.33), (0.75, 0.11), (1, 0),
    ]

    /// The height it takes: the line and the glow under it.
    static var height: Double { lineHeight + glowHeight }

    /// Where the line goes over a pane at `cell`, whose top is `top`.
    static func frame(over cell: NSRect, top: Double) -> NSRect {
        NSRect(x: cell.minX + inset, y: top, width: max(0, cell.width - inset * 2), height: height)
    }

    var look = Look.lit {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Clicks go through to the pane under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
        let theme = Theme.of(self)
        let accent = theme.accent.solid
        if look == .lit {
            drawGlow(in: context, accent: accent, strength: theme.isDark ? Self.glowAlpha.dark : Self.glowAlpha.light)
        }
        let color: RGBA
        switch look {
        case .lit: color = accent
        case .dimmed: color = accent.withAlpha(Self.dimmedAlpha)
        case .background: color = theme.palette.borderActive
        }
        NSColor(color).setFill()
        let line = NSRect(x: 0, y: 0, width: bounds.width, height: Self.lineHeight)
        NSBezierPath(roundedRect: line, xRadius: Self.lineHeight / 2, yRadius: Self.lineHeight / 2).fill()
    }

    /// The accent fading down from under the line, then faded in from each end.
    private func drawGlow(in context: CGContext, accent: RGBA, strength: Double) {
        let area = CGRect(x: 0, y: Self.lineHeight, width: bounds.width, height: Self.glowHeight)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let down = CGGradient(
            colorsSpace: space,
            colors: Self.glowStops.map { NSColor(accent.withAlpha(strength * $0.strength)).cgColor } as CFArray,
            locations: Self.glowStops.map { CGFloat($0.location) })
        let fade = Self.glowEdgeFade
        let ends = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                CGColor(gray: 0, alpha: 0),
            ] as CFArray,
            locations: [0, fade, 1 - fade, 1])
        guard let down, let ends else { return }
        context.saveGState()
        context.clip(to: area)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.drawLinearGradient(
            down, start: CGPoint(x: 0, y: area.minY), end: CGPoint(x: 0, y: area.maxY), options: [])
        // What was drawn keeps as much of itself as the ends gradient has there.
        context.setBlendMode(.destinationIn)
        context.drawLinearGradient(
            ends, start: CGPoint(x: area.minX, y: 0), end: CGPoint(x: area.maxX, y: 0), options: [])
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
