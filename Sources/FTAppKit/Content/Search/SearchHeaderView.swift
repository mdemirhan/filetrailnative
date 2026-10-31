// Port of SearchBar (apps/desktop/src/renderer/components/SearchBar.tsx), SystemButton's small size, the segmented control
// and the rounded search field, as styles.css draws them (:1245-1300, 1353-1440, 3021-3040, 3372-3388, 4502-4527,
// 6556-6583)
import AppKit
import FTFoundation

/// The bar above search results, as in Finder: where the search runs, a field that narrows what it found, Stop while
/// it runs on, and Done; and the banner when only the first matches are shown. The results themselves are drawn by the
/// folder's views.
final class SearchHeaderView: NSView {
    var onScopeChange: (String) -> Void = { _ in }
    var onFilterChange: (String) -> Void = { _ in }
    /// Return, ↓, or Esc in an empty filter field: the keyboard goes back to the results.
    var onFocusResults: () -> Void = {}
    /// Tab or Shift-Tab from a button of the bar (`paneTabSwitch`).
    var onSwitchPane: () -> Void = {}
    var onStop: () -> Void = {}
    var onDone: () -> Void = {}
    /// The header's height changed (the banner came or went).
    var onHeightChange: () -> Void = {}

    private static var layout: SearchLayout { .standard }
    private(set) var theme = AppearanceModel.shared.theme
    private let bar = SearchScopeBarView()
    private let label = FlushTextField(labelWithString: SearchBarText.scopeLabel)
    private let track = SearchSegmentTrack()
    private(set) var scopes: [SearchScopeButton] = []
    let filter = SearchFilterField()
    let stopButton = SearchSmallButton(title: SearchBarText.stop, spinner: true)
    let doneButton = SearchSmallButton(title: SearchBarText.done, spinner: false)
    private let banner = SearchBannerView()
    private let stopFlag = DelayedFlag()
    private var rootPath = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchHeader")
        bar.setAccessibilityIdentifier("searchBar")
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.toolbar)
        bar.setAccessibilityLabel(SearchBarText.scopeToolbarName)
        label.setAccessibilityIdentifier("searchBar.label")
        addSubview(bar)
        for view in [label, track, filter, stopButton, doneButton] as [NSView] { bar.addSubview(view) }
        addSubview(banner)
        banner.isHidden = true
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
        filter.onFocusResults = { [weak self] in self?.onFocusResults() }
        filter.onTab = { [weak self] view, backward in self?.moveKeyboard(from: view, backward: backward) }
        track.onTab = { [weak self] backward in
            guard let self else { return }
            self.moveKeyboard(from: self.track, backward: backward)
        }
        // A press in the header gives the pane the keyboard (ContentPane.tsx `onMouseDownCapture`).
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

    /// The bar: its scope track (the segments and the track's padding) and the bar's padding, at least its minimum.
    static var barHeight: Double {
        let trackHeight = layout.segmentHeight + 2 * layout.segmentedTrackPadding
        return max(layout.scopeBarMinHeight, trackHeight + 2 * layout.scopeBarPaddingVertical)
    }

    /// A press on the header itself gives the pane the keyboard (ContentPane.tsx `onMouseDownCapture`).
    override func mouseDown(with event: NSEvent) { onFocusResults() }

    /// Tab or Shift-Tab from one of the bar's stops. Only the filter is the browser's to Tab out of (a form control keeps
    /// its keys, useExplorerShortcuts.ts:1528): on to its ✕, Stop or Done, whichever comes next, or back to the last
    /// scope. Every other stop is in the content pane, where `paneTabSwitch` takes Tab and Shift-Tab alike, so the row is
    /// never walked past it.
    fileprivate func moveKeyboard(from view: NSView, backward: Bool) {
        guard view === filter.input else {
            onSwitchPane()
            return
        }
        if backward {
            // With no scopes what comes before the filter is the toolbar.
            if !track.takeKeyboard(backward: true), let window { ToolbarKeyboard.enterFromEnd(of: window) }
        } else if !filter.clearButton.isHidden {
            filter.clearStop.takeKeyboard()
        } else {
            (stopButton.isHidden ? doneButton : stopButton).takeKeyboard()
        }
    }

    /// The keyboard comes to the bar's first stop: Tab from what comes before it, the toolbar.
    func enterFromStart() {
        if !track.takeKeyboard() { window?.makeFirstResponder(filter.input) }
    }

    /// The header's text: `.content-header`'s weight (500), which the bar's text inherits.
    static func font(_ size: Double) -> NSFont { ThemeFonts.sans(size, .medium) }

    /// The bar, then the banner and its margin, then the 1 pt edge.
    var height: Double {
        let layout = Self.layout
        let barHeight = Self.barHeight
        let bannerHeight = banner.isHidden ? 0 : banner.height + layout.bannerMarginBottom
        return barHeight + bannerHeight + layout.headerBorderWidth
    }

    /// Shows the search on screen: its scopes, which one is pressed, how it stands, and the filter's text.
    func show(
        scopes options: [SearchScopeOption], rootPath: String, isRunning: Bool, truncated: Bool, filterText: String
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
        }
        for scope in scopes { scope.setSelected(scope.path == rootPath, theme: theme) }
        track.showSelection(scopes)
        // Most searches finish at once: Stop and its spinner come only for one that runs on.
        stopFlag.update(active: isRunning, delay: SearchTiming.stopDelay)
        stopButton.isHidden = !stopFlag.value
        if filter.text != filterText { filter.text = filterText }
        let wasHidden = banner.isHidden
        banner.isHidden = !truncated
        if wasHidden != banner.isHidden { onHeightChange() }
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
        ChromeColors.contentBackground(for: self).setFill()
        bounds.fill()
        let edge = CGFloat(Self.layout.headerBorderWidth)
        NSColor(palette.borderLight).setFill()
        NSRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge).fill()
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let barHeight = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let gap = layout.scopeBarGap
        let centerY = barHeight / 2
        var x = layout.scopeBarPaddingHorizontal
        let labelSize = label.intrinsicContentSize
        let labelWidth = Double((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width)
        label.frame = NSRect(
            x: x, y: (centerY - labelSize.height / 2).rounded(), width: ceil(labelWidth),
            height: labelSize.height)
        x += labelWidth + layout.scopeLabelMarginTrailing + gap
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
        // The segmented control keeps its width; the filter gives up room first, down to its minimum.
        let trackWidth = track.fittingWidth
        let room = right - (x + trackWidth + gap)
        let filterWidth = max(layout.filterMinWidth, min(layout.filterWidth, room))
        filter.frame = NSRect(
            x: right - filterWidth, y: centerY - layout.fieldHeight / 2, width: filterWidth, height: layout.fieldHeight)
        let trackHeight = layout.segmentHeight + 2 * layout.segmentedTrackPadding
        track.frame = NSRect(
            x: x, y: centerY - trackHeight / 2, width: min(trackWidth, max(0, filter.frame.minX - gap - x)),
            height: trackHeight)
        if !banner.isHidden {
            banner.frame = NSRect(
                x: layout.bannerMarginHorizontal, y: barHeight,
                width: max(0, bounds.width - 2 * layout.bannerMarginHorizontal), height: banner.height)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(AppearanceModel.shared.theme)
    }
}

