import AppKit
import FTFoundation

/// What has been typed to narrow the list above it, how much of the list is left, how it matches (Fuzzy and Contains
/// side by side), a pin and a way to bring the rest back. It is a bar of the pane's own across the foot of the list,
/// opaque and tinted with the accent, and the list ends above it, so no item is ever under it. It shows while there is
/// a filter and goes with it. Text that matches nothing turns it red. Its pin pins the filter to the pane, and shows
/// filled while it is: the mode is then locked.
final class ListFilterBarView: NSView, TextStyleSource {
    private let backdrop = ContentBackdrop()
    /// The accent's wash over the backdrop, red while nothing matches.
    private let tint = NSView()
    private let symbol = NSImageView()
    private let value = ListLabel()
    private let count = ListLabel()
    let modes = ListFilterModeControl()
    let pin = ListFilterPinButton()
    private let clear = ClearButton()
    private var theme = AppearanceModel.shared.theme
    /// The text matches nothing in a list that has items.
    private(set) var nothingMatches = false
    /// The filter on show is pinned.
    private(set) var isPinned = false
    /// Whether the bar shows a filter.
    private(set) var isShowingFilter = false

    /// Told when the ✕ is pressed.
    var onClear: () -> Void = {}
    /// Told when the other mode is chosen.
    var onToggleMode: () -> Void = {}
    /// Told when the pin is pressed: the filter is to be pinned, or unpinned.
    var onTogglePin: () -> Void = {}

    var styleTextField: NSTextField? { value }

    override var isFlipped: Bool { true }

    /// The bar's height, its top edge included.
    static var height: Double { SelectionLayout.FilterBar.height }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        addSubview(backdrop)
        tint.wantsLayer = true
        addSubview(tint)
        symbol.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(SelectionLayout.FilterBar.symbolSize), weight: .medium))
        symbol.imageScaling = .scaleProportionallyDown
        value.font = ThemeFonts.sans(DesignTokens.typeScale.callout, .semibold)
        value.lineBreakMode = .byTruncatingTail
        value.setAccessibilityIdentifier("listFilter.value")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(DesignTokens.typeScale.callout), weight: .regular)
        count.setAccessibilityIdentifier("listFilter.count")
        modes.onChoose = { [weak self] _ in self?.onToggleMode() }
        clear.setAccessibilityLabel("Clear filter")
        clear.toolTip = "Clear Filter (Esc)"
        clear.setAccessibilityIdentifier("listFilter.clear")
        clear.target = self
        clear.action = #selector(cleared(_:))
        pin.setAccessibilityIdentifier("listFilter.pin")
        pin.target = self
        pin.action = #selector(toggledPin(_:))
        for view in [symbol, value, count, modes, pin, clear] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("listFilter")
        setAccessibilityLabel("Filter")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func cleared(_ sender: Any?) { onClear() }

    @objc private func toggledPin(_ sender: Any?) { onTogglePin() }

    /// Shows the filter, or takes the bar away when there is none.
    func show(query: String, mode: NameMatchMode, shown: Int, total: Int, theme: Theme, pinned: Bool = false) {
        self.theme = theme
        guard !query.isEmpty else {
            isShowingFilter = false
            nothingMatches = false
            isHidden = true
            return
        }
        isShowingFilter = true
        isHidden = false
        isPinned = pinned
        pin.isPinned = pinned
        modes.mode = mode
        modes.isLocked = pinned
        clear.toolTip = pinned ? "Remove Filter" : "Clear Filter (Esc)"
        nothingMatches = shown == 0 && total > 0
        value.stringValue = query
        count.stringValue = "\(shown) of \(total)"
        clear.applyTheme(theme)
        modes.applyTheme(theme)
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    private func applyColors() {
        let palette = theme.palette
        symbol.contentTintColor = NSColor(nothingMatches ? palette.dangerText : theme.accent.solid)
        value.textColor = NSColor(palette.textPrimary)
        count.textColor = NSColor(nothingMatches ? palette.dangerText : palette.textSecondary)
        pin.theme = theme
        let wash =
            nothingMatches ? palette.danger.withAlpha(SelectionLayout.FilterBar.dangerWashAlpha) : theme.accent.softBg
        tint.layer?.backgroundColor = NSColor(wash).cgColor
    }

    /// The edge above the bar: the accent's, red while nothing matches.
    var edgeColor: RGBA { nothingMatches ? theme.palette.danger : theme.accent.border }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(edgeColor).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(SelectionLayout.FilterBar.edgeWidth)).fill()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let layout = SelectionLayout.FilterBar.self
        let edge = CGFloat(layout.edgeWidth)
        let gap = CGFloat(layout.gap)
        backdrop.frame = NSRect(x: 0, y: edge, width: bounds.width, height: max(0, bounds.height - edge))
        tint.frame = backdrop.frame
        let middle = edge + (bounds.height - edge) / 2
        func place(_ view: NSView, x: CGFloat, size: NSSize) {
            view.frame = NSRect(x: x, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        // From the right: the ✕, the pin and the modes.
        var right = bounds.width - CGFloat(layout.paddingRight)
        right -= ClearButton.size
        place(clear, x: right, size: NSSize(width: ClearButton.size, height: ClearButton.size))
        right -= gap + ListFilterPinButton.size
        place(pin, x: right, size: NSSize(width: ListFilterPinButton.size, height: ListFilterPinButton.size))
        let modesSize = modes.intrinsicContentSize
        right -= gap + modesSize.width
        place(modes, x: right, size: modesSize)
        // From the left: the symbol, the text and the count; the text gives way first.
        var x = CGFloat(layout.paddingLeft)
        let symbolSide = CGFloat(layout.symbolSize)
        place(symbol, x: x, size: NSSize(width: symbolSide, height: symbolSide))
        x += symbolSide + gap
        let countWidth = count.textWidth
        let valueWidth = min(value.textWidth, max(0, right - gap - countWidth - gap - x))
        place(value, x: x, size: NSSize(width: valueWidth, height: value.lineHeight))
        x += valueWidth + gap
        place(count, x: x, size: NSSize(width: max(0, min(countWidth, right - gap - x)), height: count.lineHeight))
    }

    /// The buttons take the pointer; the list keeps the keyboard (a press here does not change who has it).
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {}
}

