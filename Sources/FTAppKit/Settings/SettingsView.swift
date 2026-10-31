// Port of the window of apps/desktop/src/renderer/SettingsWindowApp.tsx (sidebar, pane header, notice, page), drawn as
// styles.css:4884-5047 draws it
import AppKit
import FTFoundation

/// A section in the sidebar: its icon on a coloured tile, as System Settings draws them, and its name; the one on
/// screen is semibold on the selection fill.
final class SettingsSidebarItem: TextControl {
    let tab: SettingsTab
    var isCurrent = false {
        didSet {
            font = Self.font(isCurrent)
            setAccessibilityValue(isCurrent ? 1 : 0)
            needsDisplay = true
        }
    }
    /// The ring of `:focus-visible`: when the keyboard brought the focus, not after a click (styles.css:4930).
    private(set) var focusIsVisible = false { didSet { needsDisplay = true } }

    private static func font(_ current: Bool) -> NSFont {
        ThemeFonts.sans(DesignTokens.typeScale.body, current ? .semibold : .regular)
    }

    init(tab: SettingsTab, theme: Theme) {
        self.tab = tab
        super.init(text: tab.label, theme: theme)
        font = Self.font(false)
        textColor = NSColor(theme.palette.textPrimary)
        (cell as? ThemedTextCell)?.leadingInset =
            SettingsMetrics.sidebarItemPadding + SettingsMetrics.tileSize + SettingsMetrics.sidebarItemGapInside
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.label)
        setAccessibilityIdentifier("settings.section")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        textColor = NSColor(theme.palette.textPrimary)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func drawChrome() {
        let radius = CGFloat(DesignTokens.radii.control)
        if isCurrent {
            NSColor(theme.palette.settingsSidebarSelection).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else if isHovering {
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let size = SettingsMetrics.tileSize
        let tile = NSRect(
            x: SettingsMetrics.sidebarItemPadding, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        SettingsTile.draw(tab, in: tile)
        if focusIsVisible { SettingsGlyph.focusRing(around: bounds, radius: radius, theme: theme) }
    }

    override func mouseDown(with event: NSEvent) {
        if track() { perform() }
    }

    // MARK: Keyboard

    // A native button (SettingsWindowApp.tsx:327-333): Tab stops here, and Space, Return or Enter chooses the section.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focusIsVisible = NSApp.currentEvent?.type != .leftMouseDown
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusIsVisible = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 {
            focusIsVisible = true
            perform()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The tile behind a section's icon: a top-to-bottom gradient in the section's tone, a faint edge and top highlight,
/// and the white 13 pt glyph.
@MainActor
enum SettingsTile {
    static func draw(_ tab: SettingsTab, in rect: NSRect) {
        let radius = SettingsMetrics.tileRadius
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let tone = tab.tone
        NSGradient(starting: NSColor(tone.top), ending: NSColor(tone.bottom))?.draw(in: shape, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // inset 0 1px 0 rgba(255,255,255,0.18): a line along the top.
        NSColor(SettingsMetrics.tileHighlight).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(
            roundedRect: rect.insetBy(dx: SettingsMetrics.tileEdgeWidth / 2, dy: SettingsMetrics.tileEdgeWidth / 2),
            xRadius: radius, yRadius: radius)
        edge.lineWidth = SettingsMetrics.tileEdgeWidth
        NSColor(SettingsMetrics.tileEdge).setStroke()
        edge.stroke()
        let glyph = SettingsMetrics.tileGlyphSize
        SettingsGlyph.stroke(
            tab.iconPath, box: 24,
            in: NSRect(x: rect.midX - glyph / 2, y: rect.midY - glyph / 2, width: glyph, height: glyph),
            width: SettingsMetrics.tileGlyphStroke, color: .white)
    }
}

/// A strip the window is dragged by (the top of the sidebar, the pane's header).
final class SettingsDragView: ThemedView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// The Settings window's content: a sidebar of sections, and the section on screen beside it under its title.
final class SettingsView: ThemedView {
    private(set) var activeTab: SettingsTab
    let sidebar = SettingsDragView()
    private(set) var items: [SettingsSidebarItem] = []
    let header = SettingsDragView()
    let titleText: ThemedText
    private let accessory = NSView()
    private(set) var notice: ThemedView?
    private(set) var noticeText: ThemedText?
    private(set) var noticeButton: SystemButton?
    let scroll = NSScrollView()
    private let document = FlippedView()
    private(set) var page: SettingsPageView?
    /// The line under the title shows once the page has scrolled under it.
    private(set) var isScrolled = false { didSet { syncHeaderLine() } }
    /// Told the tab on screen.
    var onTabChange: (SettingsTab) -> Void = { _ in }
    /// Builds a tab's page; nil until the preferences are loaded.
    var makePage: ((SettingsTab) -> SettingsPageView)?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Places the open pop-up again as the page scrolls.
    var onScroll: () -> Void = {}

    init(tab: SettingsTab, theme: Theme) {
        activeTab = tab
        titleText = ThemedText(
            tab.label,
            style: SettingsStyle.style(DesignTokens.typeScale.title3, .semibold) {
                $0.palette.textPrimary
            })
        super.init(frame: NSRect(origin: .zero, size: SettingsMetrics.windowSize), theme: theme)
        fill = { $0.palette.settingsPageBg }
        sidebar.fill = { $0.palette.sidebarBg }
        sidebar.edges = [.trailing: { $0.palette.settingsSidebarEdge }]
        sidebar.setAccessibilityIdentifier("settings.sidebar")
        sidebar.setAccessibilityElement(true)
        sidebar.setAccessibilityRole(.group)
        sidebar.setAccessibilityLabel("Settings sections")
        for tab in SettingsTab.allCases {
            let item = SettingsSidebarItem(tab: tab, theme: theme)
            item.target = self
            item.action = #selector(itemClicked(_:))
            items.append(item)
            sidebar.addSubview(item)
        }
        header.setAccessibilityIdentifier("settings.header")
        titleText.setAccessibilityIdentifier("settings.title")
        header.addSubview(titleText)
        header.addSubview(accessory)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.setAccessibilityIdentifier("settings.content")
        addSubview(scroll)
        addSubview(header)
        addSubview(sidebar)
        setAccessibilityIdentifier("settings")
        setAccessibilityLabel("Settings")
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScrolled = self.scroll.contentView.bounds.minY > 0
                self.onScroll()
            }
        }
        syncItems()
        syncHeaderLine()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The view itself takes the keyboard when the window opens.
    override var acceptsFirstResponder: Bool { true }

    private func syncItems() {
        for item in items { item.isCurrent = item.tab == activeTab }
    }

    private func syncHeaderLine() {
        header.edges = isScrolled ? [.bottom: { $0.palette.settingsSeparator }] : [:]
    }

    @objc private func itemClicked(_ sender: SettingsSidebarItem) {
        select(tab: sender.tab)
    }

    /// Shows a tab: its page starts at the top, without the line under the title. The tab already on screen is left
    /// as it is (its search, recording and scroll stay), as React skips setActiveTab to the same tab.
    func select(tab: SettingsTab) {
        guard tab != activeTab else { return }
        activeTab = tab
        syncItems()
        titleText.content = { [label = tab.label] theme in
            SettingsStyle.style(DesignTokens.typeScale.title3, .semibold) { $0.palette.textPrimary }.string(
                label, theme)
        }
        if page != nil || makePage != nil { showPage() }
        onTabChange(tab)
    }

    /// Builds the page of the tab on screen (once the preferences are loaded).
    func showPage() {
        page?.removeFromSuperview()
        page = makePage?(activeTab)
        for view in accessory.subviews { view.removeFromSuperview() }
        if let page {
            document.addSubview(page)
            page.applyTheme(theme, throughSubviews: true)
            if let field = page.shortcuts?.searchField {
                field.applyTheme(theme)
                accessory.addSubview(field)
            }
        }
        isScrolled = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        isScrolled = false
    }

    // MARK: Notice

    /// "Couldn’t load the settings." and the like, with Dismiss.
    func showNotice(_ text: String) {
        dismissNotice()
        let view = ThemedView(theme: theme)
        view.fill = { $0.palette.danger.withAlpha($0.palette.danger.alpha * SettingsMetrics.noticeFillPercent) }
        view.setAccessibilityIdentifier("settings.notice")
        let label = ThemedText(
            text, style: SettingsStyle.style(DesignTokens.typeScale.callout) { $0.palette.textPrimary }, wrapping: true)
        let button = SystemButton.small("Dismiss", theme: theme)
        button.target = self
        button.action = #selector(dismissPressed(_:))
        view.addSubview(label)
        view.addSubview(button)
        addSubview(view)
        notice = view
        noticeText = label
        noticeButton = button
        needsLayout = true
    }

    @objc private func dismissPressed(_ sender: Any?) { dismissNotice() }

    func dismissNotice() {
        notice?.removeFromSuperview()
        notice = nil
        noticeText = nil
        noticeButton = nil
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let sidebarWidth = SettingsMetrics.sidebarWidth
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        let side = SettingsMetrics.sidebarPaddingSide
        var y = SettingsMetrics.sidebarPaddingTop
        // The border takes the last point of the sidebar's width.
        let itemWidth = sidebarWidth - 2 * side - SettingsMetrics.separatorWidth
        for item in items {
            item.frame = NSRect(x: side, y: y, width: itemWidth, height: SettingsMetrics.sidebarItemHeight)
            y += SettingsMetrics.sidebarItemHeight + SettingsMetrics.sidebarItemGap
        }
        let paneWidth = max(0, bounds.width - sidebarWidth)
        header.frame = NSRect(x: sidebarWidth, y: 0, width: paneWidth, height: SettingsMetrics.headerHeight)
        let padding = SettingsMetrics.headerPadding
        let field = accessory.subviews.first
        let accessoryWidth: CGFloat = field == nil ? 0 : SettingsMetrics.headerSearchWidth
        let fieldHeight = CGFloat(ThemedSearchField.height)
        accessory.frame = NSRect(
            x: paneWidth - padding - accessoryWidth, y: ((SettingsMetrics.headerHeight - fieldHeight) / 2).rounded(),
            width: accessoryWidth, height: fieldHeight)
        field?.frame = accessory.bounds
        let titleWidth = max(
            0, paneWidth - 2 * padding - (field == nil ? 0 : accessoryWidth + SettingsMetrics.headerGap))
        let titleHeight = titleText.height(forWidth: titleWidth)
        titleText.frame = NSRect(
            x: padding, y: ((SettingsMetrics.headerHeight - titleHeight) / 2).rounded(), width: titleWidth,
            height: titleHeight)
        var top = SettingsMetrics.headerHeight
        if let notice, let noticeText, let noticeButton {
            let buttonWidth = noticeButton.smallWidth
            let textWidth =
                paneWidth - 2 * SettingsMetrics.noticePaddingHorizontal - buttonWidth - SettingsMetrics.noticeGap
            let textHeight = noticeText.height(forWidth: textWidth)
            let buttonHeight = CGFloat(DesignTokens.controlHeights.small)
            let inner = max(textHeight, buttonHeight)
            let height = inner + 2 * SettingsMetrics.noticePaddingVertical
            notice.frame = NSRect(x: sidebarWidth, y: top, width: paneWidth, height: height)
            noticeText.frame = NSRect(
                x: SettingsMetrics.noticePaddingHorizontal,
                y: SettingsMetrics.noticePaddingVertical + ((inner - textHeight) / 2).rounded(), width: textWidth,
                height: textHeight)
            noticeButton.frame = NSRect(
                x: paneWidth - SettingsMetrics.noticePaddingHorizontal - buttonWidth,
                y: SettingsMetrics.noticePaddingVertical + ((inner - buttonHeight) / 2).rounded(), width: buttonWidth,
                height: buttonHeight)
            top += height
        }
        scroll.frame = NSRect(x: sidebarWidth, y: top, width: paneWidth, height: max(0, bounds.height - top))
        arrangePage()
    }

    /// The page: at most 560 wide, centered in the room the padding and the scroll bar's gutter leave.
    func arrangePage() {
        let viewWidth = scroll.contentSize.width
        let room = max(
            0,
            viewWidth - SettingsMetrics.scrollGutter - SettingsMetrics.pagePaddingLeft
                - SettingsMetrics.pagePaddingRight)
        let width = min(SettingsMetrics.pageMaxWidth, room)
        guard let page else {
            document.frame = NSRect(x: 0, y: 0, width: viewWidth, height: 0)
            return
        }
        let height = page.arrange(width: width)
        // The controls lay out their own insides in the frames the page gave them.
        func invalidate(_ view: NSView) {
            view.needsLayout = true
            for child in view.subviews { invalidate(child) }
        }
        invalidate(page)
        page.frame = NSRect(
            x: SettingsMetrics.pagePaddingLeft + ((room - width) / 2).rounded(), y: SettingsMetrics.pagePaddingTop,
            width: width, height: height)
        document.frame = NSRect(
            x: 0, y: 0, width: viewWidth,
            height: SettingsMetrics.pagePaddingTop + height + SettingsMetrics.pagePaddingBottom)
    }

    // MARK: Keyboard

    /// Brings what just got the keyboard into view, as the browser scrolls to a focused element. A press doesn't move
    /// the page, as the browser skips it for a mouse focus.
    func reveal(_ view: NSView, for event: NSEvent.EventType?) {
        guard event != .leftMouseDown, event != .rightMouseDown, event != .otherMouseDown,
            view.isDescendant(of: document)
        else { return }
        let clip = scroll.contentView
        let top = Self.revealedTop(
            of: view.convert(view.bounds, to: document), in: clip.bounds, documentHeight: document.frame.height)
        guard top != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    /// Where the page's top goes for `rect` to show (Blink's CenterIfNeeded for a focused element): what shows whole
    /// stays, what is cut off comes to the near edge, and what is out of sight comes to the middle.
    static func revealedTop(of rect: NSRect, in visible: NSRect, documentHeight: CGFloat) -> CGFloat {
        let top: CGFloat
        if rect.minY >= visible.minY && rect.maxY <= visible.maxY {
            return visible.minY
        } else if rect.maxY <= visible.minY || rect.minY >= visible.maxY {
            top = rect.midY - visible.height / 2
        } else if rect.minY < visible.minY || rect.height >= visible.height {
            top = rect.minY
        } else {
            top = rect.maxY - visible.height
        }
        return min(max(top, 0), max(0, documentHeight - visible.height))
    }

    // MARK: Reading

    var sectionTitles: [String] { items.map(\.tab.label) }
    var title: String { titleText.stringValue }
    var headerShowsLine: Bool { header.edges[.bottom] != nil }
}
