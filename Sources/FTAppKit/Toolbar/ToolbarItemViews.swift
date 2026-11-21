import AppKit
import FTFoundation

/// The toolbar's title: the folder's name in 15 pt semibold, cut short with an ellipsis, its full path as the
/// tooltip. It takes the room the other items leave, and it drags the window. While something runs in the background,
/// the activity ring takes the end of its room (`activity`), and the name is cut short before the ring is.
final class ToolbarTitleView: NSView, TextStyleSource {
    /// The title's field: its text starts at the block's padding.
    let field = FlushTextField(labelWithString: "")
    /// The ring at the end of its room; hidden while nothing runs.
    let activity = TitleActivityView()
    /// Between the name and the ring.
    static let activityGap = 8.0
    static let lineHeight = 1.2
    /// The title dims while its window isn't key.
    private var windowActivity: WindowActivity?
    /// It was laid out, maybe at another width.
    var onLayout: () -> Void = {}

    var styleTextField: NSTextField? { field }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = ChromeColors.font(size: DesignTokens.toolbar.titleFontSize, weight: 600)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setAccessibilityIdentifier("toolbar.title")
        addSubview(field)
        addSubview(activity)
        activity.onWidthChange = { [weak self] in self?.activityWidthChanged() }
        setAccessibilityIdentifier("toolbar.titleBlock")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// One line of the title.
    static var textHeight: Double { (DesignTokens.toolbar.titleFontSize * lineHeight).rounded() }
    /// The block's height: room for the ring, the line centered in it.
    static var height: Double { max(textHeight, TitleActivityView.height) }

    override func layout() {
        super.layout()
        let toolbar = DesignTokens.toolbar
        // The ring keeps its room while it fades out.
        let ringWidth = activity.isShown ? activity.preferredWidth : (activity.isHidden ? 0 : activity.frame.width)
        activity.frame = NSRect(
            x: bounds.width - toolbar.titlePaddingTrailing - ringWidth,
            y: (bounds.height - TitleActivityView.height) / 2, width: ringWidth, height: TitleActivityView.height)
        let reserved = ringWidth > 0 ? ringWidth + Self.activityGap : 0
        field.frame = NSRect(
            x: toolbar.titlePaddingLeading, y: ((bounds.height - Self.textHeight) / 2).rounded(),
            width: max(0, bounds.width - toolbar.titlePaddingLeading - toolbar.titlePaddingTrailing - reserved),
            height: Self.textHeight)
        onLayout()
    }

