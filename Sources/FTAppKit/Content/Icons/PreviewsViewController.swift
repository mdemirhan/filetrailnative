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

/// Large previews of the files' content in a grid that scrolls down, as wide as the size in the status bar: the pane's
/// width decides how many fit in a row. Everything else is the Icons view's: selection, keys, drags, rename.
final class PreviewsViewController: IconViewController {
    private var magnifier: PreviewMagnifier?

    override var navigationViewMode: ExplorerViewMode { .previews }
    override var gridIdentifier: String { "previews.grid" }

    override func savedSize(for density: Density) -> Double {
        Double(host?.columnState.previewSizes[density] ?? DensitySizes.previewDefaults[density])
    }

    override var thumbnailStore: ThumbnailStore { PreviewThumbnails.store }
    override var thumbnailPixelSize: Int { ThumbnailStore.pixelSize(forPreviewSize: layout.iconSize) }

    /// The name, and how big the file is.
    override func toolTip(for entry: DirectoryEntry) -> String {
        guard !entry.isDirectoryLike, let bytes = host?.sizeBytes(of: entry) else { return entry.name }
        return "\(entry.name)\n\(SizeText.size(bytes))"
    }

    override func loadView() {
        super.loadView()
        magnifier = PreviewMagnifier(pane: self)
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
