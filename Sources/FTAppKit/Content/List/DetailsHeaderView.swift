import AppKit
import FTFoundation

/// The sort direction beside a column title, drawn as Finder draws it: a chevron that points up for ascending and
/// down for descending.
final class SortChevronView: NSView {
    var ascending = true {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The path of a 10 × 6 viewBox in a 9 × 6 box, kept in proportion and centered.
        let scale = min(bounds.width / 10, bounds.height / 6)
        let offset = NSPoint(x: (bounds.width - 10 * scale) / 2, y: (bounds.height - 6 * scale) / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        let path = NSBezierPath()
        if ascending {
            path.move(to: point(1, 5))
            path.line(to: point(5, 1))
            path.line(to: point(9, 5))
        } else {
            path.move(to: point(1, 1))
            path.line(to: point(5, 5))
            path.line(to: point(9, 1))
        }
        path.lineWidth = 1.5 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}

/// The line between two column titles, which is also where the column is resized: a short line that darkens under the
/// pointer, while dragging and when focused.
final class ColumnSeparatorView: NSView {
    var column: DetailColumn = .name
    var lineColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }
    var hoverColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    var lineSize = NSSize(width: 1, height: 14)
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var isDragging = false {
        didSet { needsDisplay = true }
    }
    private var isFocused = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?
    private var dragStartX = 0.0
    private var dragStartWidth = 0.0
    private var dragStartWidths: [DetailColumn: Double] = [:]

    /// Asked for the width on screen and the saved widths when a drag begins.
    var onBegin: (DetailColumn) -> (width: Double, saved: [DetailColumn: Double]) = { _ in (0, [:]) }
    var onDrag: (DetailColumn, Double, [DetailColumn: Double]) -> Void = { _, _, _ in }
    var onFit: (DetailColumn) -> Void = { _ in }
    var onNudge: (DetailColumn, Int) -> Void = { _, _ in }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let darker = isHovering || isDragging || isFocused
        (darker ? hoverColor : lineColor).setFill()
        NSRect(
            x: ((bounds.width - lineSize.width) / 2), y: ((bounds.height - lineSize.height) / 2), width: lineSize.width,
            height: lineSize.height
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onFit(column)
            return
        }
        let start = onBegin(column)
        dragStartX = headerX(event)
        dragStartWidth = start.width
        dragStartWidths = start.saved
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag(column, dragStartWidth + (headerX(event) - dragStartX), dragStartWidths)
    }

    /// Where the pointer is along the header, which moves with the rows: a drag that scrolls the list sideways keeps
    /// the divider under the pointer.
    private func headerX(_ event: NSEvent) -> CGFloat {
        var header: NSView? = superview
        while let view = header, !(view is DetailsHeaderView) { header = view.superview }
        return (header ?? self).convert(event.locationInWindow, from: nil).x
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onNudge(column, -1)
        case 124: onNudge(column, 1)
        default: super.keyDown(with: event)
        }
    }
}

/// One column of the header: the title (a button when the list can be sorted by the column) with the sort chevron at
/// the right, and the separator that ends it.
final class DetailsHeaderCell: NSView, TextStyleSource {
    let title = ListLabel()
    let chevron = SortChevronView()
    let separator = ColumnSeparatorView()
    private(set) var column: DetailColumn = .name
    private(set) var sortable = false
    private(set) var active = false
    var onSort: (DetailColumn) -> Void = { _ in }
    var onPress: () -> Void = {}
    /// The title is being dragged sideways, by `offset` from where it was pressed; nil once it is let go.
    var onDragTitle: (DetailColumn, Double?) -> Void = { _, _ in }
    /// How far a press must move before the title is dragged rather than clicked.
    static let dragThreshold = 4.0
    private var pressX: Double?
    private var dragging = false

    var styleTextField: NSTextField? { title }

