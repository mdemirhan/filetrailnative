// Port of the .get-info-panel box of apps/desktop/src/renderer/components/GetInfoPanel.tsx (the box only; its
// contents are P5-06's)
import AppKit
import FTFoundation

/// The Info panel's place in the window's last column: opaque, on the base background. P5-06 fills it.
final class InfoPanelView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("infoPanel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.backgroundColor = ChromeColors.color(ChromeColors.palette(for: self).bgBase).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}
