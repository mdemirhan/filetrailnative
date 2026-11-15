import AppKit
import FTFoundation

/// The bar above search results, as in Finder: where the search runs, a field that narrows what it found, Stop while
/// it runs on, and Done; and the banner when only the first matches are shown, or when something was added since that
/// they may not list, with Search Again. Where the scopes as segments leave the
/// filter less than its minimum (a pane of two, a narrow window), they are one pop-up button instead, with no label.
/// The results themselves are drawn by the folder's views.
final class SearchHeaderView: NSView {
    var onScopeChange: (String) -> Void = { _ in }
    var onFilterChange: (String) -> Void = { _ in }
    /// The filter field's mode chip was pressed: the other way of matching names is wanted.
    var onToggleFilterMode: () -> Void = {}
    /// Return, ↓, or Esc in an empty filter field: the keyboard goes back to the results.
    var onFocusResults: () -> Void = {}
    /// Tab or Shift-Tab from a button of the bar: the keyboard goes to the other pane, as Tab among the items sends it
    /// (`switchPane()`).
    var onSwitchPane: () -> Void = {}
    var onStop: () -> Void = {}
    var onDone: () -> Void = {}
    /// The banner's Search Again.
    var onSearchAgain: () -> Void = {}
    /// The header's height changed (the banner came or went).
    var onHeightChange: () -> Void = {}

