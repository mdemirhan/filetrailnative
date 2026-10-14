// Port of the glyphs of apps/desktop/src/renderer/components/GetInfoPanel.tsx (InfoPanelGlyph), the .spinner of styles.css
// and the small buttons the Info views draw
import AppKit
import FTFoundation

extension NSView {
    /// The palette of the view's own appearance (light or dark) with the app's accent.
    var infoTheme: Theme { Theme(appearance: ChromeColors.appearance(of: self), accentHex: AppearanceModel.shared.accentHex) }
}

/// The height of a line of text in the font, as the browser's `line-height: normal` rounds it.
func lineBox(_ font: NSFont?) -> Double {
    let font = font ?? .systemFont(ofSize: 12)
    return Double(font.ascender - font.descender + font.leading).rounded()
}

/// `font-variant-numeric: tabular-nums`: every digit as wide as the others.
func tabularFont(_ size: Double, weight: Int = 400) -> NSFont {
    let weights: [Int: NSFont.Weight] = [500: .medium, 600: .semibold, 700: .bold]
    return NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: weights[weight] ?? .regular)
}

/// The width of the text in the font, to a fraction, as a text box measures it.
func textExtent(_ text: String, _ font: NSFont?) -> Double {
    Double((text as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 12)]).width)
}

/// The original's locale for dates (`InfoLocale.original`).
extension DateText {
    static let original = DateText(locale: InfoLocale.original)
}

/// The line icons of the Info panel, in a 24-unit box, stroked in `currentColor` with round caps and joins.
enum InfoGlyph {
    case close, quickLook, edit, name, favorite, rootTree, finder, terminal, copy, check, refresh
    case openChevron, popupChevron

    var box: Double {
        switch self {
        case .openChevron: 8
        default: 24
        }
    }

    var paths: [String] {
        switch self {
        case .close: ["M6 6l12 12", "M18 6L6 18"]
        case .quickLook:
            [
                "M6 4h12a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
                "M14 7h3v3M10 17H7v-3M17 7l-4 4M7 17l4-4",
            ]
        case .edit: ["M11 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5", "M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4Z"]
        case .name: ["M4 7V5h16v2", "M12 5v14", "M9 19h6"]
        case .favorite: ["m12 17.27-5.18 3.05 1.39-5.88L3 9.97l6.01-.5L12 4l2.99 5.47 6.01.5-5.21 4.47 1.39 5.88Z"]
        case .rootTree: ["M4 5h8", "M8 5v12h6", "M8 11h6", "M17 9l3 2-3 2", "M17 15l3 2-3 2"]
        case .finder:
            [
                "M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z",
                "M14 13a2.5 2.5 0 1 1-5 0a2.5 2.5 0 1 1 5 0z", "M13.5 15l2.5 2.5",
            ]
        case .terminal:
            ["M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z", "M7 9l3 3-3 3", "M13 15h4"]
        case .copy:
            [
                "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71",
                "M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71",
            ]
        case .check: ["M5 12l4 4L19 6"]
        case .refresh: ["M1 4v6h6", "M3.51 15a9 9 0 1 0 2.13-9.36L1 10"]
        case .openChevron: ["M1.5 3 4 5.5 6.5 3"]
        case .popupChevron: ["M8 9.5l4-4 4 4M8 14.5l4 4 4-4"]
        }
    }

    /// Strokes the glyph into `rect`; `strokeWidth` is in box units, as the stylesheet gives it.
    @MainActor
    func draw(in rect: NSRect, strokeWidth: Double, color: NSColor) {
        let scale = rect.width / box
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: scale, y: scale)
        color.setStroke()
        for data in paths {
            let path = SVGPath.path(data)
            path.transform(using: transform)
            path.lineWidth = strokeWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }
}

/// An icon-only button of the Info views: a glyph, a hover fill, a tooltip (`title`) once the pointer has rested.
final class InfoIconButton: NSView, TooltipAnchor {
    var glyph: InfoGlyph { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var tooltip = "" {
        didSet {
            setAccessibilityHelp(tooltip)
            TooltipController.refreshIfShowing(self)
        }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
        }
    }
    /// The size of the drawn glyph and its stroke width (box units).
    var iconSize: Double
    var strokeWidth: Double
    var cornerRadius: Double
    /// (normal, hovered) colors, and the fill under the pointer.
    var normalColor: (Theme) -> RGBA = { $0.palette.textSecondary }
    var hoverColor: (Theme) -> RGBA = { $0.palette.textPrimary }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var pressed = false

    init(glyph: InfoGlyph, iconSize: Double, strokeWidth: Double, cornerRadius: Double, identifier: String, label: String) {
        self.glyph = glyph
        self.iconSize = iconSize
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var tooltipText: String { isEnabled ? tooltip : "" }
    var tooltipIsQuiet: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let hover = isHovered && isEnabled
        if hover {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        let rect = NSRect(
            x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        glyph.draw(in: rect, strokeWidth: strokeWidth, color: NSColor(hover ? hoverColor(theme) : normalColor(theme)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let window { TooltipController.of(window).hover(self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if let window { TooltipController.of(window).hover(nil) }
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
