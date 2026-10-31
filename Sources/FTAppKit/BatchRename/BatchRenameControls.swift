// Port of the controls of apps/desktop/src/renderer/components/BatchRenameSheet.tsx (TextField, NumberField, Popup,
// Checkbox, the segmented radio group, the token buttons, the chevrons and glyphs) as styles.css draws them (6696-7170,
// 1405-1450, 7303-7330, 7395-7420)
import AppKit
import FTFoundation

/// The sheet's text style for a size and color, laid on the sheet's background.
@MainActor
func batchRenameStyle(
    _ size: Double, _ color: @escaping @MainActor (Theme) -> RGBA, lineHeight: Double? = nil,
    weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left
) -> TextStyle {
    var style = TextStyle(
        font: ThemeFonts.sans(size, weight), color: color, lineHeight: lineHeight.map { $0 / size },
        alignment: alignment)
    style.background = { $0.palette.bgElevated }
    return style
}

/// The height of a line of text of this size (`line-height: normal`).
@MainActor
func batchRenameLine(_ size: Double) -> CGFloat {
    ThemeFonts.normalLineHeight(ThemeFonts.sans(size))
}

/// The width a line of text takes.
@MainActor
func batchRenameTextWidth(_ text: String, _ size: Double, weight: NSFont.Weight = .regular) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: ThemeFonts.sans(size, weight)]).width)
}

/// The focus ring the stylesheet draws around a control (`--focus-ring`: 3 px of the accent at 50%).
@MainActor
func drawBatchRenameFocusRing(_ rect: NSRect, radius: CGFloat, theme: Theme) {
    let width = CGFloat(DesignTokens.focusRingWidth)
    let ring = NSBezierPath(
        roundedRect: rect.insetBy(dx: -width / 2, dy: -width / 2), xRadius: radius + width / 2,
        yRadius: radius + width / 2)
    ring.lineWidth = width
    NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
    ring.stroke()
}

// MARK: Text field

/// The text inside a sheet field: tells when it takes the keyboard.
@MainActor
final class BatchRenameEditField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// `.batch-rename-field`: a field on the field's fill and edge, 24 tall with 8 each side, marked red while what it
/// holds is wrong. Spelling and correction are off; it keeps at most 255 characters.
@MainActor
final class BatchRenameTextField: NSView, ThemeApplying, NSTextFieldDelegate {
    let field = BatchRenameEditField()
    /// Told each change of the text, as typed.
    var onChange: (String) -> Void = { _ in }
    /// Told when the field gives up the keyboard.
    var onBlur: () -> Void = {}
    /// Told when the field takes the keyboard.
    var onFocus: () -> Void = {}
    var limit: Int
    var isInvalid = false { didSet { if isInvalid != oldValue { needsDisplay = true } } }
    /// Where the selection was when the field last gave up the keyboard (a field keeps it, as an input does); the end
    /// of the text it was given otherwise.
    var lastSelection: Range<Int>?
    private var theme = AppearanceModel.shared.theme
    private let font = ThemeFonts.sans(BatchRenameSheetLayout.Fonts.body)

