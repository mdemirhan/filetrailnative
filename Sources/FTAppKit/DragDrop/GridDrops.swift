// Port of the Icons and Compact List share of apps/desktop/src/renderer/components/IconGridView.tsx and
// ContentPane.tsx's FlowListView (data-drag-path, the items' drag and drop events) and of lib/fileDragImages.ts for
// their items: where a drag of their items sets off from, what a drag over them is offered to, and the flash of copied
// and cut items
import AppKit
import FTFileSystem
import FTFoundation

/// An item of the Icons or Compact List view, as drags and the clipboard's flash see it.
@MainActor
protocol GridItemDragging: AnyObject {
    /// The item was just copied or cut: it flashes, if it is on the clipboard.
    func flashClipboardMark(in pane: ItemGridPane)
    /// Where the item's icon and name are drawn, in `view`'s coordinates.
    func dragPlacement(in view: NSView, visible: NSRect) -> FileDragPlacement
}

extension ItemGridPane {
    /// The collection takes drags of files (B-CLIP-156); the items draw their own drop highlight.
    func registerForFileDrops() {
        collection.registerForDraggedTypes([.fileURL])
    }

    // MARK: The clipboard's flash

    func flashClipboardMarks() {
        forEachVisibleItem { item, _ in (item as? GridItemDragging)?.flashClipboardMark(in: self) }
    }

    // MARK: Drag out

    var dragView: NSView { collection }

    /// Each item in sight among `paths`: its icon and its name, in the collection's coordinates.
    func dragPlacements(for paths: [String]) -> [String: FileDragPlacement] {
        var placements: [String: FileDragPlacement] = [:]
        let wanted = Set(paths.map(PathBox.init))
        let visible = collection.visibleRect
        forEachVisibleItem { item, entry in
            guard wanted.contains(PathBox(entry.path)), let dragging = item as? GridItemDragging else { return }
            placements[entry.path] = dragging.dragPlacement(in: collection, visible: visible)
        }
        return placements
    }

    // MARK: Drag in

    /// The folder item under the drag, or nil for the folder on screen (a file or empty space).
    func dropEntry(_ info: any NSDraggingInfo) -> DirectoryEntry? {
        let point = collection.convert(info.draggingLocation, from: nil)
        guard let entry = entry(at: point), entry.kind == .directory || entry.kind == .symlinkDirectory else {
            return nil
        }
        return entry
    }
}

extension ItemGridView {
    // The collection's own drop handling (its delegate's drop index paths) is not used: drops go to the tab's hooks,
    // as the List's do.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        edgeScroll.follow(sender, in: enclosingScrollView)
        return dragOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        edgeScroll.follow(sender, in: enclosingScrollView)
        return dragOperation(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        edgeScroll.reset()
        pane?.host?.dragHooks.dragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        edgeScroll.reset()
        guard let pane else { return false }
        return pane.host?.dragHooks.performDrop?(sender, pane.dropEntry(sender)) ?? false
    }

    private func dragOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let pane else { return [] }
        return pane.host?.dragHooks.dragUpdated?(info, pane.dropEntry(info)) ?? []
    }
}
