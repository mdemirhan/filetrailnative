// Tags…: every tag in use, checked on the selected items, in a popover that stays open while tags are put on and off
import AppKit
import FTFileSystem
import FTFoundation

/// What a choice in the Tags popover does to the items.
enum TagChange: Sendable, Equatable {
    /// The color row's rule for one tag: off every item when all have it, otherwise on those without it.
    case toggle(FinderTag)
    case removeAll
}

/// The tags in use on this Mac, kept for as long as the app runs: shown at once when the popover opens, and asked of
/// Spotlight again each time, as tags are put on items by other apps too.
@MainActor
enum TagCatalog {
    private(set) static var known: [FinderTag] = []
    private static var reading: Task<[FinderTag], Never>?

    /// Asks Spotlight again, once at a time; what it answers becomes `known`.
    static func refresh() async -> [FinderTag] {
        if let reading { return await reading.value }
        let task = Task { await BlockingWork.run(qos: .userInitiated) { FinderTagCatalog.inUse() } }
        reading = task
        let read = await task.value
        reading = nil
        known = read
        return read
    }
}

/// The Tags popover: a filter, the tags as a checklist (✓ on every item, – on some, with how many), and Remove All
/// Tags. A click or Return on a tag writes it at once, as the color row does: there is no Done. Esc, or a click
/// outside, closes it.
@MainActor
final class TagsPopover: NSObject, NSPopoverDelegate {
    /// The one shown: opening another closes it.
    private(set) static var shown: TagsPopover?

    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 24
    static let mostRowsShown = 12

    private let popover = NSPopover()
    let paths: [String]
    private(set) var items: FinderTagsOnItems
    private(set) var allRows: [FinderTagChecklistRow] = []
    private(set) var rows: [FinderTagChecklistRow] = []
    private let colorNames: [FinderTagColor: String]
    /// Every tag the items had while it is open: one taken off them all, and on no other item, stays in the list to
    /// be put back.
    private var seen: [FinderTag] = []
    private let change: @MainActor (TagChange, [String]) async -> FinderTagsOnItems?
    private var writing: Task<Void, Never>?

    let view: TagsPopoverView

    /// `items`: the items' tags as read before it opens. `change` writes a choice and answers the items' tags read
    /// again (nil when they couldn't be).
    init(
        paths: [String], items: FinderTagsOnItems, title: String,
        change: @escaping @MainActor (TagChange, [String]) async -> FinderTagsOnItems?
    ) {
        self.paths = paths
        self.items = items
        self.change = change
        colorNames = Dictionary(uniqueKeysWithValues: FinderTagColor.allCases.map { ($0, $0.systemName) })
        view = TagsPopoverView(title: title)
        super.init()
        view.owner = self
        rebuild(keeping: nil)
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        resize()
    }

    /// Shows it at `rect` of `anchor`, closing the one shown before; then asks Spotlight for the tags in use again.
    func show(relativeTo rect: NSRect, of anchor: NSView) {
        Self.shown?.close()
        guard anchor.window?.isVisible == true else { return }
        Self.shown = self
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
        view.window?.makeFirstResponder(view.filter)
        Task { @MainActor [weak self] in
            _ = await TagCatalog.refresh()
            self?.rebuild(keeping: self?.view.selectedKey)
        }
    }

    func close() {
        popover.close()
        if Self.shown === self { Self.shown = nil }
    }

    var isShown: Bool { popover.isShown }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if Self.shown === self { Self.shown = nil }
        }
    }

    // MARK: Rows

    /// The rows from the items' tags and those in use, narrowed by the filter; the highlighted tag stays highlighted.
    func rebuild(keeping key: String?) {
        for tag in items.tags where !seen.contains(where: { $0.key == tag.key }) { seen.append(tag) }
        allRows = FinderTagChecklist.rows(on: items, inUse: TagCatalog.known + seen, colorNames: colorNames)
        rows = FinderTagChecklist.filter(allRows, by: view.filter.stringValue)
        view.show(rows, itemCount: items.itemCount, hasTags: !items.tags.isEmpty, keeping: key)
        resize()
    }

    func filterChanged() {
        rows = FinderTagChecklist.filter(allRows, by: view.filter.stringValue)
        view.show(rows, itemCount: items.itemCount, hasTags: !items.tags.isEmpty, keeping: nil)
        // Return then takes the first that matches.
        if !view.filter.stringValue.isEmpty, !rows.isEmpty { view.select(0) }
    }

    /// The list is as tall as every tag needs, up to `mostRowsShown`, whatever the filter leaves: it doesn't jump.
    private func resize() {
        let shownRows = min(max(allRows.count, 1), Self.mostRowsShown)
        let size = TagsPopoverView.size(rows: shownRows)
        popover.contentSize = size
        if !popover.isShown { view.frame.size = size }
    }

    // MARK: Choosing

    /// A tag was clicked, or Return pressed on it: shown changed at once, written after the writes before it.
    func choose(_ row: FinderTagChecklistRow) {
        let key = row.tag.key
        items.counts[key] = row.count == items.itemCount ? nil : items.itemCount
        if items.counts[key] != nil, !items.tags.contains(where: { $0.key == key }) { items.tags.append(row.tag) }
        if items.counts[key] == nil { items.tags.removeAll { $0.key == key } }
        rebuild(keeping: key)
        write(.toggle(row.tag), keeping: key)
    }

    func removeAll() {
        items.counts = [:]
        items.tags = []
        rebuild(keeping: view.selectedKey)
        write(.removeAll, keeping: view.selectedKey)
    }

    private func write(_ choice: TagChange, keeping key: String?) {
        let previous = writing
        writing = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            guard let read = await self.change(choice, self.paths) else { return }
            self.items = read
            self.rebuild(keeping: self.view.selectedKey ?? key)
        }
    }

    /// The writes asked for so far, done (tests).
    func waitForWrites() async {
        await writing?.value
    }
}

