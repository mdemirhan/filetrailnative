// Port of the search tab's glyph of apps/desktop/src/renderer/components/TabStrip.tsx (.tab-strip-search, B-VIEW-143)
import AppKit
import FTFoundation

/// A search tab's magnifier, 12 across before its label; in the accent while its search runs (`searching`).
final class SearchTabMagnifier: NSView {
    var searching = false {
        didSet {
            if searching != oldValue { needsDisplay = true }
        }
    }

    private static var size: Double { SearchLayout.standard.tabMagnifierSize }

    init() {
        let size = Self.size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setAccessibilityIdentifier("tab.search")
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(SearchBarText.fieldPlaceholder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let color =
            searching
            ? ChromeColors.color(ChromeColors.accent(for: self).solid) : ChromeColors.color(palette.textSecondary)
        ToolbarGlyph.draw(
            .search, in: bounds, strokeWidth: DesignTokens.toolbar.iconStrokeWidth, color: color, flipped: true)
    }
}
