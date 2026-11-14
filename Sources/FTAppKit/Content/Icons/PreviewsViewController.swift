// The Previews view: the Icons view's grid at the size of large previews, with a store of previews of its own that
// keeps under a memory limit
import AppKit
import FTFileSystem
import FTFoundation

/// The previews of the Previews view: large ones, so they are kept apart from the Icons view's (List and Compact List
/// show only icons) and under a memory limit of their own: 1 GB, less on a Mac with under 16 GB. When macOS is short
/// of memory they all go. Those scrolled far away, or let go, are asked of Quick Look again, whose cache on disk makes
/// that cheap.
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
}