/// The popover's content: its title, the filter, the checklist and the foot.
@MainActor
final class TagsPopoverView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var owner: TagsPopover?
    let title: NSTextField
    let filter = NSSearchField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    let removeAllButton = NSButton(title: "Remove All Tags", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "↑↓ to move, ↩ to apply")
    private var rows: [FinderTagChecklistRow] = []
    private var itemCount = 1

    static let inset: CGFloat = 10
    static let titleHeight: CGFloat = 18
    static let filterHeight: CGFloat = 24
    static let footHeight: CGFloat = 28

    static func size(rows: Int) -> NSSize {
        NSSize(
            width: TagsPopover.width,
            height: inset + titleHeight + 8 + filterHeight + 8 + CGFloat(rows) * TagsPopover.rowHeight + 8 + footHeight
                + 4)
    }

    init(title text: String) {
        title = NSTextField(labelWithString: text)
        super.init(frame: NSRect(origin: .zero, size: Self.size(rows: 1)))
        setAccessibilityIdentifier("tagsPopover")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityIdentifier("tagsPopover.title")
        filter.placeholderString = "Filter Tags"
        filter.delegate = self
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityIdentifier("tagsPopover.filter")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = TagsPopover.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("tagsPopover.list")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        removeAllButton.bezelStyle = .accessoryBarAction
        removeAllButton.controlSize = .small
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAllPressed)
        removeAllButton.setAccessibilityIdentifier("tagsPopover.removeAll")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        for subview in [title, filter, scroll, removeAllButton, hint] { addSubview(subview) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let width = bounds.width - 2 * inset
        var y = inset
        title.frame = NSRect(x: inset, y: y, width: width, height: Self.titleHeight)
        y += Self.titleHeight + 8
        filter.frame = NSRect(x: inset, y: y, width: width, height: Self.filterHeight)
        y += Self.filterHeight + 8
        let listHeight = max(0, bounds.height - y - 8 - Self.footHeight - 4)
        scroll.frame = NSRect(x: inset - 4, y: y, width: width + 8, height: listHeight)
        table.tableColumns.first?.width = scroll.contentSize.width
        y += listHeight + 8
        let buttonWidth = removeAllButton.intrinsicContentSize.width
        removeAllButton.frame = NSRect(x: inset, y: y + 2, width: buttonWidth, height: Self.footHeight - 4)
        hint.frame = NSRect(
            x: inset + buttonWidth + 8, y: y + 6, width: max(0, width - buttonWidth - 8), height: Self.footHeight - 8)
    }

    // MARK: Rows

    func show(_ rows: [FinderTagChecklistRow], itemCount: Int, hasTags: Bool, keeping key: String?) {
        self.rows = rows
        self.itemCount = itemCount
        removeAllButton.isEnabled = hasTags
        table.reloadData()
        if let key, let index = rows.firstIndex(where: { $0.tag.key == key }) {
            select(index)
        } else {
            table.deselectAll(nil)
        }
    }

    func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    var selectedKey: String? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].tag.key : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: TagChecklistCell.identifier, owner: nil) as? TagChecklistCell
            ?? TagChecklistCell()
        cell.show(rows[row], itemCount: itemCount)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = TagChecklistRowView()
        // A line between one's own tags and the seven colors.
        view.lineAbove = row > 0 && rows[row].isColor && !rows[row - 1].isColor
        return view
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row) else { return }
        owner?.choose(rows[row])
    }

    @objc private func removeAllPressed() {
        owner?.removeAll()
    }

    // MARK: The filter

    func controlTextDidChange(_ notification: Notification) {
        owner?.filterChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            select(table.selectedRow < 0 ? 0 : min(rows.count - 1, table.selectedRow + 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(table.selectedRow < 0 ? rows.count - 1 : max(0, table.selectedRow - 1))
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if rows.indices.contains(table.selectedRow) { owner?.choose(rows[table.selectedRow]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if filter.stringValue.isEmpty {
                owner?.close()
            } else {
                filter.stringValue = ""
                owner?.filterChanged()
            }
            return true
        default:
            return false
        }
    }
}

/// A tag of the checklist: ✓ on every item, – on some, then its dot (a ring for none), its name and, when on some,
/// how many.
@MainActor
final class TagChecklistCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("tagChecklistCell")
    let mark = NSTextField(labelWithString: "")
    let dot = TagDotView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        mark.font = .systemFont(ofSize: 12, weight: .bold)
        mark.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        for subview in [mark, dot, name, count] as [NSView] { addSubview(subview) }
        textField = name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ row: FinderTagChecklistRow, itemCount: Int) {
        let all = row.count > 0 && row.count == itemCount
        mark.stringValue = all ? "✓" : row.count > 0 ? "–" : ""
        dot.color = row.tag.color
        name.stringValue = row.tag.name
        count.stringValue = row.count > 0 && !all ? "\(row.count) of \(itemCount)" : ""
        setAccessibilityIdentifier("tagsPopover.row")
        setAccessibilityLabel(row.tag.name)
        setAccessibilityValue(all ? "On all" : row.count > 0 ? "On \(row.count) of \(itemCount)" : "Off")
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { dot.emphasized = backgroundStyle == .emphasized }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let line: CGFloat = 17
        let y = (height - line) / 2
        mark.frame = NSRect(x: 4, y: y, width: 16, height: line)
        dot.frame = NSRect(x: 24, y: (height - 10) / 2, width: 10, height: 10)
        let countWidth = count.stringValue.isEmpty ? 0 : ceil(count.intrinsicContentSize.width) + 4
        count.frame = NSRect(x: bounds.width - 6 - countWidth, y: y + 1, width: countWidth, height: line)
        name.frame = NSRect(x: 40, y: y, width: max(0, count.frame.minX - 46), height: line)
    }
}

