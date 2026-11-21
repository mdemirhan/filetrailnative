import AppKit
import FTFileSystem
import FTFoundation

/// The pixels an icon is drawn into, whatever size it then shows at. macOS has other art for other sizes, so an
/// icon keeps one shape at every size only when it is scaled from these pixels.
@MainActor
enum NativeIconPixels {
    static let side = 64
    /// The Info panel's large icon: 88 points, 176 pixels on a Retina screen, drawn from macOS's art for that size
    /// rather than scaled up from 64 pixels.
    static let heroSide = 256

    static func image(_ icon: NSImage) -> NSImage { image(icon, side: side) }

    static func image(_ icon: NSImage, side: Int) -> NSImage {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return icon }
        let size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// The macOS icon of an item, drawn into its box once it has arrived; a folder shows the stand-in folder until then.
@MainActor
final class InfoIconView: NSView {
    private var image: NSImage?
    /// The pixels the icon is drawn into (`NativeIconPixels`).
    var pixelSide = NativeIconPixels.side
    /// Room between the box and the icon drawn in it (the hero's 104 box holds a 96 icon).
    var inset = 0.0
    private var isFolder = false
    private var handle: LoadHandle?
    /// The cache key of the icon shown.
    private(set) var shown: String?
    /// `.file-icon.native-file-icon` asks for more than its box: the icon macOS drew is this big, from the box's top
    /// left, past its other edges. The stand-in stays in the box.
    var nativeIconSide: Double?
    /// Two icons, one behind the other (several items): the box holds both.
    var stack: (back: GenericIconKind, front: GenericIconKind)?
    private var stackImages: [GenericIconKind: NSImage] = [:]

    /// The Quick Look preview of the file's content, drawn in the icon's place once there is one (a photo, a PDF's
    /// first page): the icon shows until then, and stays for a file with no preview.
    private(set) var picture: ThumbnailPicture?
    private var pictureHandle: LoadHandle?
    /// The file the preview is of, as it was when asked for: its path, and its path with its date and size.
    private var picturePath: String?
    private var pictureKey: String?
    /// Stands for the file as it was read for the panel: the store checks a preview it has against the file once for
    /// each, so a file changed since gets a new one.
    private var pictureReading = NSObject()

    /// What the icon shown was asked for with, to ask again once it was dropped as System Settings' colors changed.
    private var asked: (entry: IconEntry, deferLoad: Bool)?
    private weak var askedStore: FileIconStore?

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(accentDrawnIconsDropped(_:)), name: FileIconStore.accentDrawnIconsDropped,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A folder's icon shown, or one of the stack, was dropped: it is asked for again, in the new color.
    @objc private func accentDrawnIconsDropped(_ notification: Notification) {
        guard let store = askedStore, notification.object as AnyObject? === store else { return }
        if let stack {
            for kind in [stack.back, stack.front] where FileIconStore.isDrawnInAccent(key: kind.cacheKey) {
                stackImages[kind] = nil
            }
            showStack(back: stack.back, front: stack.front, store: store)
        } else if let asked, let shown, FileIconStore.isDrawnInAccent(key: shown) {
            self.shown = nil
            show(asked.entry, store: store, deferLoad: false)
        }
    }

    /// Asks for the preview of the file the icon is of. `version` changes when the file does (its date and size). The
    /// same file changed keeps the preview drawn until the new one comes; another file starts from its icon.
    func showPreview(path: String, kind: IconEntryKind, version: String, store: ThumbnailStore?) {
        let key = path + "\u{0}" + version
        guard key != pictureKey else { return }
        pictureHandle?.cancel()
        pictureHandle = nil
        pictureKey = key
        if path != picturePath, picture != nil {
            picture = nil
            needsDisplay = true
        }
        picturePath = path
        pictureReading = NSObject()
        guard let store else { return }
        pictureHandle = store.load(path: path, kind: kind, size: ThumbnailStore.largePixelSize, listing: pictureReading)
        { [weak self] loaded in
            guard let self, self.pictureKey == key, let loaded else { return }
            self.picture = loaded
            self.needsDisplay = true
        }
    }

