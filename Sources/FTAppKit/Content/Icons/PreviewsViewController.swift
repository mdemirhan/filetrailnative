// The Previews view: the Icons view's grid at the size of large previews, with a store of previews of its own that
// keeps under a memory limit
import AppKit
import FTFileSystem
import FTFoundation

/// The previews of the Previews view: large ones, so they are kept apart from the Icons view's (List and Compact List
/// show only icons) and under a memory limit of their own: 1 GB, less on a Mac with under 16 GB. When macOS is short
/// of memory they all go, and so they do a little after the last pane that shows the Previews view is gone. Those
/// scrolled far away, or let go, are asked of Quick Look again, whose cache on disk makes that cheap.
@MainActor
enum PreviewThumbnails {
    static let memoryLimit = ThumbnailStore.previewMemoryLimit(
        physicalMemory: ProcessInfo.processInfo.physicalMemory)
    static let store: ThumbnailStore = {
        let store = ThumbnailStore(maxEntries: ThumbnailStore.maxEntries, memoryLimit: memoryLimit)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { store.dropCached() }
        }
        source.resume()
        memoryPressure = source
        return store
    }()
    /// Tells of macOS running short of memory, for as long as the app runs.
    private static var memoryPressure: (any DispatchSourceMemoryPressure)?

    /// The panes that show the Previews view now: the previews go once there are none.
    static let panes = PreviewPanes { store.dropCached() }
}

/// Counts the panes that show the Previews view, and lets go of what they shared once the last one is gone: after a
/// short while, so that a change to another view and back, or to another folder's tab, asks for nothing again.
/// Nothing waits while a pane shows the view, or once they were let go.
@MainActor
final class PreviewPanes {
    /// How long after the last pane went.
    var delay: TimeInterval = 10
    private(set) var shown = 0
    private var letGo: DispatchWorkItem?
    private let drop: @MainActor () -> Void

    init(drop: @escaping @MainActor () -> Void) {
        self.drop = drop
    }

    /// Whether it is waiting to let go.
    var isWaiting: Bool { letGo != nil }

    func appeared() {
        shown += 1
        letGo?.cancel()
        letGo = nil
    }

    func disappeared() {
        shown = max(0, shown - 1)
        guard shown == 0 else { return }
        letGo?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown == 0 else { return }
                self.letGo = nil
                self.drop()
            }
        }
        letGo = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// Large previews of the files' content in a grid that scrolls down: 9, 4, 2 or 1 of them fill the pane at a time
/// (`PreviewGrid`), as large as that many fit, so a narrower pane shows as many, smaller. Everything else is the Icons
/// view's: selection, keys, drags, rename.
final class PreviewsViewController: IconViewController {
    /// The pane's size the grid was last fitted to.
    private var fittedTo = NSSize.zero

    override var navigationViewMode: ExplorerViewMode { .previews }
    override var gridIdentifier: String { "previews.grid" }

    /// How many previews fill the pane, as the preferences have it.
    var count: Int {
        let density = host?.columnState.density ?? .standard
        return PreviewGrid.valid(host?.columnState.previewCounts[density] ?? PreviewGrid.defaultCount)
    }

    /// The grid that fits the count in the pane as it is now.
    override func metricsChanged() -> Bool {
        let next = host?.columnState.density ?? .standard
        let size = viewport
        let fitted = PreviewGrid.layout(
            base: DesignTokens.iconGrid(density: next), count: count, width: Double(size.width),
            height: Double(size.height))
        fittedTo = size
        guard next != density || fitted != layout else { return false }
        // A scroll under way was in rows of the old height: the row kept at the top (`scrollAnchor`) is where it ends.
        settle?.cancel()
        settle = nil
        scrollStart = nil
        scrolledByDrag = false
        gridColumns = PreviewGrid.shape(count).columns
        gridCount = count
        setGrid(density: next, layout: fitted)
        collection.collectionViewLayout?.invalidateLayout()
        return true
    }