    init(label: String, identifier: String = "batchRename.field", number: Bool = false, limit: Int) {
        self.limit = limit
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
        field.font = font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.alignment = number ? .right : .natural
        field.isAutomaticTextCompletionEnabled = false
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.onFocus = { [weak self] in
            self?.needsDisplay = true
            self?.onFocus()
        }
        addSubview(field)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var text: String {
        get { field.stringValue }
        set {
            guard newValue != field.stringValue else { return }
            let editor = field.currentEditor()
            let selection = editor?.selectedRange
            field.stringValue = newValue
            let length = (newValue as NSString).length
            if let editor, let selection {
                editor.selectedRange = NSRange(location: min(selection.location, length), length: 0)
            } else {
                lastSelection = length..<length
            }
        }
    }

    var isEnabled: Bool {
        get { field.isEnabled }
        set {
            guard newValue != field.isEnabled else { return }
            field.isEnabled = newValue
            field.isEditable = newValue
            alphaValue = newValue ? 1 : CGFloat(DesignTokens.disabledOpacity)
        }
    }

    var holdsKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    /// The selection, in UTF-16 offsets: the one being edited, else the one the field kept.
    var selection: Range<Int>? {
        guard let range = field.currentEditor()?.selectedRange else { return lastSelection }
        return range.location..<(range.location + range.length)
    }

    func focus(caret: Int? = nil) {
        guard let window else { return }
        if !holdsKeyboard { window.makeFirstResponder(field) }
        if let caret, let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: caret, length: 0)
        }
        needsDisplay = true
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        field.textColor = NSColor(theme.palette.textPrimary)
        needsDisplay = true
    }

    // MARK: Editing

    func controlTextDidBeginEditing(_ obj: Notification) {
        if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.insertionPointColor = NSColor(theme.accent.solid)
        }
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        let limited = BatchRenameTextRules.limited(field.stringValue, to: limit)
        if limited != field.stringValue { text = limited }
        onChange(field.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let range = (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.selectedRange {
            lastSelection = range.location..<(range.location + range.length)
        }
        needsDisplay = true
        onBlur()
    }

    /// Return and Tab are the sheet's: the field editor doesn't take them.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.insertBacktab(_:))
            || selector == #selector(NSResponder.cancelOperation(_:))
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        // The field's cell draws its text 2 in from each side of its frame, which is made wider to cancel it.
        let inset = CGFloat(BatchRenameSheetLayout.Field.paddingHorizontal) - SettingsMetrics.fieldCellInset
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        field.frame = NSRect(
            x: inset, y: ((bounds.height - lineHeight) / 2).rounded(), width: max(0, bounds.width - 2 * inset),
            height: lineHeight)
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { focus() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let box = bounds
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        if isInvalid {
            let edge = CGFloat(BatchRenameSheetLayout.Field.invalidEdge)
            let path = NSBezierPath(
                roundedRect: box.insetBy(dx: edge / 2, dy: edge / 2), xRadius: radius, yRadius: radius)
            path.lineWidth = edge
            NSColor(palette.danger).setStroke()
            path.stroke()
        } else {
            for layer in palette.fieldEdge where layer.blur == 0 && layer.spread > 0 {
                let edge = NSBezierPath(
                    roundedRect: box.insetBy(dx: CGFloat(layer.spread) / 2, dy: CGFloat(layer.spread) / 2),
                    xRadius: radius, yRadius: radius)
                edge.lineWidth = CGFloat(layer.spread)
                NSColor(layer.color).setStroke()
                edge.stroke()
            }
        }
        if holdsKeyboard { drawBatchRenameFocusRing(box, radius: radius, theme: theme) }
    }
}

// MARK: Pop-up

/// `.batch-rename-popup`: a pop-up (or, for the presets, a pull-down) with the push button's bezel, its title 8 in
/// and the chevrons Settings draws 8 from the right.
@MainActor
final class BatchRenamePopUp: NSPopUpButton, ThemeApplying {
    /// Told the index of the item chosen (a pull-down's title item not counted).
    var onChoose: (Int) -> Void = { _ in }
    private var theme = AppearanceModel.shared.theme
    private var titles: [String] = []
    private var shownTitle = ""
    private var showsFocusRing = false { didSet { needsDisplay = true } }
    private let titleFont = ThemeFonts.sans(BatchRenameSheetLayout.Fonts.body)

