// The Compact List, names in columns that fill top to bottom and scroll sideways
import AppKit
import FTFileSystem
import FTFoundation

/// The Compact List: each column is filled top to bottom, then the next one to the right; the list scrolls sideways,
/// and the wheel's up and down scroll it sideways too.
final class CompactListViewController: ItemGridPane {
    private(set) var density = Density.standard
    private(set) var layout = DesignTokens.flowList(density: .standard)
    let style = FlowItemStyle.make()
    private(set) var nameFont = ThemeFonts.sans(DesignTokens.flowList(density: .standard).fontSize)
    /// Names measured in the list's font, by name.
    private var nameWidths: [String: Double] = [:]

    override var navigationViewMode: ExplorerViewMode { .list }
    override var itemIdentifier: NSUserInterfaceItemIdentifier { CompactListItem.identifier }

    override func makeScrollView() -> ItemGridScrollView { SidewaysScrollView() }

    override func loadView() {
        super.loadView()
        collection.register(CompactListItem.self, forItemWithIdentifier: CompactListItem.identifier)
        collection.setAccessibilityIdentifier("compactList.grid")
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.verticalScrollElasticity = .none
    }

    /// The density's sizes, at the column width saved for it.
    override func metricsChanged() -> Bool {
        let next = host?.columnState.density ?? .standard
        let width = Double(host?.columnState.compactListWidths[next] ?? DensitySizes.compactListDefaults[next])
        guard next != density || width != layout.itemWidth else { return false }
        if next != density {
            density = next
            nameWidths = [:]
        }
        layout = DesignTokens.flowList(density: next)
        layout.itemWidth = width
        nameFont = ThemeFonts.sans(layout.fontSize)
        collection.collectionViewLayout?.invalidateLayout()
        return true
    }

    override func configure(_ item: NSCollectionViewItem, entry: DirectoryEntry, index: Int) {
        (item as? CompactListItem)?.configure(entry: entry, key: keys[index], pane: self)
    }

    override func refreshLook(of item: NSCollectionViewItem, at index: Int) {
        (item as? CompactListItem)?.applyLook(pane: self, entry: entries[index], key: keys[index])
    }

    // MARK: Placement

    /// The rows per column at the pane's height; the arrow keys move by it sideways, and the page keys by it.
    var rowsPerColumn: Int {
        layout.rowsPerColumn(containerHeight: Double(viewport.height) - (groups.isEmpty ? 0 : headerHeight))
    }

    // MARK: Groups

    /// A group's title at the top of a column, over its hairline, and the room before the column's first item.
    private var headerHeight: Double { Double(GroupHeaderView.gridHeight) }

    private struct ColumnsKey: Equatable {
        var listing: ObjectIdentifier
        var counts: [Int]
        var height: Double
        var rowHeight: Double
        var columnStep: Double
        var left: Double
    }
    private var columnsCache: (key: ColumnsKey, columns: GroupedColumns)?

    /// The groups one after another down the columns, each under its title, going on in the next column only when
    /// there is no room left. A title takes its height and the list's top padding, so a column's first item is as far
    /// under its title as an ungrouped column's is under the top.
    func columns(height: CGFloat) -> GroupedColumns? {
        guard !groups.isEmpty else { return nil }
        let key = ColumnsKey(
            listing: ObjectIdentifier(listing), counts: groups.map(\.range.count),
            height: Double(height) - layout.paddingBottom + layout.rowGap, rowHeight: layout.rowHeight,
            columnStep: layout.columnStep, left: layout.paddingInline)
        if let cached = columnsCache, cached.key == key { return cached.columns }
        let made = GroupedColumns(
            counts: key.counts, height: key.height, rowHeight: key.rowHeight,
            headerHeight: headerHeight + layout.paddingTop, columnStep: key.columnStep, left: key.left)
        columnsCache = (key, made)
        return made
    }

    override var groupNavigation: (any GroupNavigation)? { columns(height: viewport.height) }

    /// A title for each column a group is in, as wide as the column.
    override func headerPlaces(viewport: NSSize) -> [GroupHeaderPlace] {
        guard let columns = columns(height: viewport.height) else { return [] }
        return columns.headers.map { header in
            GroupHeaderPlace(
                group: header.group,
                frame: NSRect(
                    x: columns.columnStart(header.column), y: header.top, width: layout.itemWidth, height: headerHeight
                ), continued: header.continued)
        }
    }

    /// The titles of the columns in view; none is held at an edge.
    override func headerShows(_ frame: NSRect, until end: Double, in clip: NSRect) -> Bool {
        frame.minX < clip.maxX && frame.maxX > clip.minX
    }

