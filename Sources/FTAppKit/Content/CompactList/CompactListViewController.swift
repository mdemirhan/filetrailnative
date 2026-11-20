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
        (item as? CompactListItem)?.configure(entry: entry, pane: self)
    }

    override func refreshLook(of item: NSCollectionViewItem, entry: DirectoryEntry) {
        (item as? CompactListItem)?.applyLook(pane: self, entry: entry)
    }

    // MARK: Placement

    /// The rows per column at the pane's height; the arrow keys move by it sideways.
    var rowsPerColumn: Int {
        layout.rowsPerColumn(containerHeight: Double(viewport.height) - (groups.isEmpty ? 0 : headerHeight))
    }

    // MARK: Groups

    /// A group's title over its columns: the rows start under it.
    private var headerHeight: Double { Double(GroupHeaderView.gridHeight) }
    /// The room between two groups' columns.
    private var groupGap: Double { layout.columnGap * 2 }

    private struct LinesKey: Equatable {
        var listing: ObjectIdentifier
        var counts: [Int]
        var rows: Int
        var columnStep: Double
        var start: Double
    }
    private var linesCache: (key: LinesKey, lines: GroupedLines)?

    /// The groups side by side, each starting a column of its own under its title, while the items are grouped.
    func lines(height: CGFloat) -> GroupedLines? {
        guard !groups.isEmpty else { return nil }
        let key = LinesKey(
            listing: ObjectIdentifier(listing), counts: groups.map(\.range.count),
            rows: layout.rowsPerColumn(containerHeight: Double(height) - headerHeight), columnStep: layout.columnStep,
            start: layout.paddingInline)
        if let cached = linesCache, cached.key == key { return cached.lines }
        let made = GroupedLines(
            counts: key.counts, perLine: key.rows, lineExtent: key.columnStep, headerExtent: 0, groupGap: groupGap,
            start: key.start)
        linesCache = (key, made)
        return made
    }

    override var groupedLines: GroupedLines? { lines(height: viewport.height) }

    override func headerFrames(viewport: NSSize) -> [NSRect] {
        guard let lines = lines(height: viewport.height) else { return [] }
        return lines.groups.map { group in
            // As wide as its columns, and at least a column for a group with few items.
            let width = max(layout.itemWidth, Double(group.lineCount) * layout.columnStep - layout.columnGap)
            return NSRect(x: group.headerStart, y: 0, width: width, height: headerHeight)
        }
    }

    override var groupsEnd: Double { lines(height: viewport.height)?.end ?? super.groupsEnd }

    /// The title stays at the left edge while its group's columns scroll under it sideways.
    override func pinned(_ frame: NSRect, until end: Double, in clip: NSRect, header: GroupHeaderView) -> NSRect {
        let held = max(0, min(clip.minX - frame.minX, frame.width - 120))
        header.leadingInset = 16 + held
        return frame
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
        if let lines = lines(height: viewport.height) {
            return NSSize(width: lines.end - groupGap + layout.paddingInline, height: viewport.height)
        }
        let rows = layout.rowsPerColumn(containerHeight: Double(viewport.height))
        return NSSize(
            width: layout.contentWidth(itemCount: entries.count, rowsPerColumn: rows), height: viewport.height)
    }

    override func itemFrame(at index: Int, viewport: NSSize) -> NSRect {
        var cell: GridRect
        if let lines = lines(height: viewport.height), let place = lines.place(ofItem: index) {
            // Grouped: in its group's column, under the group's title.
            cell = layout.cellFrame(index: place.slot, rowsPerColumn: lines.perLine)
            cell.x = place.lineStart
            cell.y += headerHeight
        } else {
            cell = layout.cellFrame(
                index: index, rowsPerColumn: layout.rowsPerColumn(containerHeight: Double(viewport.height)))
        }
        // An item hugs its icon and name; one being renamed keeps its column, for the field.
        let renaming = entries.indices.contains(index) && entries[index].path == renamingPath
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
    override func refresh(paths: Set<String>?) {
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
        if let lines = lines(height: viewport.height) {
            return lines.items(from: Double(rect.minX), to: Double(rect.maxX))
        }
        return layout.items(
            left: Double(rect.minX), right: Double(rect.maxX), itemCount: entries.count,
            rowsPerColumn: layout.rowsPerColumn(containerHeight: Double(viewport.height)))
    }

    /// Only the height moves items.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old.height != new.height }

    // MARK: Drag-to-select

    /// In the coordinates of the list's rows (inside its padding).
    override func marqueeHits(box: DragSelectionBox, sizes: [String: DragSelectionSize]) -> [DragSelectionHit] {
        let left = layout.paddingInline
        let top = layout.paddingTop
        if let lines = lines(height: viewport.height) {
            // Grouped, each group's columns as a list of their own, from its first column and under its title.
            var hits: [DragSelectionHit] = []
            let paths = entryPaths
            let groupTop = top + headerHeight
            for number in lines.groups(from: box.left, to: box.right) {
                let group = lines.groups[number]
                guard group.count > 0 else { continue }
                let inGroup = DragSelectionBox(
                    left: box.left - group.linesStart, top: box.top - groupTop, right: box.right - group.linesStart,
                    bottom: box.bottom - groupTop)
                hits += DragSelection.flowListItems(
                    box: inGroup, entryPaths: Array(paths[group.items]), rowsPerColumn: lines.perLine,
                    rowHeight: layout.rowHeight, itemWidth: layout.itemWidth, columnGap: layout.columnGap,
                    sizes: sizes
                ).map { $0.moved(left: group.linesStart, top: groupTop) }
            }
            return hits
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
        if let place = lines(height: viewport.height)?.place(ofItem: index) {
            // Grouped: the item's column whole in view, moving as little as possible.
            var left = Double(clip.origin.x)
            let right = place.lineStart + layout.itemWidth
            if place.lineStart < left {
                left = place.lineStart - layout.paddingInline
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
