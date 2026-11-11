import AppKit
import FTFoundation

/// A part of a Settings page that lays itself out for a width and says how tall it is.
@MainActor
protocol SettingsBlock: NSView {
    func arrange(width: CGFloat) -> CGFloat
}

/// A control in a row: it says its size.
@MainActor
protocol SettingsSized: NSView {
    var preferredSize: NSSize { get }
}

/// The text styles of Settings.
@MainActor
enum SettingsStyle {
    static let background: @MainActor (Theme) -> RGBA = { $0.palette.settingsPageBg }

    static func style(
        _ size: Double, _ weight: NSFont.Weight = .regular, lineHeight: Double? = nil,
        color: @escaping @MainActor (Theme) -> RGBA
    ) -> TextStyle {
        var style = TextStyle(font: ThemeFonts.sans(size, weight), color: color, lineHeight: lineHeight)
        style.background = background
        return style
    }

    /// A row's title, a list row's name, a shortcut's label.
    static var body: TextStyle { style(DesignTokens.typeScale.body) { $0.palette.textPrimary } }
    /// A section's title.
    static var sectionTitle: TextStyle { style(DesignTokens.typeScale.body, .semibold) { $0.palette.textPrimary } }
    /// A row's description: 11 on 14.
    static var description: TextStyle {
        style(
            DesignTokens.typeScale.small,
            lineHeight: Double(SettingsMetrics.rowDescLineHeight) / DesignTokens.typeScale.small
        ) { $0.palette.settingsLabelSecondary }
    }
    /// A section's note.
    static var note: TextStyle {
        style(DesignTokens.typeScale.small, lineHeight: SettingsMetrics.noteLineHeight) {
            $0.palette.settingsLabelSecondary
        }
    }
}

/// Strokes SVG path data drawn in a `box` by `box` square into `rect` (a flipped context).
@MainActor
enum SettingsGlyph {
    static func stroke(
        _ data: String, box: CGFloat, in rect: NSRect, width: CGFloat, color: NSColor, round: Bool = true
    ) {
        let path = SVGPath.path(data)
        let scale = rect.width / box
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: scale, y: scale)
        path.transform(using: transform)
        path.lineWidth = width * scale
        path.lineCapStyle = round ? .round : .butt
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The pop-up's double chevron at the end of `bounds`.
    static func popupChevron(in bounds: NSRect, theme: Theme) {
        let size = SettingsMetrics.chevronSize
        let rect = NSRect(
            x: bounds.maxX - SettingsMetrics.chevronInset - size, y: (bounds.height - size) / 2, width: size,
            height: size)
        stroke(
            SettingsMetrics.chevronPath, box: 24, in: rect, width: SettingsMetrics.chevronStroke,
            color: NSColor(theme.palette.settingsLabelSecondary))
    }

    /// The push button's bezel and fill, with its hover and pressed looks.
    static func bezel(in bounds: NSRect, theme: Theme, hovering: Bool, pressed: Bool) {
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let palette = theme.palette
        NSColor(palette.pushButtonBg).setFill()
        shape.fill()
        drawPushButtonBezel(palette, around: bounds, radius: radius)
        if hovering {
            NSColor(palette.bgHover).setFill()
            shape.fill()
        }
        if pressed {
            NSColor.black.withAlphaComponent(CGFloat(1 - palette.pushButtonPressed)).setFill()
            shape.fill()
        }
    }

    /// A field's inset look: its fill and edge.
    static func field(in bounds: NSRect, theme: Theme, focused: Bool) {
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        for layer in palette.fieldEdge where layer.spread > 0 {
            let edge = NSBezierPath(
                roundedRect: bounds.insetBy(dx: CGFloat(layer.spread) / 2, dy: CGFloat(layer.spread) / 2),
                xRadius: radius, yRadius: radius)
            edge.lineWidth = CGFloat(layer.spread)
            NSColor(layer.color).setStroke()
            edge.stroke()
        }
        if focused { focusRing(around: bounds, radius: radius, theme: theme) }
    }