/// `.search-scope-bar`: the row of the bar (the capture's "search scope bar").
final class SearchScopeBarView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: The scope

/// `.segmented.search-scope-segmented` as the system's control (D-020): its segments are the places to search in. They
/// are plain buttons of the pane in the original, not a radio group: a click gives the keyboard to the results, so the
/// arrows and typeahead go on working there, and no arrow changes the scope. Tab stops at each in turn, where Return or
/// Space presses it.
final class SearchSegmentTrack: SystemSegmentedControl {
    /// Tab or Shift-Tab, which leaves the track wherever it is (`paneTabSwitch`).
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

    /// The ring goes round the segment Tab is at, each being a button of its own in the original.
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

/// A transparent view that marks a part for the capture (the selected scope), reporting its text.
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

// MARK: Buttons

/// `.push-button.is-small` as the system's button: 22 tall, 10 each side of the label, the callout size; Stop has the
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

/// `.search-results-banner`: "Showing the first 20,000 matches."
final class SearchBannerView: NSView, TextStyleSource {
    var styleTextField: NSTextField? { text }
    private let text = FlushTextField(labelWithString: SearchBarText.truncatedBanner)
    private var theme = AppearanceModel.shared.theme
    private static var layout: SearchLayout { .standard }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchBar.banner")
        text.setAccessibilityIdentifier("searchBar.banner.text")
        text.font = SearchHeaderView.font(DesignTokens.typeScale.callout)
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var height: Double {
        let layout = Self.layout
        return 2 * (layout.bannerBorderWidth + layout.bannerPaddingVertical) + Double(text.intrinsicContentSize.height)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        text.textColor = NSColor(theme.palette.textSecondary)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let inset = layout.bannerBorderWidth
        text.frame = NSRect(
            x: inset + layout.bannerPaddingHorizontal, y: inset + layout.bannerPaddingVertical,
            width: max(0, bounds.width - 2 * (inset + layout.bannerPaddingHorizontal)),
            height: text.intrinsicContentSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = Self.layout
        let radius = CGFloat(DesignTokens.radii.menu)
        let accent = theme.accent.solid
        NSColor(accent.withAlpha(layout.bannerFillAccentAlpha)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let edgeColor = Self.mix(accent, layout.bannerBorderAccentShare, theme.palette.border)
        let inset = CGFloat(layout.bannerBorderWidth) / 2
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
        edge.lineWidth = CGFloat(layout.bannerBorderWidth)
        NSColor(edgeColor).setStroke()
        edge.stroke()
    }

    /// `color-mix(in srgb, color share, other)`, with premultiplied alpha.
    static func mix(_ color: RGBA, _ share: Double, _ other: RGBA) -> RGBA {
        let alpha = color.alpha * share + other.alpha * (1 - share)
        guard alpha > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
        func channel(_ a: Double, _ b: Double) -> Double {
            (a * color.alpha * share + b * other.alpha * (1 - share)) / alpha
        }
        return RGBA(
            red: channel(color.red, other.red), green: channel(color.green, other.green),
            blue: channel(color.blue, other.blue), alpha: alpha)
    }
}

// MARK: The filter field

/// `.search-field.search-results-filter`: the filter lines, the field ("Filter by name or folder"), and the clear button
/// once something is typed. Esc clears it first, then gives the keyboard back to the results; Return and ↓ do so too.
final class SearchFilterField: NSView, NSTextFieldDelegate {
    let input = NSTextField()
    let clearButton = ClearButton()
    /// Where Tab stops at the ✕, which takes no keyboard itself: a press on it keeps the keyboard in the field.
    let clearStop = KeyboardStopView()
    var onChange: (String) -> Void = { _ in }
    var onFocusResults: () -> Void = {}
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
        addSubview(clearStop)
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
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = Self.layout
        let clear = layout.clearButtonSize
        // A field keeps 2 pt before its text: the text starts after the gap.
        let left = layout.fieldPaddingLeading + layout.fieldIconSize + layout.fieldGap - 2
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
        let layout = Self.layout
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        // `--field-edge`: an inset hairline; focused, the focus ring.
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
        // The filter lines (`M4 6h16M7 12h10M10 18h4` on 24), stroked 2.
        let size = CGFloat(layout.fieldIconSize)
        let rect = NSRect(x: layout.fieldPaddingLeading, y: (bounds.height - size) / 2, width: size, height: size)
        let scale = size / 24
        let path = NSBezierPath()
        for (x, y, length) in [(4.0, 6.0, 16.0), (7.0, 12.0, 10.0), (10.0, 18.0, 4.0)] {
            path.move(to: NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale))
            path.line(to: NSPoint(x: rect.minX + (x + length) * scale, y: rect.minY + y * scale))
        }
        path.lineWidth = CGFloat(layout.fieldIconStrokeWidth) * scale
        path.lineCapStyle = .round
        NSColor(palette.textSecondary).setStroke()
        path.stroke()
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
