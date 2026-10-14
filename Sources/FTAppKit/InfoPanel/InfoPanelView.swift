// Port of the .get-info-panel of apps/desktop/src/renderer/components/GetInfoPanel.tsx with styles.css:3127-3270 and
// 4555-4850: the header, the hero, the split Open button, the Information rows and the Quick Actions
import AppKit
import FTFileSystem
import FTFoundation

/// `color-mix(in srgb, a p%, b)`.
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
        /// Open With has items, so the chevron half shows.
        var hasOpenWith: Bool
        var actions: [InfoPanelModel.QuickAction]
        var copied: InfoPanelModel.QuickAction.ID?
    }

    struct Selection: Equatable {
        var summary: InfoSelection
        var rows: [InfoRow]
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
    var onNavigate: (String) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onAction: (InfoPanelModel.QuickAction.ID) -> Void = { _ in }
    var onOpenWithMenu: (NSView) -> Void = { _ in }
    var onOpensWithMenu: (NSView) -> Void = { _ in }
    var onCalculate: () -> Void = {}
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void = {}

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
        addSubview(scroll)
        addSubview(header)
        header.close.onClick = { [weak self] in self?.onClose() }
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

    /// The folder size cell takes up a new entry without the rest being built again.
    func updateFolderSize(_ entry: FolderSizeEntry?) {
        content.updateFolderSize(entry)
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: InfoMetrics.panelHeaderHeight)
        scroll.frame = NSRect(
            x: 0, y: InfoMetrics.panelHeaderHeight, width: bounds.width,
            height: max(0, bounds.height - InfoMetrics.panelHeaderHeight))
        content.frame.size.width = scroll.contentSize.width
        content.relayout()
        layer?.backgroundColor = ChromeColors.color(AppearanceModel.shared.theme.palette.bgBase).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        content.applyColors()
        header.applyColors()
    }
}

/// `.get-info-header`: "Info", the spinner, the close button.
final class InfoPanelHeader: NSView {
    let title = FlushTextField(labelWithString: "Info")
    let spinner = InfoSpinnerView(diameter: 10, lineWidth: 1.5)
    let close = InfoIconButton(
        glyph: .close, iconSize: InfoMetrics.closeIcon, strokeWidth: 2.5, cornerRadius: DesignTokens.radii.xs,
        identifier: "infoPanel.close", label: "Hide Info Panel")
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
        close.normalColor = { $0.palette.getInfoCloseIcon }
        close.hoverColor = { $0.palette.getInfoCloseIconHover }
        for view in [title, spinner, close] as [NSView] { addSubview(view) }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyColors() {
        title.textColor = NSColor(AppearanceModel.shared.theme.palette.textSecondary)
    }

    override func layout() {
        super.layout()
        let inset = InfoMetrics.panelInset
        let side = InfoMetrics.closeButton
        close.frame = NSRect(x: bounds.width - inset - side, y: (bounds.height - side) / 2, width: side, height: side)
        let titleHeight = lineBox(title.font)
        title.frame = NSRect(
            x: inset, y: (bounds.height - titleHeight) / 2, width: textExtent(title.stringValue, title.font),
            height: titleHeight)
        if showsSpinner {
            spinner.frame = NSRect(x: close.frame.minX - 12 - 10, y: (bounds.height - 10) / 2, width: 10, height: 10)
        }
    }
}

/// The box a value that is not plain text sits in, which the capture reads the size and style of.
final class RowValueBox: NSView, TextStyleSource {
    let sample = FlushTextField(labelWithString: "")
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

/// The main half of the split button: it carries the label's style for the capture.
final class SplitMainPart: NSView, TextStyleSource {
    weak var label: NSTextField?
    var styleTextField: NSTextField? { label }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A split button: the main half and the Open With half, drawn as one, the accent filling both.
final class SplitOpenButton: NSView, TextStyleSource {
    var styleTextField: NSTextField? { label }
    var title = "Open" { didSet { needsLayout = true } }
    var appIcon: NSImage? { didSet { needsLayout = true } }
    var isSplit = false { didSet { needsDisplay = true } }
    var onMain: () -> Void = {}
    var onChevron: () -> Void = {}
    private var hoverMain = false { didSet { needsDisplay = true } }
    private var hoverChevron = false { didSet { needsDisplay = true } }
    private var pressedPart: Int?
    private(set) var menuOpen = false { didSet { needsDisplay = true } }
    let label = FlushTextField(labelWithString: "")
    let chevron = NSView()
    /// The main half, which the capture names (`.get-info-open-main`).
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
        chevron.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setMenuOpen(_ open: Bool) { menuOpen = open }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    private var mainWidth: Double { isSplit ? bounds.width - InfoMetrics.openChevronWidth : bounds.width }
    private let iconSize = 16.0