    /// Any change of the pane's size gives the previews another size: they are made again at it, and the row that was
    /// at the top stays there.
    override func fitGrid(to new: NSSize) {
        guard new != fittedTo else { return }
        let hadASize = fittedTo.width > 0 && fittedTo.height > 0
        let anchor = scrollAnchor()
        guard metricsChanged() else { return }
        collection.reloadData()
        dropPrefetches()
        // The row goes back to the top as soon as the items are placed, in the same layout and before the selection
        // is brought into view (`keepInView`), which then has the last word: put back a turn of the main loop later,
        // the row was drawn out of place in between, and undid a place the pane was scrolled to right after the
        // layout (a tab brought back, search results shown again, the selected item of a view just switched to).
        anchorOncePlaced = anchor
        if hadASize {
            // A window growing to full size, or dragged by its edge, changes the pane's size many times a second:
            // the previews keep the pictures they have, drawn at each size, and are asked for at the new one only
            // once the size rests, rather than made again at every step on the way.
            sharpenOnceTheSizeRests()
        } else {
            pixelSizeInUse = nil
        }
        prefetchSoon()
    }

    /// What puts the top row back once the items are placed for the pane's new size.
    private var anchorOncePlaced: (() -> Void)?

    private func putTopRowBack() {
        let anchor = anchorOncePlaced
        anchorOncePlaced = nil
        anchor?()
    }

    override func keepInView(_ change: RevealKeeper.Change) {
        putTopRowBack()
        super.keepInView(change)
    }

    override func didPlaceItems() {
        super.didPlaceItems()
        putTopRowBack()
    }

    /// How long the pane's size rests before its previews are asked for at it.
    static var sizeRest: TimeInterval = 0.25
    private var sharpen: DispatchWorkItem?

