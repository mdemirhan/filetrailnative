// Port of the .drag-select-box rule of apps/desktop/src/renderer/styles.css:2273-2283
import AppKit
import FTFoundation

/// Drag-to-select's box, as in Finder: a gray tint with a gray edge, mixed from the text colour so it suits light and
/// dark. It sits in the scrolling content, so it scrolls with the items, and the pointer goes through it.
final class MarqueeBoxView: NSView {
    private var theme = AppearanceModel.shared.theme

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        isHidden = true
        setAccessibilityIdentifier("marquee")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    /// Draws the box at `frame` (in the superview's coordinates).
    func show(_ frame: NSRect) {
        self.frame = frame
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let ink = theme.palette.textPrimary
        NSColor(ink.withAlpha(SelectionLayout.Marquee.fillAlpha)).setFill()
        bounds.fill()
        // `border: 1px solid`, inside the box (`box-sizing: border-box`).
        let width = CGFloat(SelectionLayout.Marquee.borderWidth)
        NSColor(ink.withAlpha(SelectionLayout.Marquee.borderAlpha)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: width).fill()
        NSRect(x: 0, y: bounds.height - width, width: bounds.width, height: width).fill()
        NSRect(x: 0, y: width, width: width, height: max(0, bounds.height - 2 * width)).fill()
        NSRect(x: bounds.width - width, y: width, width: width, height: max(0, bounds.height - 2 * width)).fill()
    }
}
