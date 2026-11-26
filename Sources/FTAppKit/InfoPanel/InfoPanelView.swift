import AppKit
import FTFileSystem
import FTFoundation

/// `percent` of `first` mixed with the rest of `second`, channel by channel in sRGB (alpha not premultiplied).
func mixColor(_ first: RGBA, _ percent: Double, with second: RGBA) -> RGBA {
    let share = percent / 100
    return RGBA(
        red: first.red * share + second.red * (1 - share), green: first.green * share + second.green * (1 - share),
        blue: first.blue * share + second.blue * (1 - share), alpha: first.alpha * share + second.alpha * (1 - share))
}

/// The app an item opens in, for the Open button and the "Opens with" row.
struct InfoOpenApp: Equatable {
    var path: String
    var name: String
}

/// What the Info panel shows.
struct InfoPanelDisplay: Equatable {
    struct Item: Equatable {
        var item: InfoItem
        var content: InfoPanelModel.ItemContent
        var folderSize: FolderSizeEntry?
        var openApp: InfoOpenApp?
    }

    struct Selection: Equatable {
        var summary: InfoSelection
        var sections: [InfoSection]
        var folderSize: FolderSizeEntry?
    }

    enum Body: Equatable {
        /// Loading with nothing to show yet: the body is empty.
        case blank
        case empty
        case item(Item)
        case selection(Selection)
    }

    var body: Body
    /// The spinner is wanted (it shows after 300 ms).
    var wantsSpinner: Bool
}

/// The Info panel's place in the window's last column: opaque, on the base background.
final class InfoPanelView: NSView {
    /// Opaque: the panel slides away over the content.
    private let backdrop = ContentBackdrop()
    private let header = InfoPanelHeader()
    private let scroll = NSScrollView()
    private let content = InfoPanelContentView()
    private(set) var display = InfoPanelDisplay(body: .blank, wantsSpinner: false)
    private let spinnerDelay = DelayedFlag()

    // What the owner provides.
    var iconStore: FileIconStore? {
        get { content.iconStore }
        set { content.iconStore = newValue }
    }
    var closeTooltip = "Hide Info Panel" {
        didSet { header.close.tooltip = closeTooltip }
    }
    var onClose: () -> Void = {}
    /// The Original row of a symbolic link or an alias was clicked: Show Original.
    var onShowOriginal: (String) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onOpenWithMenu: (NSView) -> Void = { _ in }
    var onOpensWithMenu: (NSView) -> Void = { _ in }
    /// The Tags row was clicked: the Tags popover hangs from it.
    var onEditTags: (NSView) -> Void = { _ in }
    /// Sharing & Permissions' Edit… was clicked: the permissions popover hangs from its title.
    var onEditPermissions: (NSView) -> Void = { _ in }
    var onCalculate: () -> Void = {}
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void = {}
    /// The button beside the close button: into a window of its own, or back.
    var onPopOut: () -> Void = {}
    /// In a window of its own.
    var isPoppedOut: Bool {
        get { header.isPoppedOut }
        set { header.isPoppedOut = newValue }
    }
    /// A row's Copy, or Where's copy button: the text, and what it is ("Path").
    var onCopyText: (String, String) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("infoPanel")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = content
        addSubview(backdrop)
        addSubview(scroll)
        addSubview(header)
        header.close.onClick = { [weak self] in self?.onClose() }
        header.popOut.onClick = { [weak self] in self?.onPopOut() }
        header.close.tooltip = closeTooltip
        content.owner = self
        spinnerDelay.onChange = { [weak self] in
            guard let self else { return }
            self.header.showsSpinner = self.spinnerDelay.value
            self.needsLayout = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ next: InfoPanelDisplay) {
        guard next != display else { return }
        display = next
        spinnerDelay.update(active: next.wantsSpinner, delay: InfoMetrics.spinnerDelay)
        header.showsSpinner = spinnerDelay.value
        content.apply(next.body)
        needsLayout = true
    }

