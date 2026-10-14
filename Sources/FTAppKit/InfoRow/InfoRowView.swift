// Port of the .info-row box of apps/desktop/src/renderer/components/InfoRow.tsx (the box only; its contents are
// P5-06's)
import AppKit
import FTFoundation

/// The Info Row's place under the list: 30 tall with a line on top while open; closed it keeps its 1 pt line,
/// unseen (`max-height: 0`, `opacity: 0`). Like the path bar row it starts in the divider's half past the hairline.
final class InfoRowView: NSView {
    /// `.info-row.open { max-height: 30px }`.
    static var openHeight: Double { DesignTokens.paneHeaderHeight }
    static let closedHeight = 1.0

    var isOpen = false {
        didSet {
            alphaValue = isOpen ? 1 : 0
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        setAccessibilityIdentifier("infoRow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var height: Double { isOpen ? Self.openHeight : Self.closedHeight }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        ChromeColors.color(palette.bgBase).setFill()
        bounds.fill()
        ChromeColors.color(palette.border).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