    private static var layout: SearchLayout { .standard }
    private(set) var theme = AppearanceModel.shared.theme
    private let backdrop = ContentBackdrop()
    private let bar = SearchScopeBarView()
    private let label = FlushTextField(labelWithString: SearchBarText.scopeLabel)
    private let track = SearchSegmentTrack()
    private(set) var scopes: [SearchScopeButton] = []
    /// The scopes as one button, while the bar is too narrow for the segments.
    let scopeMenu = SearchScopePopUp()
    /// Whether the scopes show as the pop-up rather than the segments.
    private(set) var showsScopeMenu = false
    let filter = SearchFilterField()
    let stopButton = SearchSmallButton(title: SearchBarText.stop, spinner: true)
    let doneButton = SearchSmallButton(title: SearchBarText.done, spinner: false)
    let banner = SearchBannerView()
    private let stopFlag = DelayedFlag()
    private var rootPath = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchHeader")
        addSubview(backdrop)
        bar.setAccessibilityIdentifier("searchBar")
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.toolbar)
        bar.setAccessibilityLabel(SearchBarText.scopeToolbarName)
        label.setAccessibilityIdentifier("searchBar.label")
        addSubview(bar)
        for view in [label, track, scopeMenu, filter, stopButton, doneButton] as [NSView] { bar.addSubview(view) }
        scopeMenu.isHidden = true
        scopeMenu.onChoose = { [weak self] path in
            guard let self, path != self.rootPath else { return }
            self.onScopeChange(path)
        }
        scopeMenu.onMouseDown = { [weak self] in self?.onFocusResults() }
        scopeMenu.onTab = { [weak self] backward in
            guard let self else { return }
            self.moveKeyboard(from: self.scopeMenu, backward: backward)
        }
        addSubview(banner)
        banner.isHidden = true
        banner.searchAgain.onPress = { [weak self] in self?.onSearchAgain() }
        banner.searchAgain.onMouseDown = { [weak self] in self?.onFocusResults() }
        banner.searchAgain.onTab = { [weak self] _ in self?.onSwitchPane() }
        stopButton.isHidden = true
        stopButton.setAccessibilityIdentifier("searchBar.stop")
        stopButton.setAccessibilityLabel(SearchBarText.stopName)
        stopButton.toolTip = SearchBarText.stopTitle
        stopButton.onPress = { [weak self] in self?.onStop() }
        doneButton.setAccessibilityIdentifier("searchBar.done")
        doneButton.setAccessibilityLabel(SearchBarText.doneName)
        doneButton.toolTip = SearchBarText.doneTitle
        doneButton.onPress = { [weak self] in self?.onDone() }
        filter.onChange = { [weak self] text in self?.onFilterChange(text) }
        filter.onToggleMode = { [weak self] in self?.onToggleFilterMode() }
        filter.onFocusResults = { [weak self] in self?.onFocusResults() }
        filter.onTab = { [weak self] view, backward in self?.moveKeyboard(from: view, backward: backward) }
        track.onTab = { [weak self] backward in
            guard let self else { return }
            self.moveKeyboard(from: self.track, backward: backward)
        }
        // A press in the header gives the pane the keyboard.
        track.onMouseDown = { [weak self] in self?.onFocusResults() }
        for button in [stopButton, doneButton] {
            button.onMouseDown = { [weak self] in self?.onFocusResults() }
            button.onTab = { [weak self, weak button] backward in
                guard let self, let button else { return }
                self.moveKeyboard(from: button, backward: backward)
            }
        }
        stopFlag.onChange = { [weak self] in
            guard let self else { return }
            self.stopButton.isHidden = !self.stopFlag.value
            self.needsLayout = true
        }
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The scope track, the bar's tallest control: the segments and the track's padding.
    private static var trackHeight: Double { layout.segmentHeight + 2 * layout.segmentedTrackPadding }

    /// The bar: the pane's content top, where the track starts, clear of the active pane's line; the track; the bar's
    /// padding under it.
    static var barHeight: Double { DesignTokens.paneContentTop + trackHeight + layout.scopeBarPaddingBottom }

    /// A press on the header itself gives the pane the keyboard.
    override func mouseDown(with event: NSEvent) { onFocusResults() }

    /// Tab or Shift-Tab from one of the bar's stops. Only Tab out of the filter walks along the bar: on to its ✕, Stop
    /// or Done, whichever comes next, or back to the last scope. Every other stop belongs to the content pane, where
    /// Tab and Shift-Tab alike go to the other pane (`switchPane()`), so the row is never walked past it.
    fileprivate func moveKeyboard(from view: NSView, backward: Bool) {
        guard view === filter.input else {
            onSwitchPane()
            return
        }
        if backward {
            // With no scopes what comes before the filter is the toolbar.
            let tookIt = showsScopeMenu ? scopeMenu.takeKeyboard() : track.takeKeyboard(backward: true)
            if !tookIt, let window { ToolbarKeyboard.enterFromEnd(of: window) }
        } else if !filter.clearButton.isHidden {
            filter.clearStop.takeKeyboard()
        } else {
            (stopButton.isHidden ? doneButton : stopButton).takeKeyboard()
        }
    }

    /// The keyboard comes to the bar's first stop: Tab from what comes before it, the toolbar.
    func enterFromStart() {
        let tookIt = showsScopeMenu ? scopeMenu.takeKeyboard() : track.takeKeyboard()
        if !tookIt { window?.makeFirstResponder(filter.input) }
    }

    /// The header's text, at a weight of 500, which the bar's text inherits.
    static func font(_ size: Double) -> NSFont { ThemeFonts.sans(size, .medium) }

    /// The bar, then the banner and its margin, then the 1 pt edge.
    var height: Double {
        let layout = Self.layout
        let barHeight = Self.barHeight
        let bannerHeight = banner.isHidden ? 0 : banner.height + layout.bannerMarginBottom
        return barHeight + bannerHeight + layout.headerBorderWidth
    }

    /// How the filter matches names, as its chip says it.
    func showFilterMode(_ mode: NameMatchMode) {
        guard filter.modeChip.mode != mode else { return }
        filter.modeChip.mode = mode
        filter.needsLayout = true
    }

    /// Shows the search on screen: its scopes, which one is pressed, how it stands, and the filter's text.
    func show(
        scopes options: [SearchScopeOption], rootPath: String, isRunning: Bool, truncated: Bool,
        mayBeMissingItems: Bool = false, filterText: String
    ) {
        self.rootPath = rootPath
        if options.map(\.path) != scopes.map(\.path) || options.map(\.label) != scopes.map(\.title) {
            for scope in scopes { scope.removeFromSuperview() }
            scopes = options.map { option in
                let button = SearchScopeButton(option: option)
                button.onPress = { [weak self, weak button] in
                    guard let self, let button, button.path != self.rootPath else { return }
                    self.onScopeChange(button.path)
                }
                track.addSubview(button)
                return button
            }
            track.show(scopes)
            scopeMenu.show(options)
        }
        for scope in scopes { scope.setSelected(scope.path == rootPath, theme: theme) }
        track.showSelection(scopes)
        scopeMenu.showSelection(rootPath)
        // Most searches finish at once: Stop and its spinner come only for one that runs on.
        stopFlag.update(active: isRunning, delay: SearchTiming.stopDelay)
        stopButton.isHidden = !stopFlag.value
        if filter.text != filterText { filter.text = filterText }
        let wasHeight = height
        let text = SearchBarText.banner(truncated: truncated, mayBeMissingItems: mayBeMissingItems)
        banner.show(text: text ?? "", searchAgain: mayBeMissingItems)
        banner.isHidden = text == nil
        if wasHeight != height { onHeightChange() }
        needsLayout = true
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        label.font = Self.font(DesignTokens.typeScale.callout)
        label.textColor = NSColor(palette.textSecondary)
        track.applyTheme(theme)
        for scope in scopes { scope.setSelected(scope.path == rootPath, theme: theme) }
        filter.applyTheme(theme)
        stopButton.applyTheme(theme)
        doneButton.applyTheme(theme)
        banner.applyTheme(theme)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let edge = CGFloat(Self.layout.headerBorderWidth)
        NSColor(palette.borderLight).setFill()
        NSRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge).fill()
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let barHeight = Self.barHeight
        // Over the results' top: opaque, but for its 1 pt edge.
        backdrop.frame = NSRect(
            x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - layout.headerBorderWidth))
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let gap = layout.scopeBarGap
        // The bar's parts are centered on the track, which starts at the pane's content top.
        let trackHeight = Self.trackHeight
        let centerY = DesignTokens.paneContentTop + trackHeight / 2
        let x = layout.scopeBarPaddingHorizontal
        let labelSize = label.intrinsicContentSize
        let labelWidth = Double((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width)
        // From the right: Done, Stop, then the filter field.
        var right = bounds.width - layout.scopeBarPaddingHorizontal
        let doneWidth = doneButton.preferredWidth
        doneButton.frame = NSRect(
            x: right - doneWidth, y: centerY - layout.smallButtonHeight / 2, width: doneWidth,
            height: layout.smallButtonHeight)
        right -= doneWidth + gap
        if !stopButton.isHidden {
            let stopWidth = stopButton.preferredWidth
            stopButton.frame = NSRect(
                x: right - stopWidth, y: centerY - layout.smallButtonHeight / 2, width: stopWidth,
                height: layout.smallButtonHeight)
            right -= stopWidth + gap
        }
        // The segments keep their width and the filter gives up room first, down to its minimum; with less room than
        // that the scopes are one pop-up button and the filter takes the rest.
        let trackWidth = track.fittingWidth
        let segmentsEnd = x + labelWidth + layout.scopeLabelMarginTrailing + gap + trackWidth + gap
        let compact = !scopes.isEmpty && right - segmentsEnd < layout.filterMinWidth
        showScopeMenu(compact)
        if compact {
            let menuHeight = Self.trackHeight
            // The filter keeps its minimum and the place's name is cut short for it, down to the pop-up's own
            // minimum; in a bar with room for neither, the filter has what the pop-up leaves.
            let besideFilter = right - x - gap - layout.filterMinWidth
            let menuWidth = min(
                scopeMenu.preferredWidth, layout.scopeMenuMaxWidth, max(layout.scopeMenuMinWidth, besideFilter),
                max(0, right - x))
            scopeMenu.frame = NSRect(x: x, y: centerY - menuHeight / 2, width: menuWidth, height: menuHeight)
            let filterX = scopeMenu.frame.maxX + gap
            filter.frame = NSRect(
                x: filterX, y: centerY - layout.fieldHeight / 2, width: max(0, right - filterX),
                height: layout.fieldHeight)
        } else {
            label.frame = NSRect(
                x: x, y: (centerY - labelSize.height / 2).rounded(), width: ceil(labelWidth),
                height: labelSize.height)
            let filterWidth = min(layout.filterWidth, max(0, right - segmentsEnd))
            filter.frame = NSRect(
                x: right - filterWidth, y: centerY - layout.fieldHeight / 2, width: filterWidth,
                height: layout.fieldHeight)
            let trackX = x + labelWidth + layout.scopeLabelMarginTrailing + gap
            let shownWidth = min(trackWidth, max(0, filter.frame.minX - gap - trackX))
            track.frame = NSRect(x: trackX, y: centerY - trackHeight / 2, width: shownWidth, height: trackHeight)
        }
        if !banner.isHidden {
            banner.frame = NSRect(
                x: layout.bannerMarginHorizontal, y: barHeight,
                width: max(0, bounds.width - 2 * layout.bannerMarginHorizontal), height: banner.height)
        }
    }

    /// Shows the scopes as the pop-up or as the label and the segments. The keyboard, on one of them, moves to the
    /// other, so it never stays on a control out of sight.
    private func showScopeMenu(_ compact: Bool) {
        guard compact != showsScopeMenu else { return }
        let hadKeyboard = window?.firstResponder === (compact ? track : scopeMenu)
        showsScopeMenu = compact
        scopeMenu.isHidden = !compact
        label.isHidden = compact
        track.isHidden = compact
        guard hadKeyboard else { return }
        if compact { scopeMenu.takeKeyboard() } else { track.takeKeyboard() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(AppearanceModel.shared.theme)
    }
}

