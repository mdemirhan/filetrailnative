// Port of the rounded search field of apps/desktop/src/renderer/styles.css (.search-field) and components/ClearButton.tsx
import AppKit
import FTFoundation

/// The × that empties a field (`.clear-button`): a disc of the primary text at 28% (42% under the pointer, 55% pressed),
/// the cross stroked over it in the panel's color (`color: var(--bg-elevated)`), 2 wide on a 7 pt box. The field keeps
/// the keyboard, unless the × is one of the stops of what Tab goes round (`isTabStop`).
public final class ClearButton: NSControl, ThemeApplying {
    public private(set) var theme: Theme
    private var isHovering = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?
    /// Tab stops here, in a dialog that goes round its buttons. A click then gives it the keyboard too, for its action to
    /// give back.
    var isTabStop = false
    private var showsFocusRing = false {
        didSet {
            focusRingType = showsFocusRing ? .default : .none
            noteFocusRingMaskChanged()
        }
    }
    public static let size = 16.0
    /// `.clear-button svg`: 7 by 7, the path `M1 1l8 8M9 1l-8 8` on a 10 by 10 view box.
    static let crossBox = 7.0

    public init(theme: Theme = AppearanceModel.shared.theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        setAccessibilityRole(.button)
        setAccessibilityLabel("Clear search")
        setAccessibilityIdentifier("clearButton")
        toolTip = "Clear Search (Esc)"
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    // The field keeps the keyboard, so typing can continue after a click here.
    public override var acceptsFirstResponder: Bool { isTabStop }
    public override var focusRingMaskBounds: NSRect { bounds }
    public override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds).fill() }

    public override func becomeFirstResponder() -> Bool {
        // `:focus-visible`: the keyboard moved it here, not a press.
        showsFocusRing = NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    /// The disc's alpha: 28%, 42% under the pointer, 55% pressed.
    var discAlpha: Double { isPressed ? 0.55 : isHovering ? 0.42 : 0.28 }

    /// The cross's color: the panel's, so it reads as cut out of the disc.
    var crossColor: RGBA { theme.palette.bgElevated }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.palette.textPrimary.withAlpha(discAlpha)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let box = CGFloat(Self.crossBox)
        let scale = box / 10
        let origin = NSPoint(x: bounds.midX - box / 2, y: bounds.midY - box / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        let cross = NSBezierPath()
        cross.move(to: point(1, 1))
        cross.line(to: point(9, 9))
        cross.move(to: point(9, 1))
        cross.line(to: point(1, 9))
        cross.lineWidth = 2 * scale
        cross.lineCapStyle = .round
        NSColor(crossColor).setStroke()
        cross.stroke()
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
        isPressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp { break }
        }
        isPressed = false
        if inside { sendAction(action, to: target) }
    }

    /// Clicks the button, as a click on it does.
    public func perform() { sendAction(action, to: target) }
}

/// The text field inside a search field: Escape clears what is typed before it leaves the field.
final class SearchTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { SearchTextCell.self }
        set {}
    }
}

/// An unbordered cell draws text in a color with alpha twice when nothing is editing it, so `rgba(0, 0, 0, 0.26)` comes
/// out as 0.45 (once a field editor has it, it is drawn once). The placeholder is the only such text here: this draws it
/// once, where the cell would, inside the 2 pt the cell keeps on each side.
final class SearchTextCell: NSTextFieldCell {
    static let inset = 2.0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let isEditing = (controlView as? NSTextField)?.currentEditor() != nil
        guard !isEditing, stringValue.isEmpty, let placeholder = placeholderAttributedString else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        placeholder.draw(
            with: cellFrame.insetBy(dx: CGFloat(Self.inset), dy: 0), options: [.usesLineFragmentOrigin], context: nil)
    }
}

/// An icon, the field, and the clear button once something is typed (`.search-field`): 24 tall, rounded, filled.
public final class ThemedSearchField: NSView, ThemeApplying, NSTextFieldDelegate {
    public private(set) var theme: Theme
    public let input: NSTextField
    public let clearButton: ClearButton
    public var placeholder: String { didSet { applyPlaceholder() } }
    /// Told the text after each change.
    public var onChange: (String) -> Void = { _ in }

