// The Undo History list under its toolbar button, in a system popover: what Redo and Undo would do, newest nearest the
// middle, and what the history starts after. It only shows: nothing in it can be clicked.
import AppKit
import FTFoundation
import FTOperations

/// The content of the Undo History popover: a header, then a list that scrolls past `maxListHeight`, holding the Redo
/// operations, the Undo operations and, under the oldest, what can't be undone. Each row's tooltip lists its items.
final class UndoHistoryView: NSView {
    static let width = 360.0
    static let rowHeight = 38.0
    static let headingHeight = 24.0
    static let noteHeight = 22.0
    static let maxListHeight = 420.0
    private static let paddingHorizontal = 10.0
    private static let iconSize = 16.0
    private static let iconGap = 8.0

    private(set) var content: UndoHistoryContent
    /// "⌘Z" and "⇧⌘Z", after the headings.
    private let undoKey: String?
    private let redoKey: String?
    private let title = ClipboardMenuText(identifier: "undoHistoryPopover.title")
    private let subtitle = ClipboardMenuText(identifier: "undoHistoryPopover.subtitle")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var now: () -> Date

    private static var inset: Double { DesignTokens.menu.padding + DesignTokens.menu.borderWidth }
    private static var separatorHeight: Double {
        DesignTokens.menu.separatorHeight + 2 * DesignTokens.menu.separatorMarginVertical
    }