    init(label: String, identifier: String = "batchRename.popup", pullsDown: Bool = false) {
        super.init(frame: .zero, pullsDown: pullsDown)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        isBordered = false
        font = titleFont
        focusRingType = .none
        target = self
        action = #selector(chose(_:))
        autoenablesItems = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A pop-up's choices and the one chosen.
    func setChoices(_ titles: [String], selected: Int) {
        if titles != self.titles {
            self.titles = titles
            removeAllItems()
            addItems(withTitles: titles)
        }
        if indexOfSelectedItem != selected, itemArray.indices.contains(selected) { selectItem(at: selected) }
        shownTitle = itemArray.indices.contains(selected) ? titles[selected] : ""
        needsDisplay = true
    }

    /// A pull-down's items (separators as nil) under the title it shows closed.
    func setMenu(title: String, items: [String?]) {
        menu?.removeAllItems()
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu?.addItem(head)
        for item in items {
            menu?.addItem(item.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") } ?? .separator())
        }
        titles = [title] + items.map { $0 ?? "" }
        selectItem(at: 0)
        shownTitle = title
        needsDisplay = true
    }

    var shownText: String { shownTitle }

    /// The width the pop-up takes by itself: its widest choice and its padding.
    var preferredWidth: CGFloat {
        let layout = BatchRenameSheetLayout.Popup.self
        let widest = titles.map { batchRenameTextWidth($0, BatchRenameSheetLayout.Fonts.body) }.max() ?? 0
        return widest + CGFloat(layout.paddingLeft + layout.paddingRight)
    }

    @objc private func chose(_ sender: Any?) {
        let index = indexOfSelectedItem - (pullsDown ? 1 : 0)
        if pullsDown { selectItem(at: 0) }
        onChoose(index)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = BatchRenameSheetLayout.Popup.self
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(palette.pushButtonBg).setFill()
        shape.fill()
        drawPushButtonBezel(palette, around: bounds, radius: radius)
        if cell?.isHighlighted == true {
            NSColor.black.withAlphaComponent(CGFloat(1 - palette.pushButtonPressed)).setFill()
            shape.fill()
        }
        let font = titleFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textRect = NSRect(
            x: CGFloat(layout.paddingLeft), y: ((bounds.height - lineHeight) / 2).rounded(),
            width: max(0, bounds.width - CGFloat(layout.paddingLeft + layout.paddingRight)), height: lineHeight)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (shownTitle as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: NSColor(palette.textPrimary), .paragraphStyle: paragraph])
        let size = CGFloat(layout.chevronSize)
        let box = NSRect(
            x: bounds.width - CGFloat(layout.chevronRight) - size, y: ((bounds.height - size) / 2).rounded(),
            width: size, height: size)
        let data = pullsDown ? "M8 10l4 4 4-4" : "M8 9.5l4-4 4 4M8 14.5l4 4 4-4"
        BatchRenameGlyphs.stroke(
            data, in: box, viewBox: layout.chevronViewBox, width: layout.chevronStroke, color: palette.textTertiary)
        if showsFocusRing { drawBatchRenameFocusRing(bounds, radius: radius, theme: theme) }
    }
}

// MARK: Checkbox

/// `.batch-rename-check`: the 14 pt box of Settings and its label, 6 apart. Space or a click toggles it.
@MainActor
final class BatchRenameCheckbox: NSView, ThemeApplying, TextStyleSource {
    let label: ThemedText
    var onToggle: (Bool) -> Void = { _ in }
    private(set) var isChecked = false
    private var theme = AppearanceModel.shared.theme
    private var showsFocusRing = false { didSet { needsDisplay = true } }

    init(title: String) {
        label = ThemedText(
            title, style: batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textPrimary }))
        super.init(frame: .zero)
        setAccessibilityIdentifier("batchRename.check")
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        label.setAccessibilityIdentifier("batchRename.check.label")
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var styleTextField: NSTextField? { label }

    func setChecked(_ checked: Bool) {
        guard checked != isChecked else { return }
        isChecked = checked
        setAccessibilityValue(checked)
        needsDisplay = true
    }

    /// Toggles it, as a click does.
    func toggle() {
        setChecked(!isChecked)
        onToggle(isChecked)
    }

    var preferredWidth: CGFloat {
        CGFloat(BatchRenameSheetLayout.Check.boxSize + BatchRenameSheetLayout.Check.gap) + label.naturalWidth
    }

