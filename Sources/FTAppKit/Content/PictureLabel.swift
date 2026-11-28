import AppKit

/// A line of text drawn whole into a picture given to the view's layer (`updateLayer`), again only when what it shows,
/// its size, the screen's scale or the appearance changes. A text field coming into sight in a scroll was drawn by AppKit
/// a strip at a time, the part just come into view, so each name of the Compact List was laid out and drawn about five
/// times as it came in; Core Animation shows the strips from the one picture. The Icons view's names (`IconNameLabel`)
/// and the List's text (`RowTextLabel`) are drawn the same way.
///
/// It is a view of its own, not a text field: a text field that draws its own layer is given a label of AppKit's own
/// on screen, which drew the name a second time. AppKit gives the layer the screen's scale, as it does the icons'
/// (`IconPictureView`); the view is placed whole pixels wide and high, so its picture is its size exactly. Automation
/// reads its text as a text field's (`AutomationElements`), and VoiceOver as static text. The other ways tried, with
/// their code and numbers, are in `docs/records/compact-list-names/` and `docs/records/list-and-icons-text/`.
class PictureLabel: NSView {
    var stringValue = "" {
        didSet {
            guard stringValue != oldValue else { return }
            setAccessibilityValue(stringValue)
            needsDisplay = true
        }
    }
    var font: NSFont? {
        didSet { if font != oldValue { needsDisplay = true } }
    }
    var textColor: NSColor? {
        didSet { if textColor != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The height one line of the text takes: the font's own line (ascent, descent and leading).
    var lineHeight: CGFloat {
        guard let font else { return 0 }
        return font.ascender - font.descender + font.leading
    }

    /// The width the text takes on one line.
    var textWidth: CGFloat {
        guard let font else { return 0 }
        return (stringValue as NSString).size(withAttributes: [.font: font]).width
    }

    override var wantsUpdateLayer: Bool { true }

    /// The scale `view`'s text is drawn and placed for: its window's, or the main screen's before it is in one.
    static func scale(of view: NSView) -> CGFloat {
        view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func updateLayer() {
        guard let layer else { return }
        let scale = Self.scale(of: self)
        let drawn = picture(scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.contents = drawn
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// `rect` with its edges on whole pixels of a screen of `scale` pixels a point, for a view whose picture is to be its
    /// size exactly: its origin moved to the nearest pixel, its size to the next whole pixel, by under a pixel each.
    static func onWholePixels(_ rect: NSRect, scale: CGFloat) -> NSRect {
        func pixels(_ value: CGFloat, _ rule: FloatingPointRoundingRule) -> CGFloat {
            (value * scale).rounded(rule) / scale
        }
        return NSRect(
            x: pixels(rect.minX, .toNearestOrAwayFromZero), y: pixels(rect.minY, .toNearestOrAwayFromZero),
            width: pixels(rect.width, .up), height: pixels(rect.height, .up))
    }

    /// What `draw(_:)` draws over the whole view, as a picture of `scale` pixels a point, in the view's appearance; nil
    /// when the view has no size. The view is to be whole pixels high and wide, so the picture is its size exactly.
    func picture(scale: CGFloat) -> CGImage? {
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
            let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { draw(bounds) }
        return context.makeImage()
    }
}
