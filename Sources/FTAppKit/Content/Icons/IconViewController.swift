// The Icon view, an NSCollectionView whose items are placed from the icon grid's tokens, with the Info panel's glide of
// the items
import AppKit
import FTFileSystem
import FTFoundation

/// The Icon view: large icons that read left to right and scroll down, in columns that share the pane's width. Files show
/// the Quick Look preview of their content where there is one.
class IconViewController: ItemGridPane {
    private(set) var density = Density.standard
    private(set) var layout = DesignTokens.iconGrid(density: .standard)
    private(set) var style = IconItemStyle.make(density: .standard)
    /// Where the items on screen were, while the Info panel opens or closes the pane's width changes in one step.
    private var placesBefore: [String: NSPoint]?

    override var navigationViewMode: ExplorerViewMode { .icons }
    override var itemIdentifier: NSUserInterfaceItemIdentifier { IconItem.identifier }

    /// The grid's name for automation.
    var gridIdentifier: String { "icons.grid" }

    /// Where the previews of the files' content come from, and the pixels they are asked for at.
    var thumbnailStore: ThumbnailStore { IconThumbnails.store }
    var thumbnailPixelSize: Int { ThumbnailStore.pixelSize(forIconSize: layout.iconSize) }

    /// Each item's picture fills its place, whatever its shape, with the name right under it (the Previews view);
    /// otherwise it sits in a square box of the icon's size.
    var picturesFillTheirPlace: Bool { false }

    /// How long an item whose preview isn't known yet draws nothing before it shows the icon: none, as an icon's
    /// small preview is no larger than the icon it replaces.
    var iconWait: TimeInterval { 0 }

    /// What shows when the pointer rests on an item: its whole name, for one shortened in the middle.
    func toolTip(for entry: DirectoryEntry) -> String { entry.name }

    override func loadView() {
        super.loadView()
        collection.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collection.setAccessibilityIdentifier(gridIdentifier)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        collection.wantsLayer = true
    }

    /// Another grid for the items: the Previews view fits its own to the pane.
    func setGrid(density: Density, layout: IconGridLayout) {
        self.density = density
        self.layout = layout
        style = IconItemStyle.make(density: density)
    }

    /// The density's grid, at the icon size saved for it.
    override func metricsChanged() -> Bool {
        let next = host?.columnState.density ?? .standard
        let size = Double(host?.columnState.iconSizes[next] ?? DensitySizes.iconDefaults[next])
        guard next != density || size != layout.iconSize else { return false }
        density = next
        layout = DesignTokens.iconGrid(density: next).sized(iconSize: size)
        style = IconItemStyle.make(density: next)
        collection.collectionViewLayout?.invalidateLayout()
        return true
    }

    /// A new icon size or density keeps the item at the top left of the view where it is on screen: the rows before
    /// it grow or shrink, and its own row may hold more or fewer items.
    override func scrollAnchor() -> (() -> Void)? {
        guard !entries.isEmpty else { return nil }
        let clip = scroll.contentView
        let top = Double(clip.bounds.origin.y)
        let row = layout.row(atScrollTop: top)
        let index = min(row * columns, entries.count - 1)
        let offset = layout.paddingTop + Double(row) * layout.rowHeight - top
        return { [self] in
            let next = layout.anchoredScrollTop(index: index, columns: columns, offset: offset)
            scrollClamped(to: NSPoint(x: clip.bounds.origin.x, y: next))
        }
    }

    override func configure(_ item: NSCollectionViewItem, entry: DirectoryEntry, index: Int) {
        (item as? IconItem)?.configure(entry: entry, pane: self)
    }

    override func refreshLook(of item: NSCollectionViewItem, entry: DirectoryEntry) {
        (item as? IconItem)?.applyLook(pane: self, entry: entry)
    }

    /// The previews of the files are checked again: at once for the items on screen, which keep their picture until a
    /// new one comes, and when the others come into view.
    override func filesChanged(paths: Set<String>?) {
        thumbnailStore.markChanged(paths)
        forEachVisibleItem { item, entry in
            if paths?.contains(entry.path) != false { (item as? IconItem)?.loadThumbnail(entry, pane: self) }
        }
    }

    // MARK: Placement

    /// How many columns the pane holds; the arrow keys and pages step by them.
    var columns: Int { layout.columns(containerWidth: Double(viewport.width)) }

