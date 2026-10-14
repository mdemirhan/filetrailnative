// Port of the toolbar button rules of apps/desktop/src/renderer/styles.css (.tb-btn.tb-btn-icon in .window-toolbar)
// and the buttons ExplorerWorkspace.tsx draws with ToolbarIcon
import AppKit
import FTFoundation

/// An icon-only toolbar button: 32 × 32, a 17 pt stroke icon in the secondary text color, a hover fill, the primary
/// text color for a toggle that is on (or a menu button with its menu open), dimmed when it can't be used. On a capsule
/// its fill is round.
class ToolbarButton: NSView, TooltipAnchor {
    let icon: ToolbarIconView
    /// A click: a press released over the button.
    var onClick: (() -> Void)?
    /// What a press, a release and a right-click do, for buttons that do more than click (Back, Forward).
    var onPress: (() -> Void)?
    var onRelease: ((_ inside: Bool) -> Void)?
    var onRightClick: (() -> Void)?

    var isOn = false {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
        }
    }
    /// Its fills are round: it sits on a capsule.
    var onCapsule = false {
        didSet { needsDisplay = true }
    }
    /// The tooltip (`title`); an icon button has no visible label.
    var tooltip = "" {
        didSet {
            setAccessibilityHelp(tooltip)
            TooltipController.refreshIfShowing(self)
        }
    }
    /// The menu it opens is open: drawn "on", and its tooltip stays quiet.
    var menuOpen = false {
        didSet { needsDisplay = true }
    }
    /// The edit layer is over it (the toolbar is customized): it does nothing.
    var isInert = false

    private(set) var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false

    init(icon name: ToolbarIconName, label: String, identifier: String) {
        icon = ToolbarIconView(name)
        super.init(
            frame: NSRect(
                x: 0, y: 0, width: DesignTokens.toolbar.buttonWidth, height: DesignTokens.toolbar.controlHeight))
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var tooltipText: String { isEnabled ? tooltip : "" }
    var tooltipIsQuiet: Bool { menuOpen }

    override func layout() {
        super.layout()
        let size = DesignTokens.toolbar.iconSize
        icon.frame = NSRect(
            x: ((bounds.width - size) / 2).rounded(.down), y: (bounds.height - size) / 2, width: size, height: size)
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
        if let window { TooltipController.of(window).hover(self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if let window { TooltipController.of(window).hover(nil) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isInert else { return }
        pressed = true
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        onRelease?(inside)
        if inside { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, !isInert, let onRightClick else {
            super.rightMouseDown(with: event)
            return
        }
        onRightClick()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isInert else { return false }
        onClick?()
        return true
    }

    /// The fill behind the icon, as the toolbar's rules choose it: the hover fill, and nothing for a button that is on.
    /// `.tb-btn-icon.active` asks for `--toolbar-toggle-on-bg` (and `--toolbar-toggle-on-hover-bg` under the pointer),
    /// which the shipped stylesheet never defines: the background resolves to nothing, hovered or not.
    var backgroundFill: RGBA? {
        let palette = ChromeColors.palette(for: self)
        if isOn || menuOpen { return nil }
        return isHovered && isEnabled && !isInert ? palette.bgHover : nil
    }

    /// The fill behind the icon, and the icon's color: the primary text color when on or hovered.
    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let on = isOn || menuOpen
        let hover = isHovered && isEnabled && !isInert
        if let fill = backgroundFill {
            let radius = onCapsule ? bounds.height / 2 : DesignTokens.radii.control
            ChromeColors.color(fill).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        icon.color = ChromeColors.color(on || hover ? palette.textPrimary : palette.textSecondary)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension TooltipController {
    /// A tooltip showing for `anchor` takes up its new text (`mousemove` in the original).
    static func refreshIfShowing(_ anchor: TooltipAnchor & NSView) {
        guard let window = anchor.window else { return }
        let controller = of(window)
        if controller.scheduler.anchor === anchor { controller.scheduler.refresh() }
    }
}