    /// The focus ring: the accent at 50% around a control.
    static func focusRing(around bounds: NSRect, radius: CGFloat, theme: Theme) {
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
        ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
        NSColor(theme.accent.solid.withAlpha(SettingsMetrics.focusRingAlpha)).setStroke()
        ring.stroke()
    }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// A view drawn by the theme that is also a control: hover, a press tracked to its release, the theme.
@MainActor
class SettingsControlView: NSView, ThemeApplying {
    private(set) var theme: Theme
    var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : CGFloat(DesignTokens.disabledOpacity)
            needsDisplay = true
        }
    }
    /// Told on a click.
    var onPress: () -> Void = {}
    /// How far the control moved under the pointer as the press went down (a press that scrolled the page): the
    /// release is judged against where the pointer pressed it, not against where the page took it.
    var pressShift = NSSize.zero
    private var trackingArea: NSTrackingArea?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(pressPoint(next.locationInWindow))
            isPressed = inside
            if next.type == .leftMouseUp {
                release(at: next.locationInWindow)
                return
            }
        }
        isPressed = false
        pressShift = .zero
    }

    /// The press ends at `location`, in the window: a click if that is on the control where it was pressed.
    func release(at location: NSPoint) {
        let inside = bounds.contains(pressPoint(location))
        isPressed = false
        pressShift = .zero
        if inside { press() }
    }

    /// `location`, in the window, as a point of the control at the place it had when the press went down.
    private func pressPoint(_ location: NSPoint) -> NSPoint {
        let point = convert(location, from: nil)
        return NSPoint(x: point.x - pressShift.width, y: point.y - pressShift.height)
    }

    /// Clicks the control, as a click on it does.
    func press() {
        guard isEnabled else { return }
        onPress()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

// MARK: Switch

/// The system's switch at the size System Settings draws one.
final class SettingsSwitch: NSSwitch, SettingsSized, ThemeApplying {
    var isOn: Bool {
        get { state == .on }
        set {
            state = newValue ? .on : .off
            setAccessibilityValue(newValue ? 1 : 0)
        }
    }
    var onChange: (Bool) -> Void = { _ in }
    private(set) var theme: Theme

    init(label: String, isOn: Bool, theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        controlSize = .mini
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("settings.switch")
        target = self
        action = #selector(toggled(_:))
        self.isOn = isOn
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredSize: NSSize { SettingsMetrics.switchSize }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func applyTheme(_ theme: Theme) { self.theme = theme }

    /// Clicks the switch, as a click on it does.
    func press() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange(isOn)
    }

    @objc private func toggled(_ sender: Any?) {
        setAccessibilityValue(isOn ? 1 : 0)
        onChange(isOn)
    }

    override func keyDown(with event: NSEvent) {
        // Space, Return or Enter press the switch, as they press a button.
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            press()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

// MARK: Pop-up

/// The system's pop-up button, as wide as its longest choice and never narrower than 120. A choice can be listed and
/// not choosable.
final class SettingsPopup: NSPopUpButton, SettingsSized {
    struct Option: Equatable {
        var value: String
        var title: String
        var enabled = true
    }

    private(set) var options: [Option] = []
    private(set) var value: String
    var onChange: (String) -> Void = { _ in }

    init(label accessibilityLabel: String, options: [Option], value: String, theme: Theme) {
        self.value = value
        super.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        font = ThemeFonts.sans(DesignTokens.typeScale.body)
        target = self
        action = #selector(chose(_:))
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("settings.popup")
        update(options: options, value: value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Tab comes here whatever the system's keyboard navigation setting says.
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(options: [Option], value: String) {
        self.value = value
        if options != self.options {
            self.options = options
            removeAllItems()
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.value
                item.isEnabled = option.enabled
                menu?.addItem(item)
            }
        }
        selectItem(at: options.firstIndex { $0.value == value } ?? -1)
    }

    var preferredSize: NSSize {
        let size = cell?.cellSize ?? intrinsicContentSize
        return NSSize(width: max(SettingsMetrics.popupMinWidth, ceil(size.width)), height: ceil(size.height))
    }

    /// Chooses an option as the menu does; one that can't be chosen changes nothing.
    func choose(_ value: String) {
        guard let index = options.firstIndex(where: { $0.value == value }), options[index].enabled else { return }
        selectItem(at: index)
        chose(self)
    }

    @objc private func chose(_ sender: Any?) {
        guard let chosen = selectedItem?.representedObject as? String, chosen != value else { return }
        value = chosen
        onChange(chosen)
    }

    override func keyDown(with event: NSEvent) {
        // The up and down arrows open the menu, as Space does.
        if event.keyCode == 125 || event.keyCode == 126 {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: Number field

/// A short inset field for a whole number, followed by its unit ("items"). Committed when it is
/// left or Return is pressed.
final class SettingsNumberField: NSView, SettingsSized, ThemeApplying, NSTextFieldDelegate {
    let field = NSTextField()
    private let unit = FlushTextField(labelWithString: "")
    private(set) var value: Int
    private(set) var theme: Theme
    var onChange: (Int) -> Void = { _ in }
    private static var font: NSFont { ThemeFonts.sans(DesignTokens.typeScale.body) }

    init(value: Int, unit unitText: String, label: String, theme: Theme) {
        self.value = value
        self.theme = theme
        super.init(frame: .zero)
        field.stringValue = String(value)
        field.font = Self.font
        field.alignment = .right
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("settings.numberField")
        unit.stringValue = unitText
        unit.font = Self.font
        addSubview(field)
        addSubview(unit)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        NSSize(
            width: SettingsMetrics.numberFieldWidth + SettingsMetrics.unitGap
                + (unit.stringValue as NSString).size(withAttributes: [.font: Self.font]).width,
            height: CGFloat(DesignTokens.controlHeights.regular))
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        field.textColor = NSColor(theme.palette.textPrimary)
        unit.textColor = NSColor(theme.palette.settingsLabelSecondary.flattened(over: theme.palette.settingsPageBg))
        needsDisplay = true
    }

    /// The value changed elsewhere: the field shows it.
    func update(value: Int) {
        self.value = value
        if !isEditing { field.stringValue = String(value) }
    }

    private var isEditing: Bool {
        (window?.firstResponder as? NSTextView)?.delegate === field
    }

    override func layout() {
        super.layout()
        let width = SettingsMetrics.numberFieldWidth
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        // Right-aligned before the room kept for a number field's stepper. A field's cell draws its text 2
        // in from each side of its frame, which is made wider to cancel it.
        let cellInset = SettingsMetrics.fieldCellInset
        field.frame = NSRect(
            x: SettingsMetrics.fieldPadding - cellInset, y: ((bounds.height - lineHeight) / 2).rounded(),
            width: width - 2 * SettingsMetrics.fieldPadding - SettingsMetrics.numberStepperWidth + 2 * cellInset,
            height: lineHeight)
        let unitHeight = unit.intrinsicContentSize.height
        unit.frame = NSRect(
            x: width + SettingsMetrics.unitGap,
            y: ((bounds.height - unitHeight) / 2).rounded(),
            width: max(0, bounds.width - width - SettingsMetrics.unitGap),
            height: unitHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        SettingsGlyph.field(
            in: NSRect(x: 0, y: 0, width: SettingsMetrics.numberFieldWidth, height: bounds.height), theme: theme,
            focused: isEditing)
    }

    /// Commits what is typed: the default for what is not a number, else the number brought into 1 to 50.
    func commit() {
        let result = SettingsValues.commitOpenItemLimit(field.stringValue, current: value)
        field.stringValue = result.text
        if let next = result.value {
            value = next
            onChange(next)
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { needsDisplay = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            // Return leaves the field, which commits it.
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: Checkbox

/// A checkbox: 14 by 14, the accent with a white tick when on.
final class SettingsCheckbox: SettingsControlView {
    var isChecked: Bool {
        didSet {
            setAccessibilityValue(isChecked ? 1 : 0)
            needsDisplay = true
        }
    }

    init(label: String, isChecked: Bool, theme: Theme) {
        self.isChecked = isChecked
        super.init(theme: theme)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(isChecked ? 1 : 0)
        setAccessibilityIdentifier("settings.checkbox")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.xs)
        let box = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if isChecked {
            NSColor(theme.accent.solid).setFill()
            box.fill()
            SettingsGlyph.stroke(
                SettingsMetrics.checkPath, box: SettingsMetrics.checkboxSize, in: bounds,
                width: SettingsMetrics.checkStroke, color: .white)
        } else {
            NSColor(theme.palette.checkOffBg).setFill()
            box.fill()
            let edge = NSBezierPath(
                roundedRect: bounds.insetBy(dx: SettingsMetrics.hairline / 2, dy: SettingsMetrics.hairline / 2),
                xRadius: radius, yRadius: radius)
            edge.lineWidth = SettingsMetrics.hairline
            NSColor(theme.palette.checkBorder).setStroke()
            edge.stroke()
        }
    }
}

// MARK: Small push button

extension SystemButton {
    /// A small push button: 22 tall, the callout size, 10 each side.
    static func small(_ title: String, theme: Theme) -> SystemButton {
        let button = SystemButton(title: title, theme: theme)
        button.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        button.controlHeight = DesignTokens.controlHeights.small
        return button
    }

    /// The width of a small button.
    var smallWidth: CGFloat {
        SettingsGlyph.textWidth(title, font ?? ThemeFonts.sans(DesignTokens.typeScale.callout))
            + 2 * SettingsMetrics.smallButtonPadding
    }
}

// MARK: Rows and groups

/// The title and its description at the left, the control at the right.
final class SettingsRowView: ThemedView, SettingsBlock {
    let titleText: ThemedText
    let descriptionText: ThemedText?
    let control: any SettingsSized
    var drawsSeparator = true { didSet { needsDisplay = true } }

    init(title: String, description: String? = nil, control: any SettingsSized, theme: Theme) {
        titleText = ThemedText(title, style: SettingsStyle.body, wrapping: true)
        descriptionText = description.flatMap { $0.isEmpty ? nil : $0 }.map {
            ThemedText($0, style: SettingsStyle.description, wrapping: true)
        }
        self.control = control
        super.init(theme: theme)
        titleText.setAccessibilityIdentifier("settings.row.title")
        descriptionText?.setAccessibilityIdentifier("settings.row.description")
        setAccessibilityIdentifier("settings.row")
        addSubview(titleText)
        if let descriptionText { addSubview(descriptionText) }
        addSubview(control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The description changes with the keys it names; with none it isn't shown.
    func setDescription(_ text: String) {
        descriptionText?.content = { SettingsStyle.description.string(text, $0) }
        descriptionText?.isHidden = text.isEmpty
    }

    private var shownDescription: ThemedText? { descriptionText?.isHidden == false ? descriptionText : nil }

    func arrange(width: CGFloat) -> CGFloat {
        let controlSize = control.preferredSize
        let textWidth = max(0, width - controlSize.width - SettingsMetrics.rowGap)
        // `line-height: normal` on the title; the border is part of the row's height when it has one (box-sizing).
        let titleHeight = titleText.normalLineBoxHeight(forWidth: textWidth)
        var textHeight = titleHeight
        if let descriptionText = shownDescription {
            textHeight += SettingsMetrics.rowDescGap + descriptionText.height(forWidth: textWidth)
        }
        let inner = max(textHeight, controlSize.height)
        let line = drawsSeparator ? SettingsMetrics.separatorWidth : 0
        let height = max(SettingsMetrics.rowMinHeight, inner + 2 * SettingsMetrics.rowPadding + line)
        let content = height - line
        let textTop = (content - textHeight) / 2
        titleText.frame = NSRect(
            x: 0, y: textTop, width: textWidth, height: ceil(titleText.height(forWidth: textWidth)))
        if let descriptionText = shownDescription {
            let top = textTop + titleHeight + SettingsMetrics.rowDescGap
            descriptionText.frame = NSRect(
                x: 0, y: top, width: textWidth, height: descriptionText.height(forWidth: textWidth))
        }
        control.frame = NSRect(
            x: width - controlSize.width, y: ((content - controlSize.height) / 2).rounded(), width: controlSize.width,
            height: controlSize.height)
        return height
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsSeparator else { return }
        NSColor(theme.palette.settingsSeparator).setFill()
        NSRect(
            x: 0, y: bounds.height - SettingsMetrics.separatorWidth, width: bounds.width,
            height: SettingsMetrics.separatorWidth
        ).fill()
    }
}

/// A card: the rows of a group on a faint tint, a line under each but the last, the edge drawn over them.
/// A full-width row (a list) is laid from edge to edge.
final class SettingsCardView: ThemedView, SettingsBlock {
    private(set) var rows: [any SettingsBlock] = []
    /// Rows that fill the card from edge to edge (lists).
    private var fullWidth: Set<ObjectIdentifier> = []
    private let edge = SettingsCardEdge()

    override init(frame: NSRect = .zero, theme: Theme) {
        super.init(frame: frame, theme: theme)
        fill = { $0.palette.settingsCardBg }
        cornerRadius = SettingsMetrics.cardRadius
        wantsLayer = true
        layer?.cornerRadius = SettingsMetrics.cardRadius
        layer?.masksToBounds = true
        setAccessibilityIdentifier("settings.card")
        addSubview(edge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func add(_ row: any SettingsBlock, fullWidth isFull: Bool = false) {
        rows.append(row)
        if isFull { fullWidth.insert(ObjectIdentifier(row)) }
        addSubview(row, positioned: .below, relativeTo: edge)
    }

    func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        let visible = rows.filter { !$0.isHidden }
        for (index, row) in visible.enumerated() {
            let full = fullWidth.contains(ObjectIdentifier(row))
            let inset = full ? 0 : SettingsMetrics.cardPadding
            let rowWidth = width - 2 * inset
            let last = index == visible.count - 1
            (row as? SettingsRowView)?.drawsSeparator = !last
            (row as? SettingsListBlock)?.drawsSeparator = !last
            let height = row.arrange(width: rowWidth)
            row.frame = NSRect(x: inset, y: y, width: rowWidth, height: height)
            // A list sits at the top of its row, which keeps the row's 40 minimum: an empty list
            // (only its bar) leaves room under it.
            y += full ? max(height, SettingsMetrics.rowMinHeight) : height
        }
        edge.frame = NSRect(x: 0, y: 0, width: width, height: y)
        return y
    }
}

/// The card's 1 px edge over the rows, so a selected list row doesn't paint over it.
final class SettingsCardEdge: ThemedView {
    override init(frame: NSRect = .zero, theme: Theme = AppearanceModel.shared.theme) {
        super.init(frame: frame, theme: theme)
        borderColor = { $0.palette.settingsCardBorder }
        cornerRadius = SettingsMetrics.cardRadius
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An optional title over a card of rows, an optional note under it, and a button below at the right.
final class SettingsSectionView: ThemedView, SettingsBlock {
    let titleText: ThemedText?
    let card: SettingsCardView
    let noteText: ThemedText?
    let footer: NSView?

    init(title: String?, note: String? = nil, footer: SystemButton? = nil, theme: Theme) {
        titleText = title.map { ThemedText($0, style: SettingsStyle.sectionTitle) }
        card = SettingsCardView(theme: theme)
        noteText = note.map { ThemedText($0, style: SettingsStyle.note, wrapping: true) }
        self.footer = footer
        super.init(theme: theme)
        titleText?.setAccessibilityIdentifier("settings.sectionTitle")
        noteText?.setAccessibilityIdentifier("settings.sectionNote")
        setAccessibilityIdentifier("settings.group")
        if let titleText { addSubview(titleText) }
        addSubview(card)
        if let noteText { addSubview(noteText) }
        if let footer { addSubview(footer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if let titleText {
            let side = SettingsMetrics.sectionHeaderPaddingSide
            let textHeight = titleText.height(forWidth: width - 2 * side)
            let header = max(
                SettingsMetrics.sectionHeaderMinHeight, textHeight + SettingsMetrics.sectionHeaderPaddingBottom)
            // align-items: center within the box above its bottom padding.
            let top = ((header - SettingsMetrics.sectionHeaderPaddingBottom - textHeight) / 2).rounded()
            titleText.frame = NSRect(x: side, y: top, width: titleText.naturalWidth, height: textHeight)
            y = header
        }
        let cardHeight = card.arrange(width: width)
        card.frame = NSRect(x: 0, y: y, width: width, height: cardHeight)
        y += cardHeight
        if let noteText {
            let side = SettingsMetrics.sectionNoteMarginSide
            y += SettingsMetrics.sectionNoteMarginTop
            let height = noteText.height(forWidth: width - 2 * side)
            noteText.frame = NSRect(x: side, y: y, width: width - 2 * side, height: height)
            y += height
        }
        if let footer = footer as? SystemButton {
            y += SettingsMetrics.sectionFooterGap
            let size = footer.intrinsicContentSize
            footer.frame = NSRect(x: width - size.width, y: y, width: size.width, height: size.height)
            y += size.height
        }
        return y
    }
}
