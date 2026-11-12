import AppKit
import FTFoundation

/// The copy or scissors glyph after an item's name: 12 pt, in the accent, or the color of the text on a selected row.
/// It ignores the pointer.
final class ClipboardMarkGlyph: NSView {
    private let glyph = SymbolIconView(CommandIcon.copy.symbolName)

    var mark: ClipboardMark? {
        didSet {
            isHidden = mark == nil
            glyph.symbolName = (mark == .cut ? CommandIcon.cut : .copy).symbolName
            // The glyph is there only while it shows, as `IconTileView` says: every row of the folder's views has one.
            if mark == nil {
                glyph.removeFromSuperview()
            } else if glyph.superview == nil {
                addSubview(glyph)
                needsLayout = true
            }
        }
    }

    var color: NSColor {
        get { glyph.color }
        set { glyph.color = newValue }
    }

    init(identifier: String) {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glyph.frame = bounds
    }

    static var size: CGFloat { CGFloat(ClipboardLayout.Mark.iconSize) }

    /// The glyph's color on a row: the text color of a selected row in a focused pane of the window in front, the
    /// accent otherwise.
    static func color(theme: Theme, onSelection: Bool) -> NSColor {
        NSColor(onSelection ? theme.accent.onSelection : theme.accent.solidButton)
    }
}

/// The flash of items at the moment they are copied or cut: an overlay in the accent (the text color on a selected
/// row), 0.45 → 0.12 → 0 over 700 ms. With Reduce Motion it doesn't run.
@MainActor
enum ClipboardFlash {
    static var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Flashes `view` (a row's box) with `color`, rounded as the row is.
    static func flash(_ view: NSView, color: NSColor, radius: CGFloat) {
        guard !reducesMotion() else { return }
        view.wantsLayer = true
        guard let host = view.layer else { return }
        for old in host.sublayers ?? [] where old.name == "clipboard.flash" { old.removeFromSuperlayer() }
        let overlay = CALayer()
        overlay.name = "clipboard.flash"
        overlay.frame = host.bounds
        overlay.cornerRadius = radius
        overlay.backgroundColor = color.cgColor
        overlay.opacity = 0
        host.addSublayer(overlay)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = ClipboardLayout.Mark.flashOpacities
        animation.keyTimes = ClipboardLayout.Mark.flashKeyTimes.map { NSNumber(value: $0) }
        animation.duration = DesignTokens.motion.flash / 1000
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { overlay.removeFromSuperlayer() }
        overlay.add(animation, forKey: "flash")
        CATransaction.commit()
    }
}

/// `fraction` of `a` mixed with the rest of `b` in sRGB, each channel weighted by its color's alpha (premultiplied),
/// so a clear color adds no tint.
func colorMix(_ a: RGBA, _ fraction: Double, _ b: RGBA) -> RGBA {
    let alpha = a.alpha * fraction + b.alpha * (1 - fraction)
    guard alpha > 0 else { return .clear }
    func channel(_ x: Double, _ y: Double) -> Double {
        (x * a.alpha * fraction + y * b.alpha * (1 - fraction)) / alpha
    }
    return RGBA(
        red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue), alpha: alpha)
}
