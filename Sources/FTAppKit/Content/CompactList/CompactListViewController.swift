// Port of FlowListView (apps/desktop/src/renderer/components/ContentPane.tsx:1082-1404): the Compact List, names in
// columns that fill top to bottom and scroll sideways, placed from lib/flowListLayout.ts and virtualization.ts
import AppKit
import FTFileSystem
import FTFoundation

/// The Compact List: each column is filled top to bottom, then the next one to the right; the list scrolls sideways,
/// and the wheel's up and down scroll it sideways too.
final class CompactListViewController: ItemGridPane {
    private(set) var density = Density.comfortable
    private(set) var layout = DesignTokens.flowList(density: .comfortable)
    let style = FlowItemStyle.make()
    private(set) var nameFont = ThemeFonts.sans(DesignTokens.flowList(density: .comfortable).fontSize)
    /// Names measured in the list's font, by name.
    private var nameWidths: [String: Double] = [:]

    override var navigationViewMode: ExplorerViewMode { .list }
    override var itemIdentifier: NSUserInterfaceItemIdentifier { CompactListItem.identifier }

    override func loadView() {
        super.loadView()
        collection.register(CompactListItem.self, forItemWithIdentifier: CompactListItem.identifier)
        collection.setAccessibilityIdentifier("compactList.grid")
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = true
        scroll.verticalScrollElasticity = .none
        scroll.wheelScrollsSideways = true
    }

    override func metricsChanged() -> Bool {
        let next = host?.columnState.flowDensity ?? .comfortable
        guard next != density else { return false }
        density = next
        layout = DesignTokens.flowList(density: next)
        nameFont = ThemeFonts.sans(layout.fontSize)
        nameWidths = [:]
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

    /// `computeRowsPerColumn` of the pane's height; the arrow keys move by it sideways.
    var rowsPerColumn: Int { layout.rowsPerColumn(containerHeight: Double(viewport.height)) }

    private func nameWidth(_ name: String) -> Double {
        if let known = nameWidths[name] { return known }
        let width = Double((name as NSString).size(withAttributes: [.font: nameFont]).width)
        nameWidths[name] = width
        return width
    }

    override func contentSize(viewport: NSSize) -> NSSize {
        let rows = layout.rowsPerColumn(containerHeight: Double(viewport.height))
        return NSSize(
            width: layout.contentWidth(itemCount: entries.count, rowsPerColumn: rows), height: viewport.height)
    }

    override func itemFrame(at index: Int, viewport: NSSize) -> NSRect {
        let rows = layout.rowsPerColumn(containerHeight: Double(viewport.height))
        let cell = layout.cellFrame(index: index, rowsPerColumn: rows)
        // An item hugs its icon and name; one being renamed keeps its column, for the field.
        let renaming = entries.indices.contains(index) && entries[index].path == renamingPath
        let width =
            renaming || !entries.indices.contains(index)
            ? cell.width : layout.itemWidth(nameWidth: markedNameWidth(entries[index]), style: style)
        return NSRect(x: cell.x, y: cell.y, width: width, height: cell.height)
    }

    /// The name's width, and the clipboard glyph after it with its gap on an item on the clipboard (P5-08).
    private func markedNameWidth(_ entry: DirectoryEntry) -> Double {
        let width = nameWidth(entry.name)
        guard host?.clipboardMarks?.mark(for: entry.path) != nil else { return width }
        return width + ClipboardLayout.Mark.gap + ClipboardLayout.Mark.iconSize
    }

    /// The marks changed: a marked item is wider by its glyph.
    override func clipboardMarksChanged() {
        gridLayout.invalidateLayout()
        placeItems()
        super.clipboardMarksChanged()
    }

    override func items(in rect: NSRect, viewport: NSSize) -> Range<Int> {
        layout.items(
            left: Double(rect.minX), right: Double(rect.maxX), itemCount: entries.count,
            rowsPerColumn: layout.rowsPerColumn(containerHeight: Double(viewport.height)))
    }

    /// Only the height moves items.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old.height != new.height }

    // MARK: Drag-to-select

    /// `getFlowListItemsInBox`, in the coordinates of the list's rows (inside its padding).
    override func marqueeHits(box: DragSelectionBox, sizes: [String: DragSelectionSize]) -> [DragSelectionHit] {
        let left = layout.paddingInline
        let top = layout.paddingTop
        let inItems = DragSelectionBox(
            left: box.left - left, top: box.top - top, right: box.right - left, bottom: box.bottom - top)
        return DragSelection.flowListItems(
            box: inItems, entryPaths: entries.map(\.path), rowsPerColumn: rowsPerColumn, rowHeight: layout.rowHeight,
            itemWidth: layout.itemWidth, columnGap: layout.columnGap, sizes: sizes
        ).map { hit in
            var moved = hit
            moved.rect = DragSelectionBox(
                left: hit.rect.left + left, top: hit.rect.top + top, right: hit.rect.right + left,
                bottom: hit.rect.bottom + top)
            return moved
        }
    }

    // MARK: Keeping the selection in view

    /// The lead only: the item being renamed and a refused name aren't brought into view here (ContentPane.tsx:1236).
    override var keepsRenameInView: Bool { false }

    /// Sideways only: the lead's column is brought whole into view (B-VIEW-037).
    override func revealOffset(for index: Int) -> NSPoint? {
        let clip = scroll.contentView.bounds
        guard clip.width > 0, clip.height > 0 else { return nil }
        let maxLeft = max(0, Double(collection.frame.width - clip.width))
        let left = layout.revealScrollLeft(
            currentScrollLeft: Double(clip.origin.x), viewportWidth: Double(clip.width), itemIndex: index,
            rowsPerColumn: rowsPerColumn, maxScrollLeft: maxLeft)
        return NSPoint(x: left, y: clip.origin.y)
    }

    // MARK: Keys

    override var itemsPerLine: Int { rowsPerColumn }

    /// A line is a column and its gap; the viewport is the width less the padding, plus the gap the last column needs
    /// not (B-VIEW-088).
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

    /// `.inline-rename-input` in the item's name cell: 5 to the left of the name it replaces, 3 short of the item's
    /// right edge, 20 tall, in the middle of the row.
    override func renameFrame(at index: Int) -> NSRect {
        let item = itemFrame(at: index, viewport: viewport)
        let rename = SelectionLayout.Rename.self
        let inset = style.borderWidth + style.paddingInline
        let x = item.minX + inset + layout.iconSize + layout.iconGap + rename.marginLeft
        let right = item.maxX - inset - rename.marginRight
        return NSRect(
            x: x, y: item.minY + (item.height - rename.height) / 2, width: max(0, right - x), height: rename.height)
    }

    /// `font-size: var(--font-size-name)` in both densities.
    override func renameFont() -> NSFont { ThemeFonts.sans(DesignTokens.typeScale.name) }
}
