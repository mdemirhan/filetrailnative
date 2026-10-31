// Port of apps/desktop/src/renderer/components/HelpView.tsx and the .help-view rules of styles.css (ui.md section 7.1)
import AppKit
import FTFoundation

/// Help is a list of topics beside one readable column. Each topic explains an area and ends with its shortcuts;
/// "Keyboard shortcuts" lists them all, with the keys they have now, and leads to Settings → Shortcuts to change them.
/// Typing in "Search help" replaces the page with matches from every topic.
@MainActor
public final class HelpView: ThemedView {
    public private(set) var activeTopic: HelpTopicID
    /// Told the page on screen, so that Help can open on it next time.
    public var onTopicChange: ((HelpTopicID) -> Void)?
    /// Opens Settings → Shortcuts. The "Customize…" button is shown only when this is set.
    public var onCustomizeShortcuts: (() -> Void)? { didSet { rebuildPage() } }
    /// The keys the commands have now.
    public var shortcuts: ShortcutDisplay { didSet { rebuildPage() } }
    /// The single-panel layout: set, or from the width of the view while `automaticLayout`.
    public var layoutMode: SinglePanelLayout { didSet { if layoutMode != oldValue { needsLayout = true } } }
    public var automaticLayout: Bool
    /// The window's sidebar runs under the traffic lights: its content starts 52 down.
    public var topInset: CGFloat? { didSet { needsLayout = true } }

    public let searchField: ThemedSearchField
    let sidebar: ThemedView
    private(set) var topicButtons: [HelpTopicButton] = []
    private let scroll = NSScrollView()
    private let document: NSView
    private(set) var page: HelpPageView?

    /// The view itself takes the keyboard when the window opens, not the search field.
    public override var acceptsFirstResponder: Bool { true }

    public var query: String { searchField.text }
    public var isSearching: Bool { !searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(
        shortcuts: ShortcutDisplay = .defaults, layoutMode: SinglePanelLayout? = nil,
        initialTopic: HelpTopicID = .navigation,
        topInset: CGFloat? = nil, theme: Theme = AppearanceModel.shared.theme
    ) {
        self.shortcuts = shortcuts
        self.layoutMode = layoutMode ?? .wide
        automaticLayout = layoutMode == nil
        self.topInset = topInset
        activeTopic = initialTopic
        searchField = ThemedSearchField(placeholder: "Search help", theme: theme)
        sidebar = ThemedView(theme: theme)
        document = FlippedView()
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 680), theme: theme)
        fill = { $0.palette.bgBase }
        sidebar.fill = { $0.palette.sidebarBg }
        sidebar.setAccessibilityIdentifier("help.sidebar")
        searchField.setAccessibilityIdentifier("help.search")
        searchField.onChange = { [weak self] _ in self?.searchChanged() }
        sidebar.addSubview(searchField)
        for topic in HelpContent.topics {
            let button = HelpTopicButton(topic: topic, theme: theme)
            button.target = self
            button.action = #selector(topicClicked(_:))
            topicButtons.append(button)
            sidebar.addSubview(button)
        }
        scroll.drawsBackground = false
        // The content runs under the title bar on its own: no inset for it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.setAccessibilityIdentifier("help.content")
        addSubview(scroll)
        addSubview(sidebar)
        setAccessibilityIdentifier("help")
        setAccessibilityLabel("Help")
        syncTopics()
        rebuildPage()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Topics

    @objc private func topicClicked(_ sender: HelpTopicButton) {
        select(topic: sender.topic.id)
    }

    /// Choosing a topic clears the search and shows the topic; a new page starts at its top.
    public func select(topic: HelpTopicID) {
        searchField.text = ""
        let changed = topic != activeTopic
        activeTopic = topic
        syncTopics()
        rebuildPage()
        scrollToTop()
        if changed { onTopicChange?(topic) }
    }

    /// A topic asked for from outside while Help is open replaces the whole view: the search text and the scroll go.
    public func show(topic: HelpTopicID) {
        searchField.text = ""
        let changed = topic != activeTopic
        activeTopic = topic
        syncTopics()
        rebuildPage()
        scrollToTop()
        if changed { onTopicChange?(topic) }
    }

    /// Tells the page on screen to the listener once, as the view does when it appears.
    public func announceTopic() { onTopicChange?(activeTopic) }

    private func syncTopics() {
        for button in topicButtons { button.isCurrent = !isSearching && button.topic.id == activeTopic }
    }

    private func searchChanged() {
        syncTopics()
        rebuildPage()
        scrollToTop()
    }