/// The filter's mode as the system's segmented control, Fuzzy and Contains side by side. Only a click chooses: it never
/// takes the keyboard, so typing goes on into the list. While the filter is pinned the other mode can't be chosen.
final class ListFilterModeControl: SystemSegmentedControl {
    private static let modes: [NameMatchMode] = [.fuzzy, .contains]
    /// Told the mode chosen, when it is not the one shown.
    var onChoose: (NameMatchMode) -> Void = { _ in }

    var mode = NameMatchMode.fuzzy {
        didSet { if mode != oldValue { showMode() } }
    }

    /// The filter is pinned: the control shows its mode and no longer changes it.
    var isLocked = false {
        didSet { if isLocked != oldValue { showMode() } }
    }

    init() {
        super.init(titles: Self.modes.map(\.label))
        controlSize = .small
        font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        refusesFirstResponder = true
        setAccessibilityIdentifier("listFilter.mode")
        setAccessibilityLabel("Match names by")
        onSegment = { [weak self] index in self?.chose(index) }
        showMode()
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Chooses `mode` as a click on its segment does: nothing while its segment can't be clicked.
    func press(_ mode: NameMatchMode) {
        guard let index = Self.modes.firstIndex(of: mode), isEnabled(forSegment: index) else { return }
        selectedSegment = index
        sendAction(action, to: target)
    }

    private func chose(_ index: Int) {
        guard Self.modes.indices.contains(index) else { return }
        let wanted = Self.modes[index]
        // The segment pressed stays chosen once the filter has taken its mode, which then shows it.
        showMode()
        guard wanted != mode, !isLocked else { return }
        onChoose(wanted)
    }

    private func showMode() {
        selectedSegment = Self.modes.firstIndex(of: mode) ?? -1
        for (index, each) in Self.modes.enumerated() {
            setEnabled(!isLocked || each == mode, forSegment: index)
            setToolTip(Self.toolTip(each, locked: isLocked), forSegment: index)
        }
    }

    private static func toolTip(_ mode: NameMatchMode, locked: Bool) -> String {
        switch (mode, locked) {
        case (.fuzzy, false): "Fuzzy: names with the letters you type in that order"
        case (.contains, false): "Contains: names with the letters you type side by side"
        case (.fuzzy, true): "Fuzzy: files with these letters in that order. Unpin the filter to change it."
        case (.contains, true): "Contains: files with these letters side by side. Unpin the filter to change it."
        }
    }
}

/// The filter's mode as a word in a capsule of the accent, in the search results' filter field: a press switches Fuzzy
/// and Contains. It never takes the keyboard, so typing goes on where it was.
final class ListFilterModeChip: NSControl {
    private let label = ListLabel()
    private var isHovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    var mode = NameMatchMode.fuzzy {
        didSet {
            label.stringValue = mode.label
            updateToolTip()
            needsLayout = true
            needsDisplay = true
        }
    }

