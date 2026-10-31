// Port of the lists of apps/desktop/src/renderer/components/TreePane.tsx (TreeList, the favorites and locations lists) on an NSOutlineView
import AppKit
import FTFoundation

/// What a list of the sidebar reports to the sidebar that owns it.
@MainActor
protocol SidebarListDelegate: AnyObject {
    /// The primary button went down on a row's label or whitespace (not on its chevron or Eject button).
    func sidebarList(_ list: SidebarListView, pointerDown state: SidebarRowState, event: NSEvent)
    /// It came up again on the same row; `clickCount` is 2 for the second click of a double-click.
    func sidebarList(_ list: SidebarListView, click state: SidebarRowState, event: NSEvent, clickCount: Int)
    func sidebarList(_ list: SidebarListView, doubleClick state: SidebarRowState)
    /// The button went down on empty space (not a row, not a scrollbar).
    func sidebarList(_ list: SidebarListView, pressEmptySpaceIn subview: SidebarSubview)
    func sidebarList(_ list: SidebarListView, toggle state: SidebarRowState)
    func sidebarList(_ list: SidebarListView, pressHeader state: SidebarHeaderState)
    func sidebarList(_ list: SidebarListView, toggleHeader state: SidebarHeaderState)
    func sidebarList(_ list: SidebarListView, eject state: SidebarRowState)
    func sidebarList(_ list: SidebarListView, menuFor state: SidebarRowState, event: NSEvent) -> NSMenu?
    /// A key went down in the list; true when the sidebar took it.
    func sidebarList(_ list: SidebarListView, keyDown event: NSEvent) -> Bool
    func sidebarList(_ list: SidebarListView, focusChanged focused: Bool)
    func sidebarList(_ list: SidebarListView, rowArrived state: SidebarRowState)
    func sidebarList(_ list: SidebarListView, favoriteDragStarted path: String)
    func sidebarList(
        _ list: SidebarListView, favoriteDragOver target: (path: String, position: Favorites.DropPosition)?)
    func sidebarList(_ list: SidebarListView, favoriteDropped path: String)
    func sidebarListFavoriteDragEnded(_ list: SidebarListView)
}

private final class SidebarListItem: NSObject {
    var row: SidebarListRow
    init(_ row: SidebarListRow) {
        self.row = row
    }
}