    private func clearPreview() {
        pictureHandle?.cancel()
        pictureHandle = nil
        pictureKey = nil
        picturePath = nil
        picture = nil
    }

    func show(_ entry: IconEntry?, store: FileIconStore?, deferLoad: Bool) {
        stack = nil
        askedStore = store
        asked = entry.map { ($0, deferLoad) }
        guard let entry else {
            clearPreview()
            shown = nil
            image = nil
            handle?.cancel()
            needsDisplay = true
            return
        }
        let request = IconRequest(entry: entry)
        guard request.cacheKey != shown else { return }
        shown = request.cacheKey
        handle?.cancel()
        isFolder = entry.kind == .directory || entry.kind == .symlinkDirectory
        image = nil
        needsDisplay = true
        guard let store else { return }
        let key = request.cacheKey
        handle = store.load(request, deferLoad: deferLoad) { [weak self] loaded in
            guard let self, self.shown == key else { return }
            self.image = loaded.map { NativeIconPixels.image($0, side: self.pixelSide) }
            self.needsDisplay = true
        }
    }

    /// The stacked icon of several items.
    func showStack(back: GenericIconKind, front: GenericIconKind, store: FileIconStore?) {
        askedStore = store
        asked = nil
        clearPreview()
        shown = "stack:\(back):\(front)"
        image = nil
        handle?.cancel()
        stack = (back, front)
        needsDisplay = true
        guard let store else { return }
        for kind in [back, front] where stackImages[kind] == nil {
            store.load(.generic(kind)) { [weak self] loaded in
                guard let self, let loaded else { return }
                self.stackImages[kind] = loaded
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let stack {
            // `.clipboard-items-icon > .file-icon`: the first at the top left, the last at the bottom right.
            let side = InfoMetrics.heroStackIcon
            let area = bounds.insetBy(dx: inset, dy: inset)
            let backRect = NSRect(x: area.minX, y: area.minY, width: side, height: side)
            let frontRect = NSRect(x: area.maxX - side, y: area.maxY - side, width: side, height: side)
            for (kind, rect) in [(stack.back, backRect), (stack.front, frontRect)] {
                stackImages[kind]?.draw(
                    in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        let box = bounds.insetBy(dx: inset, dy: inset)
        if let picture, picture.image.size.width > 0, picture.image.size.height > 0 {
            drawPreview(picture, in: box)
        } else if let image {
            let rect = nativeIconSide.map { NSRect(x: 0, y: 0, width: $0, height: $0) } ?? box
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if isFolder {
            SidebarIconView.drawFolderStandIn(in: box)
        }
    }

    /// The preview in its own proportions, as large as the box holds; a photo or a video frame (every pixel opaque)
    /// gets the Icons view's corners and hairline, a page or a cut-out picture is drawn as it is.
    private func drawPreview(_ picture: ThumbnailPicture, in box: NSRect) {
        let size = picture.image.size
        let scale = min(box.width / size.width, box.height / size.height)
        let rect = NSRect(
            x: (box.midX - size.width * scale / 2).rounded(), y: (box.midY - size.height * scale / 2).rounded(),
            width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        NSGraphicsContext.current?.imageInterpolation = .high
        guard picture.isOpaque else {
            picture.image.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let style = IconItemStyle.make(density: .standard)
        let shape = NSBezierPath(
            roundedRect: rect, xRadius: CGFloat(style.thumbnailRadius), yRadius: CGFloat(style.thumbnailRadius))
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        picture.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(CGFloat(style.thumbnailHairlineAlpha)).setStroke()
        shape.lineWidth = CGFloat(style.thumbnailHairlineWidth)
        shape.stroke()
    }
}
