// How a row, an icon and the pane say what a drop on them would do
import AppKit
import FTFoundation

/// What a drop on a row, an icon or the pane would do, while a drag is over it.
enum DropTargetState: String, Equatable, Sendable {
    case valid, invalid
    /// A folder about to spring open: drawn as a valid one, its icon wiggling.
    case springing
}

/// The drop highlight of a row of the List or an item of the Compact List.
@MainActor
enum DropHighlight {
    /// Draws the highlight of a row in `rect`, rounded by `radius`, over what the row already drew.
    static func drawRow(_ state: DropTargetState, in rect: NSRect, radius: CGFloat, theme: Theme) {
        let palette = theme.palette
        let accent = theme.accent
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        switch state {
        case .valid, .springing:
            NSColor(colorMix(accent.softBg, ClipboardLayout.Drop.fillMix, palette.bgElevated)).setFill()
            shape.fill()
            // The halo, inside the row so neighbors don't cover it.
            NSColor(accent.border.withAlpha(accent.border.alpha * ClipboardLayout.Drop.rowHaloAlpha)).setStroke()
            let halo = NSBezierPath(
                roundedRect: rect.insetBy(
                    dx: ClipboardLayout.Drop.rowHaloWidth / 2, dy: ClipboardLayout.Drop.rowHaloWidth / 2),
                xRadius: radius, yRadius: radius)
            halo.lineWidth = ClipboardLayout.Drop.rowHaloWidth
            halo.stroke()
            // `::before`: the 4 pt bar at the leading edge.
            let bar = NSRect(
                x: rect.minX, y: rect.minY + ClipboardLayout.Drop.barInset, width: ClipboardLayout.Drop.barWidth,
                height: max(0, rect.height - 2 * ClipboardLayout.Drop.barInset))
            NSColor(colorMix(accent.border, ClipboardLayout.Drop.barMix, .white)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        case .invalid:
            NSColor(palette.danger.withAlpha(palette.danger.alpha * ClipboardLayout.Drop.invalidFillAlpha)).setFill()
            shape.fill()
            NSColor(palette.danger.withAlpha(palette.danger.alpha * ClipboardLayout.Drop.invalidHaloAlpha)).setStroke()
            let halo = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            halo.lineWidth = 1
            halo.stroke()
        }
    }

    /// The highlight of an icon of the Icons view: a fill and an edge `edgeWidth` wide inside the item, with no bar or
    /// halo.
    static func iconLook(_ state: DropTargetState, theme: Theme) -> (fill: RGBA, edge: RGBA, edgeWidth: CGFloat) {
        let palette = theme.palette
        let accent = theme.accent
        switch state {
        case .valid, .springing:
            return (
                colorMix(accent.softBg, ClipboardLayout.Drop.fillMix, palette.bgElevated),
                colorMix(accent.border, ClipboardLayout.Drop.edgeMix, .white),
                CGFloat(ClipboardLayout.Drop.iconEdgeWidth)
            )
        case .invalid:
            return (
                palette.danger.withAlpha(palette.danger.alpha * ClipboardLayout.Drop.invalidFillAlpha),
                palette.danger.withAlpha(palette.danger.alpha * ClipboardLayout.Drop.invalidEdgeAlpha),
                CGFloat(ClipboardLayout.Drop.invalidIconEdgeWidth)
            )
        }
    }

    /// The wiggle of a springing folder's icon (`spring-warning-wiggle`), or its pulse with Reduce Motion.
    static func setWiggle(_ view: NSView, on: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        guard on else {
            layer.removeAnimation(forKey: "spring.wiggle")
            return
        }
        guard layer.animation(forKey: "spring.wiggle") == nil else { return }
        let animation: CAAnimation
        if ClipboardFlash.reducesMotion() {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.4
            pulse.autoreverses = true
            animation = pulse
        } else {
            let angle = ClipboardLayout.Drop.wiggleDegrees * .pi / 180
            let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wiggle.values = [0, -angle, 0, angle, 0]
            wiggle.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation = wiggle
        }
        animation.duration = ClipboardLayout.Drop.wiggleMs / 1000
        animation.repeatCount = .infinity
        layer.add(animation, forKey: "spring.wiggle")
    }
}

/// The ring the pane draws once a drag has sprung into the folder on screen, or a drag from another app is over it
/// and would be taken: a 2 pt accent edge inside it.
final class PaneDropRingView: NSView {
    var theme: Theme? {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityIdentifier("content.dropRing")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        let width = CGFloat(ClipboardLayout.Drop.paneRingWidth)
        NSColor(colorMix(theme.accent.border, ClipboardLayout.Drop.paneRingMix, .white)).setStroke()
        let ring = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        ring.lineWidth = width
        ring.stroke()
    }
}
