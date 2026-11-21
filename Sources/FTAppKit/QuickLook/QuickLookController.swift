import AppKit
import FTFileSystem
import FTFoundation
@preconcurrency import Quartz

/// The preview panel, as the controller drives it (the system's, or a test's).
@MainActor
protocol QuickLookPanelControlling: AnyObject {
    var isVisible: Bool { get }
    /// The panel shows `controller`'s item, in front.
    func present(_ controller: QuickLookController)
    /// The panel shows the item again.
    func refresh()
    func dismiss()
}

/// The system's Quick Look panel (`QLPreviewPanel`).
@MainActor
final class SystemQuickLookPanel: QuickLookPanelControlling {
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func present(_ controller: QuickLookController) {
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = controller
        panel?.delegate = controller
        panel?.reloadData()
        panel?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        QLPreviewPanel.shared()?.reloadData()
        QLPreviewPanel.shared()?.refreshCurrentPreviewItem()
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }
}

/// Quick Look: the system's preview panel for one item, opened with Space, the menu and the Info panel's button,
/// zooming out of the item's icon or preview, and back into it when it closes.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    static let shared = QuickLookController()

    /// The item the panel previews: its URL for the panel, made of the path's own bytes. For an alias, its original's
    /// once looked up; a symbolic link Quick Look follows itself.
    private(set) var url: URL?
    private var showNumber = 0
    /// The item's path, as its row has it.
    private(set) var path: String?
    /// Where the picture of the item at a path is on screen and what it is, for the zoom transition (nil: no
    /// transition).
    var source: ((String) -> QuickLookPicture?)?
    /// Told when the panel closes.
    var onClose: (() -> Void)?
    private weak var owner: NSWindow?
    /// The panel, replaceable in tests.
    var panel: any QuickLookPanelControlling = SystemQuickLookPanel()

    var isShowing: Bool { panel.isVisible && url != nil }

    /// The panel shows the item. Showing the item it already shows closes the panel, as Space does.
    func toggle(_ path: String, from window: NSWindow?, source: @escaping (String) -> QuickLookPicture?) {
        if isShowing, let shown = self.path, DiskPath(shown) == DiskPath(path) {
            close()
            return
        }
        show(path, from: window, source: source)
    }

    func show(_ path: String, from window: NSWindow?, source: @escaping (String) -> QuickLookPicture?) {
        url = DiskPath(path).fileURL()
        self.path = path
        owner = window
        self.source = source
        if panel.isVisible {
            panel.refresh()
        } else {
            panel.present(self)
        }
        showNumber += 1
        let number = showNumber
        Task {
            // An alias is looked up away from the main thread, and the panel then shows its original.
            let original = await BlockingWork.run { Links.isFinderAlias(path) ? Links.original(of: path) : nil }
            guard let original, number == showNumber, let shown = self.path, DiskPath(shown) == DiskPath(path) else {
                return
            }
            url = DiskPath(original).fileURL()
            panel.refresh()
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.dismiss()
        ended()
    }

    func ended() {
        url = nil
        path = nil
        // It holds the tab's list: let go with the item.
        source = nil
        onClose?()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let path, let picture = source?(path) else { return .zero }
        return picture.frame
    }

    func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let path else { return nil }
        // What the item draws, so the panel shrinks into that picture: a preview stays sharp, and an icon is the one
        // on screen.
        return source?(path)?.image ?? NSWorkspace.shared.icon(forFile: path)
    }
}

/// An item's picture as drawn on screen, for Quick Look's zoom: where it is, and the image when the view has one.
struct QuickLookPicture {
    var frame: NSRect
    var image: NSImage?
}

/// An item of the Icons, Compact List or Previews view that says which of its views draws its picture.
@MainActor
protocol QuickLookPictureItem: AnyObject {
    /// The view the icon or the preview is drawn in, its bounds the picture's, and the image it draws.
    var quickLookPicture: (view: NSView, image: NSImage?) { get }
}

/// Where an item is on screen: its row in the List or its cell in the Icons view.
@MainActor
enum QuickLookItemFrame {
    /// The item's icon or preview on screen, as drawn: the icon in the List and the Compact List, the preview or the
    /// icon in the Icons and Previews views. Quick Look zooms out of it and back into it, so the picture keeps its
    /// shape and the panel shrinks into what the item shows rather than an icon stretched over the whole cell.
    static func picture(of path: String, entries: [DirectoryEntry], in root: NSView) -> QuickLookPicture? {
        let shown = DiskPath(path)
        guard let index = entries.firstIndex(where: { DiskPath($0.path) == shown }), let window = root.window else {
            return nil
        }
        if firstView(NSTableView.self, in: root) == nil, let collection = firstView(NSCollectionView.self, in: root),
            let item = collection.item(at: IndexPath(item: index, section: 0)) as? QuickLookPictureItem
        {
            let (view, image) = item.quickLookPicture
            guard view.window != nil, !view.bounds.isEmpty else { return nil }
            return QuickLookPicture(frame: window.convertToScreen(view.convert(view.bounds, to: nil)), image: image)
        }
        return screenFrame(of: path, entries: entries, in: root).map { QuickLookPicture(frame: $0, image: nil) }
    }

    static func screenFrame(of path: String, entries: [DirectoryEntry], in root: NSView) -> NSRect? {
        let shown = DiskPath(path)
        guard let index = entries.firstIndex(where: { DiskPath($0.path) == shown }), let window = root.window else {
            return nil
        }
        let rect: NSRect
        if let table = firstView(NSTableView.self, in: root), index < table.numberOfRows {
            let row = table.rect(ofRow: index)
            // Where the List draws the icon: past the row's inset and padding, at the size of the density shown.
            let metrics =
                (table.delegate as? ListViewController)?.layoutMetrics ?? DesignTokens.details(density: .standard)
            let side = min(row.height, CGFloat(metrics.iconSize))
            let x = row.minX + CGFloat(metrics.rowInset + metrics.rowPaddingInline)
            rect = table.convert(NSRect(x: x, y: row.midY - side / 2, width: side, height: side), to: nil)
        } else if let collection = firstView(NSCollectionView.self, in: root),
            let item = collection.item(at: IndexPath(item: index, section: 0))
        {
            rect = item.view.convert(item.view.bounds, to: nil)
        } else {
            return nil
        }
        return window.convertToScreen(rect)
    }

    private static func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T, !match.isHidden { return match }
        for child in view.subviews where !child.isHidden {
            if let match = firstView(type, in: child) { return match }
        }
        return nil
    }
}