/// The rows of a list in one column, drawn by hand: a flat outline, with the depth of a row in its own padding.
final class SidebarOutlineView: NSOutlineView {
    weak var list: SidebarListView?
    private var pressedRow: Int?
    private var pressEvent: NSEvent?
    private var dragStart: NSPoint?
    /// Scrolls under a drag held at an edge: the drops here don't go through the outline's own drag handling.
    var edgeScroll = DragEdgeScroll()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let list { list.delegate?.sidebarList(list, focusChanged: true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let list { list.delegate?.sidebarList(list, focusChanged: false) }
        return result
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func drawGrid(inClipRect clipRect: NSRect) {}
    override func drawBackground(inClipRect clipRect: NSRect) {}
    override func highlightSelection(inClipRect clipRect: NSRect) {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The list takes every press on a row itself; only a row's own buttons take theirs.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is SidebarChevronView || hit is SidebarEjectView || hit is SidebarHeaderButton { return hit }
        return self
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let list else { return }
        if list.delegate?.sidebarList(list, keyDown: event) == true { return }
        // Keys the sidebar does not take go on up the responder chain, not to a table's own search.
        nextResponder?.keyDown(with: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let list else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        // Control-click opens the context menu and changes nothing else.
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        pressedRow = nil
        guard index >= 0, let listRow = list.row(at: index) else {
            if !list.isInScrollbar(event) { list.delegate?.sidebarList(list, pressEmptySpaceIn: list.subview) }
            return
        }
        switch listRow {
        case .spacer:
            if !list.isInScrollbar(event) { list.delegate?.sidebarList(list, pressEmptySpaceIn: list.subview) }
        case .header(let state):
            // Beside the header's button: the button takes its own presses.
            if !list.isInScrollbar(event) { list.delegate?.sidebarList(list, pressHeader: state) }
        case .item(let state):
            pressedRow = index
            pressEvent = event
            dragStart = point
            list.delegate?.sidebarList(list, pointerDown: state, event: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let list, let index = pressedRow, let start = dragStart, case .item(let state)? = list.row(at: index)
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4, let path = state.item.path,
            state.item.kind == .favorite, list.reordersFavorites
        else { return }
        pressedRow = nil
        list.beginFavoriteDrag(path: path, state: state, event: event, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let list, let index = pressedRow else { return }
        pressedRow = nil
        let point = convert(event.locationInWindow, from: nil)
        guard row(at: point) == index, case .item(let state)? = list.row(at: index) else { return }
        let count = max(1, event.clickCount)
        list.delegate?.sidebarList(list, click: state, event: event, clickCount: count)
        if count >= 2 { list.delegate?.sidebarList(list, doubleClick: state) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let list else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0, case .item(let state)? = list.row(at: index) else { return nil }
        window?.makeFirstResponder(self)
        return list.delegate?.sidebarList(list, menuFor: state, event: event)
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        edgeScroll.follow(sender, in: enclosingScrollView)
        return list?.draggingUpdated(sender, in: self) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        edgeScroll.follow(sender, in: enclosingScrollView)
        return list?.draggingUpdated(sender, in: self) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        edgeScroll.reset()
        guard let list else { return }
        list.delegate?.sidebarList(list, favoriteDragOver: nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        edgeScroll.reset()
        return list?.performDrop(sender, in: self) ?? false
    }
}

/// A scroll view whose vertical scroller sits in a gutter of its own, 8 pt wide, as `scrollbar-gutter: stable` leaves it.
final class SidebarScrollView: NSScrollView {
    var gutter = 8.0

    override func tile() {
        super.tile()
        var frame = contentView.frame
        frame.size.width = max(0, bounds.width - gutter)
        contentView.frame = frame
    }
}

/// One list of the sidebar: the folder tree, or the separate Favorites and Locations.
@MainActor
final class SidebarListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scroll = SidebarScrollView()
    let outline = SidebarOutlineView()
    weak var delegate: SidebarListDelegate?
    let subview: SidebarSubview
    /// Favorites are dragged to a new place in this list.
    var reordersFavorites = true
    private var items: [SidebarListItem] = []
    private var heights: [Double] = []
    private var width: Double { Double(outline.bounds.width) }
    private let fade = CAGradientLayer()
    /// Where the list's content is scrolled to, as `scrollTop` of the original.
    var scrollTop: Double {
        get { Double(scroll.contentView.bounds.origin.y) }
        set {
            let maximum = max(0, Double(outline.frame.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, newValue), maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    init(subview: SidebarSubview) {
        self.subview = subview
        super.init(frame: .zero)
        outline.list = self
        let column = NSTableColumn(identifier: .init("sidebar"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        column.maxWidth = 10_000
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.intercellSpacing = .zero
        outline.rowSizeStyle = .custom
        outline.selectionHighlightStyle = .none
        outline.allowsEmptySelection = true
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.style = .plain
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.fileURL, SidebarPasteboard.favoriteType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        outline.tableColumns.first?.width = max(0, bounds.width - scroll.gutter)
        fade.frame = bounds
    }

    /// The top 6 pt of the folders tree fade out (`mask-image`), so rows scrolling under the "Folders" label do not
    /// end mid-letter.
    var fadesTop: Bool = false {
        didSet {
            guard fadesTop != oldValue else { return }
            if fadesTop {
                fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
                // This view is flipped, and so is its mask: y = 0 is its top.
                fade.startPoint = CGPoint(x: 0.5, y: 0)
                fade.endPoint = CGPoint(x: 0.5, y: 1)
                updateFade()
                layer?.mask = fade
            } else {
                layer?.mask = nil
            }
        }
    }

    func updateFade(height: Double = SidebarLayout(density: .comfortable).treeFadeHeight) {
        guard bounds.height > 0 else { return }
        fade.locations = [0, NSNumber(value: min(1, height / bounds.height))]
        fade.frame = bounds
    }

    // MARK: Rows

    func row(at index: Int) -> SidebarListRow? {
        items.indices.contains(index) ? items[index].row : nil
    }

    func index(ofRow id: String) -> Int? {
        items.firstIndex { $0.row.id == id }
    }

    func index(ofItem id: TreeItemID) -> Int? {
        items.firstIndex { $0.row.itemID == id }
    }

    var rowCount: Int { items.count }

    /// The rows now in the list: one whose state is the same is not drawn again.
    func apply(_ rows: [SidebarListRow]) {
        let ids = rows.map(\.id)
        let known = Dictionary(items.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })
        noteChevronTurns(rows, known: known)
        if ids != items.map({ $0.row.id }) {
            items = rows.map { row in
                if let item = known[row.id] {
                    item.row = row
                    return item
                }
                return SidebarListItem(row)
            }
            heights = rows.map { rowHeight($0) }
            outline.reloadData()
            return
        }
        var changedHeights = IndexSet()
        for (index, row) in rows.enumerated() where row != items[index].row {
            items[index].row = row
            let height = rowHeight(row)
            if height != heights[index] {
                heights[index] = height
                changedHeights.insert(index)
            }
            outline.reloadItem(items[index])
        }
        if !changedHeights.isEmpty { outline.noteHeightOfRows(withIndexesChanged: changedHeights) }
    }

    /// The rows that just opened or closed, and when: their chevrons turn as their cells are made, in whichever cell the
    /// list reuses for them. Noted a moment ago, or the row has scrolled away and comes back as it is.
    private var chevronTurns: [TreeItemID: TimeInterval] = [:]
    private static let chevronTurnWait = 0.25

    private func noteChevronTurns(_ rows: [SidebarListRow], known: [String: SidebarListItem]) {
        for row in rows {
            guard case .item(let next) = row, case .item(let shown)? = known[row.id]?.row,
                next.item.expanded != shown.item.expanded
            else { continue }
            chevronTurns[next.item.id] = ProcessInfo.processInfo.systemUptime
        }
    }

    private func takeChevronTurn(_ id: TreeItemID) -> Bool {
        guard let noted = chevronTurns.removeValue(forKey: id) else { return false }
        return ProcessInfo.processInfo.systemUptime - noted < Self.chevronTurnWait
    }

    func reloadAll() {
        heights = items.map { rowHeight($0.row) }
        outline.reloadData()
    }

    private func rowHeight(_ row: SidebarListRow) -> Double {
        switch row {
        case .spacer(_, let height):
            return height
        case .header(let state):
            let layout = SidebarLayout(density: state.density)
            return (state.first ? layout.sectionHeaderFirstMarginTop : layout.sectionHeaderMarginTop)
                + layout.sectionHeaderHeight
        case .item(let state):
            let layout = SidebarLayout(density: state.density)
            return layout.rowHeight
                + SidebarItemCell.noteHeight(state, width: max(1, Double(bounds.width - scroll.gutter)))
        }
    }

    /// The total height of the rows.
    var contentHeight: Double { items.indices.reduce(0) { $0 + heights[$1] } }

    // MARK: Scrolling

    /// The frame of a row in the list's own coordinates (the scrolled content).
    func frame(ofRow index: Int) -> NSRect { outline.rect(ofRow: index) }

    /// "nearest" alignment: scrolls only if the row is not fully inside.
    func reveal(_ index: Int) {
        let rect = outline.rect(ofRow: index)
        let visible = scroll.contentView.bounds
        guard rect.minY < visible.minY || rect.maxY > visible.maxY else { return }
        scroll.contentView.scrollToVisible(rect)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// How much of the list is in view.
    var visibleHeight: Double { Double(scroll.contentView.bounds.height) }

    /// The list's height can be a fraction of a point, which the clip view rounds, so a row revealed at the foot can
    /// end less than a pixel past the visible area.
    func isFullyVisible(_ index: Int) -> Bool {
        let rect = outline.rect(ofRow: index)
        let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -0.5)
        return rect.minY >= visible.minY && rect.maxY <= visible.maxY
    }

    /// A press in the scrollbar's gutter clears nothing.
    func isInScrollbar(_ event: NSEvent) -> Bool {
        let point = scroll.convert(event.locationInWindow, from: nil)
        return point.x >= scroll.bounds.width - scroll.gutter
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { items[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? SidebarListItem, let index = items.firstIndex(where: { $0 === item }) else {
            return 0
        }
        return CGFloat(heights.indices.contains(index) ? heights[index] : rowHeight(item.row))
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SidebarRow")
        return outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarRowShell
            ?? {
                let made = SidebarRowShell()
                made.identifier = id
                return made
            }()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarListItem else { return nil }
        switch item.row {
        case .spacer:
            let id = NSUserInterfaceItemIdentifier("SidebarSpacer")
            return outlineView.makeView(withIdentifier: id, owner: nil)
                ?? {
                    let made = SidebarPlainView()
                    made.identifier = id
                    return made
                }()
        case .header(let state):
            let cell =
                outlineView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) as? SidebarHeaderCell
                ?? SidebarHeaderCell()
            cell.configure(state)
            cell.onToggle = { [weak self, weak cell] in
                guard let self, let state = cell?.state else { return }
                self.delegate?.sidebarList(self, toggleHeader: state)
            }
            cell.onPress = { [weak self, weak cell] in
                guard let self, let state = cell?.state else { return }
                self.delegate?.sidebarList(self, pressHeader: state)
            }
            return cell
        case .item(let state):
            let cell =
                outlineView.makeView(withIdentifier: SidebarItemCell.identifier, owner: nil) as? SidebarItemCell
                ?? SidebarItemCell()
            cell.onToggle = { [weak self, weak cell] in
                guard let self, let state = cell?.state else { return }
                self.delegate?.sidebarList(self, toggle: state)
            }
            cell.onEject = { [weak self, weak cell] in
                guard let self, let state = cell?.state else { return }
                self.delegate?.sidebarList(self, eject: state)
            }
            cell.onMenu = { [weak self, weak cell] event in
                guard let self, let state = cell?.state,
                    let menu = self.delegate?.sidebarList(self, menuFor: state, event: event)
                else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: self.outline)
            }
            cell.onIconArrived = { [weak self, weak cell] in
                guard let self, let state = cell?.state else { return }
                self.delegate?.sidebarList(self, rowArrived: state)
            }
            cell.configure(state, width: max(1, Double(outlineView.bounds.width)))
            if takeChevronTurn(state.item.id) { cell.turnChevron() }
            return cell
        }
    }

    // MARK: Dragging favorites

    func beginFavoriteDrag(path: String, state: SidebarRowState, event: NSEvent, in view: NSView) {
        let dragging = NSDraggingItem(pasteboardWriter: SidebarPasteboard.item(favorite: path))
        let index = items.firstIndex { $0.row.itemID == state.item.id } ?? 0
        let frame = outline.rect(ofRow: index)
        dragging.setDraggingFrame(frame, contents: Self.snapshot(of: outline, rect: frame))
        delegate?.sidebarList(self, favoriteDragStarted: path)
        let session = outline.beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private static func snapshot(of view: NSView, rect: NSRect) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    /// Where a dragged favorite lands over this point: upper half before the row, lower half after.
    func favoriteDropTarget(at point: NSPoint) -> (path: String, position: Favorites.DropPosition)? {
        let index = outline.row(at: point)
        guard index >= 0, case .item(let state)? = row(at: index), state.item.kind == .favorite,
            let path = state.item.path
        else { return nil }
        let rect = outline.rect(ofRow: index)
        return (path, point.y < rect.minY + SidebarLayout(density: state.density).rowHeight / 2 ? .before : .after)
    }

    fileprivate func draggingUpdated(_ info: any NSDraggingInfo, in view: NSView) -> NSDragOperation {
        let point = view.convert(info.draggingLocation, from: nil)
        if info.draggingPasteboard.types?.contains(SidebarPasteboard.favoriteType) == true {
            guard reordersFavorites else { return [] }
            let target = favoriteDropTarget(at: point)
            let dragged = info.draggingPasteboard.string(forType: SidebarPasteboard.favoriteType)
            delegate?.sidebarList(self, favoriteDragOver: target.flatMap { $0.path == dragged ? nil : $0 })
            return .move
        }
        return fileDropOperation?(self, info, point) ?? []
    }

    fileprivate func performDrop(_ info: any NSDraggingInfo, in view: NSView) -> Bool {
        let point = view.convert(info.draggingLocation, from: nil)
        if let dragged = info.draggingPasteboard.string(forType: SidebarPasteboard.favoriteType) {
            delegate?.sidebarList(self, favoriteDropped: dragged)
            return true
        }
        return fileDrop?(self, info, point) ?? false
    }

    /// Files dragged over a row (P5-08 fills these).
    var fileDropOperation: ((SidebarListView, any NSDraggingInfo, NSPoint) -> NSDragOperation)?
    var fileDrop: ((SidebarListView, any NSDraggingInfo, NSPoint) -> Bool)?
    /// Files handed to a row by the debug seam (`AutomationDropTarget`).
    var fileDropURLs: ((SidebarListView, SidebarRowState, [URL], NSDragOperation) -> Bool)?
}

extension SidebarListView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        .move
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        MainActor.assumeIsolated { delegate?.sidebarListFavoriteDragEnded(self) }
    }
}

enum SidebarPasteboard {
    /// A favorite dragged to a new place carries this type alone, no files, so the file drops of the sidebar and the
    /// window take no notice of it. The name has to be a valid UTI: under anything else (a MIME type, say) AppKit logs
    /// an error and writes nothing, and the drag reaches no destination.
    static let favoriteType = NSPasteboard.PasteboardType("com.filetrail.native.favorite")

    /// What a favorite's drag carries.
    static func item(favorite path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(path, forType: favoriteType)
        return item
    }
}

/// The row shell of the outline: draws nothing; the cell draws the row.
final class SidebarRowShell: NSTableRowView {
    override var isFlipped: Bool { true }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
