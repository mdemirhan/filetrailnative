// Port of the push button, the link button and the keycap of apps/desktop/src/renderer/styles.css
import AppKit
import FTFoundation

/// A control that is also a label: the field draws its text, and `drawChrome` paints what lies under it (a bezel, a fill).
/// Being a text field is what lets the capture's geometry dump read its text, font and color.
@MainActor
public class TextControl: NSTextField, ThemeApplying {
    public override class var cellClass: AnyClass? {
        get { ThemedTextCell.self }
        set {}
    }

    public internal(set) var theme: Theme
    private var trackingArea: NSTrackingArea?
    public internal(set) var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    public internal(set) var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var usable = true

    public init(text: String, theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.wraps = false
        cell?.isScrollable = false
        stringValue = text
        (cell as? ThemedTextCell)?.verticallyCentered = true
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    /// A control that can't be used is drawn at the disabled opacity; the field itself stays enabled so its text keeps
    /// its colors.
    public override var isEnabled: Bool {
        get { usable }
        set {
            usable = newValue
            alphaValue = newValue ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
        }
    }

    public var title: String {
        get { stringValue }
        set {
            stringValue = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    /// What lies under the text.
    func drawChrome() {}

    public override func draw(_ dirtyRect: NSRect) {
        drawChrome()
        super.draw(dirtyRect)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { isHovering = true }
    public override func mouseExited(with event: NSEvent) { isHovering = false }

    /// Follows the mouse until it is released; true when it was released over the control.
    func track() -> Bool {
        isPressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        return inside
    }

    /// Clicks the control, as a click on it does.
    public func perform() {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

// MARK: Push button

/// The push button of the stylesheet (`.push-button`): the bezel on a rounded rectangle, 24 tall.
public final class PushButton: TextControl {
    public var isDefault = false {
        didSet {
            applyTextColor()
            needsDisplay = true
        }
    }
    private var showsFocusRing = false { didSet { needsDisplay = true } }

    public static let height = DesignTokens.controlHeights.regular
    public static let minWidth = 76.0
    static let horizontalPadding = 12.0
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    public init(
        title: String, theme: Theme = AppearanceModel.shared.theme, target: AnyObject? = nil, action: Selector? = nil
    ) {
        super.init(text: title, theme: theme)
        self.target = target
        self.action = action
        font = Self.font
        alignment = .center
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyTextColor()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var acceptsFirstResponder: Bool { isEnabled }

    /// The width the button takes: the text and 12 each side, at least 76.
    public var preferredWidth: CGFloat {
        max(
            CGFloat(Self.minWidth),
            (title as NSString).size(withAttributes: [.font: Self.font]).width + CGFloat(2 * Self.horizontalPadding))
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: CGFloat(Self.height)) }

    private func applyTextColor() {
        textColor = NSColor(isDefault ? theme.accent.onSolid : theme.palette.textPrimary)
    }

    public override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyTextColor()
    }

    override func drawChrome() {
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let palette = theme.palette
        NSColor(isDefault ? theme.accent.solidButton : palette.pushButtonBg).setFill()
        shape.fill()
        if !isDefault {
            // box-shadow: the bezel (a 0.5 px edge and a hairline of shadow under it).
            for layer in palette.pushButtonBezel where layer.blur == 0 && layer.spread > 0 {
                NSColor(layer.color).setStroke()
                let edge = NSBezierPath(
                    roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
                edge.lineWidth = CGFloat(layer.spread)
                edge.stroke()
            }
        }
        if isHovering && isEnabled {
            NSColor(palette.bgHover).setFill()
            shape.fill()
        }
        if isPressed && isEnabled {
            // filter: brightness(0.94) / brightness(0.92): the colors scaled toward black.
            let factor = isDefault ? 0.92 : palette.pushButtonPressed
            NSColor.black.withAlphaComponent(CGFloat(1 - factor)).setFill()
            shape.fill()
        }
        if showsFocusRing {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if track() { perform() }
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        showsFocusRing = NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }
}

// MARK: Link

/// A button that looks like text in the accent color (`.page-window-link`).
public final class LinkButton: TextControl {
    public var fontSize: Double { didSet { applyStyle() } }

    public init(title: String, fontSize: Double, theme: Theme = AppearanceModel.shared.theme) {
        self.fontSize = fontSize
        super.init(text: title, theme: theme)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
        applyStyle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isHovering: Bool {
        get { super.isHovering }
        set {
            super.isHovering = newValue
            applyStyle()
        }
    }

    private func applyStyle() {
        let font = ThemeFonts.sans(fontSize)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(theme.accent.solid),
        ]
        if super.isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        self.font = font
        textColor = NSColor(theme.accent.solid)
        attributedStringValue = NSAttributedString(string: stringValue, attributes: attributes)
    }

    public override var title: String {
        get { stringValue }
        set {
            stringValue = newValue
            setAccessibilityLabel(newValue)
            applyStyle()
        }
    }

    public var preferredSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: ThemeFonts.sans(fontSize)])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    public override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyStyle()
    }

    public override func mouseDown(with event: NSEvent) {
        if isEnabled { perform() }
    }
}

// MARK: Keycaps

/// One key of a shortcut (`.help-key`): 21 tall, at least 22 wide, a 1 pt border and a rounded corner.
public final class KeycapView: TextControl {
    public var key: String { stringValue }

    private static let font = ThemeFonts.sans(DesignTokens.typeScale.callout)
    public static let height = 21.0
    public static let minWidth = 22.0
    static let horizontalPadding = 6.0

    public init(key: String, theme: Theme = AppearanceModel.shared.theme) {
        super.init(text: key, theme: theme)
        font = Self.font
        alignment = .center
        textColor = NSColor(theme.palette.textSecondary)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(key)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var preferredWidth: CGFloat {
        max(
            CGFloat(Self.minWidth),
            (key as NSString).size(withAttributes: [.font: Self.font]).width + CGFloat(2 * Self.horizontalPadding + 2))
    }

    public override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.palette.textSecondary)
    }

    override func drawChrome() {
        let radius = CGFloat(DesignTokens.radii.control)
        NSColor(theme.palette.bgElevated).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        NSColor(theme.palette.border).setStroke()
        edge.stroke()
    }
}