    /// The width the name takes as its label draws it (`SplitName`): an item only as wide as the name measured whole
    /// would cut its stem short. A search's marks pad the name, so a marked one is measured each time.
    private func nameWidth(_ entry: DirectoryEntry) -> Double {
        if let marks = host?.nameMarks(entry.name), !marks.isEmpty {
            return Double(SplitName.width(entry.name, extension: entry.fileExtension, marks: marks, font: nameFont))
        }
        let key = entry.fileExtension.isEmpty ? entry.name : entry.name + "\u{0}" + entry.fileExtension
        if let known = nameWidths[key] { return known }
        // Names of folders left behind are let go once there are many more than this folder has.
        if nameWidths.count >= max(2 * entries.count, 10_000) { nameWidths.removeAll(keepingCapacity: true) }
        let width = Double(SplitName.width(entry.name, extension: entry.fileExtension, marks: [], font: nameFont))
        nameWidths[key] = width
        return width
    }

    override func contentSize(viewport: NSSize) -> NSSize {
        if let columns = columns(height: viewport.height) {
            // As wide as its columns, the last one's gap given back for the padding, as without groups.
            return NSSize(width: columns.end - layout.columnGap + layout.paddingInline, height: viewport.height)
        }
        let rows = layout.rowsPerColumn(containerHeight: Double(viewport.height))
        return NSSize(
            width: layout.contentWidth(itemCount: entries.count, rowsPerColumn: rows), height: viewport.height)
    }

    override func itemFrame(at index: Int, viewport: NSSize) -> NSRect {
        var cell: GridRect
        if let columns = columns(height: viewport.height), let place = columns.place(ofItem: index) {
            // Grouped: in its column, under its group's title.
            cell = GridRect(
                x: columns.columnStart(place.column), y: place.top, width: layout.itemWidth, height: layout.rowHeight)
        } else {
            cell = layout.cellFrame(
                index: index, rowsPerColumn: layout.rowsPerColumn(containerHeight: Double(viewport.height)))
        }
        // An item hugs its icon and name; one being renamed keeps its column, for the field.
        let renaming = keys.indices.contains(index) && keys[index] == renamingPath
        let width =
            renaming || !entries.indices.contains(index)
            ? cell.width : layout.itemWidth(nameWidth: markedNameWidth(entries[index]), style: style)
        return NSRect(x: cell.x, y: cell.y, width: width, height: cell.height)
    }

    /// The name's width, and what follows it with its gap: the tag dots, and the clipboard glyph on an item on the
    /// clipboard.
    private func markedNameWidth(_ entry: DirectoryEntry) -> Double {
        var width = nameWidth(entry)
        let tags = host?.tagColors(for: entry).count ?? 0
        if tags > 0 { width += Double(TagDotsView.gap + TagDotsView.width(count: tags)) }
        if host?.clipboardMarks?.mark(for: entry.path) != nil {
            width += ClipboardLayout.Mark.gap + ClipboardLayout.Mark.iconSize
        }
        return width
    }

    /// Tags or clipboard marks may have changed: an item is wider by its dots and its glyph.
    override func refresh(paths: Set<DiskPath>?) {
        let resized = collection.indexPathsForVisibleItems().contains { path in
            guard let item = collection.item(at: path) else { return false }
            return abs(item.view.frame.width - itemFrame(at: path.item, viewport: viewport).width) >= 1
        }
        if resized {
            gridLayout.invalidateLayout()
            placeItems()
        }
        super.refresh(paths: paths)
    }

    override func items(in rect: NSRect, viewport: NSSize) -> Range<Int> {
        if let columns = columns(height: viewport.height) {
            return columns.items(from: Double(rect.minX), to: Double(rect.maxX))
        }
        return layout.items(
            left: Double(rect.minX), right: Double(rect.maxX), itemCount: entries.count,
            rowsPerColumn: layout.rowsPerColumn(containerHeight: Double(viewport.height)))
    }

    /// Only the height moves items.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old.height != new.height }

    // MARK: Drag-to-select

    /// In the coordinates of the list's rows (inside its padding).
    override func marqueeHits(box: DragSelectionBox, sizes: [DiskPath: DragSelectionSize]) -> [DragSelectionHit] {
        let left = layout.paddingInline
        let top = layout.paddingTop
        if let columns = columns(height: viewport.height) {
            // Grouped, each group's items in a column as a list of their own, from where the first one starts.
            let paths = entryPaths
            return columns.runs(from: box.left, to: box.right).flatMap { run in
                let runLeft = columns.columnStart(run.column)
                let inRun = DragSelectionBox(
                    left: box.left - runLeft, top: box.top - run.top, right: box.right - runLeft,
                    bottom: box.bottom - run.top)
                return DragSelection.flowListItems(
                    box: inRun, entryPaths: Array(paths[run.items]), rowsPerColumn: run.count,
                    rowHeight: layout.rowHeight, itemWidth: layout.itemWidth, columnGap: layout.columnGap, sizes: sizes
                ).map { $0.moved(left: runLeft, top: run.top) }
            }
        }
        let inItems = DragSelectionBox(
            left: box.left - left, top: box.top - top, right: box.right - left, bottom: box.bottom - top)
        return DragSelection.flowListItems(
            box: inItems, entryPaths: entryPaths, rowsPerColumn: rowsPerColumn, rowHeight: layout.rowHeight,
            itemWidth: layout.itemWidth, columnGap: layout.columnGap, sizes: sizes
        ).map { hit in
            var moved = hit
            moved.rect = DragSelectionBox(
                left: hit.rect.left + left, top: hit.rect.top + top, right: hit.rect.right + left,
                bottom: hit.rect.bottom + top)
            return moved
        }
    }

