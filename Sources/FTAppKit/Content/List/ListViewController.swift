// The List view, an NSTableView with one wide column whose cells are laid out by hand
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

    /// As high as its rows, or the pane when they are fewer. A table in a clip view follows it by autoresizing, so each
    /// time the pane grew (its first layout, the Info Row shutting, a window resize) its growth was added below the rows
    /// and the list scrolled past its end.
    override func setFrameSize(_ newSize: NSSize) {
        let rows = pane?.groupedRowsHeight ?? CGFloat(numberOfRows) * (rowHeight + intercellSpacing.height)
        let height = max(rows, enclosingScrollView?.contentView.bounds.height ?? newSize.height)
        super.setFrameSize(NSSize(width: newSize.width, height: height))
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if pane?.renameField != nil, !(subview is InlineRenameField) { InlineRenameField.keepOnTop(in: self) }
    }

    // The pane keeps the selection: presses, keys and ⌘A are its own, not the table's.
    override func mouseDown(with event: NSEvent) {
        if let pane { pane.handleMouseDown(event) } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        _ = pane?.handleKeyDown(event)
    }

    override func selectAll(_ sender: Any?) {
        pane?.host?.selectAllEntries()
    }

    /// Rows selected from outside (a scenario's `select` step, accessibility) are selected in the pane's model, which
    /// the window reads; the table then shows the model's selection. Only the pane's own sync selects rows directly.
    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        guard let pane, pane.host != nil, !pane.isSyncingSelection else {
            super.selectRowIndexes(indexes, byExtendingSelection: extend)
            return
        }
        pane.selectFromOutside(extend ? selectedRowIndexes.union(indexes) : indexes)
    }

    override func deselectAll(_ sender: Any?) {
        guard let pane, pane.host != nil, !pane.isSyncingSelection else {
            super.deselectAll(sender)
            return
        }
        pane.selectFromOutside(IndexSet())
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSResponder.selectAll(_:)) { return !(pane?.host?.entryPaths.isEmpty ?? true) }
        return super.validateUserInterfaceItem(item)
    }

    /// Escape and ⌘. while nothing else takes them do nothing here (Escape never clears a selection).
    override func cancelOperation(_ sender: Any?) {}
}

/// A row of the table while the list is grouped: a group's title, or an entry by its place in `entries`.
enum ListRow: Equatable {
    case header(Int)
    case entry(Int)
}

/// The row a group's title sits in: it draws no selection, as a title is never selected.
final class GroupHeaderRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// The List view's root: the column header above the rows.
final class ListRootView: NSView, RowsBelowCard {
    weak var pane: ListViewController?
    var roomAboveRows: CGFloat = 0 {
        didSet { if roomAboveRows != oldValue { needsLayout = true } }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        pane?.layoutPane()
    }
}

/// The header's strip: the line under it, and the header clipped to it.
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

final class ListViewController: NSViewController, FolderPane, NSTableViewDataSource, NSTableViewDelegate, RevealScroller
{
    /// Weakly: the host (the content pane) holds this pane as its child.
    weak var host: (any ContentPaneHost)? {
        didSet {
            refreshLook()
            keyboard = host.map { ContentKeyboard(host: $0, navigation: self) }
        }
    }
    private(set) var keyboard: ContentKeyboard?
    /// The marquee box, in the table's content so it scrolls with the rows.
    let marquee = MarqueeBoxView()
    /// The field of the rename going on, in the table's content (so it stays alive when its row scrolls away).
    var renameField: InlineRenameField?
    var renamingPath: String?
    var lastRefusalCount = 0

    private let root = ListRootView()
    private let headerShell = DetailsHeaderShell()
    private let header = DetailsHeaderView()
    let scroll = NSScrollView()
    let table = ListTableView()
    private let column = NSTableColumn(identifier: DetailsCellView.identifier)