    private func rebuildPage() {
        page?.removeFromSuperview()
        let kind: HelpPageKind =
            isSearching
            ? .results(searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)) : .topic(activeTopic)
        let next = HelpPageView(kind: kind, display: shortcuts, theme: theme, onCustomize: onCustomizeShortcuts)
        document.addSubview(next)
        page = next
        next.applyTheme(theme, throughSubviews: true)
        needsLayout = true
    }

    private func scrollToTop() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The topic buttons, as shown.
    public var topicTitles: [String] { topicButtons.map(\.topic.title) }
    /// The topic marked as the page on screen (not while searching).
    public var currentTopic: HelpTopicID? { topicButtons.first(where: \.isCurrent)?.topic.id }
    /// Clicks a topic in the sidebar.
    public func clickTopic(_ id: HelpTopicID) { topicButtons.first { $0.topic.id == id }?.perform() }

    // MARK: Layout

    private static let wideSidebar: CGFloat = 208
    private static let narrowSidebar: CGFloat = 188

    public override func layout() {
        super.layout()
        if automaticLayout, bounds.width > 0 {
            layoutMode = ResponsiveLayout.resolveSinglePanelLayout(width: bounds.width)
        }
        let compact = layoutMode == .compact
        let sidebarTop = topInset ?? 12
        let padding: CGFloat = 10
        let fieldHeight = CGFloat(ThemedSearchField.height)

        if compact {
            // Topics above the page, in a wrapping row.
            let width = bounds.width
            searchField.frame = NSRect(x: padding, y: sidebarTop, width: width - 2 * padding, height: fieldHeight)
            var x = padding
            var y = sidebarTop + fieldHeight + 10
            let rowHeight = CGFloat(HelpTopicButton.height)
            for button in topicButtons {
                let buttonWidth = button.preferredWidth
                if x > padding, x + buttonWidth > width - padding {
                    x = padding
                    y += rowHeight + 4
                }
                button.frame = NSRect(x: x, y: y, width: buttonWidth, height: rowHeight)
                x += buttonWidth + 4
            }
            let sidebarHeight = y + rowHeight + 12 + 1
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: sidebarHeight)
            sidebar.edges = [.bottom: { $0.palette.borderLight }]
            scroll.frame = NSRect(x: 0, y: sidebarHeight, width: width, height: max(0, bounds.height - sidebarHeight))
        } else {
            let sidebarWidth = layoutMode == .narrow ? Self.narrowSidebar : Self.wideSidebar
            sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
            sidebar.edges = [.trailing: { $0.palette.borderLight }]
            // The border takes the last point: the content is 10 in from each side of what is left.
            let contentWidth = sidebarWidth - 2 * padding - 1
            searchField.frame = NSRect(x: padding, y: sidebarTop, width: contentWidth, height: fieldHeight)
            var y = sidebarTop + fieldHeight + 10
            for button in topicButtons {
                button.frame = NSRect(x: padding, y: y, width: contentWidth, height: CGFloat(HelpTopicButton.height))
                y += CGFloat(HelpTopicButton.height) + 1
            }
            scroll.frame = NSRect(
                x: sidebarWidth, y: 0, width: max(0, bounds.width - sidebarWidth), height: bounds.height)
        }
        arrangePage(compact: compact)
    }

    private func arrangePage(compact: Bool) {
        guard let page else { return }
        // padding 22 28 36; 52 above in the window; compact 16 16 28 (which also replaces the window's 52).
        let top: CGFloat = compact ? 16 : (topInset ?? 22)
        let sidePadding: CGFloat = compact ? 16 : 28
        let bottom: CGFloat = compact ? 28 : 36
        let scrollWidth = scroll.contentSize.width
        func column(_ width: CGFloat) -> CGFloat { min(HelpPageView.maxWidth, max(0, width - 2 * sidePadding)) }
        var columnWidth = column(scrollWidth)
        var height = page.arrange(width: columnWidth, compact: compact)
        // The original's scroll bar (8 wide) takes room from the page once it has something to scroll.
        if top + height + bottom > scroll.contentSize.height {
            columnWidth = column(scrollWidth - 8)
            height = page.arrange(width: columnWidth, compact: compact)
        }
        page.frame = NSRect(x: sidePadding, y: top, width: columnWidth, height: height)
        document.frame = NSRect(x: 0, y: 0, width: scrollWidth, height: top + height + bottom)
    }
}

/// A flipped plain view, for the scrolled document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