/// The row of the search scope bar.
final class SearchScopeBarView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: The scope

/// The search's scope as the system's segmented control: its segments are the places to search in. They
/// are plain buttons of the pane, not a radio group: a click gives the keyboard to the results, so the
/// arrows and typeahead go on working there, and no arrow changes the scope. Tab stops at each in turn, where Return or
/// Space presses it.
final class SearchSegmentTrack: SystemSegmentedControl {
    /// Tab or Shift-Tab, which leaves the track wherever it is.
    var onTab: (_ backward: Bool) -> Void = { _ in }
    var onMouseDown: () -> Void = {}
    /// The segment Tab is at.
    private(set) var keyboardSegment = 0 {
        didSet { noteFocusRingMaskChanged() }
    }
    private var takingKeyboard = false

    init() {
        super.init(titles: [])
        font = SearchHeaderView.font(DesignTokens.typeScale.callout)
        refusesFirstResponder = true
        setAccessibilityIdentifier("searchBar.scopes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static var layout: SearchLayout { .standard }

    private var buttons: [SearchScopeButton] { subviews.compactMap { $0 as? SearchScopeButton } }

    // MARK: Keyboard

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isEnabled }
    override var canBecomeKeyView: Bool { false }

    /// Gives the keyboard to the first segment, or the last going backward; false with none, or when the window would not.
    @discardableResult
    func takeKeyboard(backward: Bool = false) -> Bool {
        guard let window, segmentCount > 0 else { return false }
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
            onTab(event.modifierFlags.contains(.shift))
        case 36, 76, 49:
            guard (0..<segmentCount).contains(keyboardSegment) else { return }
            selectedSegment = keyboardSegment
            sendAction(action, to: target)
        default:
            // No arrow changes the scope: the keys go on to the pane.
            nextResponder?.keyDown(with: event)
        }
    }