    init() {
        super.init(frame: .zero)
        addSubview(title)
        addSubview(chevron)
        addSubview(separator)
        setAccessibilityIdentifier("list.header.cell")
        title.setAccessibilityIdentifier("list.header.title")
        chevron.setAccessibilityIdentifier("list.header.chevron")
        separator.setAccessibilityIdentifier("list.header.separator")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(
        column: DetailColumn, sortable: Bool, active: Bool, ascending: Bool, theme: Theme, layout: DetailsLayout
    ) {
        self.column = column
        self.sortable = sortable
        self.active = active
        let palette = theme.palette
        title.stringValue = DetailsColumns.title(column)
        title.font = ListFonts.header(layout, active: active)
        title.textColor = NSColor(active ? palette.textPrimary : palette.textSecondary)
        title.lineBreakMode = .byTruncatingTail
        chevron.isHidden = !active
        chevron.ascending = ascending
        chevron.color = NSColor(palette.textSecondary)
        separator.column = column
        separator.lineColor = NSColor(palette.border)
        separator.hoverColor = NSColor(palette.textSecondary)
        separator.lineSize = NSSize(width: layout.separatorWidth, height: layout.separatorHeight)
        setAccessibilityLabel(DetailsColumns.title(column))
        needsLayout = true
    }

    /// The column's title, or another in its place (a group's name in the Name column); nil for the column's own.
    func showTitle(_ text: String?) {
        title.stringValue = text ?? DetailsColumns.title(column)
        needsLayout = true
    }

    /// The cell lays out its pieces in its own box: the title's height is the box's, and the separator's hit area
    /// reaches 6 beyond it above, below and to the right (`separatorHitOverhang`).
    func layoutPieces(layout: DetailsLayout) {
        let height = bounds.height
        var titleWidth = bounds.width
        if active {
            let gap = layout.headerButtonGap
            let chevronWidth = layout.sortChevronWidth
            titleWidth = max(0, bounds.width - gap - chevronWidth - layout.sortChevronTrailingMargin)
            chevron.frame = NSRect(
                x: titleWidth + gap, y: (height - layout.sortChevronHeight) / 2, width: chevronWidth,
                height: layout.sortChevronHeight)
        }
        // A column that can't be sorted by is a plain label, as wide as its text; a button's title takes the room.
        title.frame = NSRect(
            x: 0, y: 0, width: sortable ? titleWidth : min(titleWidth, ceil(title.textWidth * 100) / 100),
            height: height)
        let overhang = layout.separatorHitOverhang
        separator.frame = NSRect(
            x: bounds.width + overhang - layout.separatorHitWidth, y: -overhang, width: layout.separatorHitWidth,
            height: height + 2 * overhang)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if separator.frame.contains(local) { return separator }
        // Name can't be moved, so a title that doesn't sort is only pressed where it could be dragged.
        return bounds.contains(local) && (sortable || column != .name) ? self : nil
    }

    /// A press gives the content pane the keyboard; the sort waits for the release, and a press that moves sideways
    /// drags the column instead (Name stays first).
    override func mouseDown(with event: NSEvent) {
        onPress()
        pressX = event.locationInWindow.x
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard column != .name, let pressX else { return }
        let offset = event.locationInWindow.x - pressX
        if !dragging, abs(offset) < Self.dragThreshold { return }
        dragging = true
        onDragTitle(column, offset)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressX = nil
            dragging = false
        }
        if dragging {
            onDragTitle(column, nil)
            return
        }
        guard sortable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSort(column)
    }

    /// The header's menu: the cell has none of its own.
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }

    override func accessibilityPerformPress() -> Bool {
        guard sortable else { return false }
        onSort(column)
        return true
    }
}

/// The header row: a cell per visible column, laid out like the rows below it (12 of padding each side, 12 between
/// cells).
final class DetailsHeaderView: NSView {
    private var cells: [DetailsHeaderCell] = []
    private(set) var layoutMetrics = DesignTokens.details(density: .standard)
    private var columnSet = DetailsColumnSet(columns: [], widths: [:])

    var onSort: (DetailColumn) -> Void = { _ in }
    var onPress: () -> Void = {}
    var onBegin: (DetailColumn) -> (width: Double, saved: [DetailColumn: Double]) = { _ in (0, [:]) }
    var onDrag: (DetailColumn, Double, [DetailColumn: Double]) -> Void = { _, _, _ in }
    var onFit: (DetailColumn) -> Void = { _ in }
    var onNudge: (DetailColumn, Int) -> Void = { _, _ in }
    /// The right-click menu, for the column under the pointer (nil: none).
    var onMenu: (DetailColumn?) -> NSMenu? = { _ in nil }
    /// A column's title was dragged and let go: it comes before `before` (nil: last).
    var onMove: (DetailColumn, DetailColumn?) -> Void = { _, _ in }
    /// The column being dragged and how far, while one is.
    private var dragged: (column: DetailColumn, offset: Double)?
    /// The line showing where a dragged column would go.
    private let dropLine = NSView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("list.header")
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropLine.layer?.cornerRadius = 1
        dropLine.isHidden = true
        addSubview(dropLine)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The cell showing a column, as it is on screen.
    func cell(for column: DetailColumn) -> DetailsHeaderCell? { cells.first { $0.column == column } }

    /// While the list is grouped, the name of the group at its top, in place of Name, as Finder's header has it.
    var nameTitle: String? {
        didSet {
            guard nameTitle != oldValue else { return }
            cell(for: .name)?.showTitle(nameTitle)
        }
    }