    private func sharpenOnceTheSizeRests() {
        sharpen?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sharpen = nil
                guard self.pixelSizeForThePane != self.pixelSizeInUse else { return }
                self.screenChanged()
            }
        }
        sharpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sizeRest, execute: work)
    }

    /// A name being edited stays under its picture when the picture comes or changes.
    override func pictureShapeChanged(of path: DiskPath) {
        if renamingPath == path { positionRenameField() }
    }

    /// The places follow the pane's width and its height.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old != new }

    /// Another count keeps the row that was mostly at the top, now at the top: the pane shows whole rows.
    override func scrollAnchor() -> (() -> Void)? {
        guard !entries.isEmpty else { return nil }
        let top = Double(scroll.contentView.bounds.origin.y)
        // By the columns the grid on screen was fitted with: counted from the pane's width, which has changed by
        // now, the old places give another number (2 across a pane a little narrower count as 1), and the row kept
        // was another row.
        let index = min(firstItem(onRow: layout.row(atScrollTop: top + layout.rowHeight / 2)), entries.count - 1)
        return { [self] in
            placing {
                scrollClamped(to: NSPoint(x: 0, y: Double(row(ofItem: index)) * layout.rowHeight))
            }
        }
    }

    /// The first file of a row: grouped, each group starts a row of its own, so rows aren't all full.
    private func firstItem(onRow row: Int) -> Int {
        guard let lines = groupedLines else { return row * max(1, gridColumns) }
        let items = lines.items(onLine: row)
        return items.isEmpty ? entries.count - 1 : items.lowerBound
    }

    /// The row a file is on.
    private func row(ofItem index: Int) -> Int {
        groupedLines?.place(ofItem: index)?.line ?? index / max(1, gridColumns)
    }

    // MARK: Groups

    /// No header rows: a row stays exactly the pane's height, which every rule of the file on screen at 1 at a time
    /// stands on. Each group starts on a row of its own, and a label over the pane names the group on screen.
    override var groupHeaderExtent: Double { 0 }

    /// The group of the row at the top, over the pane's top left corner on glass; made the first time it shows.
    private var groupLabelView: GroupLabelView?

    override func placeGroupHeaders() {
        super.placeGroupHeaders()
        guard let lines = groupedLines, let host, !entries.isEmpty, layout.rowHeight > 0 else {
            groupLabelView?.isHidden = true
            return
        }
        let groupLabel = groupLabelView ?? GroupLabelView()
        groupLabelView = groupLabel
        let top = Double(scroll.contentView.bounds.origin.y)
        let row = layout.row(atScrollTop: top + layout.rowHeight / 2)
        let first = lines.items(onLine: row).lowerBound
        guard let number = lines.group(ofItem: min(first, entries.count - 1)), groups.indices.contains(number) else {
            groupLabel.isHidden = true
            return
        }
        let group = groups[number]
        // At 1 at a time, which of the group's files this is.
        let place = count == 1 ? "\(first - group.range.lowerBound + 1) of \(group.range.count)" : nil
        groupLabel.show(title: group.group.title, place: place, theme: host.theme)
        groupLabel.isHidden = false
        let size = groupLabel.fittingSize
        groupLabel.frame = NSRect(x: 12, y: root.roomAboveRows + 10, width: size.width, height: size.height)
        root.addSubview(groupLabel, positioned: .above, relativeTo: nil)
    }

    /// The columns of the grid as it was last fitted (`PreviewGrid.shape`).
    private var gridColumns = PreviewGrid.shape(PreviewGrid.defaultCount).columns
    /// The count the grid was last fitted for.
    private var gridCount = PreviewGrid.defaultCount

    override func layoutPane() {
        placing { super.layoutPane() }
    }

    override func columnsChanged() { countChanged(showsSelected: false) }

    /// Another count, or another density. Arriving at 1 at a time from more (the slider, Make Bigger, a folder's
    /// view), the file now on screen is selected, as a scroll that came to rest on it would select it: the selected
    /// file stays on screen when it was (`keepInViewAfterStep`), and one scrolled away from would leave Space, the
    /// Info panel and Move to Trash acting on a file not shown. `showsSelected` is View ▸ Show Previews ▸ 1 at a
    /// Time, which brings the selected file on screen itself and so leaves the selection as it is.
    func countChanged(showsSelected: Bool) {
        let before = gridCount
        // Another count is asked for at its size at once.
        pixelSizeInUse = nil
        placing { super.columnsChanged() }
        if !showsSelected, before != 1, count == 1 {
            selectFileOnScreen(unlessDragged: false)
        }
        // The previews come at another size now: those asked for ahead at the old one are asked for again.
        dropPrefetches()
        prefetchSoon()
    }

    // MARK: Whole rows

    /// The furthest down the pane scrolls.
    private var maxScrollTop: Double {
        Double(max(0, collection.frame.height - scroll.contentView.bounds.height))
    }

    /// The top of the row nearest to `top`, within the content.
    private func rowTop(nearest top: Double) -> Double {
        guard layout.rowHeight > 0 else { return top }
        return min(maxScrollTop, max(0, (top / layout.rowHeight).rounded() * layout.rowHeight))
    }

    /// An item is brought into view by its whole row, at the top of the pane or a whole number of rows down it.
    override func revealOffset(for index: Int) -> NSPoint? {
        guard let offset = super.revealOffset(for: index) else { return nil }
        return NSPoint(x: offset.x, y: rowTop(nearest: Double(offset.y)))
    }

    /// Bringing a file into view (one selected, a listing's selection kept on screen) is the pane's own scroll, to a
    /// whole row: none to settle. Taken as a scroll to settle, it selected the file on screen a moment later at 1 at a
    /// time, whatever had happened since: a selection cleared and its file removed in that moment left the next file
    /// selected.
    override func reveal(index: Int) {
        placing { super.reveal(index: index) }
    }

    /// A place to scroll to from outside (the one a folder was left at, which Back returns to) is taken to the row
    /// nearest to it: the pane may have had another size then, with rows of another height. While the mouse button
    /// is held the place is taken as it is, as a drag-to-select past the pane's edge scrolls by a few points at a
    /// time; the pane settles on a row when it ends. At 1 at a time with one file selected the pane goes to that
    /// file instead (`selectedFileTop`).
    override var scrollPosition: (top: Double, left: Double) {
        get { super.scrollPosition }
        set {
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                super.scrollPosition = newValue
                return
            }
            placing {
                placeItems()
                super.scrollPosition = (selectedFileTop ?? rowTop(nearest: newValue.top), newValue.left)
            }
        }
    }

    /// At 1 at a time, the top of the one selected file's row: where a view put back from outside rests, whatever
    /// place was saved with it. A row is as high as the pane, so a place saved at another height of the pane is
    /// another file's row now, and the pane would show a file that isn't the selected one, which Space, the Info
    /// panel and Move to Trash act on. Nil at any other count, and with several files selected or none, where the
    /// saved place is the one to go to.
    private var selectedFileTop: Double? {
        guard count == 1, layout.rowHeight > 0, let paths = host?.selection.paths, paths.count == 1,
            let index = indexByPath[DiskPath(paths[0])]
        else { return nil }
        return min(maxScrollTop, Double(row(ofItem: index)) * layout.rowHeight)
    }

    /// A scroll that ends between rows settles on the next row the way it went, or back where it started when it went
    /// less than `share` of a row, so the pane shows whole previews.
    private func snapToRow(share: Double = PreviewGrid.swipeShare) {
        let clip = scroll.contentView
        let top = PreviewGrid.snappedScrollTop(
            from: scrollStart ?? Double(clip.bounds.origin.y), to: Double(clip.bounds.origin.y),
            rowHeight: layout.rowHeight, maxScrollTop: maxScrollTop, share: share)
        scrollStart = nil
        let byDrag = scrolledByDrag
        scrolledByDrag = false
        guard abs(top - Double(clip.bounds.origin.y)) >= 0.5 else {
            selectFileOnScreen(unlessDragged: byDrag)
            return
        }
        isSnapping = true
        // A window that isn't on screen draws no frames to move over: the pane goes there at once.
        guard scroll.window?.isVisible == true else {
            scrollClamped(to: NSPoint(x: clip.bounds.origin.x, y: top))
            isSnapping = false
            lastTop = Double(clip.bounds.origin.y)
            selectFileOnScreen(unlessDragged: byDrag)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.motion.fast / 1000
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: top))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSnapping = false
                self.lastTop = Double(clip.bounds.origin.y)
                self.scroll.reflectScrolledClipView(clip)
                self.selectFileOnScreen(unlessDragged: byDrag)
            }
        }
    }

    /// At 1 at a time a scroll goes from file to file, as ↓ does, and the file it rests on is the one selected, so
    /// Space, the Info panel and Move to Trash act on the file on screen. A selection of several files is kept, and so
    /// is one made by a drag that scrolled the pane (a drag-to-select or a drag of files held at the edge), and one
    /// being renamed. With more than one on screen, scrolling leaves the selection alone, as in the Icons view.
    private func selectFileOnScreen(unlessDragged byDrag: Bool) {
        guard count == 1, !byDrag, renamingPath == nil, !entries.isEmpty, layout.rowHeight > 0, let host,
            host.selection.paths.count <= 1
        else { return }
        let top = Double(scroll.contentView.bounds.origin.y)
        // At 1 at a time a row is a file; grouped, rows are numbered across the groups as well.
        let row = layout.row(atScrollTop: top + layout.rowHeight / 2)
        let index = min(groupedLines == nil ? row : firstItem(onRow: row), entries.count - 1)
        let selected = host.selection.paths
        guard !(selected.count == 1 && DiskPath(selected[0]) == keys[index]) else { return }
        host.selectionChanged(.single(entries[index].path))
    }

    /// At 1 at a time, a listing that took the selected file away (Move to Trash, a move, a delete in Finder) leaves
    /// another file in its place on screen, and that file is selected, as a scroll to it would select it: Move to Trash
    /// pressed again acts on the file shown, not on nothing. Only when the selection is empty because its files left
    /// (`gapIndex`) and this listing is the one that took the file at that place away: a folder just opened, a
    /// selection cleared by hand, a listing that took away some other file, and a place left empty long before (in
    /// another view, or at another count) change nothing. A listing that comes in while the mouse button is held
    /// counts as a drag's.
    private func selectFileInPlaceOfOneRemoved(listedBefore: [String]) {
        guard count == 1, let host, host.selection.isEmpty, let gap = host.selection.gapIndex,
            listedBefore.indices.contains(gap), indexByPath[DiskPath(listedBefore[gap])] == nil
        else { return }
        selectFileOnScreen(unlessDragged: NSEvent.pressedMouseButtons & 1 != 0)
    }

    private var observers: [any NSObjectProtocol] = []
    /// Where the scroll under way started.
    private var scrollStart: Double?
    /// A swipe, or a drag of the scroller, is under way: the system says when it ends.
    private var isLiveScrolling = false
    /// The scroll under way moved while the mouse button was held outside the scroller: a drag scrolled the pane.
    private var scrolledByDrag = false
    /// The pane is moving to a row's top by itself.
    private var isSnapping = false
    /// Where the pane was scrolled to when it last moved.
    private var lastTop = 0.0
    /// The pane is placing its items again (for another count, another size of the pane, another listing) and moves
    /// itself to keep a row at the top: none of that is a scroll to settle.
    private var placingDepth = 0

    /// Runs `body`, whose scrolls are the pane's own; the pane rests where it is then.
    private func placing(_ body: () -> Void) {
        placingDepth += 1
        body()
        placingDepth -= 1
        if placingDepth == 0 { lastTop = Double(scroll.contentView.bounds.origin.y) }
    }
    /// Waits for a scroll the system doesn't say the end of (a mouse wheel's notches, a drag-to-select past the edge)
    /// to rest; nothing waits while the pane is still.
    private var settle: DispatchWorkItem?
    /// How long such a scroll rests before the pane settles on a row.
    var settleDelay: TimeInterval = 0.15

    /// Whether the pane is waiting to settle on a row, or moving to it.
    var isSettling: Bool { settle != nil || isSnapping }

    /// The pane scrolled. A swipe says when it ends, and its end settles the pane; a mouse wheel turned a notch at a
    /// time and a drag-to-select that scrolls say nothing, so the pane settles once they rest.
    private func scrolled() {
        let top = Double(scroll.contentView.bounds.origin.y)
        defer { lastTop = top }
        if top != lastTop {
            wentUp = top < lastTop
            prefetchSoon()
        }
        guard placingDepth == 0, !isLiveScrolling, !isSnapping, top != lastTop else { return }
        if scrollStart == nil { scrollStart = lastTop }
        if NSEvent.pressedMouseButtons & 1 != 0 { scrolledByDrag = true }
        settleAfterRest()
    }

    private func settleAfterRest() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settleNow() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func settleNow() {
        settle = nil
        guard !isLiveScrolling else { return }
        // A drag-to-select still holds the button: it may scroll on.
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            settleAfterRest()
            return
        }
        // One notch of a wheel moves the pane a little: any of it goes on to the next row.
        snapToRow(share: PreviewGrid.wheelShare)
    }

    // MARK: The next page

    /// The previews asked for ahead of need, by path.
    private var prefetched: [DiskPath: LoadHandle] = [:]
    private var prefetchWaits = false
    /// Whether the pane last scrolled up: the page above is then asked for first.
    private var wentUp = false

    /// The paths whose previews are asked for ahead of need, for a test.
    var prefetchedPaths: Set<String> { Set(prefetched.keys.lazy.map(\.string)) }

    /// Asks for the page past the one on screen once the items on screen have asked for theirs, so that it shows its
    /// previews as soon as it comes into view.
    private func prefetchSoon() {
        guard !prefetchWaits else { return }
        prefetchWaits = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.prefetchWaits = false
                self?.prefetchNextPages()
            }
        }
    }

    /// The previews of the page after the one on screen, the way the pane last went, then of the page before, are
    /// asked for ahead of need: behind every preview on screen, so they never hold one up. Those no longer a page
    /// away are taken back if they have not started.
    func prefetchNextPages() {
        let clip = scroll.contentView.bounds
        var wanted: [Int] = []
        if view.window != nil, !entries.isEmpty, clip.height > 0, layout.rowHeight > 0 {
            let shown = items(in: clip, viewport: clip.size)
            let rows = max(1, Int((Double(clip.height) / layout.rowHeight).rounded()))
            let page = rows * max(1, columns)
            let below = Array(shown.upperBound..<min(entries.count, shown.upperBound + page))
            let above = Array(max(0, shown.lowerBound - page)..<shown.lowerBound).reversed()
            wanted = wentUp ? Array(above) + below : below + Array(above)
        }
        let paths = Set(wanted.lazy.map { self.keys[$0] })
        for (path, handle) in prefetched where !paths.contains(path) { handle.cancel() }
        prefetched = prefetched.filter { paths.contains($0.key) }
        let size = thumbnailPixelSize
        for index in wanted where prefetched[keys[index]] == nil {
            let entry = entries[index]
            prefetched[keys[index]] = thumbnailStore.prefetch(
                path: entry.path, kind: entry.iconEntry.kind, size: size, listing: listing)
        }
        for handle in outdated.values { handle.cancel() }
        outdated = [:]
    }

    /// The next pages' previews are checked again too.
    override func filesChanged(paths: Set<DiskPath>?) {
        super.filesChanged(paths: paths)
        askAgainForPrefetches()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        prefetchSoon()
    }

    /// The folder was read again, or files in it changed: the previews a page away are asked for again, for the
    /// folder as it is now, and only then are the earlier requests taken back. A load under way for a file still a
    /// page away so goes on and answers the new request, rather than being stopped and begun again, which a folder
    /// that keeps changing (a download, a camera's card being copied in) would do to it over and over.
    private func askAgainForPrefetches() {
        for (path, handle) in prefetched {
            outdated[path]?.cancel()
            outdated[path] = handle
        }
        prefetched = [:]
        prefetchSoon()
    }

    /// The requests made before the folder was last read, until the next page is asked for again.
    private var outdated: [DiskPath: LoadHandle] = [:]

    /// Takes back every preview asked for ahead of need: the pane shows other items, or other sizes of them.
    private func dropPrefetches() {
        for handle in prefetched.values { handle.cancel() }
        prefetched = [:]
        for handle in outdated.values { handle.cancel() }
        outdated = [:]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        settle?.cancel()
        sharpen?.cancel()
        for handle in prefetched.values { handle.cancel() }
        for handle in outdated.values { handle.cancel() }
        if isCounted { PreviewThumbnails.panes.disappeared() }
    }

    override var picturesFillTheirPlace: Bool { true }

    /// Most previews come within this; one that does is drawn in a place left empty until then, rather than over the
    /// icon a moment after it.
    static var iconWait: TimeInterval = 0.2
    override var iconWait: TimeInterval { Self.iconWait }
    override var thumbnailStore: ThumbnailStore { PreviewThumbnails.store }

    /// A screen's scale and longer side in points, in place of the window's own: a test's.
    static var screenForTests: (scale: Double, longestSide: Double)?

    /// The pixels a picture is asked for at: its place's longer side on this screen, at most the screen's own longer
    /// side, so a preview filling a large screen is as sharp as the screen.
    override var thumbnailPixelSize: Int {
        if let pixelSizeInUse { return pixelSizeInUse }
        // Not kept while the pane is in no window: its screen is not known yet.
        guard view.window != nil else { return pixelSizeForThePane }
        let size = pixelSizeForThePane
        pixelSizeInUse = size
        return size
    }

    /// The size the previews are asked for at now: the pane's, as it was when its size last rested.
    private var pixelSizeInUse: Int?

    private var pixelSizeForThePane: Int {
        let box = PreviewGrid.pictureBox(layout)
        let screen = view.window?.screen ?? NSScreen.main
        let scale = Self.screenForTests?.scale ?? Double(screen?.backingScaleFactor ?? 2)
        let side = Self.screenForTests?.longestSide ?? screen.map { Double(max($0.frame.width, $0.frame.height)) }
        let longest = side.map { $0 * scale } ?? 4096
        return ThumbnailStore.pixelSize(forPreviewSize: max(box.width, box.height), scale: scale, limit: Int(longest))
    }

    /// The window moved to a screen with other pixels (a sharper one, a larger one): the previews on screen are asked
    /// for again at its size, each keeping its picture until a sharper one comes. Those kept sharp enough are given
    /// as they are, and the others are asked for as they come into view.
    func screenChanged() {
        pixelSizeInUse = nil
        forEachVisibleIndex { item, index in
            (item as? IconItem)?.loadThumbnail(entries[index], key: keys[index], pane: self)
        }
        dropPrefetches()
        prefetchSoon()
    }

    /// The shapes of the pictures seen, by path: a drag-to-select goes by where each picture really is, for those
    /// scrolled out of view since too.
    private var pictureShapes: [DiskPath: DragSelectionSize] = [:]

    /// A drag-to-select touches a preview on its picture, whatever its shape, or on its name.
    override func gridHits(
        box: DragSelectionBox, paths: [String], sizes: [DiskPath: DragSelectionSize]
    ) -> [DragSelectionHit] {
        forEachVisibleIndex { item, index in
            pictureShapes[keys[index]] = (item as? IconItem)?.pictureShape
        }
        return DragSelection.previewGridItems(
            box: box, entryPaths: paths, columns: columns,
            gridWidth: layout.gridWidth(containerWidth: Double(viewport.width)), layout: layout,
            heightInset: style.heightInset, pictures: pictureShapes, sizes: sizes)
    }

    override func reload(scrollToTop: Bool) {
        // What was listed, for telling whether this listing took the selected file away; only 1 at a time asks.
        let listedBefore = count == 1 && !scrollToTop ? entryPaths : []
        placing {
            super.reload(scrollToTop: scrollToTop)
            selectFileInPlaceOfOneRemoved(listedBefore: listedBefore)
        }
        askAgainForPrefetches()
        let listed = indexByPath
        pictureShapes = pictureShapes.filter { listed[$0.key] != nil }
    }

    /// The rename field goes where the name is: right under the picture.
    override func renameFrame(at index: Int) -> NSRect {
        let place = itemFrame(at: index, viewport: viewport)
        guard let item = visibleItem(at: index) as? IconItem else { return super.renameFrame(at: index) }
        let name = item.nameFrame
        return NSRect(
            x: place.minX + (place.width - CGFloat(layout.labelWidth)) / 2,
            y: place.minY + name.minY, width: CGFloat(layout.labelWidth), height: CGFloat(style.renameHeight))
    }

    /// The name, and how big the file is.
    override func toolTip(for entry: DirectoryEntry) -> String {
        guard !entry.isDirectoryLike, let bytes = host?.sizeBytes(of: entry) else { return entry.name }
        return "\(entry.name)\n\(SizeText.size(bytes))"
    }

    override func loadView() {
        super.loadView()
        isCounted = true
        PreviewThumbnails.panes.appeared()
        let center = NotificationCenter.default
        let clip = scroll.contentView
        observers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = true
                    self.settle?.cancel()
                    self.settle = nil
                    if self.scrollStart == nil { self.scrollStart = Double(self.scroll.contentView.bounds.origin.y) }
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isLiveScrolling = false
                    self?.snapToRow()
                }
            },
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            },
        ]
        // The window's screen: its scale, or another screen altogether.
        for name in [NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let changed = (note.object as? NSWindow).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        guard let self, self.isViewLoaded, let window = self.view.window,
                            changed == ObjectIdentifier(window)
                        else { return }
                        self.screenChanged()
                    }
                })
        }
    }

    /// Whether this pane is one of those `PreviewThumbnails.panes` counts: from when it has its view until it is
    /// let go, which a pane is when its tab shows another view or closes.
    private var isCounted = false
}
