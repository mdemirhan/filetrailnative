// Port of the .content-pathbar-row of apps/desktop/src/renderer/components/ContentPane.tsx (the row only; the path
// bar in it is P5-06's)
import AppKit
import FTFoundation

/// The row under the list: 28 tall with a line on top, the path bar on its left (P5-06) and the status text on its
/// right. It starts in the half of the divider past the hairline (4 pt left of the content), so its line reaches the
/// hairline, and keeps its contents where they were.
final class PathBarRowView: NSView {
    /// `.content-pathbar-row { height: 28px }`.
    static var height: Double { WindowMetrics.standard.controlHeights.large }
    /// How far it reaches into the divider.
    static var reach: Double { WindowMetrics.standard.explorer.resizerWidth / 2 }
    /// Padding: 10 on each side, plus the reach on the left.
    static let paddingInline = 10.0

    let status = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("pathBarRow")
        status.font = ChromeColors.font(size: DesignTokens.typeScale.small)
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("statusBar")
        addSubview(status)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = status.intrinsicContentSize
        let width = min(size.width, bounds.width * 0.55)
        status.frame = NSRect(
            x: bounds.width - Self.paddingInline - width, y: 1 + ((bounds.height - 1 - size.height) / 2).rounded(),
            width: width, height: size.height)
        let palette = ChromeColors.palette(for: self)
        status.textColor = ChromeColors.color(palette.textSecondary)
        layer?.backgroundColor = ChromeColors.color(palette.bgBase).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeColors.color(ChromeColors.palette(for: self).border).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
