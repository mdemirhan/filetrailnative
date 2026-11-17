// The Activity list under the title's ring: what runs in the background, each with Stop
import AppKit
import FTFoundation

/// The content of the Activity popover: a header, then a row for each thing running or waiting, the file operation
/// first. A row says what it is and how far along, has a bar when how far is known, and Stop.
///
/// While the list is open no row changes place, so a press aimed at one row's Stop never lands on another's: a row
/// whose item ended stays where it was, dimmed, saying how it ended, with no Stop; one whose turn came says so where it
/// is; and what is new goes to the end. The list opened again shows only what runs, in its usual order.
final class ActivityView: NSView {
    static let width = 320.0
    static let rowHeight = 48.0
    static let headerHeight = 30.0
    /// The rows it shows at once: with more, the rows scroll under the header, so a long list stays a short one.
    static let visibleRows = 6
    private static var inset: Double { DesignTokens.menu.padding + DesignTokens.menu.borderWidth }

    private(set) var items: [ActivityItem]
    var onStop: (ActivityItem) -> Void = { _ in }
    /// How what a row listed ended, once it is no longer listed (nil: not known).
    var outcome: (ActivityItem) -> ActivityOutcome? = { _ in nil }
    private let title = ClipboardMenuText(identifier: "activityPopover.title")
    private(set) var rows: [ActivityRow] = []
    let scroll = NSScrollView()
    private let rowsView = FlippedView()

    init(items: [ActivityItem]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Activity")
        setAccessibilityIdentifier("activityPopover")
        addSubview(title)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.documentView = rowsView
        addSubview(scroll)
        let palette = AppearanceModel.shared.theme.palette
        title.set("Activity", font: ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600))
        title.textColor = NSColor(palette.contextMenuText)
        update(items)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A row whose item is still listed is kept and told what changed, so a press on its Stop under way, its hover
    /// and VoiceOver's place in it outlast the list's updates, which come several times a second while something
    /// runs. A row whose item is no longer listed says how it ended, where it is; the rows of items new to the list
    /// are added after the others.
    func update(_ items: [ActivityItem]) {
        self.items = items
        let listed = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shown = Set<String>()
        for row in rows {
            if let item = listed[row.item.id] {
                row.update(item)
                shown.insert(item.id)
            } else {
                row.end(ActivityList.endedDetail(row.item.kind, outcome(row.item)))
            }
        }
        for item in items where shown.insert(item.id).inserted {
            let row = ActivityRow(item: item)
            row.onStop = { [weak self, weak row] in
                guard let self, let row, !row.isEnded else { return }
                self.onStop(row.item)
            }
            rowsView.addSubview(row)
            rows.append(row)
        }
        needsLayout = true
    }

    /// Its size: a row for everything it has listed since it opened, up to `visibleRows` of them.
    var listSize: NSSize {
        NSSize(
            width: Self.width,
            height: 2 * Self.inset + Self.headerHeight + Double(min(rows.count, Self.visibleRows)) * Self.rowHeight)
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width - 2 * inset
        let paddingHorizontal = 10.0
        title.frame = NSRect(
            x: inset + paddingHorizontal, y: inset + (Self.headerHeight - title.lineHeight) / 2,
            width: width - 2 * paddingHorizontal, height: title.lineHeight)
        let top = inset + Self.headerHeight
        scroll.frame = NSRect(x: inset, y: top, width: width, height: max(0, bounds.height - top - inset))
        // The rows keep their places, and where the list was scrolled to, as rows are added.
        rowsView.frame = NSRect(
            x: 0, y: 0, width: width, height: max(scroll.frame.height, Double(rows.count) * Self.rowHeight))
        var y = 0.0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        if rows.count > Self.visibleRows { scroll.flashScrollers() }
    }
}

/// One thing running or waiting: its name over how far along it is, a bar when that is known, and Stop.
final class ActivityRow: NSView {
    private(set) var item: ActivityItem
    /// What it says once its item is no longer listed (nil: it is listed).
    private(set) var endedDetail: String?
    var isEnded: Bool { endedDetail != nil }
    var onStop: () -> Void = {}
    private let name = ClipboardMenuText(identifier: "activityPopover.name")
    private let detail = ClipboardMenuText(identifier: "activityPopover.detail")
    private let bar = NSProgressIndicator()
    let stop = ClearButton()

    init(item: ActivityItem) {
        self.item = item
        super.init(frame: .zero)
        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityIdentifier("activityPopover.progress")
        stop.setAccessibilityIdentifier("activityPopover.stop")
        stop.target = self
        stop.action = #selector(stopPressed)
        for view in [name, detail, bar, stop] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("activityPopover.row")
        show()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The item moved on: the row says so, staying the view it was.
    func update(_ next: ActivityItem) {
        guard next != item || isEnded else { return }
        item = next
        endedDetail = nil
        show()
    }

    /// The item is no longer listed: the row stays, dimmed, saying how it ended, with nothing to stop.
    func end(_ detail: String) {
        guard endedDetail != detail else { return }
        endedDetail = detail
        show()
    }

    private func show() {
        let palette = AppearanceModel.shared.theme.palette
        let dimmed = item.isWaiting || isEnded
        name.set(item.title, font: ChromeColors.font(size: DesignTokens.typeScale.body))
        name.textColor = NSColor(dimmed ? palette.contextMenuShortcut : palette.contextMenuText)
        let text = endedDetail ?? item.detail
        detail.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.small))
        detail.textColor = NSColor(palette.contextMenuShortcut)
        let hadBar = !bar.isHidden
        bar.doubleValue = item.progress ?? 0
        bar.isHidden = item.progress == nil || isEnded
        if hadBar == bar.isHidden { needsLayout = true }
        stop.isHidden = isEnded
        // Set only when it changes: setting a tooltip takes away the one showing.
        let tip = item.isWaiting ? "Stop Waiting" : "Stop"
        if stop.toolTip != tip { stop.toolTip = tip }
        stop.setAccessibilityLabel("Stop \(item.title)")
        setAccessibilityLabel("\(item.title), \(text)")
    }

    @objc private func stopPressed() { onStop() }

    override func layout() {
        super.layout()
        let padding = 10.0
        let stopSize = ClearButton.size
        stop.frame = NSRect(
            x: bounds.width - padding - stopSize, y: (bounds.height - stopSize) / 2, width: stopSize,
            height: stopSize)
        let textWidth = max(0, stop.frame.minX - 8 - padding)
        let gap = 2.0
        let barHeight = bar.isHidden ? 0 : 6.0
        let total = name.lineHeight + gap + detail.lineHeight + (bar.isHidden ? 0 : gap + barHeight)
        var y = (bounds.height - total) / 2
        name.frame = NSRect(x: padding, y: y, width: textWidth, height: name.lineHeight)
        y += name.lineHeight + gap
        detail.frame = NSRect(x: padding, y: y, width: textWidth, height: detail.lineHeight)
        y += detail.lineHeight + gap
        bar.frame = NSRect(x: padding, y: y, width: textWidth, height: barHeight)
    }
}