    /// The ring goes round the segment Tab is at, each being a button of its own.
    override func drawFocusRingMask() {
        var x = 0.0
        for index in 0..<keyboardSegment { x += width(forSegment: index) }
        let segment = width(forSegment: keyboardSegment)
        NSBezierPath(
            roundedRect: NSRect(x: x, y: 0, width: segment > 0 ? segment : bounds.width, height: bounds.height),
            xRadius: 4, yRadius: 4
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }

    var fittingWidth: Double {
        let layout = Self.layout
        let widths = buttons.map(\.preferredWidth)
        return 2 * layout.segmentedTrackPadding + widths.reduce(0, +)
            + Double(max(0, widths.count - 1)) * layout.segmentedGap
    }

    /// The scopes changed: a segment for each, its tooltip its path.
    func show(_ scopes: [SearchScopeButton]) {
        setTitles(scopes.map(\.title))
        for (index, scope) in scopes.enumerated() { setToolTip(scope.path, forSegment: index) }
        onSegment = { index in
            if scopes.indices.contains(index) { scopes[index].onPress() }
        }
        showSelection(scopes)
        needsLayout = true
    }

    func showSelection(_ scopes: [SearchScopeButton]) {
        selectedSegment = scopes.firstIndex(where: \.isSelected) ?? -1
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        var x = layout.segmentedTrackPadding
        let limit = bounds.width - layout.segmentedTrackPadding
        var widths: [CGFloat] = []
        for button in buttons {
            let width = max(0, min(button.preferredWidth, limit - x))
            button.frame = NSRect(x: x, y: layout.segmentedTrackPadding, width: width, height: layout.segmentHeight)
            widths.append(width)
            x += width + layout.segmentedGap
        }
        setSegmentWidths(
            widths, trackPadding: layout.segmentedTrackPadding, gap: layout.segmentedGap)
    }
}

/// Where a place to search in lies, for captures to find, read and click: it draws nothing and a click goes through it
/// to the control. The one searched has a mark.
final class SearchScopeButton: TextControl {
    let path: String
    var onPress: () -> Void = {}
    private(set) var isSelected = false
    private let selectedMarker = SearchMarkerView(id: "searchBar.scope.selected")
    private static var layout: SearchLayout { .standard }
    private static var font: NSFont { SearchHeaderView.font(DesignTokens.typeScale.callout) }

