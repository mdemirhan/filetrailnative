// Port of the toolbar items of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx (title block, view
// switch, search slot, clipboard button) as the views of system toolbar items
import AppKit
import FTFoundation

/// `.toolbar-title-block`: the folder's name in 15 pt semibold, cut short with an ellipsis, its full path as the
/// tooltip. It takes the room the other items leave, and it drags the window.
final class ToolbarTitleView: NSView, TextStyleSource {
    /// The `.toolbar-title` box: its text starts at the block's padding.
    let field = FlushTextField(labelWithString: "")
    static let lineHeight = 1.2
    /// The title dims while its window isn't key.
    private var windowActivity: WindowActivity?

    var styleTextField: NSTextField? { field }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = ChromeColors.font(size: DesignTokens.toolbar.titleFontSize, weight: 600)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setAccessibilityIdentifier("toolbar.title")
        addSubview(field)
        setAccessibilityIdentifier("toolbar.titleBlock")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// The block's height: one line of the title.
    static var height: Double { (DesignTokens.toolbar.titleFontSize * lineHeight).rounded() }

    override func layout() {
        super.layout()
        let toolbar = DesignTokens.toolbar
        field.frame = NSRect(
            x: toolbar.titlePaddingLeading, y: 0,
            width: max(0, bounds.width - toolbar.titlePaddingLeading - toolbar.titlePaddingTrailing),
            height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The text is part of the block: a press on it drags the window.
        let hit = super.hitTest(point)
        return hit === field ? self : hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitleColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowActivity?.stop()
        windowActivity = window.map { WindowActivity(window: $0) }
        windowActivity?.onChange = { [weak self] _ in self?.applyTitleColor() }
        applyTitleColor()
    }

    private func applyTitleColor() {
        field.textColor = ChromeColors.toolbarTitle(for: self, isKey: window?.isKeyWindow ?? true)
    }
}

/// The view switch (`.toolbar-segmented`), the system's segmented control: three icons, one selected. Search results
/// are one table: it is disabled in search mode.
final class ToolbarViewSwitch: NSSegmentedControl {
    static let modes: [(ExplorerViewMode, ToolbarIconName, String, ShortcutCommandID)] = [
        (.icons, .icons, "View as Icons", .viewAsIcons), (.details, .details, "View as List", .viewAsDetails),
        (.list, .list, "View as Compact List", .viewAsList),
    ]
    /// Finder's selected segment, read from its screenshots; the system's fit around these icons is 30.
    static let segmentWidth = 34.0
    var onChoose: (ExplorerViewMode) -> Void = { _ in }
    /// The segment Tab is at: each is a button of its own in the original.
    private(set) var keyboardSegment = 0 {
        didSet { noteFocusRingMaskChanged() }
    }
    private var takingKeyboard = false
    var selected: ExplorerViewMode {
        get { Self.modes[max(0, selectedSegment)].0 }
        set { selectedSegment = Self.modes.firstIndex { $0.0 == newValue } ?? 0 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        segmentCount = Self.modes.count
        trackingMode = .selectOne
        for (index, (_, icon, label, _)) in Self.modes.enumerated() {
            let image = ToolbarGlyph.image(icon)
            image.accessibilityDescription = label
            setImage(image, forSegment: index)
            setImageScaling(.scaleNone, forSegment: index)
            setWidth(Self.segmentWidth, forSegment: index)
        }
        selectedSegment = 0
        target = self
        action = #selector(segmentChosen(_:))
        setAccessibilityLabel("View")
        setAccessibilityIdentifier("toolbar.viewSwitch")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func segmentChosen(_ sender: Any?) {
        choose(segment: selectedSegment)
    }

    /// The segment at `index` was chosen.
    func choose(segment index: Int) {
        guard Self.modes.indices.contains(index) else { return }
        onChoose(Self.modes[index].0)
    }

    // MARK: Keyboard

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isEnabled }
    override var canBecomeKeyView: Bool { false }

    /// Gives the keyboard to the first segment, or the last going backward; false when the window would not.
    @discardableResult
    func takeKeyboard(backward: Bool = false) -> Bool {
        guard let window else { return false }
        keyboardSegment = backward ? segmentCount - 1 : 0
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 48:
            let backward = event.modifierFlags.contains(.shift)
            let next = keyboardSegment + (backward ? -1 : 1)
            if (0..<segmentCount).contains(next) {
                keyboardSegment = next
            } else {
                ToolbarKeyboard.move(from: self, backward: backward)
            }
        case 36, 76, 49:
            selectedSegment = keyboardSegment
            choose(segment: keyboardSegment)
        default:
            // No arrow changes the view: plain buttons take none.
            nextResponder?.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() {
        var x = 0.0
        for index in 0..<keyboardSegment { x += width(forSegment: index) }
        NSBezierPath(
            roundedRect: NSRect(x: x, y: 0, width: width(forSegment: keyboardSegment), height: bounds.height),
            xRadius: 4, yRadius: 4
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    func setTooltips(_ shortcuts: ShortcutDisplay) {
        for (index, (_, _, label, command)) in Self.modes.enumerated() {
            setToolTip(Tooltips.format(label, shortcut: shortcuts.written(command)), forSegment: index)
        }
    }
}

/// The clipboard button (`.clipboard-button`): the copy or cut icon and how many items wait to be pasted, in the
/// accent color. Its list is P5-08's. The button's own title, in no color, keeps the room the system's bezel measures;
/// the count is a label of its own over that room, as the scenarios read it.
final class ToolbarClipboardButton: ToolbarButton, TextStyleSource {
    let count = FlushTextField(labelWithString: "")
    private static let countFont = NSFont.monospacedDigitSystemFont(
        ofSize: DesignTokens.typeScale.small, weight: .semibold)

    var styleTextField: NSTextField? { count }
    /// `button:focus-visible`: a click leaves the page's focus on the button, and the first key after it (the list's
    /// arrows) shows the ring while the list is open.
    var showsKeyboardRing = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(icon: .copy, label: "Clipboard", identifier: "toolbar.clipboard")
        count.font = Self.countFont
        count.setAccessibilityIdentifier("toolbar.clipboard.count")
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(count value: Int, cut: Bool) {
        iconName = cut ? .cut : .copy
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        count.stringValue = text
        count.isHidden = value == 0
        imagePosition = value == 0 ? .imageOnly : .imageLeading
        attributedTitle = NSAttributedString(
            string: value == 0 ? "" : text, attributes: [.font: Self.countFont, .foregroundColor: NSColor.clear])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !count.isHidden, let cell else { return }
        let room = cell.titleRect(forBounds: bounds)
        let size = count.intrinsicContentSize
        count.frame = NSRect(
            x: room.minX, y: (bounds.height - size.height) / 2, width: max(room.width, size.width),
            height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = ChromeColors.accent(for: self)
        count.textColor = ChromeColors.color(accent.solidButton)
        guard showsKeyboardRing else { return }
        let width = DesignTokens.focusRingWidth
        let radius = bounds.height / 2 + width / 2
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: -width / 2, dy: -width / 2), xRadius: radius, yRadius: radius)
        ring.lineWidth = width
        ChromeColors.color(accent.focusRing.color).setStroke()
        ring.stroke()
    }
}

/// The toolbar's search field (`.toolbar-search`), the system's, in an `NSSearchToolbarItem`: the magnifier with its
/// small chevron is the Search Options button, the placeholder is "Search", the system's clear button shows once the
/// trimmed text is not empty.
final class ToolbarSearchField: NSSearchField {
    /// The field took the keyboard (`onFocus` of the field: the cached search may come back).
    var onFocus: () -> Void = {}
    /// The magnifier was pressed: the options menu opens, the keyboard staying in the field; or Return or Space on it
    /// (`fromKeyboard`), which marks the menu's first item.
    var onOptions: (_ fromKeyboard: Bool) -> Void = { _ in }
    /// The ✕ was clicked.
    var onClear: () -> Void = {}
    /// The press target over the system's magnifier, for the capture and the accessibility tree.
    let optionsButton = ToolbarSearchOptionsButton()
    /// Where Tab stops at the system's ✕, which takes no keyboard itself.
    let clearStop = KeyboardStopView()
    /// The options menu is open.
    var optionsOpen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        placeholderString = SearchBarText.fieldPlaceholder
        sendsSearchStringImmediately = true
        setAccessibilityIdentifier("toolbar.search")
        setAccessibilityLabel(SearchBarText.fieldName)
        if let cell = cell as? NSSearchFieldCell {
            // The system draws the chevron on the magnifier of a field with a menu; the press is the options button's.
            cell.searchMenuTemplate = NSMenu()
        }
        optionsButton.onPress = { [weak self] fromKeyboard in self?.onOptions(fromKeyboard) }
        addSubview(optionsButton)
        clearStop.isHidden = true
        clearStop.onPress = { [weak self] in self?.onClear() }
        clearStop.onTab = { [weak self] backward in
            guard let self else { return }
            ToolbarKeyboard.move(from: self.clearStop, backward: backward)
        }
        addSubview(clearStop)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The ✕ is the app's (`TabSearch`). The system's item points the button at itself when it takes the field, and
    /// again as it goes into the toolbar, so this comes after that.
    func takeClearButton() {
        guard let cell = cell as? NSSearchFieldCell else { return }
        cell.cancelButtonCell?.target = self
        cell.cancelButtonCell?.action = #selector(clearPressed(_:))
        syncClearButton()
    }

    @objc private func clearPressed(_ sender: Any?) { onClear() }

    /// The button the system makes for the field's cancel cell.
    var clearButton: NSButton? {
        (cell as? NSSearchFieldCell)?.cancelButtonCell?.controlView as? NSButton
    }

    /// The ✕ shows once the trimmed text is not empty (`searchDraftQuery.trim()`).
    var clearButtonShows: Bool {
        !SearchTiming.trimmed(currentEditor()?.string ?? stringValue).isEmpty
    }

    /// The system's button says what the original's does. The system shows and hides it by whether there is any text,
    /// as it updates the field, so its `isHidden` isn't ours: for text of only spaces it is see-through and does nothing.
    private func syncClearButton() {
        let shows = clearButtonShows
        clearStop.isHidden = !shows
        guard let button = clearButton else { return }
        button.toolTip = SearchBarText.clearSearchTitle
        button.setAccessibilityLabel(SearchBarText.clearSearchName)
        button.setAccessibilityIdentifier("toolbar.search.clear")
        button.setAccessibilityElement(shows)
        button.alphaValue = shows ? 1 : 0
        button.isEnabled = shows && isEnabled
    }

    override var stringValue: String {
        didSet { syncClearButton() }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        syncClearButton()
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus() }
        return took
    }

    /// Whether the field has the keyboard.
    var isActive: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === self
    }

    override func layout() {
        super.layout()
        guard let cell = cell as? NSSearchFieldCell else { return }
        optionsButton.frame = cell.searchButtonRect(forBounds: bounds)
        clearStop.frame = cell.cancelButtonRect(forBounds: bounds)
        // The system makes its button when the field first goes on screen.
        syncClearButton()
    }
}

/// The magnifier and chevron of the search field (`.toolbar-search-options-button`, "Search Options"): a press opens the
/// options menu and leaves the keyboard in the field. Shift-Tab from the field gives it the keyboard, as the button
/// before the field in the original; Return or Space on it then opens the menu from the keyboard. The system's field
/// draws it; this view takes the keys and has the keyboard's focus ring, and the press comes from the toolbar
/// (`ExplorerToolbar.pressSearchOptions`).
final class ToolbarSearchOptionsButton: NSView {
    var onPress: (_ fromKeyboard: Bool) -> Void = { _ in }
    /// Set while the keyboard is given to the button: a press never takes it (`onMouseDown: preventDefault`).
    private var takingKeyboard = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityIdentifier("toolbar.search.options")
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel(SearchBarText.optionsName)
        toolTip = SearchBarText.optionsTitle
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { takingKeyboard }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasKeyboard: Bool { window?.firstResponder === self }

    /// Gives the button the keyboard; false when the window would not.
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // The press itself opens the menu; its mouse-down moves no focus (`onMouseDown: preventDefault`).
    override func mouseDown(with event: NSEvent) { onPress(false) }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49:
            // Return, Enter or Space: a keyboard click (`event.detail === 0`).
            onPress(true)
        case 48:
            // Tab goes on to the field after the button; Shift-Tab to what comes before the field.
            guard let field = superview else { return }
            if event.modifierFlags.contains(.shift) {
                ToolbarKeyboard.move(from: self, backward: true)
            } else {
                window?.makeFirstResponder(field)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress(false)
        return true
    }
}