    var entries: [DirectoryEntry] = []
    /// The table's rows while the list is grouped: for each group its title and its items; empty while it isn't
    /// grouped, when a row is the entry at the same place. A title's row is as high as an item's, and every title but
    /// the first has half a row of space above it, in its own row (`height(ofRow:)`), so the groups are told apart
    /// without an empty row between them. The Name column's title stays Name: a group's name in its place read as a
    /// column called "Today", or "work" for a folder of search results.
    private(set) var rows: [ListRow] = []
    /// The table row of each entry, while grouped.
    private var entryRows: [Int] = []
    /// Each entry's place in its group, while grouped: the stripes start again under each title.
    private var placesInGroup: [Int] = []
    /// Whether the table asks for each row's height: only while grouped, as a table that asks measures every row at
    /// each reload and finds a row by search, where rows all as high need neither.
    private var asksRowHeights = false
    private(set) var groups: [ShownGroup] = []
    /// Rows by path, made when a selection or a lookup needs it.
    private var rowsCache: [String: Int]?
    var rowByPath: [String: Int] {
        if let rowsCache { return rowsCache }
        let made = Dictionary(
            entries.enumerated().map { ($1.path, tableRow(ofEntry: $0)) }, uniquingKeysWith: { first, _ in first })
        rowsCache = made
        return made
    }
    private(set) var columnSet = DetailsColumnSet(columns: [.name], widths: [:])
    private(set) var layoutMetrics = DesignTokens.details(density: .standard)
    private var isSyncing = false
    /// Whether the table's selection is being set from the model (and not from outside).
    var isSyncingSelection: Bool { isSyncing }
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
        column.minWidth = 1
        column.maxWidth = 100_000
        column.resizingMask = []
        table.addTableColumn(column)
        table.setAccessibilityIdentifier("list.table")
        registerForFileDrops()

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
            MainActor.assumeIsolated {
                // The scrollers show while a pane scrolls, by the keyboard too.
                self?.scroll.flashScrollers()
                self?.scrolled()
            }
        }

        headerShell.clipsToBounds = true
        headerShell.addSubview(header)
        header.onSort = { [weak self] column in self?.sortRequested(column) }
        header.onPress = { [weak self] in self?.giveKeyboard() }
        header.onBegin = { [weak self] column in self?.beginResize(column) ?? (0, [:]) }
        header.onDrag = { [weak self] column, width, saved in self?.resize(column, to: width, from: saved) }
        header.onNudge = { [weak self] column, direction in self?.nudge(column, direction) }
        header.onFit = { [weak self] column in self?.fitToContent(column) }
        header.onMenu = { [weak self] column in self?.host?.headerMenu(for: column) }
        header.onMove = { [weak self] column, before in self?.host?.columnMoved(column, before: before) }
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
        DesignTokens.details(density: host?.columnState.density ?? .standard)
    }

    func reload(scrollToTop: Bool) {
        reload(scrollToTop: scrollToTop, change: .list)
    }

    private func reload(scrollToTop: Bool, change: RevealKeeper.Change) {
        entries = host?.entries ?? []
        makeRows()
        rowsCache = nil
        layoutMetrics = metrics
        table.rowHeight = CGFloat(layoutMetrics.rowHeight)
        sizeColumns()
        configureHeader()
        isSyncing = true
        table.reloadData()
        mirrorSort()
        isSyncing = false
        applySelection()
        if scrollToTop {
            // At the top and at the left: a folder opened afresh starts at its first column, an empty one too.
            scrollPosition = (top: 0, left: 0)
            revealKeeper.forget()
        }
        keepInView(change)
        updateMinuteHold()
        requestMetadata()
        syncRename()
    }

    func reloadRows(paths: Set<String>) {
        entries = host?.entries ?? []
        let asked = asksRowHeights
        makeRows()
        rowsCache = nil
        let rows = IndexSet(paths.compactMap { rowByPath[$0] })
        isSyncing = true
        if asked != asksRowHeights {
            // Grouped or not any more: every row's place is another.
            table.reloadData()
        } else {
            table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        isSyncing = false
        applySelection()
        keepInView(.list)
        updateMinuteHold()
        requestMetadata()
    }

    func refresh(paths: Set<String>?) {
        guard let paths else {
            forEachVisibleBar { $0.refreshCells() }
            updateMinuteHold()
            requestMetadata()
            return
        }
        for path in paths {
            if let row = rowByPath[path], let bar = bar(atRow: row) { bar.refreshCells() }
        }
        updateMinuteHold()
        requestMetadata()
    }

    func syncSelection() {
        applySelection()
        keepInView(.ask)
    }

    func showNothingMatches(_ shown: Bool) {
        if headerShell.isHidden != shown { headerShell.isHidden = shown }
    }

    func refreshLook() {
        configureHeader()
        forEachVisibleBar { $0.refreshCells() }
    }

    func columnsChanged() {
        let density = host?.columnState.density
        if density != nil, DesignTokens.details(density: density ?? .standard) != layoutMetrics {
            reload(scrollToTop: false, change: .layout)
            return
        }
        sizeColumns()
        configureHeader()
        reconfigureVisibleBars()
        requestMetadata()
        syncRename()
    }

    private let revealKeeper = RevealKeeper()

    /// The item being renamed, or else the selection's lead, is kept in view as `RevealKeeper` says.
    func keepInView(_ change: RevealKeeper.Change) {
        guard let host else { return }
        let ask = host.revealAsk(followingRename: true)
        revealKeeper.keepInView(change, ask: ask, index: ask.path.flatMap { rowByPath[$0] }, scroller: self)
    }

    var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }

    func isInView(index: Int) -> Bool {
        let clip = scroll.contentView.bounds
        // Grouped, the rows are not all as high.
        if !rows.isEmpty {
            let row = table.rect(ofRow: index)
            return row.minY >= clip.minY && row.maxY <= clip.maxY
        }
        let top = CGFloat(index) * table.rowHeight
        return top >= clip.minY && top + table.rowHeight <= clip.maxY
    }

    func bringIntoView(index: Int) {
        guard scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0 else { return }
        // A group's first item comes with its title, where both fit: the item is what must show.
        if groupIndex(atRow: index - 1) != nil { table.scrollRowToVisible(index - 1) }
        table.scrollRowToVisible(index)
    }

    var scrollPosition: (top: Double, left: Double) {
        get {
            let origin = scroll.contentView.bounds.origin
            return (Double(origin.y), Double(origin.x))
        }
        set {
            let clip = scroll.contentView
            let document = scroll.documentView?.frame.size ?? .zero
            let maxX = max(0, document.width - clip.bounds.width)
            let maxY = max(0, document.height - clip.bounds.height)
            // Through the scroll view, which keeps AppKit's own record of where the list is: scrolled past it, by the
            // clip view alone, the list goes back to where a trackpad left it the next time its width changes.
            scroll.scroll(clip, to: NSPoint(x: min(maxX, max(0, newValue.left)), y: min(maxY, max(0, newValue.top))))
            scroll.reflectScrolledClipView(clip)
        }
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
        let rowsTop = headerHeight + root.roomAboveRows
        scroll.frame = NSRect(x: 0, y: rowsTop, width: width, height: max(0, height - rowsTop))
        let before = columnSet
        sizeColumns()
        if columnSet != before {
            configureHeader()
            reconfigureVisibleBars()
        }
        positionHeader()
        let viewport = scroll.contentView.bounds.size
        if viewport != lastViewport {
            lastViewport = viewport
            keepInView(.layout)
        }
        requestMetadata()
        positionRenameField()
    }

    private var lastViewport = NSSize.zero

    /// The columns keep the widths they were given whatever the pane's width: a pane narrower than the columns
    /// scrolls sideways, and a wider one leaves room to the right of the last column.
    private func sizeColumns() {
        let state = host?.columnState ?? .standard
        columnSet = DetailsColumnSet(columns: state.columns, widths: state.widths)
        let table = DetailsColumns.tableWidth(
            widths: columnSet.widths, columns: columnSet.columns, layout: layoutMetrics)
        // The list never gets narrower than what it shows to the right: a column narrowed with the list scrolled to
        // its right end leaves empty room there, during the drag and after it, which goes as the list is scrolled back
        // (`scrolled`). Were the list to close up at once it would scroll back under the pointer, which the drag would
        // take for the pointer moving on, and the column would close up to its smallest. The room never grows: a
        // list pulled past its end and springing back shows more than it has.
        let fitted = max(Double(root.bounds.width), table + 2 * layoutMetrics.rowInset)
        // By the width given last, not the table's frame, which AppKit sets to its own between two layouts.
        let shown = min(givenWidth, Double(scroll.contentView.bounds.maxX))
        let documentWidth = max(fitted, shown)
        givenWidth = documentWidth
        holdsRoom = documentWidth > fitted
        column.width = documentWidth
        column.minWidth = documentWidth
        column.maxWidth = documentWidth
        // A narrower column leaves the table and its rows as wide as before (the Info panel opening): they follow
        // the pane, so the rows stop at the gutter as the header does.
        if self.table.frame.width != documentWidth {
            self.table.setFrameSize(NSSize(width: documentWidth, height: self.table.frame.height))
        }
        self.table.enumerateAvailableRowViews { row, _ in
            if row.frame.width != documentWidth {
                row.setFrameSize(NSSize(width: documentWidth, height: row.frame.height))
            }
        }
    }

    /// The header is as wide as the table, at least the pane; it follows the rows' horizontal scroll.
    private func positionHeader() {
        let inset = CGFloat(layoutMetrics.rowInset)
        let table = DetailsColumns.tableWidth(
            widths: columnSet.widths, columns: columnSet.columns, layout: layoutMetrics)
        let width = max(CGFloat(table), root.bounds.width - 2 * inset)
        header.frame = NSRect(
            x: inset - scroll.contentView.bounds.origin.x, y: 0, width: width, height: headerShell.bounds.height)
    }

    private func configureHeader() {
        guard let host else { return }
        headerShell.lineColor = NSColor(host.theme.palette.borderLight)
        let search = host.search
        header.configure(
            columnSet: columnSet, sortKey: search?.headerSortKey ?? host.sortBy.rawValue,
            sortDirection: search?.sortDirection ?? host.sortDirection, search: search != nil, theme: host.theme,
            layout: layoutMetrics)
        positionHeader()
    }

    /// The list is wider than its columns, for what it showed to the right when a column was narrowed.
    private var holdsRoom = false
    /// The width `sizeColumns` gave the list last.
    private var givenWidth = 0.0

    private func scrolled() {
        // Scrolled back, the list gives up the empty room it no longer shows.
        if holdsRoom { sizeColumns() }
        positionHeader()
        requestMetadata()
        // Scrolling moves the row away from the reason a name was refused, so it is dropped until the next try.
        renameField?.hideError()
    }

    // MARK: Rows

    func bar(atRow row: Int) -> DetailsBarView? {
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
        for row in rows.location..<(rows.location + rows.length) {
            guard let index = entryIndex(atRow: row) else { continue }
            bar(atRow: row)?.configure(
                entry: entries[index], row: stripeRow(ofEntry: index), selected: selected.contains(row), host: host,
                columnSet: columnSet, layout: layoutMetrics)
        }
    }

    // MARK: Groups

    /// The rows of the groups the host shows: each title, then its items.
    private func makeRows() {
        groups = host?.groups ?? []
        defer { askRowHeights(!rows.isEmpty) }
        guard !groups.isEmpty else {
            rows = []
            entryRows = []
            placesInGroup = []
            return
        }
        var made: [ListRow] = []
        made.reserveCapacity(entries.count + groups.count)
        var rowOf = [Int](repeating: 0, count: entries.count)
        var placeOf = [Int](repeating: 0, count: entries.count)
        for (number, group) in groups.enumerated() {
            made.append(.header(number))
            for index in group.range where index < entries.count {
                rowOf[index] = made.count
                placeOf[index] = index - group.range.lowerBound
                made.append(.entry(index))
            }
        }
        rows = made
        entryRows = rowOf
        placesInGroup = placeOf
    }

    var rowCount: Int { rows.isEmpty ? entries.count : rows.count }

    /// The space above a group's title, but the first's: half a row.
    var groupSpace: CGFloat { (CGFloat(layoutMetrics.rowHeight) / 2).rounded() }

    /// A row's height while grouped: an item's and the first title's are a row's, another title's has the space above
    /// it too.
    func height(ofRow row: Int) -> CGFloat {
        let height = CGFloat(layoutMetrics.rowHeight)
        guard rows.indices.contains(row), case .header(let number) = rows[row], number > 0 else { return height }
        return height + groupSpace
    }

    /// How high the rows are together while grouped; nil while they are all as high.
    var groupedRowsHeight: CGFloat? {
        guard !rows.isEmpty else { return nil }
        return CGFloat(rows.count) * CGFloat(layoutMetrics.rowHeight) + CGFloat(max(0, groups.count - 1)) * groupSpace
    }

    /// The row an entry's stripe goes by: its place under its group's title while grouped, so every group starts
    /// without a stripe as the list does; else its row.
    private func stripeRow(ofEntry index: Int) -> Int {
        placesInGroup.indices.contains(index) ? placesInGroup[index] : index
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(ofRow: row) }

    /// The table learns which of its delegate's methods there are when it is given the delegate, so it is given it
    /// again when the rows start or stop having heights of their own.
    private func askRowHeights(_ asks: Bool) {
        guard asks != asksRowHeights else { return }
        asksRowHeights = asks
        table.delegate = nil
        table.delegate = self
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSTableViewDelegate.tableView(_:heightOfRow:)) {
            return MainActor.assumeIsolated { asksRowHeights }
        }
        return super.responds(to: aSelector)
    }

    /// The entry a row shows; nil for a header, or a row past the end.
    func entryIndex(atRow row: Int) -> Int? {
        if rows.isEmpty { return entries.indices.contains(row) ? row : nil }
        guard rows.indices.contains(row), case .entry(let index) = rows[row] else { return nil }
        return index
    }

    /// The group whose header a row is; nil for an entry's row.
    func groupIndex(atRow row: Int) -> Int? {
        guard rows.indices.contains(row), case .header(let number) = rows[row] else { return nil }
        return number
    }

    func tableRow(ofEntry index: Int) -> Int {
        rows.isEmpty || !entryRows.indices.contains(index) ? index : entryRows[index]
    }

    /// The path of each row, "" for a group's title: what the marquee finds rows by.
    var rowPaths: [String] {
        guard !rows.isEmpty else { return entries.map(\.path) }
        return rows.map {
            switch $0 {
            case .header: ""
            case .entry(let index): entries[index].path
            }
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { entryIndex(atRow: row) != nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if !rows.isEmpty, entryIndex(atRow: row) == nil {
            let id = NSUserInterfaceItemIdentifier("details.groupRow")
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? GroupHeaderRowView { return reused }
            let made = GroupHeaderRowView()
            made.identifier = id
            return made
        }
        let id = NSUserInterfaceItemIdentifier("details.row")
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? DetailsRowView { return reused }
        let made = DetailsRowView()
        made.identifier = id
        return made
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host else { return nil }
        if let number = groupIndex(atRow: row), groups.indices.contains(number) {
            let id = NSUserInterfaceItemIdentifier("details.groupHeader")
            let header = tableView.makeView(withIdentifier: id, owner: nil) as? GroupHeaderView ?? GroupHeaderView()
            header.identifier = id
            // Lined up with the names, under the space that sets its group apart.
            header.leadingInset = CGFloat(
                layoutMetrics.rowInset + layoutMetrics.rowPaddingInline + layoutMetrics.iconSize
                    + layoutMetrics.nameIconGap)
            header.spaceAbove = number > 0 ? groupSpace : 0
            header.configure(groups[number], style: .list, theme: host.theme)
            return header
        }
        guard let index = entryIndex(atRow: row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: DetailsCellView.identifier, owner: nil) as? DetailsCellView
            ?? DetailsCellView()
        cell.bar.configure(
            entry: entries[index], row: stripeRow(ofEntry: index), selected: tableView.isRowSelected(row), host: host,
            columnSet: columnSet, layout: layoutMetrics)
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

    /// Rows selected from outside the pane: the model takes them, in list order, the first the anchor and the last the
    /// lead.
    func selectFromOutside(_ rows: IndexSet) {
        let paths = rows.compactMap { entryIndex(atRow: $0).map { entries[$0].path } }
        host?.selectionChanged(ContentSelection.of(paths))
        // The model may not have changed (the same rows again): the table still shows it.
        applySelection()
    }

    /// The menu for a right-click: on an item, which keeps the selection when it is selected and otherwise selects it
    /// alone first; or on the background, which clears the selection. The list gets the keyboard either way.
    func menu(forEventAt point: NSPoint) -> NSMenu? {
        guard let host else { return nil }
        giveKeyboard()
        let row = table.row(at: point)
        if let index = entryIndex(atRow: row) {
            let path = entries[index].path
            if !host.selection.paths.contains(path) { host.selectionChanged(.single(path)) }
            return host.contextMenu(for: selectedEntries)
        }
        host.selectionChanged(.empty)
        return host.contextMenu(for: nil)
    }

    /// The entry under a point of the table, for drops.
    func entry(at point: NSPoint) -> DirectoryEntry? {
        return entryIndex(atRow: table.row(at: point)).map { entries[$0] }
    }

    var selectedEntries: [DirectoryEntry] {
        table.selectedRowIndexes.compactMap { entryIndex(atRow: $0).map { entries[$0] } }
    }

    // MARK: Sorting

    /// The table's sort descriptor mirrors the sort the folder is in (the header is the control; scenarios and the
    /// automation read the descriptor).
    private func mirrorSort() {
        guard let host else { return }
        let descriptor =
            host.search.map { NSSortDescriptor(key: $0.sortBy.rawValue, ascending: $0.sortDirection == .asc) }
            ?? NSSortDescriptor(key: host.sortBy.rawValue, ascending: host.sortDirection == .asc)
        if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let host
        else { return }
        if let search = host.search {
            // Search results: by Name, Folder or Kind, set from outside (a scenario's step).
            guard let sortBy = SearchResultsSortByPreference(rawValue: key) else { return }
            let direction: SortDirectionPreference = descriptor.ascending ? .asc : .desc
            if sortBy != search.sortBy || direction != search.sortDirection { search.setSort(sortBy, direction) }
            return
        }
        guard let sortBy = SortByPreference(rawValue: key) else { return }
        // Set from outside (a scenario's step): the folder is put in exactly this order.
        if sortBy != host.sortBy || (descriptor.ascending ? SortDirectionPreference.asc : .desc) != host.sortDirection {
            host.sortSetFromOutside(sortBy, ascending: descriptor.ascending)
        }
    }

    private func sortRequested(_ column: DetailColumn) {
        if let search = host?.search {
            guard let key = DetailsSorting.sortKey(for: column, search: true),
                let sortBy = SearchResultsSortByPreference(rawValue: key)
            else { return }
            search.requestSort(sortBy)
            return
        }
        guard let key = DetailsSorting.sortKey(for: column, search: false), let sortBy = SortByPreference(rawValue: key)
        else { return }
        host?.requestSort(sortBy)
    }

    // MARK: Columns

    private func beginResize(_ column: DetailColumn) -> (width: Double, saved: [DetailColumn: Double]) {
        (columnSet.width(column), host?.columnState.widths ?? [:])
    }

    private func resize(_ column: DetailColumn, to width: Double, from saved: [DetailColumn: Double]) {
        let clamped = DetailsColumns.clamp(width, column: column, search: host?.search != nil)
        // Against the width it has now, not the one the drag began with: dragged back to where it started, the
        // column takes that width again.
        guard clamped != columnSet.width(column) else { return }
        var next = saved
        next[column] = clamped
        host?.columnWidthsChanged(next)
        keepDividerInView(column)
    }

    /// ←/→ on a focused separator steps the width.
    private func nudge(_ column: DetailColumn, _ direction: Int) {
        let saved = host?.columnState.widths ?? [:]
        let width = DetailsColumns.clamp(
            columnSet.width(column) + Double(direction) * layoutMetrics.columnKeyboardStep, column: column,
            search: host?.search != nil)
        guard width != saved[column] else { return }
        var next = saved
        next[column] = width
        host?.columnWidthsChanged(next)
        keepDividerInView(column)
    }

    /// A double-click on a separator fits the column to its title and its widest value, every row's and not only those
    /// on screen: their text is measured in the fonts the cells are drawn in.
    private func fitToContent(_ column: DetailColumn) {
        guard let host, let width = fittedWidth(column) else { return }
        var saved = host.columnState.widths
        guard width != saved[column] else { return }
        saved[column] = width
        host.columnWidthsChanged(saved)
        keepDividerInView(column)
    }

    /// The header's Size All Columns to Fit: every column shown at the width that fits its title and values, in one
    /// change.
    func fitAllColumns() {
        guard let host else { return }
        var saved = host.columnState.widths
        for column in host.columnState.columns {
            if let width = fittedWidth(column) { saved[column] = width }
        }
        guard saved != host.columnState.widths else { return }
        host.columnWidthsChanged(saved)
    }

    /// The width that shows a column's title and its widest value whole.
    private func fittedWidth(_ column: DetailColumn) -> Double? {
        guard let host, let headerCell = header.cell(for: column) else { return nil }
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
            let text = column == .folder ? host.search?.folderLabel(entry.path) ?? "" : content.text
            return Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let extra = column == .name ? layout.iconSize + layout.nameIconGap : 0
        return DetailsColumns.fitWidth(
            for: column, headerWidth: headerWidth, valueWidths: widths, valueExtraWidth: extra, layout: layout
        ) { [search = host.search != nil] in DetailsColumns.clamp($0, column: column, search: search) }
    }

    /// A column made wider than the pane has room for scrolls the list sideways, so its divider stays in view.
    private func keepDividerInView(_ column: DetailColumn) {
        guard let index = columnSet.columns.firstIndex(of: column) else { return }
        let through = columnSet.columns[...index]
        let edge =
            layoutMetrics.rowInset + layoutMetrics.rowPaddingInline
            + through.reduce(0) { $0 + columnSet.width($1) } + Double(index) * layoutMetrics.columnGap
            + layoutMetrics.separatorHitOverhang
        let clip = scroll.contentView
        let visible = clip.bounds
        guard CGFloat(edge) > visible.maxX else { return }
        let maxX = max(0, table.frame.width - visible.width)
        // Through the scroll view, as `scrollPosition` does.
        scroll.scroll(clip, to: NSPoint(x: min(maxX, CGFloat(edge) - visible.width), y: visible.origin.y))
        scroll.reflectScrolledClipView(clip)
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

    /// The entries on screen and ten either side of them. Grouped, a row is not an entry: the rows on screen are
    /// looked up, and titles and the rows before them passed over.
    var entriesNearScreen: Range<Int>? {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0, !entries.isEmpty else { return nil }
        let onScreen = (rows.location..<rows.location + rows.length).compactMap { entryIndex(atRow: $0) }
        guard let first = onScreen.first, let last = onScreen.last else { return nil }
        let overscan = 10
        return max(0, first - overscan)..<min(entries.count, last + 1 + overscan)
    }

    private func requestMetadataNow() {
        guard let host, let near = entriesNearScreen else { return }
        let shown = Array(entries[near])
        host.requestMetadata(for: shown)
        host.requestTags(for: shown.map(\.path))
    }

    // MARK: The clock

    private func clockTicked() {
        // A tab at the back has no dates to keep current, and reads them again as it comes to the front.
        if view.window?.isBehindAnotherTab == true {
            minuteHold?()
            minuteHold = nil
            return
        }
        forEachVisibleBar { $0.refreshCells() }
        updateMinuteHold()
    }

    /// The minute timer runs only while a date under an hour old is on screen.
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