/// A tag's dot in the checklist: its color, or a ring for a tag without one.
@MainActor
final class TagDotView: NSView {
    var color: FinderTagColor? {
        didSet { needsDisplay = true }
    }
    var emphasized = false {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if let color {
            color.dotColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
            if emphasized {
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            }
        } else {
            (emphasized ? NSColor.white : NSColor.secondaryLabelColor).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

/// A row of the checklist: highlighted in the accent though the filter keeps the keyboard, with a line above the
/// first of the seven colors.
final class TagChecklistRowView: NSTableRowView {
    var lineAbove = false

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard lineAbove else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 6, y: 0, width: bounds.width - 12, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

extension MainWindowController {
    /// File ▸ Tags… and its key: the items selected in the list.
    func editTags() {
        editTags(content.selection.paths)
    }

    /// The Tags popover for `paths`, at the lead item of the selection in the list (the first of `paths` when the
    /// lead isn't among them), or at `anchor` when one was clicked (the Info panel's row), or at the top of the list
    /// when the item is not on screen. Nothing for items in the Trash, whichever way it was asked.
    func editTags(_ paths: [String], from anchor: NSView? = nil) {
        guard !paths.isEmpty, !paths.contains(where: { Paths.isInsideTrash($0, homePath: trashHomePath) }) else {
            return
        }
        let title =
            paths.count == 1
            ? "Tags for \u{201C}\(ClipboardSummary.leafName(paths[0]))\u{201D}"
            : "Tags for \(FormatLocale.count(paths.count)) Items"
        let coordinator = contextMenus
        Task { @MainActor [weak self] in
            let items = await BlockingWork.run(qos: .userInitiated) { FinderTags.onItems(paths) }
            guard let self else { return }
            let popover = TagsPopover(paths: paths, items: items, title: title) { choice, paths in
                await coordinator.changeTags(choice, paths: paths)
            }
            if let place = self.tagsPopoverPlace(for: paths, anchor: anchor) {
                popover.show(relativeTo: place.rect, of: place.view)
            }
            self.shownTagsPopover?(popover)
        }
    }

    /// Where the popover hangs: `anchor`, the lead item in the list, or the top of the list. An anchor's place is taken
    /// in the window's content, which stays: the Info panel builds its rows again as the tags change, and a popover
    /// hung from the row it took away would close with it.
    private func tagsPopoverPlace(for paths: [String], anchor: NSView?) -> (rect: NSRect, view: NSView)? {
        if let anchor, let host = anchor.window?.contentView {
            return (anchor.convert(anchor.bounds, to: host), host)
        }
        guard let window, let list = content.view.window == nil ? nil : content.view else { return nil }
        let lead =
            content.selection.leadPath.flatMap { lead in
                paths.contains { DiskPath($0) == DiskPath(lead) } ? lead : nil
            } ?? paths[0]
        let visible = list.visibleRect
        if let itemFrame = QuickLookItemFrame.screenFrame(of: lead, entries: content.entries, in: content.view) {
            let rect = list.convert(window.convertFromScreen(itemFrame), from: nil)
            if rect.intersects(visible) { return (rect.intersection(visible), list) }
        }
        let top = list.isFlipped ? visible.minY : visible.maxY - 1
        return (NSRect(x: visible.midX, y: top, width: 1, height: 1), list)
    }
}
