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
    private var placesBefore: [DiskPath: NSPoint]?

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

    // MARK: Previews ahead

    /// Whether the pane asks for the previews of the page past the items made: the Previews view asks for its own
    /// pages (`PreviewsViewController.prefetchNextPages`).
    var asksForThePageAhead: Bool { true }
    /// The previews asked for ahead of need, by path.
    private var aheadOfScreen: [DiskPath: LoadHandle] = [:]
    private var aheadWait: DispatchWorkItem?
    private var lastTopAhead = 0.0
    private var aheadGoesUp = false

    /// The previews of a screen of items past those made, the way the pane last scrolled first and then the other way,
    /// asked for behind every preview on screen, so they never hold one up, a tenth of a second after the scroll last
    /// moved: the rows coming into view no longer wait for theirs ("What the folder on screen needs is read for it,
    /// ahead of the scroll"). Those no longer that near are taken back if they have not started.
    override func itemsOnScreenChanged() {
        lastMoved = ContinuousClock.now
        // Fitting that stopped while the tab was out of sight goes on.
        if fitWork == nil, fitNext < namesToFitAhead { fitNextNames(after: 0.25) }
        guard asksForThePageAhead else { return }
        let top = Double(scroll.contentView.bounds.origin.y)
        if top != lastTopAhead { aheadGoesUp = top < lastTopAhead }
        lastTopAhead = top
        aheadWait?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.askForThePageAhead() }
        }
        aheadWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func askForThePageAhead() {
        aheadWait = nil
        let made = collection.indexPathsForVisibleItems().map(\.item).filter { entries.indices.contains($0) }
        var wanted: [Int] = []
        let clip = scroll.contentView.bounds
        if view.window != nil, let lower = made.min(), let upper = made.max() {
            let page = max(1, items(in: clip, viewport: clip.size).count)
            let below = Array((upper + 1)..<min(entries.count, upper + 1 + page))
            let above = Array((max(0, lower - page)..<lower).reversed())
            wanted = aheadGoesUp ? above + below : below + above
        }
        let paths = Set(wanted.lazy.map { self.keys[$0] })
        for (path, handle) in aheadOfScreen where !paths.contains(path) { handle.cancel() }
        aheadOfScreen = aheadOfScreen.filter { paths.contains($0.key) }
        let size = thumbnailPixelSize
        for index in wanted where aheadOfScreen[keys[index]] == nil {
            let entry = entries[index]
            guard thumbnailStore.mayHaveThumbnail(entry.iconEntry.kind) else { continue }
            aheadOfScreen[keys[index]] = thumbnailStore.prefetch(
                path: entry.path, kind: entry.iconEntry.kind, size: size, listing: listing)
        }
    }

    override func reload(scrollToTop: Bool) {
        // Another listing: what was asked for ahead is asked again for it.
        for handle in aheadOfScreen.values { handle.cancel() }
        aheadOfScreen = [:]
        super.reload(scrollToTop: scrollToTop)
        // Another folder, or the same from its top: the way the last one was scrolled says nothing of this one.
        lastTopAhead = Double(scroll.contentView.bounds.origin.y)
        aheadGoesUp = false
        fitNamesAhead()
    }

    // MARK: Names fitted ahead

    /// The next item whose name is fitted ahead, and the turn of the main thread that fits the next few.
    private var fitNext = 0
    private var fitWork: DispatchWorkItem?
    /// When the items on screen last changed: a scroll, a reload.
    private var lastMoved = ContinuousClock.now
    /// How many times in a row the fitting found its tab out of sight.
    private var fitLooksWhileHidden = 0

    /// Fits the names of the folder's items under their icons while the main thread is idle, so that the items a first
    /// scroll brings in find theirs ready (`IconLabelText` keeps them): fitting a name is most of what an item costs
    /// as it comes on screen, and a first flick through ten thousand items took a third longer than a second one. It
    /// starts once the folder is drawn, takes 2 ms at most at a time, and waits while the folder scrolls, when the
    /// items coming in fit their own, and while its tab is out of sight. It reads nothing, so it is within "nothing is
    /// read for what isn't shown". A name is fitted as an item without tag dots fits it, as most are.
    private func fitNamesAhead() {
        fitWork?.cancel()
        fitNext = 0
        fitLooksWhileHidden = 0
        fitNextNames(after: 0.25)
    }

    private func fitNextNames(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fitSomeNames() }
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Whether the pane fits its names ahead: the Previews view shows a few items a screen, at a label width that
    /// follows the pane's, and fitting the rest would be work thrown away at each width.
    var fitsNamesAhead: Bool { true }

    /// How many names are fitted ahead: half of what `IconLabelText` keeps before it starts over, so that one large
    /// folder, fitted from nothing kept, never makes it start over itself. Names kept from other folders may still
    /// bring it there; the names of the items on screen are then fitted again as they are drawn.
    private var namesToFitAhead: Int { fitsNamesAhead ? min(entries.count, IconLabel.fittedLabelCacheMax / 2) : 0 }

    private func fitSomeNames() {
        fitWork = nil
        guard fitNext < namesToFitAhead else { return }
        // Only while the tab shows: a tab out of sight looks again each second for half a minute, then waits for its
        // items to change again (`itemsOnScreenChanged`), as when it comes back.
        guard view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else {
            fitLooksWhileHidden += 1
            if fitLooksWhileHidden < 30 { fitNextNames(after: 1) }
            return
        }
        fitLooksWhileHidden = 0
        let now = ContinuousClock.now
        guard now - lastMoved > .milliseconds(250) else {
            fitNextNames(after: 0.25)
            return
        }
        let layout = self.layout
        while fitNext < namesToFitAhead, ContinuousClock.now - now < .milliseconds(2) {
            let entry = entries[fitNext]
            fitNext += 1
            let fitted = IconLabelText.fit(name: entry.name, extension: entry.fileExtension, layout: layout)
            _ = IconLabelText.lines(fitted, layout: layout)
            _ = IconLabelText.width(fitted, layout: layout)
        }
        if fitNext < namesToFitAhead { fitNextNames(after: 0.001) }
    }

    isolated deinit {
        fitWork?.cancel()
        aheadWait?.cancel()
        for handle in aheadOfScreen.values { handle.cancel() }
    }

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
        let changed =
            layout.labelFontSize != self.layout.labelFontSize
            || layout.labelTextWidth != self.layout.labelTextWidth
        self.density = density
        self.layout = layout
        style = IconItemStyle.make(density: density)
        if changed { fitNamesAhead() }
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
        fitNamesAhead()
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
        (item as? IconItem)?.configure(entry: entry, key: keys[index], pane: self)
    }

    override func refreshLook(of item: NSCollectionViewItem, at index: Int) {
        (item as? IconItem)?.applyLook(pane: self, entry: entries[index], key: keys[index])
    }

    /// The previews of the files are checked again: at once for the items on screen, which keep their picture until a
    /// new one comes, and when the others come into view.
    override func filesChanged(paths: Set<DiskPath>?) {
        thumbnailStore.markChanged(paths)
        forEachVisibleIndex { item, index in
            if paths?.contains(keys[index]) != false {
                (item as? IconItem)?.loadThumbnail(entries[index], key: keys[index], pane: self)
            }
        }
    }

    /// The previews of the items taken out and put in are checked against their files again, as a new listing's are: a
    /// file put in where one was taken out, under its name, is another file.
    /// Marked before the items are put in, which ask for their previews as they are made; marking more than goes in,
    /// when the change is refused and every item drawn again, costs only a look at those files.
    override func apply(_ change: ListChange) -> Bool {
        let after = host?.entryKeys ?? []
        let removed = change.removed.compactMap { keys.indices.contains($0) ? keys[$0] : nil }
        let inserted = change.inserted.compactMap { after.indices.contains($0) ? after[$0] : nil }
        thumbnailStore.markChanged(Set(removed + inserted))
        guard super.apply(change) else { return false }
        // The names put in are fitted with the rest; those fitted before are kept, and pass at once.
        fitNamesAhead()
        return true
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
    override func marqueeHits(box: DragSelectionBox, sizes: [DiskPath: DragSelectionSize]) -> [DragSelectionHit] {
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
    func gridHits(box: DragSelectionBox, paths: [String], sizes: [DiskPath: DragSelectionSize]) -> [DragSelectionHit] {
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
        var places: [DiskPath: NSPoint] = [:]
        forEachVisibleIndex { item, index in places[keys[index]] = item.view.frame.origin }
        placesBefore = places
    }

    /// An item's picture came, or gave way to its icon, and its place has another shape (the Previews view, where
    /// the name follows the picture).
    func pictureShapeChanged(of path: DiskPath) {}

    override func didPlaceItems() {
        guard let before = placesBefore else { return }
        placesBefore = nil
        let duration = WorkspaceView.slideDuration
        let easing = DesignTokens.motion.easing
        forEachVisibleIndex { item, index in
            guard let old = before[keys[index]], let layer = item.view.layer ?? Self.layer(of: item.view) else {
                return
            }
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
