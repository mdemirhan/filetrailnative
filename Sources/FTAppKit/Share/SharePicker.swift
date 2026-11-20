import AppKit
import FTFileSystem
import FTFoundation

/// The system's share popover, as Finder's Share… shows it: the items' icon, name and kind at the top, then AirDrop,
/// Mail, Messages, Notes, the share extensions installed, Copy and Edit Extensions…. macOS chooses what it offers for
/// the items; the app neither lists nor filters it. The picker's delegate isn't marked for the main actor, though
/// AppKit calls it there.
@MainActor
final class SharePicker: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let shared = SharePicker()

    /// The picker showing, kept until it closes, so that the next Share closes it first.
    private var picker: NSSharingServicePicker?
    /// Where the items are on screen, for the animation of a service that starts from them (Mail, Messages).
    private var sourceFrame: NSRect?
    private weak var sourceWindow: NSWindow?
    private var firstPath: String?

    /// The items as a sharing service is handed them: each path's own bytes, so an accent reaches the service as
    /// the disk spells it.
    static func items(_ paths: [String]) -> [NSURL] {
        paths.map { DiskPath($0).fileURL() as NSURL }
    }

    /// Shows the popover for `paths` by `rect` of `view`, below it where there is room.
    func show(_ paths: [String], relativeTo rect: NSRect, of view: NSView, sourceFrame: NSRect? = nil) {
        guard !paths.isEmpty, view.window != nil else { return }
        picker?.close()
        let picker = NSSharingServicePicker(items: Self.items(paths))
        picker.delegate = self
        self.picker = picker
        self.sourceFrame = sourceFrame
        sourceWindow = view.window
        firstPath = paths.first
        picker.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    private func ended() {
        picker = nil
        sourceFrame = nil
        sourceWindow = nil
        firstPath = nil
    }

    // MARK: NSSharingServicePickerDelegate

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    /// Called with the service chosen, or nil when the popover closed without one.
    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        // A service chosen still asks for the items' frame and window as it starts: they go once it has.
        guard service == nil else { return }
        if picker === sharingServicePicker { ended() }
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        ended()
    }

    func sharingService(
        _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
        ended()
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any)
        -> NSRect
    {
        sourceFrame ?? .zero
    }

    func sharingService(
        _ sharingService: NSSharingService, transitionImageForShareItem item: Any,
        contentRect: UnsafeMutablePointer<NSRect>
    ) -> NSImage? {
        firstPath.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    func sharingService(
        _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        sourceWindow
    }
}

extension MainWindowController {
    /// Share…: the system's share popover for `paths`, under `button` when one was pressed (the toolbar's, the Info
    /// panel's), else under the lead item of the selection in the list (the first of `paths` when the lead isn't
    /// among them), or at the top of the list when that item is not on screen. Nothing for items in the Trash,
    /// whichever way it was asked: a key set for Share… comes here though its menu item is dimmed.
    func share(_ paths: [String], from button: NSView? = nil) {
        guard !paths.isEmpty, !paths.contains(where: { Paths.isInsideTrash($0, homePath: trashHomePath) }) else {
            return
        }
        func show(_ rect: NSRect, of view: NSView, sourceFrame: NSRect? = nil) {
            if let showSharePicker {
                showSharePicker(paths, rect, view)
            } else {
                SharePicker.shared.show(paths, relativeTo: rect, of: view, sourceFrame: sourceFrame)
            }
        }
        let content = content
        let lead =
            content.selection.leadPath.flatMap { lead in
                paths.contains { DiskPath($0) == DiskPath(lead) } ? lead : nil
            } ?? paths[0]
        let itemFrame = QuickLookItemFrame.screenFrame(of: lead, entries: content.entries, in: content.view)
        if let button, button.window != nil {
            show(button.bounds, of: button, sourceFrame: itemFrame)
            return
        }
        guard let window, let list = content.view.window == nil ? nil : content.view else { return }
        let visible = list.visibleRect
        if let itemFrame {
            let rect = list.convert(window.convertFromScreen(itemFrame), from: nil)
            if rect.intersects(visible) {
                show(rect.intersection(visible), of: list, sourceFrame: itemFrame)
                return
            }
        }
        // The item is scrolled out of sight: the popover hangs from the top of the list.
        let top = list.isFlipped ? visible.minY : visible.maxY - 1
        show(NSRect(x: visible.midX, y: top, width: 1, height: 1), of: list)
    }

    /// File ▸ Share… and its key: the items selected in the list.
    func shareSelection(from button: NSView? = nil) {
        share(content.selection.paths, from: button)
    }
}
