// Port of DetailsView (apps/desktop/src/renderer/components/ContentPane.tsx:1450-1893): the List view, an NSTableView with
// one wide column whose cells are laid out by hand
import AppKit
import FTFileSystem
import FTFoundation

/// The table. It asks the pane for a row's menu, and lets the pane know when it gains or loses the keyboard (a selected
/// row is grey in a list that doesn't have it).
final class ListTableView: NSTableView {
    weak var pane: ListViewController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { pane?.keyboardChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { pane?.keyboardChanged(false) }
        return accepted
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        pane?.menu(forEventAt: convert(event.locationInWindow, from: nil))
    }

    override var isFlipped: Bool { true }
}

/// The List view's root: the column header above the rows.
final class ListRootView: NSView {
    weak var pane: ListViewController?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        pane?.layoutPane()
    }
}

/// The header's strip (`.details-header-shell`): the line under it, and the header clipped to it.
final class DetailsHeaderShell: NSView {
    var lineColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var lineWidth: CGFloat = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        NSRect(x: 0, y: bounds.height - lineWidth, width: bounds.width, height: lineWidth).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        for child in subviews.reversed() {
            if let hit = child.hitTest(local) { return hit }
        }
        return nil
    }
}

final class ListViewController: NSViewController, FolderPane, NSTableViewDataSource, NSTableViewDelegate {
    var host: (any ContentPaneHost)? {
        didSet { refreshLook() }
    }

    private let root = ListRootView()
    private let headerShell = DetailsHeaderShell()
    private let header = DetailsHeaderView()
    private let scroll = NSScrollView()
    private let table = ListTableView()
    private let column = NSTableColumn(identifier: DetailsCellView.identifier)

    private var entries: [DirectoryEntry] = []
    /// Rows by path, made when a selection or a lookup needs it.
    private var rowsCache: [String: Int]?
    private var rowByPath: [String: Int] {
        if let rowsCache { return rowsCache }
        let made = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        rowsCache = made
        return made
    }
    private var fitted = DetailsColumnSet(columns: [.name], widths: [:])
    private var layoutMetrics = DesignTokens.details(density: .comfortable)
    private var isSyncing = false
    private var clockRelease: RelativeClock.Release?
    private var minuteHold: RelativeClock.Release?
    private var scrollObserver: (any NSObjectProtocol)?
    private var metadataWork: DispatchWorkItem?

    var focusView: NSView { table }

    /// The list keeps its column header above the rows, so the states below it start under the header.
    var contentTopInset: Double { layoutMetrics.headerHeight }

    override func loadView() {
        root.pane = self
        table.pane = self
        table.style = .plain
        table.headerView = nil
        table.rowHeight = CGFloat(layoutMetrics.rowHeight)
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsTypeSelect = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        column.minWidth = 1
        column.maxWidth = 100_000
        column.resizingMask = []
        table.addTableColumn(column)
        table.setAccessibilityIdentifier("list.table")

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }

        headerShell.clipsToBounds = true
        headerShell.addSubview(header)
        header.onSort = { [weak self] column in self?.sortRequested(column) }
        header.onBegin = { [weak self] column in self?.beginResize(column) ?? (0, [:]) }
        header.onDrag = { [weak self] column, width, saved in self?.resize(column, to: width, from: saved) }
        header.onNudge = { [weak self] column, direction in self?.nudge(column, direction) }
        header.onFit = { [weak self] column in self?.fitToContent(column) }
        root.addSubview(scroll)
        root.addSubview(headerShell)
        view = root
        clockRelease = RelativeClock.shared.subscribe { [weak self] in self?.clockTicked() }
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        clockRelease?()
        minuteHold?()
    }

    // MARK: Pane

    private var metrics: DetailsLayout {
        DesignTokens.details(density: host?.columnState.density ?? .comfortable)
    }

    func reload(scrollToTop: Bool) {
        entries = host?.entries ?? []
        rowsCache = nil
        layoutMetrics = metrics
        table.rowHeight = CGFloat(layoutMetrics.rowHeight)
        fitColumns()
        configureHeader()
        isSyncing = true
        table.reloadData()
        mirrorSort()
        isSyncing = false
        applySelection()
        if scrollToTop, !entries.isEmpty { table.scrollRowToVisible(0) }
        updateMinuteHold()
        requestMetadata()
    }

    func refresh(paths: Set<String>?) {
        guard let paths else {
            forEachVisibleBar { $0.refreshCells() }
            updateMinuteHold()
            return
        }
        for path in paths {
            if let row = rowByPath[path], let bar = bar(atRow: row) { bar.refreshCells() }
        }
        updateMinuteHold()
    }

    func syncSelection() {
        applySelection()
    }

    func refreshLook() {
        configureHeader()
        forEachVisibleBar { $0.refreshCells() }
    }

    func columnsChanged() {
        let density = host?.columnState.density
        if density != nil, DesignTokens.details(density: density ?? .comfortable) != layoutMetrics {
            reload(scrollToTop: false)
            return
        }
        fitColumns()
        configureHeader()
        reconfigureVisibleBars()
        requestMetadata()
    }

    func reveal(paths: [String]) {
        guard let row = paths.compactMap({ rowByPath[$0] }).min() else { return }
        table.scrollRowToVisible(row)
    }

    /// Whether the table has the keyboard (a selection is grey in a list that doesn't).
    private(set) var hasKeyboard = false

    func keyboardChanged(_ has: Bool) {
        hasKeyboard = has
        forEachVisibleBar { $0.refreshCells() }
    }

    // MARK: Layout

    func layoutPane() {
        let width = root.bounds.width
        let height = root.bounds.height
        let headerHeight = CGFloat(layoutMetrics.headerHeight)
        headerShell.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        headerShell.lineWidth = CGFloat(layoutMetrics.headerBorderWidth)
        scroll.frame = NSRect(x: 0, y: headerHeight, width: width, height: max(0, height - headerHeight))
        let before = fitted
        fitColumns()
        if fitted != before {
            configureHeader()
            reconfigureVisibleBars()
        }
        positionHeader()
        requestMetadata()
    }

    /// The columns fitted to the pane: in a narrow pane Name gives up width and then columns drop away from the
    /// right, instead of the table scrolling sideways (B-VIEW-044, B-VIEW-045).
    private func fitColumns() {
        let state = host?.columnState ?? .standard
        let available = max(0, root.bounds.width - layoutMetrics.scrollbarAllowance - 2 * layoutMetrics.rowInset)
        fitted = DetailsColumns.fit(
            columns: state.columns, widths: state.widths, availableWidth: available, layout: layoutMetrics)
        let table = DetailsColumns.tableWidth(widths: fitted.widths, columns: fitted.columns, layout: layoutMetrics)
        let documentWidth = max(root.bounds.width, table + 2 * layoutMetrics.rowInset)
        column.width = documentWidth
        column.minWidth = documentWidth
        column.maxWidth = documentWidth
    }

    /// The header is as wide as the table, at least the pane; it follows the rows' horizontal scroll.
    private func positionHeader() {
        let inset = CGFloat(layoutMetrics.rowInset)
        let table = DetailsColumns.tableWidth(widths: fitted.widths, columns: fitted.columns, layout: layoutMetrics)
        let width = max(CGFloat(table), root.bounds.width - 2 * inset)
        header.frame = NSRect(
            x: inset - scroll.contentView.bounds.origin.x, y: 0, width: width, height: headerShell.bounds.height)
    }

    private func configureHeader() {
        guard let host else { return }
        headerShell.lineColor = NSColor(host.theme.palette.borderLight)
        header.configure(
            fitted: fitted, sortBy: host.sortBy, sortDirection: host.sortDirection, search: false, theme: host.theme,
            layout: layoutMetrics)
        positionHeader()
    }

    private func scrolled() {
        positionHeader()
        requestMetadata()
    }

    // MARK: Rows

    private func bar(atRow row: Int) -> DetailsBarView? {
        guard row >= 0, row < table.numberOfRows,
            let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? DetailsRowView
        else { return nil }
        return rowView.cellView?.bar
    }

    private func forEachVisibleBar(_ body: (DetailsBarView) -> Void) {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            if let bar = bar(atRow: row) { body(bar) }
        }
    }

    private func reconfigureVisibleBars() {
        guard let host else { return }
        let selected = table.selectedRowIndexes
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) where entries.indices.contains(row) {
            bar(atRow: row)?.configure(
                entry: entries[row], row: row, selected: selected.contains(row), host: host, fitted: fitted,
                layout: layoutMetrics)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("details.row")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? DetailsRowView { return reused }
        let made = DetailsRowView()
        made.identifier = id
        return made
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host, entries.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: DetailsCellView.identifier, owner: nil) as? DetailsCellView
            ?? DetailsCellView()
        cell.bar.configure(
            entry: entries[row], row: row, selected: tableView.isRowSelected(row), host: host, fitted: fitted,
            layout: layoutMetrics)
        return cell
    }

    // MARK: Selection

    private func applySelection() {
        guard let host else { return }
        var rows = IndexSet()
        if host.selection.paths.isEmpty, table.selectedRowIndexes.isEmpty { return }
        for path in host.selection.paths {
            if let row = rowByPath[path] { rows.insert(row) }
        }
        guard rows != table.selectedRowIndexes else { return }
        isSyncing = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncing = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, let host else { return }
        // A click in the list gives it the keyboard.
        if table.window?.firstResponder !== table { table.window?.makeFirstResponder(table) }
        let rows = table.selectedRowIndexes
        let paths = rows.compactMap { entries.indices.contains($0) ? entries[$0].path : nil }
        let old = Set(host.selection.paths)
        let anchor =
            host.selection.anchorPath.flatMap { paths.contains($0) ? $0 : nil } ?? paths.first
        // The lead is the row the gesture ended on: of those added, the one furthest from the anchor.
        let anchorRow = anchor.flatMap { rowByPath[$0] } ?? 0
        let added = paths.filter { !old.contains($0) }
        let lead =
            added.max { abs((rowByPath[$0] ?? 0) - anchorRow) < abs((rowByPath[$1] ?? 0) - anchorRow) }
            ?? host.selection.leadPath.flatMap { paths.contains($0) ? $0 : nil } ?? paths.last
        host.selectionChanged(ContentSelection(paths: paths, anchorPath: anchor, leadPath: lead))
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0, entries.indices.contains(table.clickedRow) else { return }
        let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        host?.activate(selected, newTab: NSEvent.modifierFlags.contains(.command))
    }

    /// The menu for a right-click: on an item (selecting it first when it isn't selected), or on the background, which
    /// clears the selection (`onContextMenu`).
    func menu(forEventAt point: NSPoint) -> NSMenu? {
        let row = table.row(at: point)
        if row >= 0, entries.indices.contains(row) {
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
            return host?.contextMenu(for: selected)
        }
        table.deselectAll(nil)
        return host?.contextMenu(for: nil)
    }

    /// The entry under a point of the table, for drops.
    func entry(at point: NSPoint) -> DirectoryEntry? {
        let row = table.row(at: point)
        return entries.indices.contains(row) ? entries[row] : nil
    }

    var selectedEntries: [DirectoryEntry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    // MARK: Sorting

    /// The table's sort descriptor mirrors the sort the folder is in (the header is the control; scenarios and the
    /// automation read the descriptor).
    private func mirrorSort() {
        guard let host else { return }
        let descriptor = NSSortDescriptor(key: host.sortBy.rawValue, ascending: host.sortDirection == .asc)
        if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
            let sortBy = SortByPreference(rawValue: key), let host
        else { return }
        // Set from outside (a scenario's step): the folder is put in exactly this order.
        if sortBy != host.sortBy || (descriptor.ascending ? SortDirectionPreference.asc : .desc) != host.sortDirection {
            host.sortSetFromOutside(sortBy, ascending: descriptor.ascending)
        }
    }

    private func sortRequested(_ column: DetailColumn) {
        guard let key = DetailsSorting.sortKey(for: column, search: false), let sortBy = SortByPreference(rawValue: key)
        else { return }
        host?.requestSort(sortBy)
    }

    // MARK: Columns

    private func beginResize(_ column: DetailColumn) -> (width: Double, saved: [DetailColumn: Double]) {
        (fitted.width(column), host?.columnState.widths ?? [:])
    }

    private func resize(_ column: DetailColumn, to width: Double, from saved: [DetailColumn: Double]) {
        let clamped = DetailsColumns.clamp(width, column: column, search: false)
        guard clamped != saved[column] else { return }
        var next = saved
        next[column] = clamped
        host?.columnWidthsChanged(next)
    }

    /// ←/→ on a focused separator steps the width (`nudgeColumnWidth`).
    private func nudge(_ column: DetailColumn, _ direction: Int) {
        let saved = host?.columnState.widths ?? [:]
        let width = DetailsColumns.clamp(
            fitted.width(column) + Double(direction) * layoutMetrics.columnKeyboardStep, column: column, search: false)
        guard width != saved[column] else { return }
        var next = saved
        next[column] = width
        host?.columnWidthsChanged(next)
    }

    /// A double-click on a separator fits the column to its title and its widest value, every row's and not only those
    /// on screen: their text is measured in the fonts the cells are drawn in (B-VIEW-052).
    private func fitToContent(_ column: DetailColumn) {
        guard let host, let headerCell = header.cell(for: column) else { return }
        let layout = layoutMetrics
        let titleFont = ListFonts.header(layout, active: headerCell.active)
        var headerWidth = ceil(
            (DetailsColumns.title(column) as NSString).size(withAttributes: [.font: titleFont]).width)
        if headerCell.active {
            headerWidth += layout.sortChevronWidth + layout.sortChevronTrailingMargin + layout.headerButtonGap
        }
        let font = column == .permissions ? ListFonts.permissions(layout) : ListFonts.row(layout)
        let now = RelativeClock.shared.relativeNow
        let widths = entries.map { entry -> Double in
            let content = ListCellText.content(
                column: column, entry: entry, metadata: host.metadata(for: entry.path),
                folderSize: host.folderSizeEntry(entry.path), now: now)
            return Double((content.text as NSString).size(withAttributes: [.font: font]).width)
        }
        let extra = column == .name ? layout.iconSize + layout.nameIconGap : 0
        let width = DetailsColumns.fitWidth(
            for: column, headerWidth: headerWidth, valueWidths: widths, valueExtraWidth: extra, layout: layout
        ) { DetailsColumns.clamp($0, column: column, search: false) }
        var saved = host.columnState.widths
        guard width != saved[column] else { return }
        saved[column] = width
        host.columnWidthsChanged(saved)
    }

    // MARK: Details of the rows on screen

    /// Asks for the details of the rows on screen and ten either side of them (`overscan: 10`), once the scrolling has
    /// settled for a moment.
    private func requestMetadata() {
        metadataWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestMetadataNow() }
        }
        metadataWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private func requestMetadataNow() {
        guard let host, !entries.isEmpty else { return }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        let overscan = 10
        let lower = max(0, rows.location - overscan)
        let upper = min(entries.count, rows.location + rows.length + overscan)
        host.requestMetadata(for: entries[lower..<upper].map(\.path))
    }

    // MARK: The clock

    private func clockTicked() {
        forEachVisibleBar { $0.refreshCells() }
        updateMinuteHold()
    }

    /// The minute timer runs only while a date under an hour old is on screen (`useRelativeDate`).
    private func updateMinuteHold() {
        var wanted = false
        forEachVisibleBar { if $0.readsInMinutes { wanted = true } }
        if wanted, minuteHold == nil {
            minuteHold = RelativeClock.shared.holdMinuteTicks()
        } else if !wanted, let hold = minuteHold {
            hold()
            minuteHold = nil
        }
    }
}

#if DEBUG
    extension ListTableView: AutomationDragSource, AutomationDropTarget {
        func automationDragItems(at point: NSPoint) -> [URL] {
            guard let pane else { return [] }
            let entries: [DirectoryEntry]
            if let hit = pane.entry(at: point), !pane.selectedEntries.contains(where: { $0.path == hit.path }) {
                entries = [hit]
            } else {
                entries = pane.selectedEntries
            }
            return pane.hostDragHooks?.itemsToDrag?(entries) ?? entries.map(\.url)
        }

        func automationDrop(_ items: [URL], at point: NSPoint, allowed: NSDragOperation) -> Bool {
            guard let pane, let accept = pane.hostDragHooks?.acceptDrop else { return false }
            return accept(items, pane.entry(at: point), allowed)
        }
    }

    extension ListViewController {
        var hostDragHooks: ContentDragHooks? { host?.dragHooks }
    }
#endif