    // MARK: Resizing the columns

    /// A new column width (the status bar's slider) resizes the columns in place, the column at the left of the view
    /// keeping its left edge where it is, then the lead brought back into view if it was in view, and an item out of
    /// view left there; a new density lays the list out again, the lead kept in view as well.
    override func columnsChanged() {
        guard let restoreScroll = scrollAnchor() else {
            super.columnsChanged()
            return
        }
        let leadWasInView = leadIsInView
        guard metricsChanged() else { return }
        placeItems()
        restoreScroll()
        positionRenameField()
        keepInViewAfterStep(leadWasInView)
    }

    override func scrollAnchor() -> (() -> Void)? {
        guard (host?.columnState.density ?? .standard) == density else { return nil }
        let startWidth = layout.itemWidth
        let startScroll = Double(scroll.contentView.bounds.origin.x)
        let column = layout.column(atScrollLeft: startScroll)
        return { [self] in
            let left = layout.anchoredScrollLeft(column: column, startWidth: startWidth, startScrollLeft: startScroll)
            scrollClamped(to: NSPoint(x: left, y: scroll.contentView.bounds.origin.y))
        }
    }

    // MARK: Keeping the selection in view

    /// The lead only: the item being renamed and a refused name aren't brought into view here.
    override var keepsRenameInView: Bool { false }

    /// Sideways only: the lead's column is brought whole into view.
    override func revealOffset(for index: Int) -> NSPoint? {
        let clip = scroll.contentView.bounds
        guard clip.width > 0, clip.height > 0 else { return nil }
        let maxLeft = max(0, Double(collection.frame.width - clip.width))
        if let columns = columns(height: viewport.height), let place = columns.place(ofItem: index) {
            // Grouped: the item's column whole in view, moving as little as possible.
            var left = Double(clip.origin.x)
            let start = columns.columnStart(place.column)
            let right = start + layout.itemWidth
            if start < left {
                left = start - layout.paddingInline
            } else if right > left + Double(clip.width) {
                left = right + layout.paddingInline - Double(clip.width)
            }
            return NSPoint(x: min(maxLeft, max(0, left)), y: clip.origin.y)
        }
        let left = layout.revealScrollLeft(
            currentScrollLeft: Double(clip.origin.x), viewportWidth: Double(clip.width), itemIndex: index,
            rowsPerColumn: rowsPerColumn, maxScrollLeft: maxLeft)
        return NSPoint(x: left, y: clip.origin.y)
    }

    // MARK: Keys

    override var itemsPerLine: Int { rowsPerColumn }

    /// A line is a column and its gap; the viewport is the width less the padding, plus the gap the last column needs
    /// not.
    override var pageGeometry: (viewportSize: Double, lineExtent: Double) {
        (layout.pageViewport(viewportWidth: Double(scroll.contentView.bounds.width)), layout.columnStep)
    }

    override func isWhollyInView(index: Int) -> Bool {
        guard let offset = revealOffset(for: index) else { return false }
        return abs(offset.x - scroll.contentView.bounds.origin.x) <= 1
    }

    @discardableResult
    override func scroll(by delta: Double) -> Bool {
        scrollAlong(vertical: false, by: delta)
    }

    // MARK: Rename

    /// The rename field in the item's name cell: 5 to the left of the name it replaces, 3 short of the item's right
    /// edge, 20 tall, in the middle of the row.
    override func renameFrame(at index: Int) -> NSRect {
        let item = itemFrame(at: index, viewport: viewport)
        let rename = SelectionLayout.Rename.self
        let inset = style.borderWidth + style.paddingInline
        let x = item.minX + inset + layout.iconSize + layout.iconGap + rename.marginLeft
        let right = item.maxX - inset - rename.marginRight
        return NSRect(
            x: x, y: item.minY + (item.height - rename.height) / 2, width: max(0, right - x), height: rename.height)
    }

    /// The name's font size in both densities.
    override func renameFont() -> NSFont { ThemeFonts.sans(DesignTokens.typeScale.name) }
}