    override func layout() {
        super.layout()
        chevron.isHidden = !isSplit
        mainPart.frame = NSRect(x: 0, y: 0, width: mainWidth, height: bounds.height)
        chevron.frame = NSRect(x: mainWidth, y: 0, width: InfoMetrics.openChevronWidth, height: bounds.height)
        label.stringValue = title
        let textWidth = textExtent(title, label.font)
        let padding = 12.0
        let icon = appIcon != nil ? iconSize + 6 : 0
        let available = max(0, mainWidth - 2 * padding)
        let shown = min(textWidth, max(0, available - icon))
        let start = (mainWidth - (icon + shown)) / 2
        let height = lineBox(label.font)
        label.frame = NSRect(x: start + icon, y: (bounds.height - height) / 2, width: shown, height: height)
        label.textColor = NSColor(AppearanceModel.shared.theme.accent.onSolid)
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppearanceModel.shared.theme
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
        if isSplit {
            NSColor(theme.accent.onSolid.withAlpha(0.35)).setFill()
            NSRect(x: mainWidth, y: 0, width: 1, height: bounds.height).fill()
            let box = 8.0
            InfoGlyph.openChevron.draw(
                in: NSRect(x: mainWidth + (InfoMetrics.openChevronWidth - box) / 2 + 0.5, y: (bounds.height - box) / 2, width: box, height: box),
                strokeWidth: 1.6, color: NSColor(theme.accent.onSolid))
        }
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
        return isSplit && point.x >= mainWidth ? 1 : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
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
    let name = FlushTextField(labelWithString: "")
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
                self?.icon = image
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
        name.textColor = NSColor(AppearanceModel.shared.theme.palette.textPrimary)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = AppearanceModel.shared.theme
        if isHovered || menuOpen {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control).fill()
        }
        if app != nil, let icon {
            icon.draw(
                in: NSRect(x: Self.paddingLeading, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let box = Self.chevron
        InfoGlyph.popupChevron.draw(
            in: NSRect(x: bounds.width - Self.paddingTrailing - box, y: (bounds.height - box) / 2, width: box, height: box),
            strokeWidth: 2.4, color: NSColor(theme.palette.textSecondary))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
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

/// The panel's scrolled content: laid out from the display as the stylesheet stacks it.
final class InfoPanelContentView: NSView {
    weak var owner: InfoPanelView?
    var iconStore: FileIconStore? {
        didSet { opensWith.iconStore = iconStore }
    }
    private var body = InfoPanelDisplay.Body.blank
    private let heroIcon = InfoIconView()
    private let name = FlushTextField(wrappingLabelWithString: "")
    private let subtitle = FlushTextField(labelWithString: "")
    private let open = SplitOpenButton()
    private let opensWith = OpensWithPopupView()
    private let cell = FolderSizeCellView(style: .panel, identifier: "infoPanel.folderSize")
    private let emptyLabel = FlushTextField(wrappingLabelWithString: "Select a file or folder to show its info.")
    private var sectionTitles: [FlushTextField] = []
    private var rowViews: [RowViews] = []
    private var actionButtons: [(InfoPanelModel.QuickAction.ID, InfoIconButton)] = []
    private var dividers: [Double] = []

    private struct RowViews {
        var row: InfoRow
        var label: FlushTextField
        var value: NSView
        var extra: FlushTextField?
        /// The `<dd>` of a value that is not plain text, which the capture names.
        var box: RowValueBox?
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heroIcon.setAccessibilityIdentifier("infoPanel.heroIcon")
        name.setAccessibilityIdentifier("infoPanel.name")
        subtitle.setAccessibilityIdentifier("infoPanel.subtitle")
        emptyLabel.setAccessibilityIdentifier("infoPanel.empty")
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.font = ChromeColors.font(size: DesignTokens.typeScale.title3, weight: 600)
        subtitle.alignment = .center
        subtitle.font = tabularFont(DesignTokens.typeScale.callout)
        subtitle.lineBreakMode = .byTruncatingTail
        emptyLabel.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: 600)
        for view in [heroIcon, name, subtitle, open, emptyLabel, opensWith, cell] as [NSView] { addSubview(view) }
        open.onMain = { [weak self] in self?.owner?.onOpen() }
        open.onChevron = { [weak self] in
            guard let self else { return }
            self.owner?.onOpenWithMenu(self.open)
        }
        opensWith.onClick = { [weak self] in
            guard let self else { return }
            self.owner?.onOpensWithMenu(self.opensWith)
        }
        cell.onCalculate = { [weak self] in self?.owner?.onCalculate() }
        cell.onRecalculate = { [weak self] in self?.owner?.onRecalculate() }
        cell.onCancel = { [weak self] in self?.owner?.onCancel() }
        cell.onSizeChange = { [weak self] in
            self?.relayout()
        }
        cell.isHidden = true
        opensWith.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateFolderSize(_ entry: FolderSizeEntry?) {
        if let entry { cell.update(entry) }
    }

    func setOpenMenuOpen(_ value: Bool) { open.setMenuOpen(value) }
    func setOpensWithMenuOpen(_ value: Bool) { opensWith.setMenuOpen(value) }

    // MARK: Building

    func apply(_ next: InfoPanelDisplay.Body) {
        body = next
        for title in sectionTitles { title.removeFromSuperview() }
        sectionTitles = []
        for views in rowViews {
            views.label.removeFromSuperview()
            if views.value !== cell, views.value !== opensWith { views.value.removeFromSuperview() }
            views.extra?.removeFromSuperview()
            views.box?.removeFromSuperview()
        }
        rowViews = []
        for (_, button) in actionButtons { button.removeFromSuperview() }
        actionButtons = []
        cell.isHidden = true
        opensWith.isHidden = true
        switch next {
        case .blank, .empty:
            break
        case .item(let item):
            buildHeroIcon(item.item)
            name.stringValue = item.item.name
            name.toolTip = item.item.name
            subtitle.stringValue = item.content.subtitle
            open.title = item.openApp.map { "Open in \($0.name)" } ?? "Open"
            open.toolTip = open.title
            open.isSplit = item.hasOpenWith
            loadOpenIcon(item.openApp)
            sectionTitles = [sectionTitle("Information"), sectionTitle("Quick Actions")]
            buildRows(item.content.rows, folderSize: item.folderSize, opensWith: item.openApp, kind: item.item.kindLabel)
            for action in item.actions {
                let button = InfoIconButton(
                    glyph: Self.glyph(action.id, copied: item.copied == action.id), iconSize: InfoMetrics.actionIcon,
                    strokeWidth: 1.8, cornerRadius: DesignTokens.radii.control, identifier: "infoPanel.action",
                    label: action.label)
                button.tooltip = Tooltips.format(action.label, shortcutLabel: action.shortcut)
                button.isEnabled = !action.disabled
                button.onClick = { [weak self] in self?.owner?.onAction(action.id) }
                addSubview(button)
                actionButtons.append((action.id, button))
            }
        case .selection(let selection):
            let contains = InfoPanelModel.selectionContains(selection.summary)
            heroIcon.showStack(
                back: contains == "files" ? .file : .folder, front: contains == "folders" ? .folder : .file,
                store: iconStore)
            name.stringValue = InfoPanelModel.selectionName(selection.summary)
            name.toolTip = nil
            subtitle.stringValue = InfoPanelModel.selectionSubtitle(selection.summary)
            sectionTitles = [sectionTitle("Information")]
            buildRows(selection.rows, folderSize: selection.folderSize, opensWith: nil, kind: "")
        }
        if case .item(let item) = next, let entry = item.folderSize { cell.update(entry) }
        if case .selection(let selection) = next, let entry = selection.folderSize { cell.update(entry) }
        applyColors()
        needsLayout = true
    }

    private func buildHeroIcon(_ item: InfoItem) {
        let kind: IconEntryKind
        switch item.kind {
        case .directory: kind = .directory
        case .file: kind = .file
        case .symlinkDirectory: kind = .symlinkDirectory
        case .symlinkFile: kind = .symlinkFile
        case .bundle: kind = .bundle
        case .other: kind = .other
        }
        heroIcon.show(
            IconEntry(path: item.path, name: item.name, extension: item.fileExtension, kind: kind), store: iconStore,
            deferLoad: true)
    }

    private func loadOpenIcon(_ app: InfoOpenApp?) {
        guard let app, let iconStore else {
            open.appIcon = nil
            return
        }
        iconStore.load(.app(path: app.path)) { [weak self] image in self?.open.appIcon = image }
    }

    private func sectionTitle(_ text: String) -> FlushTextField {
        let field = FlushTextField(labelWithString: text)
        field.font = ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600)
        field.setAccessibilityIdentifier("infoPanel.section.title")
        addSubview(field)
        return field
    }

    private func buildRows(_ rows: [InfoRow], folderSize: FolderSizeEntry?, opensWith app: InfoOpenApp?, kind: String) {
        for row in rows {
            let label = FlushTextField(labelWithString: row.label)
            label.font = tabularFont(DesignTokens.typeScale.callout)
            label.setAccessibilityIdentifier("infoPanel.row.label")
            addSubview(label)
            var extra: FlushTextField?
            var box: RowValueBox?
            let value: NSView
            switch row.value {
            case .text(let text):
                let field = FlushTextField(labelWithString: text)
                field.lineBreakMode = .byTruncatingTail
                field.alignment = .right
                field.setAccessibilityIdentifier("infoPanel.row.value")
                addSubview(field)
                value = field
            case .folderSize:
                cell.isHidden = false
                value = cell
                box = RowValueBox()
            case .permissions(let words, let octal, let symbolic):
                let field = FlushTextField(labelWithString: words)
                field.alignment = .right
                field.setAccessibilityIdentifier("infoPanel.row.words")
                box = RowValueBox()
                box?.sample.stringValue = words
                let code = FlushTextField(labelWithString: octal)
                code.font = ThemeFonts.mono(DesignTokens.typeScale.small)
                code.toolTip = symbolic
                code.setAccessibilityIdentifier("infoPanel.row.code")
                addSubview(field)
                addSubview(code)
                extra = code
                value = field
            case .whereLink(let text, let path):
                let link = TextLinkView(identifier: "infoPanel.where")
                box = RowValueBox()
                box?.sample.stringValue = text
                link.text = text
                link.toolTip = path
                link.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
                link.onClick = { [weak self] in self?.owner?.onNavigate(path) }
                addSubview(link)
                value = link
            case .opensWith:
                opensWith.isHidden = false
                opensWith.kindLabel = kind
                opensWith.app = app
                value = opensWith
                box = RowValueBox()
                box?.sample.stringValue = app?.name ?? "None"
            }
            if let box { addSubview(box) }
            rowViews.append(RowViews(row: row, label: label, value: value, extra: extra, box: box))
        }
    }

    static func glyph(_ id: InfoPanelModel.QuickAction.ID, copied: Bool) -> InfoGlyph {
        switch id {
        case .quickLook: .quickLook
        case .edit: .edit
        case .copyPath: copied ? .check : .copy
        case .copyName: copied ? .check : .name
        case .terminal: .terminal
        case .finder: .finder
        case .favorite: .favorite
        case .rootTree: .rootTree
        }
    }

    // MARK: Colors

    func applyColors() {
        let theme = AppearanceModel.shared.theme
        let palette = theme.palette
        name.textColor = NSColor(palette.textPrimary)
        subtitle.textColor = NSColor(palette.textSecondary)
        emptyLabel.textColor = NSColor(palette.getInfoMetaValue)
        for title in sectionTitles { title.textColor = NSColor(palette.textSecondary) }
        for views in rowViews {
            views.label.textColor = NSColor(palette.textSecondary)
            views.extra?.textColor = NSColor(palette.textSecondary)
            if let box = views.box {
                let muted = views.row.muted
                box.sample.textColor = NSColor(
                    muted ? mixColor(palette.getInfoMetaValueMuted, 45, with: palette.getInfoMetaValue) : palette.textPrimary)
                box.sample.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: muted ? 600 : 400)
            }
            if let field = views.value as? NSTextField {
                let muted = views.row.muted
                field.textColor = NSColor(
                    muted ? mixColor(palette.getInfoMetaValueMuted, 45, with: palette.getInfoMetaValue) : palette.textPrimary)
                field.font = ChromeColors.font(size: DesignTokens.typeScale.callout, weight: muted ? 600 : 400)
            } else if let link = views.value as? TextLinkView {
                link.applyStyle()
            }
        }
        needsDisplay = true
    }

    // MARK: Layout

    private func lineHeight(_ font: NSFont?) -> Double {
        lineBox(font)
    }

    private func textWidth(_ field: NSTextField) -> Double {
        textExtent(field.stringValue, field.font)
    }

    func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        let inset = InfoMetrics.panelInset
        let width = max(0, bounds.width - 2 * inset)
        var y = 0.0
        dividers = []
        let isEmpty: Bool
        var hasHero = false
        switch body {
        case .blank: isEmpty = false
        case .empty: isEmpty = true
        default:
            isEmpty = false
            hasHero = true
        }
        emptyLabel.isHidden = !isEmpty
        for view in [heroIcon, name, subtitle] as [NSView] { view.isHidden = !hasHero }
        open.isHidden = true
        if isEmpty {
            // `.get-info-empty`: padding-top 18.
            let height = ceil(emptyLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 0)
            emptyLabel.frame = NSRect(x: inset, y: 18, width: width, height: height)
            frame.size.height = max(superview?.bounds.height ?? 0, 18 + height + 18)
            return
        }
        guard hasHero else { return }
        // The hero: padding 8 8 14, a 6 gap.
        let heroPad = 8.0
        y += heroPad
        var boxSide = InfoMetrics.heroIconBox
        var iconSide = 96.0
        if case .selection = body {
            boxSide = InfoMetrics.heroStackBox
            iconSide = boxSide
        }
        heroIcon.inset = (boxSide - iconSide) / 2
        heroIcon.frame = NSRect(x: inset + (width - boxSide) / 2, y: y, width: boxSide, height: boxSide)
        y += boxSide + InfoMetrics.heroGap
        let nameWidth = max(0, width - 2 * heroPad)
        let nameLine = (name.font?.pointSize ?? 15) * 1.3
        let nameParagraph = NSMutableParagraphStyle()
        nameParagraph.alignment = .center
        nameParagraph.minimumLineHeight = nameLine
        nameParagraph.maximumLineHeight = nameLine
        nameParagraph.lineBreakMode = .byTruncatingTail
        let nameFont = name.font ?? ChromeColors.font(size: 15, weight: 600)
        name.attributedStringValue = NSAttributedString(
            string: name.stringValue,
            attributes: [
                .font: nameFont, .foregroundColor: NSColor(AppearanceModel.shared.theme.palette.textPrimary),
                .paragraphStyle: nameParagraph,
            ])
        let measured = (name.stringValue as NSString).boundingRect(
            with: NSSize(width: nameWidth, height: 10000), options: [.usesLineFragmentOrigin],
            attributes: [.font: nameFont, .paragraphStyle: nameParagraph])
        let lines = min(2, max(1, Int((measured.height / nameLine).rounded(.up))))
        let nameHeight = Double(lines) * nameLine
        let nameShown = min(nameWidth, max(ceil(measured.width), textExtent(name.stringValue, nameFont)))
        name.frame = NSRect(x: inset + (width - nameShown) / 2, y: y, width: nameShown, height: nameHeight)
        y += nameHeight + InfoMetrics.heroGap
        let subtitleHeight = lineHeight(subtitle.font)
        let subtitleShown = min(nameWidth, textExtent(subtitle.stringValue, subtitle.font))
        subtitle.frame = NSRect(x: inset + (width - subtitleShown) / 2, y: y, width: subtitleShown, height: subtitleHeight)
        y += subtitleHeight + 14

        if case .item = body {
            open.isHidden = false
            open.frame = NSRect(x: inset, y: y, width: width, height: InfoMetrics.openButtonHeight)
            y += InfoMetrics.openButtonHeight + 18
        }
        // Information.
        var titleIndex = 0
        func place(title: FlushTextField) {
            let height = lineHeight(title.font)
            title.frame = NSRect(x: inset, y: y, width: width, height: height)
            y += height + InfoMetrics.sectionTitleGap
        }
        if titleIndex < sectionTitles.count {
            place(title: sectionTitles[titleIndex])
            titleIndex += 1
        }
        let bodyLine = lineHeight(ChromeColors.font(size: DesignTokens.typeScale.callout))
        for (index, views) in rowViews.enumerated() {
            let top = y + InfoMetrics.rowPaddingBlock
            let label = views.label
            let labelWidth = textWidth(label)
            var valueHeight = bodyLine
            var valueWidth: Double
            switch views.value {
            case let field as NSTextField:
                valueWidth = textWidth(field)
                if let extra = views.extra {
                    valueWidth += 6 + textWidth(extra)
                }
            case let link as TextLinkView:
                valueWidth = link.naturalWidth
            case let popup as OpensWithPopupView:
                valueWidth = popup.naturalWidth
            case let sizeCell as FolderSizeCellView:
                let natural = sizeCell.naturalSize
                valueWidth = natural.width
                valueHeight = max(natural.height, 0)
            default: valueWidth = 0
            }
            let maxValue = max(0, width - labelWidth - InfoMetrics.rowGap)
            valueWidth = min(valueWidth, maxValue)
            let valueX = inset + width - valueWidth
            let rowContent = max(bodyLine, valueHeight)
            label.frame = NSRect(x: inset, y: top, width: labelWidth, height: bodyLine)
            switch views.value {
            case let field as NSTextField:
                if let extra = views.extra {
                    let codeWidth = textWidth(extra)
                    let codeHeight = lineHeight(extra.font)
                    field.frame = NSRect(x: valueX, y: top, width: max(0, valueWidth - 6 - codeWidth), height: bodyLine)
                    // Baselines line up: the code is smaller.
                    let baselineShift = (field.font?.ascender ?? 0) - (extra.font?.ascender ?? 0)
                    extra.frame = NSRect(x: inset + width - codeWidth, y: top + baselineShift, width: codeWidth, height: codeHeight)
                } else {
                    field.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
                }
            case let popup as OpensWithPopupView:
                // margin -4 0: the pop-up is 4 pt taller above and below than its text.
                popup.frame = NSRect(x: valueX, y: top - 2, width: valueWidth, height: bodyLine + 4)
            case let sizeCell as FolderSizeCellView:
                sizeCell.frame = NSRect(x: valueX, y: top, width: valueWidth, height: valueHeight)
            default:
                views.value.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
            }
            views.box?.frame = NSRect(x: valueX, y: top, width: valueWidth, height: valueHeight)
            if let words = views.value as? NSTextField, views.extra != nil, let box = views.box {
                box.frame = NSRect(x: valueX, y: top, width: valueWidth, height: bodyLine)
                _ = words
            }
            y = top + rowContent + InfoMetrics.rowPaddingBlock
            if index < rowViews.count - 1 {
                dividers.append(y)
                y += 1
            }
        }
        y += InfoMetrics.sectionGap
        if case .item = body {
            if titleIndex < sectionTitles.count { place(title: sectionTitles[titleIndex]) }
            // `.get-info-actions`: margin 2 -8 0, a 2 gap, wrapping.
            var x = inset - 8
            for (_, button) in actionButtons {
                if x + InfoMetrics.actionWidth > inset + width + 8 {
                    x = inset - 8
                    y += InfoMetrics.actionHeight + InfoMetrics.actionGap
                }
                button.frame = NSRect(x: x, y: y, width: InfoMetrics.actionWidth, height: InfoMetrics.actionHeight)
                x += InfoMetrics.actionWidth + InfoMetrics.actionGap
            }
            y += InfoMetrics.actionHeight + InfoMetrics.sectionGap
        }
        frame.size.height = y + 18 - InfoMetrics.sectionGap + (actionButtons.isEmpty ? 0 : 0)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = AppearanceModel.shared.theme.palette
        ChromeColors.color(palette.borderLight).setFill()
        for y in dividers {
            NSRect(x: InfoMetrics.panelInset, y: y, width: bounds.width - 2 * InfoMetrics.panelInset, height: 1).fill()
        }
    }
}
