// Port of FileIcon with `deferLoad` (apps/desktop/src/renderer/lib/fileIcons.tsx) as the Info views use it
import AppKit
import FTFileSystem
import FTFoundation

/// What the original's icon request gives: `nativeGetFileIcon` draws the icon into this many pixels (`ICON_PIXEL_SIZE`),
/// whatever size it then shows at. macOS has other art for other sizes, so an icon only has the original's shape when
/// it is scaled from these pixels.
@MainActor
enum NativeIconPixels {
    static let side = 64

    static func image(_ icon: NSImage) -> NSImage {
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
    /// Room between the box and the icon drawn in it (the hero's 104 box holds a 96 icon).
    var inset = 0.0
    private var isFolder = false
    private var handle: LoadHandle?
    private var shown: String?
    /// `.file-icon.native-file-icon` asks for more than its box: the icon macOS drew is this big, from the box's top
    /// left, past its other edges. The stand-in stays in the box.
    var nativeIconSide: Double?
    /// Two icons, one behind the other (several items): the box holds both.
    var stack: (back: GenericIconKind, front: GenericIconKind)?
    private var stackImages: [GenericIconKind: NSImage] = [:]

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ entry: IconEntry?, store: FileIconStore?, deferLoad: Bool) {
        stack = nil
        guard let entry else {
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
            self.image = loaded.map(NativeIconPixels.image)
            self.needsDisplay = true
        }
    }

    /// The stacked icon of several items.
    func showStack(back: GenericIconKind, front: GenericIconKind, store: FileIconStore?) {
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
        if let image {
            let rect = nativeIconSide.map { NSRect(x: 0, y: 0, width: $0, height: $0) } ?? box
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if isFolder {
            SidebarIconView.drawFolderStandIn(in: box)
        }
    }
}