    /// The filter is pinned: the chip shows its mode and no longer switches it.
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            updateToolTip()
            needsDisplay = true
        }
    }

    private func updateToolTip() {
        switch (mode, isLocked) {
        case (.fuzzy, false): toolTip = "Fuzzy: names with the letters you type in that order. Click for Contains."
        case (.contains, false): toolTip = "Contains: names with the letters you type side by side. Click for Fuzzy."
        case (.fuzzy, true): toolTip = "Fuzzy: files with these letters in that order. Unpin the filter to change it."
        case (.contains, true):
            toolTip = "Contains: files with these letters side by side. Unpin the filter to change it."
        }
    }

    var theme = AppearanceModel.shared.theme {
        didSet {
            label.textColor = NSColor(theme.accent.solid)
            needsDisplay = true
        }
    }

    override var font: NSFont? {
        get { label.font }
        set { label.font = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.stringValue = mode.label
        addSubview(label)
        setAccessibilityRole(.button)
        mode = .fuzzy
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fittingWidth: CGFloat {
        label.textWidth + 2 * CGFloat(SelectionLayout.FilterChip.chipPaddingHorizontal)
    }

    var fittingHeight: CGFloat {
        label.lineHeight + 2 * CGFloat(SelectionLayout.FilterChip.chipPaddingVertical)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: CGFloat(SelectionLayout.FilterChip.chipPaddingHorizontal), y: (bounds.height - label.lineHeight) / 2,
            width: label.textWidth, height: label.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = SelectionLayout.FilterChip.self
        let alpha = isHovering && !isLocked ? layout.chipHoverFillAlpha : layout.chipFillAlpha
        NSColor(theme.accent.solid.withAlpha(alpha)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}

/// The pin in the filter bar: an outline while the filter is typed, filled in the accent while it is pinned. It never
/// takes the keyboard, so typing goes on into the list.
final class ListFilterPinButton: NSControl {
    static let size = 16.0
    private let image = NSImageView()
    private var isHovering = false { didSet { applyLook() } }
    private var trackingArea: NSTrackingArea?

    var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            applyLook()
        }
    }

    var theme = AppearanceModel.shared.theme {
        didSet { applyLook() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyDown
        addSubview(image)
        setAccessibilityRole(.button)
        applyLook()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyLook() {
        image.image = Self.tilted(isPinned ? "pin.fill" : "pin")
        let palette = theme.palette
        image.contentTintColor =
            NSColor(isPinned ? theme.accent.solid : isHovering ? palette.textPrimary : palette.textSecondary)
        setAccessibilityLabel(isPinned ? "Unpin filter" : "Pin filter")
        toolTip = isPinned ? "Unpin Filter: typing changes it again" : "Pin Filter: keep it in other folders"
    }

    /// The symbol leaning 45° to the right, as a pin stuck in a board, still tinted as a template.
    private static func tilted(_ name: String) -> NSImage? {
        guard
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: CGFloat(SelectionLayout.FilterBar.symbolSize), weight: .medium))
        else { return nil }
        let side = size
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: -45)
            transform.concat()
            let drawn = symbol.size
            symbol.draw(
                in: NSRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    override func layout() {
        super.layout()
        image.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }
}