    init(content: UndoHistoryContent, undoKey: String?, redoKey: String?, now: @escaping () -> Date = { AppClock.now })
    {
        self.content = content
        self.undoKey = undoKey
        self.redoKey = redoKey
        self.now = now
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Undo History")
        setAccessibilityIdentifier("undoHistoryPopover")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = list
        list.setAccessibilityIdentifier("undoHistoryPopover.list")
        for view in [title, subtitle, scroll] as [NSView] { addSubview(view) }
        update(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Contents

    /// The history changed while the list is open.
    func update(_ content: UndoHistoryContent) {
        self.content = content
        let palette = AppearanceModel.shared.theme.palette
        title.set("Undo History", font: ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600))
        title.textColor = NSColor(palette.contextMenuText)
        subtitle.set(
            "In every window, until File Trail quits", font: ChromeColors.font(size: DesignTokens.typeScale.small))
        subtitle.textColor = NSColor(palette.contextMenuShortcut)
        fillList()
        needsLayout = true
    }

    /// The rows, top to bottom, and the list's height.
    private func fillList() {
        for view in list.subviews { view.removeFromSuperview() }
        let width = Self.width - 2 * Self.inset
        var y = 0.0
        func add(_ view: NSView, height: Double) {
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            list.addSubview(view)
            y += height
        }
        let date = now()
        if !content.redo.isEmpty {
            add(UndoHistoryHeading("Redo", key: redoKey), height: Self.headingHeight)
            if content.redoMore > 0 {
                add(UndoHistoryNote("and \(content.redoMore) more"), height: Self.noteHeight)
            }
            for row in content.redo { add(UndoHistoryRowView(row, undone: true, now: date), height: Self.rowHeight) }
        }
        if !content.undo.isEmpty {
            add(UndoHistoryHeading("Undo", key: undoKey), height: Self.headingHeight)
            for row in content.undo { add(UndoHistoryRowView(row, undone: false, now: date), height: Self.rowHeight) }
            if content.undoMore > 0 {
                add(UndoHistoryNote("and \(content.undoMore) earlier"), height: Self.noteHeight)
            }
        }
        if let barrier = content.barrier {
            add(UndoHistoryBarrierView(barrier, now: date), height: Self.rowHeight)
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: y)
    }

    private var headerHeight: Double {
        2 * ClipboardLayout.Menu.headerPaddingVertical + title.lineHeight + subtitle.lineHeight
            + ClipboardLayout.Menu.breakdownPaddingBottom
    }

    private var listHeight: Double { min(Self.maxListHeight, list.frame.height) }

    /// 360 wide, or the window's width less 16 if that is less; as tall as the list, up to `maxListHeight` of it.
    func fittingSize(viewportWidth: Double) -> NSSize {
        let width = min(
            Self.width, max(ClipboardLayout.Menu.minWidth, viewportWidth - ClipboardLayout.Menu.viewportInset))
        return NSSize(width: width, height: 2 * Self.inset + headerHeight + Self.separatorHeight + listHeight)
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width - 2 * inset
        let padding = ClipboardLayout.Menu.headerPaddingHorizontal
        var y = inset + ClipboardLayout.Menu.headerPaddingVertical
        title.frame = NSRect(
            x: inset + padding, y: y, width: max(0, min(title.textWidth, width - 2 * padding)),
            height: title.lineHeight)
        y += title.lineHeight
        subtitle.frame = NSRect(
            x: inset + padding, y: y, width: max(0, width - 2 * padding), height: subtitle.lineHeight)
        y +=
            subtitle.lineHeight + ClipboardLayout.Menu.breakdownPaddingBottom
            + ClipboardLayout.Menu.headerPaddingVertical
        y += Self.separatorHeight
        scroll.frame = NSRect(x: inset, y: y, width: width, height: max(0, bounds.height - y - inset))
        list.frame.size.width = scroll.contentSize.width
        for view in list.subviews { view.frame.size.width = list.frame.width }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let margin = DesignTokens.menu.separatorMarginHorizontal
        NSColor(palette.contextMenuSeparator).setFill()
        NSRect(
            x: Self.inset + margin,
            y: scroll.frame.minY - Self.separatorHeight + DesignTokens.menu.separatorMarginVertical,
            width: bounds.width - 2 * Self.inset - 2 * margin, height: DesignTokens.menu.separatorHeight
        ).fill()
    }

    /// The tooltip of a row: where its items were, the items, and when, to the second.
    static func tooltip(_ row: UndoHistoryRow, undone: Bool) -> String {
        var lines: [String] = []
        if let paths = row.placePaths { lines.append(paths.prefix(1).uppercased() + paths.dropFirst()) }
        lines += row.items
        lines.append("\(undone ? "Undone" : "Done") \(DateText.shared.exactDateTime(row.date))")
        return lines.joined(separator: "\n")
    }

    // MARK: Pieces

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// "Redo" or "Undo", with its key at the trailing side.
    final class UndoHistoryHeading: NSView {
        private let label = ClipboardMenuText(identifier: "undoHistoryPopover.heading")
        private let key = ClipboardMenuText(identifier: "undoHistoryPopover.heading.key")

        init(_ text: String, key shortcut: String?) {
            super.init(frame: .zero)
            let palette = AppearanceModel.shared.theme.palette
            label.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600))
            label.textColor = NSColor(palette.contextMenuShortcut)
            key.set(shortcut ?? "", font: ChromeColors.font(size: DesignTokens.typeScale.small))
            key.textColor = NSColor(palette.contextMenuShortcut)
            addSubview(label)
            addSubview(key)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text)
            setAccessibilityIdentifier("undoHistoryPopover.heading.\(text.lowercased())")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let padding = UndoHistoryView.paddingHorizontal
            let y = (bounds.height - label.lineHeight) / 2
            key.frame = NSRect(
                x: bounds.width - padding - key.textWidth, y: y, width: key.textWidth, height: key.lineHeight)
            label.frame = NSRect(
                x: padding, y: y, width: max(0, key.frame.minX - 2 * padding), height: label.lineHeight)
        }
    }

    /// "and 12 more".
    final class UndoHistoryNote: NSView {
        private let label = ClipboardMenuText(identifier: "undoHistoryPopover.more")

        init(_ text: String) {
            super.init(frame: .zero)
            label.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.small))
            label.textColor = NSColor(AppearanceModel.shared.theme.palette.contextMenuShortcut)
            addSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let x = UndoHistoryView.paddingHorizontal + UndoHistoryView.iconSize + UndoHistoryView.iconGap
            label.frame = NSRect(
                x: x, y: (bounds.height - label.lineHeight) / 2, width: max(0, bounds.width - x),
                height: label.lineHeight)
        }
    }

    /// An icon, a first line and a second, smaller one: an operation, or what can't be undone.
    class TwoLineRow: NSView {
        let icon: SymbolIconView
        let first = ClipboardMenuText(identifier: "undoHistoryPopover.row.title")
        let second = ClipboardMenuText(identifier: "undoHistoryPopover.row.detail")

        init(symbol: String, first text: String, second detail: String, dimmed: Bool) {
            icon = SymbolIconView(symbol)
            super.init(frame: .zero)
            let palette = AppearanceModel.shared.theme.palette
            let main = NSColor(dimmed ? palette.contextMenuShortcut : palette.contextMenuText)
            icon.color = main
            first.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.body))
            first.textColor = main
            second.set(detail, font: ChromeColors.font(size: DesignTokens.typeScale.small))
            second.textColor = NSColor(palette.contextMenuShortcut)
            for view in [icon, first, second] as [NSView] { addSubview(view) }
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel("\(text), \(detail)")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            let padding = UndoHistoryView.paddingHorizontal
            let size = UndoHistoryView.iconSize
            icon.frame = NSRect(x: padding, y: (bounds.height - size) / 2, width: size, height: size)
            let x = icon.frame.maxX + UndoHistoryView.iconGap
            let width = max(0, bounds.width - x - padding)
            let top = (bounds.height - first.lineHeight - second.lineHeight) / 2
            first.frame = NSRect(x: x, y: top, width: min(width, first.textWidth), height: first.lineHeight)
            second.frame = NSRect(
                x: x, y: top + first.lineHeight, width: min(width, second.textWidth), height: second.lineHeight)
        }
    }

    /// An operation: what the Edit menu calls it, where and when; its tooltip lists its items.
    final class UndoHistoryRowView: TwoLineRow {
        let row: UndoHistoryRow

        init(_ row: UndoHistoryRow, undone: Bool, now: Date) {
            self.row = row
            let when = DateText.shared.relative(row.date, now: now)
            super.init(
                symbol: row.icon.symbolName, first: row.title,
                second: [row.place, when].compactMap { $0 }.joined(separator: " · "), dimmed: undone)
            toolTip = UndoHistoryView.tooltip(row, undone: undone)
            setAccessibilityIdentifier(undone ? "undoHistoryPopover.redoRow" : "undoHistoryPopover.undoRow")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// What can't be undone, under the oldest operation.
    final class UndoHistoryBarrierView: TwoLineRow {
        init(_ barrier: UndoBarrier, now: Date) {
            let when = DateText.shared.relative(barrier.date, now: now)
            super.init(
                symbol: "lock", first: UndoHistoryRows.barrierTitle(barrier),
                second: "\(UndoHistoryRows.barrierReason(barrier)) · \(when)", dimmed: true)
            toolTip = DateText.shared.exactDateTime(barrier.date)
            setAccessibilityIdentifier("undoHistoryPopover.barrier")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