    override func contentSize(viewport: NSSize) -> NSSize {
        if let lines = lines(width: viewport.width) {
            return NSSize(width: viewport.width, height: lines.end + layout.paddingBottom)
        }
        let columns = layout.columns(containerWidth: Double(viewport.width))
        return NSSize(width: viewport.width, height: layout.contentHeight(itemCount: entries.count, columns: columns))
    }

    override func itemFrame(at index: Int, viewport: NSSize) -> NSRect {
        let width = Double(viewport.width)
        // Grouped, an item is placed as the first line's item in its slot, on its own line.
        let place = lines(width: viewport.width)?.place(ofItem: index)
        let frame = layout.itemFrame(
            index: place?.slot ?? index, columns: layout.columns(containerWidth: width), containerWidth: width,
            style: style)
        return NSRect(x: frame.x, y: place?.lineStart ?? frame.y, width: frame.width, height: frame.height)
    }

    override func items(in rect: NSRect, viewport: NSSize) -> Range<Int> {
        if let lines = lines(width: viewport.width) {
            return lines.items(from: Double(rect.minY), to: Double(rect.maxY))
        }
        return layout.items(
            top: Double(rect.minY), bottom: Double(rect.maxY), itemCount: entries.count,
            columns: layout.columns(containerWidth: Double(viewport.width)))
    }

    /// Only the width moves items.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old.width != new.width }

    // MARK: Groups

    /// The room a group's header takes above its items: none in Previews, which shows no headers.
    var groupHeaderExtent: Double { Double(GroupHeaderView.gridHeight) }

    private struct LinesKey: Equatable {
        var listing: ObjectIdentifier
        var counts: [Int]
        var columns: Int
        var rowHeight: Double
        var headerExtent: Double
        var top: Double
    }
    private var linesCache: (key: LinesKey, lines: GroupedLines)?

    /// The groups' lines at a pane this wide, while the items are grouped: each group's header, then its rows.
    func lines(width: CGFloat) -> GroupedLines? {
        guard !groups.isEmpty else { return nil }
        let key = LinesKey(
            listing: ObjectIdentifier(listing), counts: groups.map(\.range.count),
            columns: layout.columns(containerWidth: Double(width)), rowHeight: layout.rowHeight,
            headerExtent: groupHeaderExtent, top: layout.paddingTop)
        if let cached = linesCache, cached.key == key { return cached.lines }
        let made = GroupedLines(
            counts: key.counts, perLine: key.columns, lineExtent: key.rowHeight, headerExtent: key.headerExtent,
            start: key.top)
        linesCache = (key, made)
        return made
    }

    override var groupedLines: GroupedLines? { lines(width: viewport.width) }

    override func headerFrames(viewport: NSSize) -> [NSRect] {
        guard groupHeaderExtent > 0, let lines = lines(width: viewport.width) else { return [] }
        return lines.groups.map {
            NSRect(x: 0, y: $0.headerStart, width: viewport.width, height: groupHeaderExtent)
        }
    }

    override var groupsEnd: Double { lines(width: viewport.width)?.end ?? super.groupsEnd }

    // MARK: Drag-to-select

    /// In the coordinates of the grid's items (inside the pane's padding).
    override func marqueeHits(box: DragSelectionBox, sizes: [String: DragSelectionSize]) -> [DragSelectionHit] {
        let left = layout.paddingInline
        let top = layout.paddingTop
        let inItems = DragSelectionBox(
            left: box.left - left, top: box.top - top, right: box.right - left, bottom: box.bottom - top)
        guard let lines = lines(width: viewport.width) else {
            return gridHits(box: inItems, paths: entryPaths, sizes: sizes).map { $0.moved(left: left, top: top) }
        }
        // Grouped, each group's items as a grid of their own, from its first line.
        var hits: [DragSelectionHit] = []
        let paths = entryPaths
        for number in lines.groups(from: box.top, to: box.bottom) {
            let group = lines.groups[number]
            guard group.count > 0 else { continue }
            let groupTop = group.linesStart
            let inGroup = DragSelectionBox(
                left: box.left - left, top: box.top - groupTop, right: box.right - left, bottom: box.bottom - groupTop)
            hits += gridHits(box: inGroup, paths: Array(paths[group.items]), sizes: sizes)
                .map { $0.moved(left: left, top: groupTop) }
        }
        return hits
    }

