// Views that draw with the app's palette (apps/desktop/src/renderer/styles.css), redrawn when the theme changes
import AppKit
import FTFoundation

/// A view that draws with the theme and is told when it changes.
@MainActor
public protocol ThemeApplying: AnyObject {
    func applyTheme(_ theme: Theme)
}

extension NSView {
    /// Gives `theme` to this view and every view below it that draws with it, and has them redraw.
    public func applyTheme(_ theme: Theme, throughSubviews: Bool) {
        (self as? any ThemeApplying)?.applyTheme(theme)
        needsDisplay = true
        if throughSubviews { for child in subviews { child.applyTheme(theme, throughSubviews: true) } }
    }
}

/// A flipped box with a themed fill, an optional rounded border and hairlines along its edges.
public class ThemedView: NSView, ThemeApplying {
    /// A color of the palette or the accent, for the theme at hand.
    public typealias ColorProvider = @MainActor @Sendable (Theme) -> RGBA

    public enum Edge: Hashable, Sendable { case top, bottom, leading, trailing }

    public final var fill: ColorProvider? = nil { didSet { needsDisplay = true } }
    /// Hairlines of 1 pt along the edges.
    public final var edges: [Edge: ColorProvider] = [:] { didSet { needsDisplay = true } }
    /// A 1 pt border inside the bounds, with this corner radius (zero radius draws a square border).
    public final var borderColor: ColorProvider? = nil { didSet { needsDisplay = true } }
    public final var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    public private(set) var theme: Theme

    public init(frame: NSRect = .zero, theme: Theme = AppearanceModel.shared.theme) {
        self.theme = theme
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        if let color = fill?(theme) {
            NSColor(color).setFill()
            shape.fill()
        }
        for (edge, provider) in edges {
            NSColor(provider(theme)).setFill()
            switch edge {
            case .top: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            case .bottom: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
            case .leading: NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            case .trailing: NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
            }
        }
        if let color = borderColor?(theme) {
            let inset = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, cornerRadius - 0.5),
                yRadius: max(0, cornerRadius - 0.5))
            inset.lineWidth = 1
            NSColor(color).setStroke()
            inset.stroke()
        }
    }
}

/// Text that is rebuilt from the theme: one line or wrapped, selectable when it is worth copying.
public final class ThemedText: NSTextField, ThemeApplying {
    /// The text as the theme draws it.
    public var content: @MainActor (Theme) -> NSAttributedString {
        didSet { applyTheme(AppearanceModel.shared.theme) }
    }