    func setOpenMenuOpen(_ value: Bool) { content.setOpenMenuOpen(value) }
    func setOpensWithMenuOpen(_ value: Bool) { content.setOpensWithMenuOpen(value) }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InfoMetrics.panelHeaderHeight)
        scroll.frame = NSRect(
            x: 0, y: InfoMetrics.panelHeaderHeight, width: bounds.width,
            height: max(0, bounds.height - InfoMetrics.panelHeaderHeight))
        content.frame.size.width = scroll.contentSize.width
        content.relayout()
        backdrop.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        content.applyColors()
        header.applyColors()
    }
}

/// The panel's header: "Info", the spinner, the close button.
final class InfoPanelHeader: NSView {
    let title = TextBoxField(labelWithString: "Info")
    let spinner = InfoSpinnerView(diameter: 10, lineWidth: 1.5)
    let close = InfoIconButton(
        glyph: .close, iconSize: InfoMetrics.closeIcon, cornerRadius: DesignTokens.radii.xs,
        identifier: "infoPanel.close", label: "Hide Info Panel")
    /// Beside the close button: the panel into a window of its own, or, there, back into the window.
    let popOut = InfoIconButton(
        glyph: .popOut, iconSize: InfoMetrics.closeIcon, cornerRadius: DesignTokens.radii.xs,
        identifier: "infoPanel.popOut", label: InfoPanelHeader.popOutLabel)
    static let popOutLabel = "Show Info Panel in Its Own Window"
    static let popInLabel = "Show Info Panel in the Window"
    /// In a window of its own: the window's buttons are at the left and its own close button closes it.
    var isPoppedOut = false {
        didSet {
            popOut.glyph = isPoppedOut ? .popIn : .popOut
            let label = isPoppedOut ? Self.popInLabel : Self.popOutLabel
            popOut.setAccessibilityLabel(label)
            popOut.tooltip = label
            close.isHidden = isPoppedOut
            needsLayout = true
        }
    }
    var showsSpinner = false {
        didSet {
            spinner.isHidden = !showsSpinner
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("infoPanel.header")
        title.font = tabularFont(DesignTokens.typeScale.callout, weight: 600)
        title.setAccessibilityIdentifier("infoPanel.title")
        spinner.setAccessibilityIdentifier("infoPanel.spinner")
        spinner.setAccessibilityLabel("Loading info")
        spinner.isHidden = true
        // In the text's own color, the hover's fill behind them under the pointer, and heavy: in grey they read as
        // dimmed beside the window's own buttons.
        for button in [close, popOut] {
            button.normalColor = { $0.palette.textPrimary }
            button.hoverColor = { $0.palette.textPrimary }
            button.weight = .heavy
        }
        popOut.tooltip = Self.popOutLabel
        for view in [title, spinner, close, popOut] as [NSView] { addSubview(view) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyColors() {
        title.textColor = NSColor(infoTheme.palette.textSecondary)
    }

    override func layout() {
        super.layout()
        applyColors()
        let inset = InfoMetrics.panelInset
        let side = InfoMetrics.closeButton
        close.frame = NSRect(x: bounds.width - inset - side, y: (bounds.height - side) / 2, width: side, height: side)
        // Left of the close button, 4 apart; in a window of its own, where the close button was.
        let popOutX = isPoppedOut ? close.frame.minX : close.frame.minX - 4 - side
        popOut.frame = NSRect(x: popOutX, y: close.frame.minY, width: side, height: side)
        let titleHeight = lineBox(title.font)
        // In a window of its own the title starts past the window's buttons.
        title.frame = NSRect(
            x: isPoppedOut ? InfoMetrics.popOutTitleX : inset, y: (bounds.height - titleHeight) / 2,
            width: textExtent(title.stringValue, title.font), height: titleHeight)
        if showsSpinner {
            spinner.frame = NSRect(x: popOut.frame.minX - 12 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
        }
    }
}

/// The box a value that is not plain text sits in, which automation reads the size and style of.
final class RowValueBox: NSView, TextStyleSource {
    let sample = TextBoxField(labelWithString: "")
    var styleTextField: NSTextField? { sample }

    override init(frame: NSRect) {
        super.init(frame: frame)
        sample.alphaValue = 0
        sample.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(sample)
        setAccessibilityIdentifier("infoPanel.row.value")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The main half of the split button: it carries the label's style for automation.
final class SplitMainPart: NSView, TextStyleSource {
    weak var label: NSTextField?
    var styleTextField: NSTextField? { label }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Open With half, which automation names (`infoPanel.openWith`). The button takes its presses: it takes
/// the first click of a window not in front, as a click on the chevron opens the menu there too.
final class SplitChevronPart: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A split button: the main half and the Open With half, drawn as one, the accent filling both.
final class SplitOpenButton: NSView, TextStyleSource {
    var styleTextField: NSTextField? { label }
    var title = "Open" { didSet { needsLayout = true } }
    var appIcon: NSImage? { didSet { needsLayout = true } }
    /// The app is known and its icon is on its way: its room is kept, so the title doesn't move when it comes.
    var reservesIcon = false { didSet { needsLayout = true } }
    var onMain: () -> Void = {}
    var onChevron: () -> Void = {}
    private var hoverMain = false { didSet { needsDisplay = true } }
    private var hoverChevron = false { didSet { needsDisplay = true } }
    private var pressedPart: Int?
    private(set) var menuOpen = false { didSet { needsDisplay = true } }
    let label = TextBoxField(labelWithString: "")
    let chevron = SplitChevronPart()
    /// The main half, which automation names (`infoPanel.open`).
    let mainPart = SplitMainPart()

    override init(frame: NSRect) {
        super.init(frame: frame)
        mainPart.label = label
        addSubview(mainPart)
        label.font = ChromeColors.font(size: DesignTokens.typeScale.body)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.setAccessibilityIdentifier("infoPanel.open.label")
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("infoPanel.openGroup")
        mainPart.setAccessibilityIdentifier("infoPanel.open")
        chevron.setAccessibilityIdentifier("infoPanel.openWith")
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setMenuOpen(_ open: Bool) { menuOpen = open }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private var mainWidth: Double { bounds.width - InfoMetrics.openChevronWidth }
    /// The app's icon, 18 rather than 16.
    private let iconSize = 18.0

    override func layout() {
        super.layout()
        mainPart.frame = NSRect(x: 0, y: 0, width: mainWidth, height: bounds.height)
        chevron.frame = NSRect(x: mainWidth, y: 0, width: InfoMetrics.openChevronWidth, height: bounds.height)
        label.stringValue = title
        let textWidth = textExtent(title, label.font)
        let padding = 12.0
        let icon = appIcon != nil || reservesIcon ? iconSize + 6 : 0
        let available = max(0, mainWidth - 2 * padding)
        let shown = min(textWidth, max(0, available - icon))
        let start = (mainWidth - (icon + shown)) / 2
        let height = lineBox(label.font)
        label.frame = NSRect(x: start + icon, y: (bounds.height - height) / 2, width: shown, height: height)
        label.textColor = NSColor(infoTheme.accent.onSolid)
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        let radius = DesignTokens.radii.control
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(theme.accent.solidButton).setFill()
        bounds.fill()
        for (index, hovered) in [hoverMain, hoverChevron].enumerated() where hovered {
            NSColor(theme.palette.bgHover).setFill()
            (index == 0 ? NSRect(x: 0, y: 0, width: mainWidth, height: bounds.height) : chevron.frame).fill()
        }
        if let part = pressedPart ?? (menuOpen ? 1 : nil) {
            NSColor.black.withAlphaComponent(0.08).setFill()
            (part == 0 ? NSRect(x: 0, y: 0, width: mainWidth, height: bounds.height) : chevron.frame).fill()
        }
        NSColor(theme.accent.onSolid.withAlpha(0.35)).setFill()
        NSRect(x: mainWidth, y: 0, width: 1, height: bounds.height).fill()
        let box = 8.0
        InfoGlyph.openChevron.draw(
            in: NSRect(
                x: mainWidth + (InfoMetrics.openChevronWidth - box) / 2 + 0.5, y: (bounds.height - box) / 2,
                width: box, height: box),
            color: NSColor(theme.accent.onSolid))
        NSGraphicsContext.restoreGraphicsState()
        if let appIcon {
            let textWidth = textExtent(title, label.font)
            let available = max(0, mainWidth - 24)
            let shown = min(textWidth, max(0, available - iconSize - 6))
            let start = (mainWidth - (iconSize + 6 + shown)) / 2
            appIcon.draw(
                in: NSRect(x: start, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func part(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return nil }
        return point.x >= mainWidth ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = part(at: event)
        hoverMain = hovered == 0
        hoverChevron = hovered == 1
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hoverMain = false
        hoverChevron = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedPart = part(at: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedPart
        pressedPart = nil
        needsDisplay = true
        guard let pressed, part(at: event) == pressed else { return }
        if pressed == 0 { onMain() } else { onChevron() }
    }

    override func accessibilityPerformPress() -> Bool {
        onMain()
        return true
    }
}

/// "Opens with" in Information: the app as a small pop-up button that keeps the row's text size.
final class OpensWithPopupView: NSView {
    let name = TextBoxField(labelWithString: "")
    var app: InfoOpenApp? { didSet { reload() } }
    var iconStore: FileIconStore?
    var kindLabel = ""
    var onClick: () -> Void = {}
    private var icon: NSImage?
    private var handle: LoadHandle?
    private var isHovered = false { didSet { needsDisplay = true } }
    private(set) var menuOpen = false { didSet { needsDisplay = true } }

    static let paddingLeading = 6.0
    static let paddingTrailing = 4.0
    static let gap = 5.0
    static let iconSize = 18.0
    static let chevron = 9.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = ChromeColors.font(size: DesignTokens.typeScale.callout)
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityIdentifier("infoPanel.opensWith.name")
        addSubview(name)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityIdentifier("infoPanel.opensWith")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    func setMenuOpen(_ open: Bool) { menuOpen = open }

    private func reload() {
        name.stringValue = app?.name ?? "None"
        setAccessibilityLabel("Opens with \(app?.name ?? "no app"): change the app for every \(kindLabel)")
        handle?.cancel()
        icon = nil
        if let app, let iconStore {
            handle = iconStore.load(.app(path: app.path)) { [weak self] image in
                self?.icon = image.map(NativeIconPixels.image)
                self?.needsDisplay = true
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    var naturalWidth: Double {
        let text = textExtent(name.stringValue, name.font)
        let icon = app != nil ? Self.iconSize + Self.gap : 0
        return Self.paddingLeading + icon + text + Self.gap + Self.chevron + Self.paddingTrailing
    }

    override func layout() {
        super.layout()
        let icon = app != nil ? Self.iconSize + Self.gap : 0
        let textX = Self.paddingLeading + icon
        let width = max(0, bounds.width - textX - Self.gap - Self.chevron - Self.paddingTrailing)
        let height = lineBox(name.font)
        name.frame = NSRect(x: textX, y: (bounds.height - height) / 2, width: width, height: height)
        name.textColor = NSColor(infoTheme.palette.textPrimary)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = infoTheme
        if isHovered || menuOpen {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control)
                .fill()
        }
        if app != nil, let icon {
            icon.draw(
                in: NSRect(
                    x: Self.paddingLeading, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize,
                    height: Self.iconSize),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let box = Self.chevron
        InfoGlyph.popupChevron.draw(
            in: NSRect(
                x: bounds.width - Self.paddingTrailing - box, y: (bounds.height - box) / 2, width: box, height: box),
            color: NSColor(theme.palette.textSecondary))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
