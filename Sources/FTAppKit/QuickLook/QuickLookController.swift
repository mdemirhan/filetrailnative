// Port of the Quick Look part of apps/desktop/src/main/bootstrap/systemHandlers.ts (system:quickLook, BrowserWindow.previewFile)
import AppKit
import FTFileSystem
import FTFoundation
@preconcurrency import Quartz

/// Quick Look: the system's preview panel for one item (the original previews a single file, PLAN.md §3.3), opened
/// with Space, the menu and the Info panel's button, zooming out of the item's row.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    /// The item the panel previews.
    private(set) var url: URL?
    /// Where the item is on screen, for the zoom transition (nil: no transition).
    var sourceFrame: ((URL) -> NSRect?)?
    /// Told when the panel closes.
    var onClose: (() -> Void)?
    private weak var owner: NSWindow?
    /// The panel, replaceable in tests.
    var panelProvider: () -> QLPreviewPanel? = { QLPreviewPanel.shared() }

    var isShowing: Bool { panelProvider()?.isVisible == true && url != nil }

    /// `previewFile`: the panel shows the item. Showing the item it already shows closes the panel, as Space does.
    func toggle(_ path: String, from window: NSWindow?, sourceFrame: @escaping (URL) -> NSRect?) {
        let target = URL(fileURLWithPath: path)
        if isShowing, url == target {
            close()
            return
        }
        show(path, from: window, sourceFrame: sourceFrame)
    }

    func show(_ path: String, from window: NSWindow?, sourceFrame: @escaping (URL) -> NSRect?) {
        guard let panel = panelProvider() else { return }
        url = URL(fileURLWithPath: path)
        owner = window
        self.sourceFrame = sourceFrame
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if panel.isVisible {
            panel.refreshCurrentPreviewItem()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard let panel = panelProvider(), panel.isVisible else { return }
        panel.orderOut(nil)
        ended()
    }

    /// The panel is taken from a window that no longer shows its item (the folder changed).
    func windowWillChange(_ window: NSWindow) {
        if owner === window { close() }
    }

    func ended() {
        url = nil
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
        guard let url, let frame = sourceFrame?(url) else { return .zero }
        return frame
    }

    func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        guard let url else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Where an item is on screen: its row in the List or its cell in the Icons view.
@MainActor
enum QuickLookItemFrame {
    static func screenFrame(of path: String, entries: [DirectoryEntry], in root: NSView) -> NSRect? {
        guard let index = entries.firstIndex(where: { $0.path == path }), let window = root.window else { return nil }
        let rect: NSRect
        if let table = firstView(NSTableView.self, in: root), index < table.numberOfRows {
            let row = table.rect(ofRow: index)
            // The icon sits at the row's left edge.
            let side = min(row.height, CGFloat(DesignTokens.details(density: .comfortable).iconSize))
            rect = table.convert(NSRect(x: row.minX + 8, y: row.midY - side / 2, width: side, height: side), to: nil)
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
