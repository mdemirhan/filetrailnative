// Port of DetailsHeaderCell, SortButton and SortIndicator (apps/desktop/src/renderer/components/ContentPane.tsx:2063-2131,
// 2259-2281; components/SortIndicator.tsx) and the header rules of styles.css:2722-2800, 2820-2872 and 4410-4432
import AppKit
import FTFoundation

/// The sort direction beside a column title, drawn as Finder draws it: a chevron that points up for ascending and
/// down for descending (`SortIndicator`).
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

/// The line between two column titles, which is also where the column is resized (`.details-column-resizer`): a short
/// line that darkens under the pointer, while dragging and when focused.
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
        dragStartX = event.locationInWindow.x
        dragStartWidth = start.width
        dragStartWidths = start.saved
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag(column, dragStartWidth + (event.locationInWindow.x - dragStartX), dragStartWidths)
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

    /// The cell lays out its pieces in its own box: the title's height is the box's, and the separator's hit area
    /// reaches beyond it (`top: -6px; right: -6px`).
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
            x: 0, y: 0, width: sortable ? titleWidth : min(titleWidth, ceil(title.textWidth * 100) / 100), height: height)
        let overhang = layout.separatorHitOverhang
        separator.frame = NSRect(
            x: bounds.width + overhang - layout.separatorHitWidth, y: -overhang, width: layout.separatorHitWidth,
            height: height + 2 * overhang)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if separator.frame.contains(local) { return separator }
        return bounds.contains(local) && sortable ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard sortable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSort(column)
    }

    override func accessibilityPerformPress() -> Bool {
        guard sortable else { return false }
        onSort(column)
        return true
    }
}

/// The header row: a cell per visible column, laid out like the rows below it (`.details-header`: padding 0 12, a
/// 12 gap).
final class DetailsHeaderView: NSView {
    private var cells: [DetailsHeaderCell] = []
    private(set) var layoutMetrics = DesignTokens.details(density: .comfortable)
    private var fitted = DetailsColumnSet(columns: [], widths: [:])

    var onSort: (DetailColumn) -> Void = { _ in }
    var onBegin: (DetailColumn) -> (width: Double, saved: [DetailColumn: Double]) = { _ in (0, [:]) }
    var onDrag: (DetailColumn, Double, [DetailColumn: Double]) -> Void = { _, _, _ in }
    var onFit: (DetailColumn) -> Void = { _ in }
    var onNudge: (DetailColumn, Int) -> Void = { _, _ in }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("list.header")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The cell showing a column, as it is on screen.
    func cell(for column: DetailColumn) -> DetailsHeaderCell? { cells.first { $0.column == column } }

    func configure(
        fitted: DetailsColumnSet, sortBy: SortByPreference, sortDirection: SortDirectionPreference, search: Bool,
        theme: Theme, layout: DetailsLayout
    ) {
        self.fitted = fitted
        layoutMetrics = layout
        while cells.count < fitted.columns.count {
            let cell = DetailsHeaderCell()
            cell.onSort = { [weak self] column in self?.onSort(column) }
            cell.separator.onBegin = { [weak self] column in self?.onBegin(column) ?? (0, [:]) }
            cell.separator.onDrag = { [weak self] column, width, saved in self?.onDrag(column, width, saved) }
            cell.separator.onFit = { [weak self] column in self?.onFit(column) }
            cell.separator.onNudge = { [weak self] column, direction in self?.onNudge(column, direction) }
            addSubview(cell)
            cells.append(cell)
        }
        for (index, cell) in cells.enumerated() {
            guard fitted.columns.indices.contains(index) else {
                cell.isHidden = true
                continue
            }
            let column = fitted.columns[index]
            let key = DetailsSorting.sortKey(for: column, search: search)
            cell.isHidden = false
            cell.configure(
                column: column, sortable: key != nil, active: key != nil && key == sortBy.rawValue,
                ascending: sortDirection == .asc, theme: theme, layout: layout)
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var x = layoutMetrics.rowPaddingInline
        for (index, cell) in cells.enumerated() where fitted.columns.indices.contains(index) {
            let width = fitted.width(fitted.columns[index])
            let height = cell.title.lineHeight
            cell.frame = NSRect(x: x, y: ((bounds.height - height) / 2), width: width, height: height)
            cell.layoutPieces(layout: layoutMetrics)
            x += width + layoutMetrics.columnGap
        }
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
            return cell.hitTest(local)
        }
        return nil
    }
}