    public static let height = DesignTokens.controlHeights.regular
    private static let iconSize = 13.0
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    public init(placeholder: String, theme: Theme = AppearanceModel.shared.theme) {
        self.theme = theme
        self.placeholder = placeholder
        input = SearchTextField()
        clearButton = ClearButton(theme: theme)
        super.init(frame: .zero)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = Self.font
        input.lineBreakMode = .byClipping
        input.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.setAccessibilityLabel(placeholder)
        input.setAccessibilityIdentifier("searchField.input")
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.isHidden = true
        addSubview(input)
        addSubview(clearButton)
        applyPlaceholder()
        applyTheme(theme)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public var text: String {
        get { input.stringValue }
        set {
            input.stringValue = newValue
            clearButton.isHidden = newValue.isEmpty
            needsLayout = true
        }
    }

    private var isFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === input
    }

    private func applyPlaceholder() {
        input.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.font: Self.font, .foregroundColor: NSColor(theme.palette.textTertiary)])
    }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        input.textColor = NSColor(theme.palette.textPrimary)
        applyPlaceholder()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        // padding 0 4 0 8; the icon, 6 of gap, the field, 6 of gap, the clear button.
        let clearWidth = CGFloat(ClearButton.size)
        let left = 8 + CGFloat(Self.iconSize) + 6
        let right: CGFloat = clearButton.isHidden ? 4 : 4 + clearWidth + 6
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        // `padding: 0` on the input: its text starts at `left`, so the frame reaches out by what the cell keeps.
        let inset = CGFloat(SearchTextCell.inset)
        input.frame = NSRect(
            x: left - inset, y: ((bounds.height - lineHeight) / 2).rounded(),
            width: max(0, bounds.width - left - right) + 2 * inset, height: lineHeight)
        clearButton.frame = NSRect(
            x: bounds.width - 4 - clearWidth, y: ((bounds.height - clearWidth) / 2).rounded(), width: clearWidth,
            height: clearWidth)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        // box-shadow: inset 0 0 0 0.5px var(--border-active)
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius - 0.25, yRadius: radius - 0.25)
        edge.lineWidth = 0.5
        NSColor(palette.borderActive).setStroke()
        edge.stroke()
        if isFocused {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
        drawIcon(
            in: NSRect(
                x: 8, y: (bounds.height - CGFloat(Self.iconSize)) / 2, width: CGFloat(Self.iconSize),
                height: CGFloat(Self.iconSize)))
    }

    /// The magnifier (a 24 by 24 drawing: a circle of 6.5 at 11,11 and a line to 20.5,20.5), stroked 2 wide.
    private func drawIcon(in rect: NSRect) {
        let scale = rect.width / 24
        func point(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(y) * scale)
        }
        let path = NSBezierPath(
            ovalIn: NSRect(origin: point(4.5, 4.5), size: NSSize(width: 13 * scale, height: 13 * scale)))
        path.move(to: point(16, 16))
        path.line(to: point(20.5, 20.5))
        path.lineWidth = 2 * scale
        path.lineCapStyle = .round
        NSColor(theme.palette.textSecondary).setStroke()
        path.stroke()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(input)
    }

    // MARK: Typing

    @objc private func clearPressed(_ sender: Any?) {
        clear()
    }

    /// Empties the field, which keeps the keyboard.
    public func clear() {
        text = ""
        onChange("")
    }

    public func controlTextDidChange(_ notification: Notification) {
        clearButton.isHidden = input.stringValue.isEmpty
        needsLayout = true
        onChange(input.stringValue)
    }

    public func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    public func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Escape clears the search first, without leaving the window; with nothing to clear it passes through.
        if selector == #selector(NSResponder.cancelOperation(_:)), !input.stringValue.isEmpty {
            clear()
            return true
        }
        return false
    }
}
