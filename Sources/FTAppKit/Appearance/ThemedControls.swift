// Port of the push button, the segmented control, the link button and the keycap of
// apps/desktop/src/renderer/styles.css, the first two as system controls (D-020)
import AppKit
import FTFoundation

/// A control that is also a label: the field draws its text, and `drawChrome` paints what lies under it (a fill, a key).
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

/// The push button (`.push-button`) as the system's button: its bezel, press and focus ring (D-020). The default one is
/// tinted with the theme's accent and never takes Return from the system: the panels press it themselves (they know
/// what has the keyboard). It is as wide as the original's: the text and 12 each side, at least 76.
public class SystemButton: NSButton, ThemeApplying {
    public private(set) var theme: Theme
    public var isDefault = false { didSet { applyLook() } }
    /// Red text on the plain bezel (`.is-destructive`), for a button that destroys something and is not the default.
    public var isDestructive = false { didSet { applyLook() } }
    /// The button's height: 24 (`--control-height`) unless a panel says otherwise (an alert's are 28, a small one's 22).
    public var controlHeight = SystemButton.height {
        didSet {
            applySize()
            invalidateIntrinsicContentSize()
        }
    }
    /// No focus ring while focused, until the keyboard moves the focus (an alert's default button, styles.css:1462).
    public var suppressesFocusRing = false {
        didSet { if suppressesFocusRing { showsFocusRing = false } }
    }
    public private(set) var showsFocusRing = false {
        didSet {
            focusRingType = showsFocusRing ? .default : .none
            noteFocusRingMaskChanged()
        }
    }

    public static let height = DesignTokens.controlHeights.regular
    public static let minWidth = 76.0
    static let horizontalPadding = 12.0
    private static let bodyFont = ThemeFonts.sans(DesignTokens.typeScale.body)

    public init(
        title: String, theme: Theme = AppearanceModel.shared.theme, target: AnyObject? = nil, action: Selector? = nil
    ) {
        self.theme = theme
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        bezelStyle = .push
        font = Self.bodyFont
        focusRingType = .none
        self.title = title
        setAccessibilityLabel(title)
        applyLook()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var title: String {
        didSet {
            setAccessibilityLabel(title)
            applyTitleColor()
            invalidateIntrinsicContentSize()
        }
    }

    public override var isEnabled: Bool {
        didSet { applyLook() }
    }

    /// Tab comes here whatever the system's keyboard navigation setting says, as it does to the original's, unless the
    /// button refuses the keyboard (`refusesFirstResponder`: one in a pane or a card leaves it where it is).
    public override var acceptsFirstResponder: Bool { isEnabled && !refusesFirstResponder }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder }

    /// The width the button takes: the text and 12 each side, at least 76.
    public var preferredWidth: CGFloat {
        max(
            CGFloat(Self.minWidth),
            (title as NSString).size(withAttributes: [.font: font ?? Self.bodyFont]).width
                + CGFloat(2 * Self.horizontalPadding))
    }

    public override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: CGFloat(controlHeight)) }

    /// The bezels the system draws at a fixed height, by height; another height takes the bezel that fills its frame.
    private func applySize() {
        switch controlHeight {
        case DesignTokens.controlHeights.regular:
            bezelStyle = .push
            controlSize = .regular
        case DesignTokens.controlHeights.large:
            bezelStyle = .push
            controlSize = .large
        default:
            bezelStyle = .flexiblePush
            controlSize = .small
        }
    }

    private func applyLook() {
        // A disabled one takes the system's disabled look: the system dims a set tint too little under its dimmed title.
        bezelColor = isDefault && isEnabled ? NSColor(theme.accent.solidButton) : nil
        hasDestructiveAction = isDestructive
        applyTitleColor()
    }

    /// The title's color where the theme chooses it: black on a light accent, red on a button that destroys something.
    /// Otherwise, and while disabled, the system's: white on the accent, and dark once the window is inactive and the
    /// system takes the tint away.
    var titleColor: RGBA? {
        guard isEnabled else { return nil }
        if isDefault { return theme.accent.onSolid == .white ? nil : theme.accent.onSolid }
        return isDestructive ? theme.palette.dangerText : nil
    }

    private func applyTitleColor() {
        guard !title.isEmpty else { return }
        guard let titleColor else {
            if attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil {
                attributedTitle = NSAttributedString(string: title)
            }
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(titleColor), .font: font ?? Self.bodyFont,
                .paragraphStyle: paragraph,
            ])
    }

    public func applyTheme(_ theme: Theme) {
        self.theme = theme
        applyLook()
    }

    /// Clicks the button, as a click on it does.
    public func perform() {
        guard isEnabled else { return }
        sendAction(action, to: target)
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        showsFocusRing = !suppressesFocusRing && NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }
}

