// Port of FileIcon with `deferLoad` (apps/desktop/src/renderer/lib/fileIcons.tsx) as the Info views use it
import AppKit
import FTFileSystem
import FTFoundation

/// The macOS icon of an item, drawn into its box once it has arrived; a folder shows the stand-in folder until then.
@MainActor
final class InfoIconView: NSView {
    private var image: NSImage?
    private var isFolder = false
    private var handle: LoadHandle?
    private var shown: String?
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
            self.image = loaded
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
            let backRect = NSRect(x: 0, y: 0, width: side, height: side)
            let frontRect = NSRect(x: bounds.width - side, y: bounds.height - side, width: side, height: side)
            for (kind, rect) in [(stack.back, backRect), (stack.front, frontRect)] {
                stackImages[kind]?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        if let image {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if isFolder {
            SidebarIconView.drawFolderStandIn(in: bounds)
        }
    }
}