    /// The ring came, went or its count changed: the count's pill grows or shrinks to the left, the ring staying put.
    private func activityWidthChanged() {
        guard window != nil, !activity.reducesMotion() else {
            needsLayout = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
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

/// The view switch, the system's segmented control: four icons, one selected. Search results are one table: it is
/// disabled in search mode. The Previews segment holds View ▸ Show Previews' counts: a click switches to Previews, and a
/// press held on it shows the menu, with no arrow, which would make it wider than the others.
final class ToolbarViewSwitch: NSSegmentedControl, NSMenuDelegate {
    static let modes: [(ExplorerViewMode, CommandIcon, String, ShortcutCommandID)] = [
        (.icons, .icons, "View as Icons", .viewAsIcons), (.details, .details, "View as List", .viewAsDetails),
        (.list, .list, "View as Compact List", .viewAsList),
        (.previews, .previews, "View as Previews", .viewAsPreviews),
    ]
    /// Finder's selected segment, read from its screenshots; the system's fit around these icons is 30.
    static let segmentWidth = 34.0
    static let previewsSegment = 3
    var onChoose: (ExplorerViewMode) -> Void = { _ in }
    /// A count chosen from the Previews segment's menu.
    var onChooseCount: (Int) -> Void = { _ in }
    /// The count the pane shows while it shows Previews, checked in the segment's menu; nil in another view.
    var previewCount: Int?
    let countsMenu = NSMenu(title: "Show Previews")
    /// The segment Tab is at: each segment is a stop of its own.
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
            let image = icon.image
            image.accessibilityDescription = label
            setImage(image, forSegment: index)
            setImageScaling(.scaleNone, forSegment: index)
            setWidth(Self.segmentWidth, forSegment: index)
        }
        for count in PreviewGrid.counts {
            let item = NSMenuItem(title: "\(count) at a Time", action: #selector(countChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            countsMenu.addItem(item)
        }
        countsMenu.delegate = self
        setMenu(countsMenu, forSegment: Self.previewsSegment)
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

    @objc private func countChosen(_ sender: NSMenuItem) {
        onChooseCount(sender.tag)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.state = item.tag == previewCount ? .on : .off }
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

/// The clipboard button: the copy or cut icon and how many items wait to be pasted, in the
/// accent color; with both cut and copied items, the scissors and how many move, then the copy icon and how many are
/// copied. To the system it is an icon-only button, made wider for the count: one with a title gets a glass
/// capsule of its own, so it would never share one with the buttons beside it. The icon keeps to the leading side
/// (`LeadingIconCell`), and the count is a label of its own after it, as the scenarios read it.
final class ToolbarClipboardButton: ToolbarButton, TextStyleSource {
    let count = FlushTextField(labelWithString: "")
    /// The copied items' icon and count, after the cut ones', on a clipboard holding both.
    private let copiedIcon = SymbolIconView(CommandIcon.copy.symbolName)
    let copiedCount = FlushTextField(labelWithString: "")
    /// Between the cut items' count and the copied items' icon.
    static let pairGap = 8.0
    /// The copied items' icon beside the scissors: as tall as the toolbar's other symbols.
    static let copiedIconSize = 20.0
    private static let countFont = NSFont.monospacedDigitSystemFont(
        ofSize: DesignTokens.typeScale.small, weight: .semibold)
    /// With a count: 12 at each side, 2 between the icon and the count, as the system lays out an icon and a title.
    static let countPadding = 12.0
    static let countGap = 2.0

    override class var cellClass: AnyClass? {
        get { LeadingIconCell.self }
        set {}
    }

    var styleTextField: NSTextField? { count }
    /// The focus ring the keyboard brings: a click leaves the keyboard on the button, and the first key after it (the
    /// list's arrows) shows the ring while the list is open.
    var showsKeyboardRing = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(icon: .copy, label: "Clipboard", identifier: "toolbar.clipboard")
        count.font = Self.countFont
        count.setAccessibilityIdentifier("toolbar.clipboard.count")
        addSubview(count)
        copiedCount.font = Self.countFont
        copiedCount.setAccessibilityIdentifier("toolbar.clipboard.copiedCount")
        copiedCount.isHidden = true
        copiedIcon.isHidden = true
        addSubview(copiedIcon)
        addSubview(copiedCount)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Whether the count shows: the icon then keeps to the leading side.
    var showsCount: Bool { !count.isHidden }

    /// `copied`: on a clipboard holding both, how many are copied; `value` is then how many are cut.
    func set(count value: Int, cut: Bool, copied: Int? = nil) {
        iconName = cut || copied != nil ? .cut : .copy
        // The scissors are wider than the copy icon and read as larger at the toolbar's size: they are drawn a scale
        // down, so the two weigh the same on their own and side by side.
        symbolConfiguration = iconName == .cut ? NSImage.SymbolConfiguration(scale: .medium) : nil
        let text = FormatLocale.count(value)
        let copiedText = copied.map { FormatLocale.count($0) } ?? ""
        let changed =
            count.stringValue != text || count.isHidden != (value == 0) || copiedCount.stringValue != copiedText
            || copiedCount.isHidden != (copied == nil)
        count.stringValue = text
        count.isHidden = value == 0
        copiedCount.stringValue = copiedText
        copiedCount.isHidden = copied == nil
        copiedIcon.isHidden = copied == nil
        if changed { invalidateIntrinsicContentSize() }
        needsLayout = true
        needsDisplay = true
    }

    /// Whether the copied items' count shows beside the cut ones'.
    private var showsBoth: Bool { !copiedCount.isHidden }

    /// The icon's width, as an icon-only button lays it out.
    private var iconWidth: Double {
        guard let cell = cell as? LeadingIconCell else { return 0 }
        return cell.centeredImageRect(forBounds: NSRect(x: 0, y: 0, width: Self.iconOnlyWidth, height: 36)).width
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard showsCount else { return size }
        var width =
            Self.countPadding + iconWidth + Self.countGap + count.intrinsicContentSize.width + Self.countPadding
        if showsBoth {
            width += Self.pairGap + Self.copiedIconSize + Self.countGap + copiedCount.intrinsicContentSize.width
        }
        return NSSize(width: max(Self.iconOnlyWidth, width), height: size.height)
    }

    override func layout() {
        super.layout()
        guard showsCount, let cell else { return }
        let icon = cell.imageRect(forBounds: bounds)
        let size = count.intrinsicContentSize
        count.frame = NSRect(
            x: icon.maxX + Self.countGap, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        guard showsBoth else { return }
        let side = Self.copiedIconSize
        copiedIcon.frame = NSRect(
            x: count.frame.maxX + Self.pairGap, y: (bounds.height - side) / 2, width: side, height: side)
        let copiedSize = copiedCount.intrinsicContentSize
        copiedCount.frame = NSRect(
            x: copiedIcon.frame.maxX + Self.countGap, y: (bounds.height - copiedSize.height) / 2,
            width: copiedSize.width, height: copiedSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = ChromeColors.accent(for: self)
        count.textColor = ChromeColors.color(accent.solidButton)
        copiedCount.textColor = count.textColor
        copiedIcon.color = isEnabled ? .controlTextColor : .disabledControlTextColor
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

/// The clipboard button's cell: while the count shows, the icon sits `countPadding` in from the leading edge rather
/// than in the middle of the wider button.
final class LeadingIconCell: NSButtonCell {
    /// Where the system puts the icon: the middle of `rect`.
    func centeredImageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: rect)
    }

    private func leading(_ rect: NSRect) -> NSRect {
        guard let button = controlView as? ToolbarClipboardButton, button.showsCount else { return rect }
        var moved = rect
        moved.origin.x = button.bounds.minX + ToolbarClipboardButton.countPadding
        return moved
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        leading(super.imageRect(forBounds: rect))
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: leading(frame), in: controlView)
    }
}

/// The toolbar's search field, the system's, in an `NSSearchToolbarItem`: the magnifier with its small chevron is the
/// Search Options button, the placeholder is "Search", the system's clear button shows once the trimmed text is not
/// empty.
final class ToolbarSearchField: NSSearchField {
    /// The field took the keyboard (`onFocus` of the field: the cached search may come back).
    var onFocus: () -> Void = {}
    /// The magnifier was pressed: the options menu opens, the keyboard staying in the field; or Return or Space on it
    /// (`fromKeyboard`), which marks the menu's first item.
    var onOptions: (_ fromKeyboard: Bool) -> Void = { _ in }
    /// The ✕ was clicked.
    var onClear: () -> Void = {}
    /// The field took the keyboard or let it go: the toolbar decides again whether it stays open (`updateSearchWidth`).
    var onEditingChange: () -> Void = {}
    /// The press target over the system's magnifier, for automation and the accessibility tree.
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

    /// The ✕ shows once the trimmed text is not empty.
    var clearButtonShows: Bool {
        !SearchTiming.trimmed(currentEditor()?.string ?? stringValue).isEmpty
    }

    /// The system shows and hides the button by whether there is any text, as it updates the field, so its `isHidden`
    /// isn't ours: for text of only spaces it is see-through and does nothing.
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
        if took {
            onFocus()
            onEditingChange()
        }
        return took
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onEditingChange()
    }

    /// Whether an option of the search the field drives differs from the defaults.
    private var optionsChanged = false

    /// The magnifier's tooltip names the options that differ from the defaults, and while any does, the magnifier is
    /// marked as long as the field has the keyboard: the field at rest stays plain.
    func showOptions(changed: [String]) {
        optionsChanged = !changed.isEmpty
        optionsButton.toolTip = SearchBarText.optionsTitle(changed: changed)
        showOptionsMark()
    }

    /// The window moved the keyboard (`ExplorerTabWindow.makeFirstResponder`, which every move passes, the system's
    /// own included): the magnifier's mark follows whether the field has it.
    func showOptionsMark() {
        applyOptionsMark()
        // A move can be one step of several (the field, then its editor): looked at again once they are done.
        DispatchQueue.main.async { [weak self] in self?.applyOptionsMark() }
    }

    private func applyOptionsMark() {
        // Being edited: the field's own answer, which holds through every step of taking the keyboard.
        optionsButton.marked = optionsChanged && (currentEditor() != nil || isActive)
    }

    /// Whether the field has the keyboard.
    var isActive: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === self
    }

    /// Whether the keyboard is in the field or on one of its own stops, Search Options and the ✕, which Tab and
    /// Shift-Tab reach from its text.
    var holdsKeyboard: Bool {
        guard let responder = window?.firstResponder else { return false }
        return isActive || responder === optionsButton || responder === clearStop
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

/// The magnifier and chevron of the search field, "Search Options": a press opens the options menu and leaves the
/// keyboard in the field. Shift-Tab from the field gives it the keyboard, as a button before the field; Return or
/// Space on it then opens the menu from the keyboard. The system's field draws it; this view takes the keys and has
/// the keyboard's focus ring, and the press comes from the toolbar (`ExplorerToolbar.pressSearchOptions`).
final class ToolbarSearchOptionsButton: NSView {
    var onPress: (_ fromKeyboard: Bool) -> Void = { _ in }
    /// An option differs from the defaults: a dot in the accent at the magnifier's top right, as the results bar's
    /// Options has.
    var marked = false {
        didSet { if marked != oldValue { needsDisplay = true } }
    }
    /// Set while the keyboard is given to the button: a press never takes it.
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

    override func draw(_ dirtyRect: NSRect) {
        guard marked else { return }
        let size = SearchSmallButton.markDiameter
        // Over the magnifier's lens, whose top right is about a third in from the button's top right.
        let center = NSPoint(x: bounds.maxX - bounds.width * 0.38, y: bounds.minY + bounds.height * 0.26)
        NSColor(AppearanceModel.shared.theme.accent.solidButton).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)).fill()
    }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // The press itself opens the menu; it moves no focus.
    override func mouseDown(with event: NSEvent) { onPress(false) }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49:
            // Return, Enter or Space: a click from the keyboard.
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
