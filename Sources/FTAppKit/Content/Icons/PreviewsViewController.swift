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
        setGrid(density: next, layout: fitted)
        collection.collectionViewLayout?.invalidateLayout()
        return true
    }

    /// Any change of the pane's size gives the previews another size: they are made again at it, and the row that was
    /// at the top stays there.
    override func fitGrid(to new: NSSize) {
        guard new != fittedTo else { return }
        let anchor = scrollAnchor()
        guard metricsChanged() else { return }
        collection.reloadData()
        DispatchQueue.main.async { anchor?() }
    }

    /// The places follow the pane's width and its height.
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool { old != new }

    /// Another count keeps the row that was mostly at the top, now at the top: the pane shows whole rows.
    override func scrollAnchor() -> (() -> Void)? {
        guard !entries.isEmpty else { return nil }
        let top = Double(scroll.contentView.bounds.origin.y)
        let index = min(layout.row(atScrollTop: top + layout.rowHeight / 2) * columns, entries.count - 1)
        return { [self] in
            scrollClamped(to: NSPoint(x: 0, y: Double(index / max(1, columns)) * layout.rowHeight))
        }
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

    /// A place to scroll to from outside (the one a folder was left at, which Back returns to) is taken to the row
    /// nearest to it: the pane may have had another size then, with rows of another height. While the mouse button
    /// is held the place is taken as it is, as a drag-to-select past the pane's edge scrolls by a few points at a
    /// time; the pane settles on a row when it ends.
    override var scrollPosition: (top: Double, left: Double) {
        get { super.scrollPosition }
        set {
            guard NSEvent.pressedMouseButtons & 1 == 0 else {
                super.scrollPosition = newValue
                return
            }
            placeItems()
            super.scrollPosition = (rowTop(nearest: newValue.top), newValue.left)
        }
    }

    /// A scroll that ends between rows settles on the next row the way it went, or back where it started when it went
    /// less than `share` of a row, so the pane shows whole previews.
    private func snapToRow(share: Double = PreviewGrid.swipeShare) {
        let clip = scroll.contentView
        let top = PreviewGrid.snappedScrollTop(
            from: scrollStart ?? Double(clip.bounds.origin.y), to: Double(clip.bounds.origin.y),
            rowHeight: layout.rowHeight, maxScrollTop: maxScrollTop, share: share)
        scrollStart = nil
        guard abs(top - Double(clip.bounds.origin.y)) >= 0.5 else { return }
        isSnapping = true
        // A window that isn't on screen draws no frames to move over: the pane goes there at once.
        guard scroll.window?.isVisible == true else {
            scrollClamped(to: NSPoint(x: clip.bounds.origin.x, y: top))
            isSnapping = false
            lastTop = Double(clip.bounds.origin.y)
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
            }
        }
    }

    private var observers: [any NSObjectProtocol] = []
    /// Where the scroll under way started.
    private var scrollStart: Double?
    /// A swipe, or a drag of the scroller, is under way: the system says when it ends.
    private var isLiveScrolling = false
    /// The pane is moving to a row's top by itself.
    private var isSnapping = false
    /// Where the pane was scrolled to when it last moved.
    private var lastTop = 0.0
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
        guard !isLiveScrolling, !isSnapping, top != lastTop else { return }
        if scrollStart == nil { scrollStart = lastTop }
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

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        settle?.cancel()
        if isCounted { PreviewThumbnails.panes.disappeared() }
    }

    override var picturesFillTheirPlace: Bool { true }
    override var thumbnailStore: ThumbnailStore { PreviewThumbnails.store }

    /// A screen's scale and longer side in points, in place of the window's own: a test's.
    static var screenForTests: (scale: Double, longestSide: Double)?

    /// The pixels a picture is asked for at: its place's longer side on this screen, at most the screen's own longer
    /// side, so a preview filling a large screen is as sharp as the screen.
    override var thumbnailPixelSize: Int {
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
        forEachVisibleItem { item, entry in
            (item as? IconItem)?.loadThumbnail(entry, pane: self)
        }
    }

    /// The shapes of the pictures seen, by path: a drag-to-select goes by where each picture really is, for those
    /// scrolled out of view since too.
    private var pictureShapes: [String: DragSelectionSize] = [:]

    /// A drag-to-select touches a preview on its picture, whatever its shape, or on its name.
    override func gridHits(box: DragSelectionBox, sizes: [String: DragSelectionSize]) -> [DragSelectionHit] {
        forEachVisibleItem { item, entry in
            pictureShapes[entry.path] = (item as? IconItem)?.pictureShape
        }
        return DragSelection.previewGridItems(
            box: box, entryPaths: entryPaths, columns: columns,
            gridWidth: layout.gridWidth(containerWidth: Double(viewport.width)), layout: layout,
            heightInset: style.heightInset, pictures: pictureShapes, sizes: sizes)
    }

    override func reload(scrollToTop: Bool) {
        super.reload(scrollToTop: scrollToTop)
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