    init(option: SearchScopeOption) {
        path = option.path
        super.init(text: option.label, theme: AppearanceModel.shared.theme)
        font = Self.font
        alignment = .center
        lineBreakMode = .byTruncatingTail
        alphaValue = 0
        setAccessibilityElement(false)
        setAccessibilityIdentifier("searchBar.scope")
        selectedMarker.source = self
        selectedMarker.isHidden = true
        addSubview(selectedMarker)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its text and 12 each side, at most 220.
    var preferredWidth: Double {
        let layout = Self.layout
        let text = Double((title as NSString).size(withAttributes: [.font: Self.font]).width)
        return min(layout.segmentMaxWidth, text + 2 * layout.segmentPaddingHorizontal)
    }

    func setSelected(_ selected: Bool, theme: Theme) {
        isSelected = selected
        self.theme = theme
        selectedMarker.isHidden = !selected
        applyColors()
    }

    private func applyColors() {
        let palette = theme.palette
        textColor = NSColor(isSelected ? palette.toolbarToggleIconActive : palette.textSecondary)
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyColors()
    }

    override func layout() {
        super.layout()
        selectedMarker.frame = bounds
    }
}

/// A transparent view that marks a part for automation (the selected scope), reporting its text.
final class SearchMarkerView: NSView, TextStyleSource {
    weak var source: NSTextField?
    var styleTextField: NSTextField? { source }