    /// `sortKey` is the key the list is ordered by: a folder's (`SortByPreference`) or search results'
    /// (`SearchResultsSortByPreference`).
    func configure(
        columnSet: DetailsColumnSet, sortKey: String, sortDirection: SortDirectionPreference, search: Bool,
        theme: Theme, layout: DetailsLayout
    ) {
        self.columnSet = columnSet
        layoutMetrics = layout
        while cells.count < columnSet.columns.count {
            let cell = DetailsHeaderCell()
            cell.onSort = { [weak self] column in self?.onSort(column) }
            cell.onPress = { [weak self] in self?.onPress() }
            cell.onDragTitle = { [weak self] column, offset in self?.dragTitle(column, offset) }
            cell.separator.onBegin = { [weak self] column in self?.onBegin(column) ?? (0, [:]) }
            cell.separator.onDrag = { [weak self] column, width, saved in self?.onDrag(column, width, saved) }
            cell.separator.onFit = { [weak self] column in self?.onFit(column) }
            cell.separator.onNudge = { [weak self] column, direction in self?.onNudge(column, direction) }
            addSubview(cell)
            cells.append(cell)
        }
        for (index, cell) in cells.enumerated() {
            guard columnSet.columns.indices.contains(index) else {
                cell.isHidden = true
                continue
            }
            let column = columnSet.columns[index]
            let key = DetailsSorting.sortKey(for: column, search: search)
            cell.isHidden = false
            cell.configure(
                column: column, sortable: key != nil, active: key != nil && key == sortKey,
                ascending: sortDirection == .asc, theme: theme, layout: layout)
            if column == .name, nameTitle != nil { cell.showTitle(nameTitle) }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x = layoutMetrics.rowPaddingInline
        for (index, cell) in cells.enumerated() where columnSet.columns.indices.contains(index) {
            let width = columnSet.width(columnSet.columns[index])
            let height = cell.title.lineHeight
            let offset = dragged?.column == cell.column ? dragged?.offset ?? 0 : 0
            cell.frame = NSRect(x: x + offset, y: ((bounds.height - height) / 2), width: width, height: height)
            cell.alphaValue = dragged?.column == cell.column ? 0.6 : 1
            cell.layoutPieces(layout: layoutMetrics)
            x += width + layoutMetrics.columnGap
        }
        if let dragged, let drop = dropPlace(of: dragged.column, offset: dragged.offset) {
            dropLine.isHidden = false
            dropLine.frame = NSRect(x: drop.x - 1, y: 2, width: 2, height: max(0, bounds.height - 4))
        } else {
            dropLine.isHidden = true
        }
    }

    /// Where a column dragged by `offset` would go: the column it would come before (nil: last), and the x of the
    /// gap there. Nil while it would stay where it is. Nothing goes before Name.
    func dropPlace(of column: DetailColumn, offset: Double) -> (before: DetailColumn?, x: Double)? {
        let columns = columnSet.columns
        guard let index = columns.firstIndex(of: column) else { return nil }
        var starts: [Double] = []
        var x = layoutMetrics.rowPaddingInline
        for shown in columns {
            starts.append(x)
            x += columnSet.width(shown) + layoutMetrics.columnGap
        }
        let center = starts[index] + columnSet.width(column) / 2 + offset
        // The gap after the last column whose middle the dragged middle has passed; never before Name.
        var target = 1
        for (place, shown) in columns.enumerated() where place > 0 && shown != column {
            if center > starts[place] + columnSet.width(shown) / 2 { target = place + 1 }
        }
        if target == index || target == index + 1 { return nil }
        let before = target < columns.count ? columns[target] : nil
        let gapX =
            target < columns.count ? starts[target] - layoutMetrics.columnGap / 2 : x - layoutMetrics.columnGap / 2
        return (before, gapX)
    }

    private func dragTitle(_ column: DetailColumn, _ offset: Double?) {
        guard let offset else {
            let drop = dragged.flatMap { dropPlace(of: $0.column, offset: $0.offset) }
            dragged = nil
            needsLayout = true
            if let drop { onMove(column, drop.before) }
            return
        }
        dragged = (column, offset)
        needsLayout = true
    }

    /// The column under a right-click, if any.
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let column = cells.first { !$0.isHidden && $0.frame.contains(local) }?.column
        return onMenu(column)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        // A separator's hit area reaches above and below the header cell, and a little past its right edge.
        for cell in cells where !cell.isHidden {
            let inCell = cell.convert(local, from: self)
            if cell.separator.frame.contains(inCell) { return cell.separator }
        }
        for cell in cells where !cell.isHidden && cell.frame.contains(local) {
            if let hit = cell.hitTest(local) { return hit }
        }
        return bounds.contains(local) ? self : nil
    }

    /// A press between the cells, or on one that doesn't sort.
    override func mouseDown(with event: NSEvent) { onPress() }
}
