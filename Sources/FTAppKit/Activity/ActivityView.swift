// The Activity list under the title's ring: what runs in the background, each with Stop
import AppKit
import FTFoundation

/// The content of the Activity popover: a header, then a row for each thing running or waiting, the file operation
/// first. A row says what it is and how far along, has a bar when how far is known, and Stop.
final class ActivityView: NSView {
    static let width = 320.0
    static let rowHeight = 48.0
    static let headerHeight = 30.0
    /// How long Stop is not taken after a row came to another place: a press aimed at one row's Stop as the row
    /// above it ended would land on the next one's.
    static let settleInterval = 0.4
    private static var inset: Double { DesignTokens.menu.padding + DesignTokens.menu.borderWidth }

    private(set) var items: [ActivityItem]
    var onStop: (ActivityItem) -> Void = { _ in }
    /// The time now, in seconds; a test hands its own.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let title = ClipboardMenuText(identifier: "activityPopover.title")
    private var rows: [ActivityRow] = []
    private var movedAt = -TimeInterval.infinity

    init(items: [ActivityItem]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Activity")
        setAccessibilityIdentifier("activityPopover")
        addSubview(title)
        let palette = AppearanceModel.shared.theme.palette
        title.set("Activity", font: ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600))
        title.textColor = NSColor(palette.contextMenuText)
        update(items)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A row whose item is still listed is kept and told what changed, so a press on its Stop under way, its hover
    /// and VoiceOver's place in it outlast the list's updates, which come several times a second while something
    /// runs. Only the rows of items new to the list are made, and those of items gone removed.
    func update(_ items: [ActivityItem]) {
        self.items = items
        let places = Dictionary(
            rows.enumerated().map { ($0.element.item.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var kept = Dictionary(rows.map { ($0.item.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = false
        rows = items.enumerated().map { index, item in
            if let row = kept.removeValue(forKey: item.id) {
                if places[item.id] != index { moved = true }
                row.update(item)
                return row
            }
            let row = ActivityRow(item: item)
            row.onStop = { [weak self, weak row] in
                guard let self, let row, self.takesStop else { return }
                self.onStop(row.item)
            }
            addSubview(row)
            return row
        }
        for row in kept.values { row.removeFromSuperview() }
        if moved { movedAt = now() }
        needsLayout = true
    }

    /// Whether a press on Stop counts: not just after a row came to another place.
    var takesStop: Bool { now() - movedAt >= Self.settleInterval }

    var listSize: NSSize {
        NSSize(
            width: Self.width,
            height: 2 * Self.inset + Self.headerHeight + Double(items.count) * Self.rowHeight)
    }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width - 2 * inset
        let paddingHorizontal = 10.0
        title.frame = NSRect(
            x: inset + paddingHorizontal, y: inset + (Self.headerHeight - title.lineHeight) / 2,
            width: width - 2 * paddingHorizontal, height: title.lineHeight)
        var y = inset + Self.headerHeight
        for row in rows {
            row.frame = NSRect(x: inset, y: y, width: width, height: Self.rowHeight)
            y += Self.rowHeight
        }
    }
}

/// One thing running or waiting: its name over how far along it is, a bar when that is known, and Stop.
final class ActivityRow: NSView {
    private(set) var item: ActivityItem
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
        guard next != item else { return }
        let hadBar = item.progress != nil
        item = next
        show()
        if hadBar != (next.progress != nil) { needsLayout = true }
    }

    private func show() {
        let palette = AppearanceModel.shared.theme.palette
        name.set(item.title, font: ChromeColors.font(size: DesignTokens.typeScale.body))
        name.textColor = NSColor(item.isWaiting ? palette.contextMenuShortcut : palette.contextMenuText)
        detail.set(item.detail, font: ChromeColors.font(size: DesignTokens.typeScale.small))
        detail.textColor = NSColor(palette.contextMenuShortcut)
        bar.doubleValue = item.progress ?? 0
        bar.isHidden = item.progress == nil
        // Set only when it changes: setting a tooltip takes away the one showing.
        let tip = item.isWaiting ? "Stop Waiting" : "Stop"
        if stop.toolTip != tip { stop.toolTip = tip }
        stop.setAccessibilityLabel("Stop \(item.title)")
        setAccessibilityLabel("\(item.title), \(item.detail)")
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
