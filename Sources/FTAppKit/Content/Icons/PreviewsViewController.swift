// The Previews view: the Icons view's grid at the size of large previews, with a store of previews of its own that
// keeps under a memory limit, and a magnifier while ⌥ is held over a preview
import AppKit
import FTFileSystem
import FTFoundation

/// The previews of the Previews view: large ones, so they are kept apart from the icons' and under a memory limit of
/// their own. Those scrolled far away are asked of Quick Look again, whose cache on disk makes that cheap.
@MainActor
enum PreviewThumbnails {
    /// 256 MB: a few dozen previews at the largest size, a few hundred at the default one.
    static let memoryLimit = 256 * 1024 * 1024
    static let store = ThumbnailStore(maxEntries: ThumbnailStore.maxEntries, memoryLimit: memoryLimit)
}

/// Large previews of the files' content in a grid that scrolls down: 9, 4, 2 or 1 of them fill the pane at a time
/// (`PreviewGrid`), as large as that many fit, so a narrower pane shows as many, smaller. Everything else is the Icons
/// view's: selection, keys, drags, rename.
final class PreviewsViewController: IconViewController {
    private var magnifier: PreviewMagnifier?
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
    override func placesChange(from old: NSSize, to new: NSSize) -> Bool {
        guard new != fittedTo else { return old.width != new.width }
        let anchor = scrollAnchor()
        guard metricsChanged() else { return old.width != new.width }
        collection.reloadData()
        DispatchQueue.main.async { anchor?() }
        return true
    }

    /// Another count keeps the row that was mostly at the top, now at the top: the pane shows whole rows.
    override func scrollAnchor() -> (() -> Void)? {
        guard !entries.isEmpty else { return nil }
        let top = Double(scroll.contentView.bounds.origin.y)
        let index = min(layout.row(atScrollTop: top + layout.rowHeight / 2) * columns, entries.count - 1)
        return { [self] in
            scrollClamped(to: NSPoint(x: 0, y: Double(index / max(1, columns)) * layout.rowHeight))
        }
    }

    /// A swipe that ends between rows settles on the next row the way it went, or back where it started when it went
    /// only a little, so the pane shows whole previews.
    private func snapToRow() {
        let clip = scroll.contentView
        let maxTop = Double(max(0, collection.frame.height - clip.bounds.height))
        let top = PreviewGrid.snappedScrollTop(
            from: scrollStart ?? Double(clip.bounds.origin.y), to: Double(clip.bounds.origin.y),
            rowHeight: layout.rowHeight, maxScrollTop: maxTop)
        scrollStart = nil
        guard abs(top - Double(clip.bounds.origin.y)) >= 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.motion.fast / 1000
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: top))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.scroll.reflectScrolledClipView(clip) }
        }
    }

    private var scrollObservers: [any NSObjectProtocol] = []
    /// Where the swipe under way started.
    private var scrollStart: Double?

    isolated deinit {
        for observer in scrollObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override var picturesFillTheirPlace: Bool { true }
    override var thumbnailStore: ThumbnailStore { PreviewThumbnails.store }

    /// The pixels a picture is asked for at: its place's longer side on this screen, at most the screen's own longer
    /// side, so a preview filling a large screen is as sharp as the screen.
    override var thumbnailPixelSize: Int {
        let box = PreviewGrid.pictureBox(layout)
        let screen = view.window?.screen ?? NSScreen.main
        let scale = Double(screen?.backingScaleFactor ?? 2)
        let longest = screen.map { Double(max($0.frame.width, $0.frame.height)) * scale } ?? 4096
        return ThumbnailStore.pixelSize(forPreviewSize: max(box.width, box.height), scale: scale, limit: Int(longest))
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
        magnifier = PreviewMagnifier(pane: self)
        let center = NotificationCenter.default
        scrollObservers = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scrollStart = Double(self.scroll.contentView.bounds.origin.y)
                }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.snapToRow() }
            },
        ]
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        magnifier?.end()
    }

    // MARK: The magnifier

    /// The items on screen and their entries, for the magnifier.
    func visibleItems() -> [(item: IconItem, entry: DirectoryEntry)] {
        var found: [(IconItem, DirectoryEntry)] = []
        forEachVisibleItem { item, entry in
            if let item = item as? IconItem { found.append((item, entry)) }
        }
        return found
    }
}