    init(id: String) {
        super.init(frame: .zero)
        setAccessibilityIdentifier(id)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: The scope as a pop-up

/// The search's scope as the system's pop-up button, for a bar too narrow for the segments: it names the place searched,
/// and its menu has each place with its icon, the one searched checked. As the segments, it is a plain button of the
/// pane: a click gives the keyboard to the results, and only Tab stops here, where Space or Return opens the menu, in
/// which the arrows move and Return chooses. No arrow changes the scope while the menu is closed.
final class SearchScopePopUp: NSPopUpButton {
    /// A place was chosen in the menu: its path.
    var onChoose: (String) -> Void = { _ in }
    var onMouseDown: () -> Void = {}
    /// Tab or Shift-Tab, which leaves it.
    var onTab: (_ backward: Bool) -> Void = { _ in }
    private var paths: [String] = []
    private var takingKeyboard = false
    private static var font: NSFont { SearchHeaderView.font(DesignTokens.typeScale.callout) }
    private static let iconSize = 16.0

    init() {
        super.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        font = Self.font
        (cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        refusesFirstResponder = true
        target = self
        action = #selector(chosen(_:))
        setAccessibilityIdentifier("searchBar.scopeMenu")
        setAccessibilityLabel(SearchBarText.scopeToolbarName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The scopes changed: an item for each, with the place's icon, its tooltip its path.
    func show(_ options: [SearchScopeOption]) {
        removeAllItems()
        paths = options.map(\.path)
        for option in options {
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: option.path)
            icon.size = NSSize(width: Self.iconSize, height: Self.iconSize)
            item.image = icon
            item.toolTip = option.path
            menu?.addItem(item)
        }
        invalidateIntrinsicContentSize()
    }

    /// Checks the place searched, which the button names.
    func showSelection(_ rootPath: String) {
        guard let index = paths.firstIndex(of: rootPath) else { return }
        if indexOfSelectedItem != index { selectItem(at: index) }
        toolTip = rootPath
    }

    /// As wide as the place searched, its icon and the arrows need: the system sizes a pop-up for its longest item,
    /// which would take the filter's room for a place not shown.
    var preferredWidth: Double {
        guard let cell else { return 0 }
        let widths = itemArray.map { Double(($0.title as NSString).size(withAttributes: [.font: Self.font]).width) }
        let widest = widths.max() ?? 0
        let shown = widths.indices.contains(indexOfSelectedItem) ? widths[indexOfSelectedItem] : widest
        return Double(ceil(cell.cellSize.width)) - (widest - shown).rounded(.down)
    }

    @objc private func chosen(_ sender: Any?) {
        guard paths.indices.contains(indexOfSelectedItem) else { return }
        onChoose(paths[indexOfSelectedItem])
    }

    // MARK: Keyboard

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isEnabled }
    override var canBecomeKeyView: Bool { false }

    /// Gives it the keyboard; false while it has no places or is hidden, or when the window would not.
    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window, numberOfItems > 0, !isHiddenOrHasHiddenAncestor else { return false }
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
            onTab(event.modifierFlags.contains(.shift))
        case 36, 76, 49:
            performClick(nil)
        case 123, 124, 125, 126:
            // No arrow changes the scope: the keys go on to the pane.
            nextResponder?.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }
}

// MARK: Buttons

/// A small push button as the system's button: 22 tall, 10 each side of the label, the callout size; Stop has the
/// spinner before its label. A click gives the keyboard to the results; Tab stops here, where Return or Space presses it.
final class SearchSmallButton: SystemButton {
    var onPress: () -> Void = {}
    var onMouseDown: () -> Void = {}
    var onTab: (_ backward: Bool) -> Void = { _ in }
    private var takingKeyboard = false
    private let spinner: InfoSpinnerView?
    private static var layout: SearchLayout { .standard }
    private static var smallFont: NSFont { ThemeFonts.sans(DesignTokens.typeScale.callout) }

    init(title: String, spinner hasSpinner: Bool) {
        let layout = Self.layout
        spinner = hasSpinner ? InfoSpinnerView(diameter: layout.spinnerSize, lineWidth: layout.spinnerLineWidth) : nil
        super.init(title: title, theme: AppearanceModel.shared.theme)
        font = Self.smallFont
        controlHeight = layout.smallButtonHeight
        refusesFirstResponder = true
        target = self
        action = #selector(pressed(_:))
        if let spinner {
            // The room for the spinner, which lies over it.
            image = NSImage(size: NSSize(width: layout.spinnerSize + layout.smallButtonGap, height: 1))
            imagePosition = .imageLeading
            imageHugsTitle = true
            spinner.setAccessibilityIdentifier("searchBar.spinner")
            addSubview(spinner)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredWidth: CGFloat {
        let layout = Self.layout
        let start =
            layout.smallButtonPaddingHorizontal + (spinner == nil ? 0 : layout.spinnerSize + layout.smallButtonGap)
        let text = Double(ceil((title as NSString).size(withAttributes: [.font: Self.smallFont]).width))
        return start + text + layout.smallButtonPaddingHorizontal
    }

    override func layout() {
        super.layout()
        guard let spinner else { return }
        let layout = Self.layout
        let size = layout.spinnerSize
        spinner.frame = NSRect(
            x: layout.smallButtonPaddingHorizontal, y: (bounds.height - size) / 2, width: size, height: size)
    }

    @objc private func pressed(_ sender: Any?) { onPress() }

    /// Only Tab gives it the keyboard: a press never does.
    override var acceptsFirstResponder: Bool { takingKeyboard && isEnabled }
    override var canBecomeKeyView: Bool { false }

    @discardableResult
    func takeKeyboard() -> Bool {
        guard let window else { return false }
        takingKeyboard = true
        defer { takingKeyboard = false }
        return window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onTab(event.modifierFlags.contains(.shift))
        } else if event.keyCode == 76 {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown()
        super.mouseDown(with: event)
    }
}

// MARK: The banner

/// The banner over the results (`SearchBarText.banner`): that they were cut short, that they may be missing what was
/// added since, with Search Again for that.
final class SearchBannerView: NSView, TextStyleSource {
    var styleTextField: NSTextField? { text }
    private let text = FlushTextField(labelWithString: SearchBarText.truncatedBanner)
    let searchAgain = SearchSmallButton(title: SearchBarText.searchAgain, spinner: false)
    private var theme = AppearanceModel.shared.theme
    private static var layout: SearchLayout { .standard }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchBar.banner")
        text.setAccessibilityIdentifier("searchBar.banner.text")
        text.font = SearchHeaderView.font(DesignTokens.typeScale.callout)
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
        searchAgain.setAccessibilityIdentifier("searchBar.banner.searchAgain")
        searchAgain.setAccessibilityLabel(SearchBarText.searchAgainName)
        searchAgain.toolTip = SearchBarText.searchAgainTitle
        searchAgain.isHidden = true
        addSubview(searchAgain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// What it says, and whether it offers Search Again.
    func show(text value: String, searchAgain offers: Bool) {
        if text.stringValue != value { text.stringValue = value }
        searchAgain.isHidden = !offers
        text.toolTip = value
        needsLayout = true
    }

    /// What it says now.
    var shownText: String { text.stringValue }

    /// The text's line with its padding, or the button with a little room above and below, whichever is taller.
    var height: Double {
        let layout = Self.layout
        let line = 2 * layout.bannerPaddingVertical + Double(text.intrinsicContentSize.height)
        let button = searchAgain.isHidden ? 0 : layout.smallButtonHeight + 2 * Self.buttonInset
        return 2 * layout.bannerBorderWidth + max(line, button)
    }

    private static let buttonInset = 4.0

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        text.textColor = NSColor(theme.palette.textSecondary)
        searchAgain.applyTheme(theme)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let inset = layout.bannerBorderWidth
        var right = bounds.width - inset - layout.bannerPaddingHorizontal
        if !searchAgain.isHidden {
            let width = searchAgain.preferredWidth
            right = bounds.width - inset - Self.buttonInset - width
            searchAgain.frame = NSRect(
                x: right, y: (bounds.height - layout.smallButtonHeight) / 2, width: width,
                height: layout.smallButtonHeight)
            right -= layout.bannerPaddingHorizontal
        }
        let textHeight = Double(text.intrinsicContentSize.height)
        let x = inset + layout.bannerPaddingHorizontal
        text.frame = NSRect(x: x, y: (bounds.height - textHeight) / 2, width: max(0, right - x), height: textHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = Self.layout
        let radius = CGFloat(DesignTokens.radii.menu)
        let accent = theme.accent.solid
        NSColor(accent.withAlpha(layout.bannerFillAccentAlpha)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let edgeColor = colorMix(accent, layout.bannerBorderAccentShare, theme.palette.border)
        let inset = CGFloat(layout.bannerBorderWidth) / 2
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        edge.lineWidth = CGFloat(layout.bannerBorderWidth)
        NSColor(edgeColor).setStroke()
        edge.stroke()
    }
}

// MARK: The filter field

/// The results' filter: the mode chip, the field ("Name or folder"), and the clear button once something is typed. Esc clears it first, then gives the keyboard back to the results; Return and ↓ do so too.
final class SearchFilterField: NSView, NSTextFieldDelegate {
    let input = NSTextField()
    let clearButton = ClearButton()
    /// Where Tab stops at the ✕, which takes no keyboard itself: a press on it keeps the keyboard in the field.
    let clearStop = KeyboardStopView()
    var onChange: (String) -> Void = { _ in }
    var onFocusResults: () -> Void = {}
    /// The mode chip was pressed.
    var onToggleMode: () -> Void = {}
    /// How the filter matches the names (Fuzzy or Contains), at the field's start; a press switches it.
    let modeChip = ListFilterModeChip()
    /// Tab or Shift-Tab from the field or its ✕.
    var onTab: (_ from: NSView, _ backward: Bool) -> Void = { _, _ in }
    private var theme = AppearanceModel.shared.theme
    private static var layout: SearchLayout { .standard }
    private static var font: NSFont { SearchHeaderView.font(DesignTokens.typeScale.body) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchBar.filterField")
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = Self.font
        input.lineBreakMode = .byClipping
        input.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.delegate = self
        input.setAccessibilityLabel(SearchBarText.filterAccessibilityName)
        input.setAccessibilityIdentifier("searchBar.filter")
        clearButton.setAccessibilityIdentifier("searchBar.filter.clear")
        clearButton.setAccessibilityLabel(SearchBarText.clearFilterName)
        clearButton.toolTip = SearchBarText.clearFilterTitle
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.isHidden = true
        clearStop.onPress = { [weak self] in
            guard let self else { return }
            self.clearPressed(nil)
            self.window?.makeFirstResponder(self.input)
        }
        clearStop.onTab = { [weak self] backward in
            guard let self else { return }
            self.onTab(self.clearStop, backward)
        }
        modeChip.font = SearchHeaderView.font(DesignTokens.typeScale.callout)
        modeChip.setAccessibilityIdentifier("searchBar.filter.mode")
        modeChip.target = self
        modeChip.action = #selector(modePressed(_:))
        addSubview(clearStop)
        addSubview(modeChip)
        addSubview(input)
        addSubview(clearButton)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var text: String {
        get { input.stringValue }
        set {
            input.stringValue = newValue
            clearButton.isHidden = newValue.isEmpty
            needsLayout = true
        }
    }

    var isFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === input
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        input.textColor = NSColor(theme.palette.textPrimary)
        input.placeholderAttributedString = NSAttributedString(
            string: SearchBarText.filterPlaceholder,
            attributes: [.font: Self.font, .foregroundColor: NSColor(theme.palette.textTertiary)])
        clearButton.applyTheme(theme)
        modeChip.theme = theme
        needsDisplay = true
    }

    @objc private func modePressed(_ sender: Any?) { onToggleMode() }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let clear = layout.clearButtonSize
        let chipLeft = layout.fieldPaddingLeading
        modeChip.frame = NSRect(
            x: chipLeft, y: ((bounds.height - modeChip.fittingHeight) / 2).rounded(), width: modeChip.fittingWidth,
            height: modeChip.fittingHeight)
        // A field keeps 2 pt before its text: the text starts after the gap.
        let left = modeChip.frame.maxX + layout.fieldGap - 2
        let right =
            clearButton.isHidden ? layout.fieldPaddingTrailing : layout.fieldPaddingTrailing + clear + layout.fieldGap
        let font = Self.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        input.frame = NSRect(
            x: left, y: ((bounds.height - lineHeight) / 2).rounded(), width: max(0, bounds.width - left - right),
            height: lineHeight)
        clearButton.frame = NSRect(
            x: bounds.width - layout.fieldPaddingTrailing - clear, y: ((bounds.height - clear) / 2).rounded(),
            width: clear, height: clear)
        clearStop.frame = clearButton.frame
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        // The field's edge: an inset hairline; focused, the focus ring.
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
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(input)
    }

    @objc private func clearPressed(_ sender: Any?) {
        text = ""
        onChange("")
    }

    func controlTextDidChange(_ notification: Notification) {
        clearButton.isHidden = input.stringValue.isEmpty
        needsLayout = true
        onChange(input.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { needsDisplay = true }
    func controlTextDidEndEditing(_ notification: Notification) { needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc clears the filter first; with nothing to clear it returns to the list.
            if input.stringValue.isEmpty {
                onFocusResults()
            } else {
                text = ""
                onChange("")
            }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
            onFocusResults()
            return true
        case #selector(NSResponder.insertTab(_:)):
            onTab(input, false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            onTab(input, true)
            return true
        default:
            return false
        }
    }
}