    var boxRect: NSRect {
        let size = CGFloat(BatchRenameSheetLayout.Check.boxSize)
        return NSRect(x: 0, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
    }

    override func layout() {
        super.layout()
        let x = CGFloat(BatchRenameSheetLayout.Check.boxSize + BatchRenameSheetLayout.Check.gap)
        let height = batchRenameLine(BatchRenameSheetLayout.Fonts.body)
        label.frame = NSRect(
            x: x, y: ((bounds.height - height) / 2).rounded(), width: label.naturalWidth, height: height)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = NSApp.currentEvent?.type != .leftMouseDown
        return true
    }

    override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        toggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggle() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = BatchRenameSheetLayout.Check.self
        let box = boxRect
        let radius = CGFloat(DesignTokens.radii.xs)
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        let palette = theme.palette
        if isChecked {
            NSColor(theme.accent.solid).setFill()
            shape.fill()
            BatchRenameGlyphs.stroke(
                "M3.5 7.2l2.3 2.3 4.7-5", in: box, viewBox: layout.boxSize, width: layout.markStroke,
                color: RGBA(red: 1, green: 1, blue: 1))
        } else {
            NSColor(palette.checkOffBg).setFill()
            shape.fill()
            let edge = NSBezierPath(
                roundedRect: box.insetBy(dx: CGFloat(layout.edge) / 2, dy: CGFloat(layout.edge) / 2), xRadius: radius,
                yRadius: radius)
            edge.lineWidth = CGFloat(layout.edge)
            NSColor(palette.checkBorder).setStroke()
            edge.stroke()
        }
        if showsFocusRing { drawBatchRenameFocusRing(box, radius: radius, theme: theme) }
    }
}

// MARK: Mode control

/// Where one segment of the mode control lies, for captures to find, read and click: its label, and on the chosen one
/// the mark the scenarios find it by. It draws nothing and a click goes through it to the control.
@MainActor
final class BatchRenameSegment: NSView, TextStyleSource {
    let mode: BatchRenameMode
    let label: ThemedText
    let selectedMark = BatchRenameSelectedMark()