/// While ⌥ is held with the pointer over a preview, the part under the pointer shows at three times its size, from a
/// picture of the file at full size. With several previews selected and the pointer over one of them, all of them zoom
/// to the same spot, to tell near-identical ones apart.
@MainActor
final class PreviewMagnifier {
    static let zoom: CGFloat = 3
    private weak var pane: PreviewsViewController?
    private var monitor: Any?
    /// The zoomed views over the previews, by path.
    private var lenses: [String: NSImageView] = [:]
    /// Full-size pictures, kept only while ⌥ is held.
    private var pictures: [String: NSImage] = [:]
    private var loading: Set<String> = []

    init(pane: PreviewsViewController) {
        self.pane = pane
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged, .leftMouseDragged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
        guard let pane, let window = pane.view.window, event.window === window,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
        else {
            end()
            return
        }
        // ⌥ pressed or let go says nothing of the pointer: where it is now is asked of the window.
        let point = window.mouseLocationOutsideOfEventStream
        let items = pane.visibleItems()
        guard
            let (hovered, hoveredEntry) = items.first(where: { item, _ in
                let box = item.thumbnail
                return !box.isHidden && box.bounds.contains(box.convert(point, from: nil))
            })
        else {
            end()
            return
        }
        // Where the pointer is in the preview, from 0 to 1 each way.
        let inBox = hovered.thumbnail.convert(point, from: nil)
        let bounds = hovered.thumbnail.bounds
        let spot = CGPoint(x: inBox.x / max(1, bounds.width), y: inBox.y / max(1, bounds.height))
        let together =
            pane.isSelected(hoveredEntry.path)
            ? items.filter { pane.isSelected($0.entry.path) } : [(hovered, hoveredEntry)]
        let shown = Set(together.map(\.entry.path))
        for (path, lens) in lenses where !shown.contains(path) {
            lens.removeFromSuperview()
            lenses[path] = nil
        }
        for (item, entry) in together { show(item: item, entry: entry, spot: spot) }
    }

    private func show(item: IconItem, entry: DirectoryEntry, spot: CGPoint) {
        let box = item.thumbnail
        let lens = lenses[entry.path] ?? makeLens(over: box, path: entry.path)
        lens.frame = box.bounds
        guard let picture = pictures[entry.path] else {
            load(entry)
            lens.isHidden = true
            return
        }
        lens.isHidden = false
        // The picture drawn three times the preview's size, moved so the spot under the pointer stays under it.
        let size = NSSize(width: box.bounds.width * Self.zoom, height: box.bounds.height * Self.zoom)
        let origin = NSPoint(
            x: box.bounds.width * spot.x - size.width * spot.x, y: box.bounds.height * spot.y - size.height * spot.y)
        let zoomed = NSImage(size: box.bounds.size, flipped: box.isFlipped) { _ in
            picture.draw(
                in: NSRect(origin: origin, size: size), from: .zero, operation: .copy, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return true
        }
        lens.image = zoomed
    }

    private func makeLens(over box: NSView, path: String) -> NSImageView {
        let lens = NSImageView(frame: box.bounds)
        lens.imageScaling = .scaleNone
        lens.wantsLayer = true
        lens.layer?.cornerRadius = box.layer?.cornerRadius ?? 0
        lens.layer?.masksToBounds = true
        lens.setAccessibilityIdentifier("previews.item.magnifier")
        box.addSubview(lens)
        lenses[path] = lens
        return lens
    }

    /// The file's picture at full size: the image itself when it is one, otherwise Quick Look's at a large size.
    private func load(_ entry: DirectoryEntry) {
        guard !loading.contains(entry.path) else { return }
        loading.insert(entry.path)
        let path = entry.path
        if let image = NSImage(contentsOfFile: path), image.isValid {
            loading.remove(path)
            pictures[path] = image
            return
        }
        // Not through the previews' store: a picture this large is kept only while ⌥ is held.
        Task { @MainActor [weak self] in
            let response = await FileThumbnailService().response(path: path, size: 2048, knownVersion: nil)
            guard let self, self.loading.contains(path) else { return }
            self.loading.remove(path)
            if let image = response.picture?.image { self.pictures[path] = image }
        }
    }

    /// ⌥ let go, or the pointer left the previews: the magnified views and the full-size pictures go.
    func end() {
        for lens in lenses.values { lens.removeFromSuperview() }
        lenses.removeAll()
        pictures.removeAll()
        loading.removeAll()
    }
}