    public init(wrapping: Bool = false, selectable: Bool = false, content: @escaping @MainActor (Theme) -> NSAttributedString) {
        self.content = content
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = selectable
        allowsEditingTextAttributes = false
        focusRingType = .none
        lineBreakMode = wrapping ? .byWordWrapping : .byClipping
        usesSingleLineMode = !wrapping
        cell?.wraps = wrapping
        cell?.isScrollable = false
        applyTheme(AppearanceModel.shared.theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    public func applyTheme(_ theme: Theme) {
        attributedStringValue = content(theme)
    }

    /// The height the text takes at this width.
    public func height(forWidth width: CGFloat) -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        return ceil(cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    /// The width the text takes on one line.
    public var naturalWidth: CGFloat {
        ceil(attributedStringValue.size().width)
    }
}

/// Styles for the text of the stylesheet: font, color and line height.
public struct TextStyle {
    public var font: NSFont
    public var color: @MainActor (Theme) -> RGBA
    /// CSS `line-height` as a multiple of the font size; nil is the font's own.
    public var lineHeight: Double?
    public var alignment: NSTextAlignment = .left
    /// CSS `letter-spacing` in points.
    public var kern: Double = 0

    public init(
        font: NSFont, color: @escaping @MainActor (Theme) -> RGBA, lineHeight: Double? = nil,
        alignment: NSTextAlignment = .left, kern: Double = 0
    ) {
        self.font = font
        self.color = color
        self.lineHeight = lineHeight
        self.alignment = alignment
        self.kern = kern
    }

    @MainActor
    public func attributes(_ theme: Theme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        if let lineHeight {
            let height = CGFloat(Double(font.pointSize) * lineHeight)
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(color(theme)), .paragraphStyle: paragraph,
        ]
        if kern != 0 { attributes[.kern] = kern }
        return attributes
    }

    /// With CSS's half-leading: a line box taller than the glyphs puts the extra above and below the text equally.
    @MainActor
    public func string(_ text: String, _ theme: Theme) -> NSAttributedString {
        var attributes = attributes(theme)
        if let lineHeight, let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            let natural = font.ascender - font.descender + font.leading
            let extra = CGFloat(Double(font.pointSize) * lineHeight) - natural
            if abs(extra) > 0.01 { attributes[.baselineOffset] = extra / 2 }
            _ = paragraph
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

extension ThemedText {
    /// A label with a single style.
    public convenience init(_ text: String, style: TextStyle, wrapping: Bool = false, selectable: Bool = false) {
        self.init(wrapping: wrapping, selectable: selectable) { style.string(text, $0) }
    }
}

// MARK: Buttons

/// The push button of the stylesheet (`.push-button`): the bezel on a rounded rectangle, 24 tall.
public final class PushButton: NSControl, ThemeApplying {
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var isDefault = false { didSet { needsDisplay = true } }
    public override var isEnabled: Bool { didSet { needsDisplay = true; alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity } }
    public private(set) var theme: Theme

    private var isHovering = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var showsFocusRing = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    public static let height = DesignTokens.controlHeights.regular
    public static let minWidth = 76.0
    static let horizontalPadding = 12.0
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    public init(title: String, theme: Theme = AppearanceModel.shared.theme, target: AnyObject? = nil, action: Selector? = nil) {
        self.title = title
        self.theme = theme
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { isEnabled }
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    /// The width the button takes: the text and 12 each side, at least 76.
    public var preferredWidth: CGFloat {
        max(CGFloat(Self.minWidth), ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + CGFloat(2 * Self.horizontalPadding))
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: CGFloat(Self.height)) }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let palette = theme.palette
        let background = isDefault ? theme.accent.solidButton : palette.pushButtonBg
        NSColor(background).setFill()
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
            if isHovering && isEnabled {
                NSColor(palette.bgHover).setFill()
                shape.fill()
            }
        } else if isHovering && isEnabled {
            NSColor(palette.bgHover).setFill()
            shape.fill()
        }
        if isPressed && isEnabled {
            // filter: brightness(0.94) / brightness(0.92): the colors scaled toward black.
            let factor = isDefault ? 0.92 : palette.pushButtonPressed
            NSColor.black.withAlphaComponent(CGFloat(1 - factor)).setFill()
            shape.fill()
        }
        let color = isDefault ? theme.accent.onSolid : palette.textPrimary
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor(color), .paragraphStyle: paragraph,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            in: NSRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width, height: size.height),
            withAttributes: attributes)
        if showsFocusRing {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
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

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        if inside { perform() }
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

    /// Clicks the button, as a click on it does.
    public func perform() {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }
}

/// A button that looks like text in the accent color (`.page-window-link`).
public final class LinkButton: NSControl, ThemeApplying {
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var fontSize: Double
    public private(set) var theme: Theme
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    public init(title: String, fontSize: Double, theme: Theme = AppearanceModel.shared.theme) {
        self.title = title
        self.fontSize = fontSize
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: ThemeFonts.sans(fontSize), .foregroundColor: NSColor(theme.accent.solid),
        ]
        if isHovering { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    public var preferredSize: NSSize {
        let size = (title as NSString).size(withAttributes: [.font: ThemeFonts.sans(fontSize)])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    public override var intrinsicContentSize: NSSize { preferredSize }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let attributes = attributes
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: 0, y: ((bounds.height - size.height) / 2).rounded()), withAttributes: attributes)
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

    public override func mouseDown(with event: NSEvent) {
        if isEnabled { sendAction(action, to: target) }
    }

    public func perform() {
        if isEnabled { sendAction(action, to: target) }
    }
}

// MARK: Keycaps

/// One key of a shortcut (`.help-key`): 21 tall, at least 22 wide, a 1 pt border and a rounded corner.
public final class KeycapView: NSView, ThemeApplying {
    public let key: String
    public private(set) var theme: Theme

    private static let font = ThemeFonts.sans(DesignTokens.typeScale.callout)
    public static let height = 21.0
    public static let minWidth = 22.0
    static let horizontalPadding = 6.0

    public init(key: String, theme: Theme = AppearanceModel.shared.theme) {
        self.key = key
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(key)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    public var preferredWidth: CGFloat {
        max(
            CGFloat(Self.minWidth),
            ceil((key as NSString).size(withAttributes: [.font: Self.font]).width) + CGFloat(2 * Self.horizontalPadding + 2))
    }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        NSColor(theme.palette.bgElevated).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        NSColor(theme.palette.border).setStroke()
        edge.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor(theme.palette.textSecondary), .paragraphStyle: paragraph,
        ]
        let size = (key as NSString).size(withAttributes: attributes)
        (key as NSString).draw(
            in: NSRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width, height: size.height),
            withAttributes: attributes)
    }
}