    /// The items of `paths`, laid out as a grid from the box's origin, that a box touches: all the pane's items, or
    /// one group's. Sizes are of the names; the hit test places them itself.
    func gridHits(box: DragSelectionBox, paths: [String], sizes: [String: DragSelectionSize]) -> [DragSelectionHit] {
        DragSelection.iconGridItems(
            box: box, entryPaths: paths, columns: columns,
            gridWidth: layout.gridWidth(containerWidth: Double(viewport.width)), layout: layout, sizes: sizes)
    }

    // MARK: Keeping the selection in view

    override func revealOffset(for index: Int) -> NSPoint? {
        let clip = scroll.contentView.bounds
        guard clip.height > 0 else { return nil }
        if let place = lines(width: viewport.width)?.place(ofItem: index) {
            // Grouped: the item's row whole below the header held at the top, moving as little as possible.
            let top = place.lineStart - groupHeaderExtent
            let bottom = place.lineStart + layout.rowHeight
            var y = Double(clip.origin.y)
            if top < y { y = top } else if bottom > y + Double(clip.height) { y = bottom - Double(clip.height) }
            return NSPoint(x: clip.origin.x, y: max(0, y))
        }
        let top = layout.revealScrollTop(
            currentScrollTop: Double(clip.origin.y), viewportHeight: Double(clip.height), itemIndex: index,
            itemCount: entries.count, columns: columns)
        return NSPoint(x: clip.origin.x, y: top)
    }

    // MARK: Keys

    override var itemsPerLine: Int { columns }

    override var pageGeometry: (viewportSize: Double, lineExtent: Double) {
        (Double(scroll.contentView.bounds.height), layout.lineExtent)
    }

    override func isWhollyInView(index: Int) -> Bool {
        guard let offset = revealOffset(for: index) else { return false }
        return abs(offset.y - scroll.contentView.bounds.origin.y) <= 1
    }

    @discardableResult
    override func scroll(by delta: Double) -> Bool {
        scrollAlong(vertical: true, by: delta)
    }

    // MARK: Rename

    /// The rename field over an icon: the label's width, 20 tall (19 with Finder's sizes), under the tile.
    override func renameFrame(at index: Int) -> NSRect {
        let item = itemFrame(at: index, viewport: viewport)
        let label = layout.labelFrame(textWidth: layout.labelWidth, lines: 1)
        return NSRect(
            x: item.minX + label.x, y: item.minY + label.y, width: label.width, height: style.renameHeight)
    }

    override func renameFont() -> NSFont { ThemeFonts.sans(style.renameFontSize) }

    override var renameAlignment: NSTextAlignment { .center }

    // MARK: The Info panel's glide

    /// The Info panel opening or closing changes the pane's width in one step: where the items were is kept, to move each
    /// from there to its new place. Items that move for another reason (a resize, new items) jump.
    override func paneWidthWillChange() {
        guard Self.infoPanelSliding(from: root) else {
            placesBefore = nil
            return
        }
        var places: [String: NSPoint] = [:]
        forEachVisibleItem { item, entry in places[entry.path] = item.view.frame.origin }
        placesBefore = places
    }

    /// An item's picture came, or gave way to its icon, and its place has another shape (the Previews view, where
    /// the name follows the picture).
    func pictureShapeChanged(of path: String) {}

    override func didPlaceItems() {
        guard let before = placesBefore else { return }
        placesBefore = nil
        let duration = WorkspaceView.slideDuration
        let easing = DesignTokens.motion.easing
        forEachVisibleItem { item, entry in
            guard let old = before[entry.path], let layer = item.view.layer ?? Self.layer(of: item.view) else { return }
            let place = item.view.frame.origin
            let dx = old.x - place.x
            let dy = old.y - place.y
            guard dx != 0 || dy != 0 else { return }
            layer.removeAnimation(forKey: Self.glideKey)
            let flipped = layer.superlayer?.contentsAreFlipped() ?? true
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = CATransform3DMakeTranslation(dx, flipped ? dy : -dy, 0)
            animation.toValue = CATransform3DIdentity
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(easing.x1), Float(easing.y1), Float(easing.x2), Float(easing.y2))
            layer.add(animation, forKey: Self.glideKey)
        }
    }

    static let glideKey = "icons.glide"

    private static func layer(of view: NSView) -> CALayer? {
        view.wantsLayer = true
        return view.layer
    }

    /// Whether the workspace around the view is sliding the Info panel in or out.
    static func infoPanelSliding(from view: NSView) -> Bool {
        var current = view.superview
        while let candidate = current {
            if let workspace = candidate as? WorkspaceView { return workspace.slide != nil }
            current = candidate.superview
        }
        return false
    }
}
