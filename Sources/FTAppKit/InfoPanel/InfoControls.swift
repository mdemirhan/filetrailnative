import AppKit
import FTFoundation

extension NSView {
    /// The palette of the view's own appearance (light or dark) with the app's accent.
    var infoTheme: Theme { Theme.of(self) }
}

/// The height of a line of text in the font: its ascent, descent and leading, rounded.
func lineBox(_ font: NSFont?) -> Double {
    let font = font ?? .systemFont(ofSize: 12)
    return Double(font.ascender - font.descender + font.leading).rounded()
}

/// The system font with tabular digits: every digit as wide as the others.
func tabularFont(_ size: Double, weight: Int = 400) -> NSFont {
    let weights: [Int: NSFont.Weight] = [500: .medium, 600: .semibold, 700: .bold]
    return NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: weights[weight] ?? .regular)
}

/// The width of the text in the font, to a fraction, as a text box measures it.
func textExtent(_ text: String, _ font: NSFont?) -> Double {
    Double((text as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 12)]).width)
}

/// The icons of the Info panel, system symbols in the text color; a quick action shows its command's symbol.
enum InfoGlyph {
    case close, quickLook, edit, name, favorite, rootTree, finder, terminal, copy, check, refresh
    case openChevron, popupChevron

    var symbolName: String {
        switch self {
        case .close: "xmark"
        case .quickLook: CommandIcon.quickLook.symbolName
        case .edit: CommandIcon.edit.symbolName
        case .name: "textformat"
        case .favorite: CommandIcon.favorite.symbolName
        case .rootTree: CommandIcon.rootTreeHere.symbolName
        case .finder: CommandIcon.showInFinder.symbolName
        case .terminal: CommandIcon.terminal.symbolName
        case .copy: CommandIcon.copyPath.symbolName
        case .check: "checkmark"
        case .refresh: CommandIcon.refresh.symbolName
        case .openChevron: "chevron.down"
        case .popupChevron: "chevron.up.chevron.down"
        }
    }

    /// Draws the symbol as large as fits in `rect`, centered there. Semibold, as the panel's small boxes need for a
    /// stroke as strong as its text's.
    @MainActor
    func draw(in rect: NSRect, color: NSColor) {
        SymbolGlyph.draw(symbolName, in: rect, color: color, weight: .semibold)
    }
}

/// An icon-only button of the Info views: a glyph, a hover fill, and the system's tooltip while it can be used.
final class InfoIconButton: NSView {
    var glyph: InfoGlyph { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var tooltip = "" {
        didSet {
            setAccessibilityHelp(tooltip)
            syncToolTip()
        }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
            syncToolTip()
        }
    }
    /// The size of the drawn glyph.
    var iconSize: Double
    var cornerRadius: Double
    /// (normal, hovered) colors, and the fill under the pointer.
    var normalColor: (Theme) -> RGBA = { $0.palette.textSecondary }
    var hoverColor: (Theme) -> RGBA = { $0.palette.textPrimary }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var pressed = false

    init(
        glyph: InfoGlyph, iconSize: Double, cornerRadius: Double, identifier: String, label: String
    ) {
        self.glyph = glyph
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func syncToolTip() {
        let shown = isEnabled && !tooltip.isEmpty ? tooltip : nil
        if toolTip != shown { toolTip = shown }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let hover = isHovered && isEnabled
        if hover {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        let rect = NSRect(
            x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        glyph.draw(in: rect, color: NSColor(hover ? hoverColor(theme) : normalColor(theme)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// `.spinner`: a ring with its head in the accent, turning once in 700 ms.
final class InfoSpinnerView: NSView {
    var diameter: Double
    var lineWidth: Double

    init(diameter: Double = 12, lineWidth: Double = 2) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = lineWidth
        NSColor(theme.palette.textPrimary.withAlpha(0.15)).setStroke()
        ring.stroke()
        let head = NSBezierPath()
        head.appendArc(
            withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2, startAngle: 180, endAngle: 270)
        head.lineWidth = lineWidth
        NSColor(theme.accent.solid).setStroke()
        head.stroke()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.removeAnimation(forKey: "spin")
        guard window != nil, let layer else { return }
        // Turn about the center.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = DesignTokens.motion.spin / 1000
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A one-shot timer that goes with a view's state.
@MainActor
final class DelayedFlag {
    private var work: DispatchWorkItem?
    private(set) var value = false
    var onChange: (() -> Void)?

    /// Sets the flag after `delay` while `active`; clears it at once when not.
    func update(active: Bool, delay: Double) {
        if !active {
            work?.cancel()
            work = nil
            if value {
                value = false
                onChange?()
            }
            return
        }
        guard !value, work == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.work = nil
                self.value = true
                self.onChange?()
            }
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