// MARK: Segmented control

/// `.segmented` as the system's segmented control: a radio group, so Tab lands on it, the arrow keys move the choice
/// (wrapping) and Space takes the one shown. A click shows no focus ring (`:focus-visible`). The selected segment is
/// tinted with the theme's accent. The views that name the segments for captures lie over it, take no clicks and draw
/// nothing. One that sets `refusesFirstResponder` never has the keyboard: only clicks choose.
class SystemSegmentedControl: NSSegmentedControl, ThemeApplying {
    private(set) var theme = AppearanceModel.shared.theme
    /// Told the segment chosen, by a click or a key.
    var onSegment: (Int) -> Void = { _ in }
    private(set) var showsFocusRing = false {
        didSet {
            focusRingType = showsFocusRing ? .default : .none
            noteFocusRingMaskChanged()
        }
    }
    private var focusingByClick = false

    init(titles: [String]) {
        super.init(frame: .zero)
        trackingMode = .selectOne
        controlSize = .large
        font = ThemeFonts.sans(DesignTokens.typeScale.body)
        focusRingType = .none
        target = self
        action = #selector(segmentClicked(_:))
        setTitles(titles)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitles(_ titles: [String]) {
        segmentCount = titles.count
        for (index, title) in titles.enumerated() { setLabel(title, forSegment: index) }
    }

    /// Lays the segments out so each lies under the place `widths` gives it: the track's padding at the ends, and each
    /// gap shared by the two segments beside it.
    func setSegmentWidths(_ widths: [CGFloat], trackPadding: CGFloat, gap: CGFloat) {
        for (index, width) in widths.enumerated() where index < segmentCount {
            let leading = index == 0 ? trackPadding : gap / 2
            let trailing = index == widths.count - 1 ? trackPadding : gap / 2
            setWidth(max(1, width + leading + trailing), forSegment: index)
        }
    }

    /// What tints the selected segment.
    func selectionColor(_ theme: Theme) -> RGBA { theme.accent.solid }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        selectedSegmentBezelColor = NSColor(selectionColor(theme))
    }

    override var acceptsFirstResponder: Bool { isEnabled && !refusesFirstResponder }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Puts the keyboard here as a click does: no ring.
    func focusByClick() {
        // Asking one that refuses would leave the keyboard with the window instead of where it was.
        guard acceptsFirstResponder else { return }
        focusingByClick = true
        window?.makeFirstResponder(self)
        focusingByClick = false
        showsFocusRing = false
    }

    override func mouseDown(with event: NSEvent) {
        focusByClick()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = !focusingByClick && NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard segmentCount > 0 else { return super.keyDown(with: event) }
        let current = selectedSegment
        switch event.keyCode {
        case 123, 126: choose((max(current, 0) - 1 + segmentCount) % segmentCount)
        case 124, 125: choose((max(current, 0) + 1) % segmentCount)
        case 49: choose(max(current, 0))
        default: super.keyDown(with: event)
        }
    }

    private func choose(_ index: Int) {
        selectedSegment = index
        onSegment(index)
    }

    @objc private func segmentClicked(_ sender: Any?) {
        guard selectedSegment >= 0 else { return }
        onSegment(selectedSegment)
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