    init(mode: BatchRenameMode, title: String) {
        self.mode = mode
        label = ThemedText(
            title, style: batchRenameStyle(BatchRenameSheetLayout.Fonts.body, { $0.palette.textSecondary }))
        super.init(frame: .zero)
        alphaValue = 0
        setAccessibilityIdentifier("batchRename.mode")
        setAccessibilityLabel(title)
        selectedMark.setAccessibilityIdentifier("batchRename.mode.selected")
        selectedMark.setAccessibilityLabel(title)
        selectedMark.setAccessibilityValue(title)
        selectedMark.label = label
        addSubview(label)
        addSubview(selectedMark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var styleTextField: NSTextField? { label }
    var title: String { label.stringValue }

    var preferredWidth: CGFloat {
        label.exactWidth + CGFloat(2 * BatchRenameSheetLayout.Modes.segmentPadding)
    }

    override func layout() {
        super.layout()
        let height = batchRenameLine(BatchRenameSheetLayout.Fonts.body)
        label.frame = NSRect(
            x: CGFloat(BatchRenameSheetLayout.Modes.segmentPadding), y: ((bounds.height - height) / 2).rounded(),
            width: label.exactWidth, height: height)
        selectedMark.frame = bounds
    }
}

/// The mark on the chosen segment (`.segmented-item.is-selected`): it reads as the segment's title, as the original's
/// selected item does.
@MainActor
final class BatchRenameSelectedMark: NSView, TextStyleSource {
    weak var label: NSTextField?
    var styleTextField: NSTextField? { label }
    override var isFlipped: Bool { true }
}

/// `.segmented` as the system's control (D-020), a radio group ("How to rename"): Tab lands on it, the arrow keys move
/// between the segments, a click chooses one.
@MainActor
final class BatchRenameModeControl: SystemSegmentedControl {
    let segments: [BatchRenameSegment]
    var onChoose: (BatchRenameMode) -> Void = { _ in }
    private(set) var selected: BatchRenameMode = .replace

    init() {
        segments = BatchRenameSheetText.modes.map { BatchRenameSegment(mode: $0.mode, title: $0.label) }
        super.init(titles: BatchRenameSheetText.modes.map(\.label))
        setAccessibilityIdentifier("batchRename.modes")
        setAccessibilityLabel(BatchRenameSheetText.modeGroupLabel)
        setSegmentWidths(
            segments.map(\.preferredWidth), trackPadding: CGFloat(BatchRenameSheetLayout.Modes.trackPadding),
            gap: CGFloat(BatchRenameSheetLayout.Modes.segmentGap))
        for segment in segments { addSubview(segment) }
        onSegment = { [weak self] index in
            guard let self, self.segments.indices.contains(index) else { return }
            self.choose(self.segments[index].mode)
        }
        select(.replace)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ mode: BatchRenameMode) {
        selected = mode
        selectedSegment = segments.firstIndex { $0.mode == mode } ?? -1
        for segment in segments {
            let isSelected = segment.mode == mode
            segment.selectedMark.isHidden = !isSelected
            segment.label.content = { [title = segment.title] theme in
                batchRenameStyle(
                    BatchRenameSheetLayout.Fonts.body,
                    { isSelected ? $0.palette.segmentedSelectedText : $0.palette.textSecondary }
                ).string(title, theme)
            }
        }
    }

    var preferredSize: NSSize {
        let layout = BatchRenameSheetLayout.Modes.self
        let widths = segments.map(\.preferredWidth).reduce(0, +)
        let gaps = CGFloat(layout.segmentGap) * CGFloat(max(0, segments.count - 1))
        return NSSize(
            width: widths + gaps + CGFloat(2 * layout.trackPadding),
            height: CGFloat(BatchRenameSheetLayout.controlHeight + 2 * layout.trackPadding))
    }

    override func layout() {
        super.layout()
        let layout = BatchRenameSheetLayout.Modes.self
        var x = CGFloat(layout.trackPadding)
        for segment in segments {
            let width = segment.preferredWidth
            segment.frame = NSRect(
                x: x, y: CGFloat(layout.trackPadding), width: width,
                height: CGFloat(BatchRenameSheetLayout.controlHeight))
            x += width + CGFloat(layout.segmentGap)
        }
    }

    func choose(_ mode: BatchRenameMode) {
        guard mode != selected else { return }
        select(mode)
        onChoose(mode)
    }
}

// MARK: Token button

/// `.batch-rename-token`: a date token on the marks' tint, 20 tall, 7 each side, its name in the tooltip.
@MainActor
final class BatchRenameTokenButton: TextControl {
    let token: BatchRenameDateToken
    private var showsFocusRing = false { didSet { needsDisplay = true } }
    private static let font = ThemeFonts.sans(BatchRenameSheetLayout.Fonts.small)

    init(token: BatchRenameDateToken) {
        self.token = token
        super.init(text: token.rawValue, theme: AppearanceModel.shared.theme)
        font = Self.font
        alignment = .center
        toolTip = BatchRenameSheetText.tokenName(token)
        setAccessibilityIdentifier("batchRename.token")
        setAccessibilityRole(.button)
        setAccessibilityLabel(BatchRenameSheetText.tokenName(token))
        applyTextColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredWidth: CGFloat {
        batchRenameTextWidth(token.rawValue, BatchRenameSheetLayout.Fonts.small)
            + CGFloat(2 * BatchRenameSheetLayout.Tokens.paddingHorizontal)
    }

    private func applyTextColor() { textColor = NSColor(theme.accent.batchRenameMarkText) }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyTextColor()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = NSApp.currentEvent?.type != .leftMouseDown
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        return super.resignFirstResponder()
    }

    override func drawChrome() {
        let radius = CGFloat(DesignTokens.radii.xs)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(isHovering ? theme.accent.actionHoverBg : theme.accent.batchRenameMarkBg).setFill()
        shape.fill()
        if showsFocusRing { drawBatchRenameFocusRing(bounds, radius: radius, theme: theme) }
    }

    override func mouseDown(with event: NSEvent) {
        if track() { perform() }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: Glyphs

/// The sheet's drawn glyphs: a folder, a file, the warning sign, the arrow between the names and the chevrons.
@MainActor
enum BatchRenameGlyphs {
    /// Strokes SVG path data drawn from a square `viewBox` into `rect`.
    static func stroke(_ data: String, in rect: NSRect, viewBox: Double, width: Double, color: RGBA) {
        let path = transformed(data, in: rect, viewBox: viewBox)
        path.lineWidth = CGFloat(width) * rect.width / CGFloat(viewBox)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(color).setStroke()
        path.stroke()
    }

    static func transformed(_ data: String, in rect: NSRect, viewBox: Double) -> NSBezierPath {
        let path = SVGPath.path(data)
        let scale = rect.width / CGFloat(viewBox)
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(scale)
        path.transform(using: transform)
        return path
    }
}

/// A glyph of the sheet, drawn in its frame.
@MainActor
final class BatchRenameGlyphView: NSView, ThemeApplying {
    enum Kind {
        case folder, file, warning, arrow
    }

    var kind: Kind { didSet { needsDisplay = true } }
    private var theme = AppearanceModel.shared.theme

    init(_ kind: Kind, identifier: String) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        switch kind {
        case .folder:
            let viewBox = BatchRenameSheetLayout.Preview.glyphViewBox
            let path = BatchRenameGlyphs.transformed(
                "M2 4.5a1 1 0 0 1 1-1h3.6l1.4 1.5h7a1 1 0 0 1 1 1v7.5a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z", in: bounds,
                viewBox: viewBox)
            NSColor(theme.accent.folderTint).setFill()
            path.fill()
            path.lineWidth = bounds.width / CGFloat(viewBox)
            NSColor(theme.accent.solid).setStroke()
            path.stroke()
        case .file:
            let viewBox = BatchRenameSheetLayout.Preview.glyphViewBox
            let page = BatchRenameGlyphs.transformed(
                "M4.5 2h6l3 3v10a1 1 0 0 1-1 1h-8a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1z", in: bounds, viewBox: viewBox)
            NSColor(palette.bgElevated).setFill()
            page.fill()
            page.lineWidth = bounds.width / CGFloat(viewBox)
            NSColor(palette.textSecondary).setStroke()
            page.stroke()
            let fold = BatchRenameGlyphs.transformed("M10.5 2v3h3", in: bounds, viewBox: viewBox)
            fold.lineWidth = bounds.width / CGFloat(viewBox)
            fold.stroke()
        case .warning:
            let layout = BatchRenameSheetLayout.Advice.self
            let sign = BatchRenameGlyphs.transformed("M8 1.5 15 14H1z", in: bounds, viewBox: layout.glyphViewBox)
            NSColor(palette.warningGlyphFill).setFill()
            sign.fill()
            sign.lineWidth = bounds.width / CGFloat(layout.glyphViewBox)
            sign.lineJoinStyle = .round
            NSColor(palette.warningGlyphStroke).setStroke()
            sign.stroke()
            BatchRenameGlyphs.stroke(
                "M8 6v3.6M8 11.4v.1", in: bounds, viewBox: layout.glyphViewBox, width: layout.markStroke,
                color: palette.warningGlyphMark)
        case .arrow:
            let layout = BatchRenameSheetLayout.Preview.self
            BatchRenameGlyphs.stroke(
                "M2 6h8M7 3l3 3-3 3", in: bounds, viewBox: layout.arrowSize, width: layout.arrowStroke,
                color: palette.textTertiary)
        }
    }
}
