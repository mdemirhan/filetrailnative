// Port of the List's drag hooks of apps/desktop/src/renderer/components/ContentPane.tsx (data-drag-path, the rows'
// drag and drop events) and of lib/fileDragImages.ts for its rows: where a drag of its items sets off from, what a
// drag over it is offered to, and the flash of copied and cut rows
import AppKit
import FTFileSystem
import FTFoundation

extension ListViewController {
    /// The table takes drags of files (B-CLIP-156); the rows draw their own drop highlight.
    func registerForFileDrops() {
        table.registerForDraggedTypes([.fileURL])
        table.draggingDestinationFeedbackStyle = .none
        table.setDraggingSourceOperationMask([], forLocal: true)
    }

    // MARK: The clipboard's flash

    func flashClipboardMarks() {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            bar(atRow: row)?.flashClipboardMark()
        }
    }

    // MARK: Drag out

    var dragView: NSView { table }

    /// Each row in sight among `paths`: its icon and its name, in the table's coordinates.
    func dragPlacements(for paths: [String]) -> [String: FileDragPlacement] {
        var placements: [String: FileDragPlacement] = [:]
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return placements }
        let wanted = Set(paths.map(PathBox.init))
        let visible = table.visibleRect
        for row in rows.location..<(rows.location + rows.length) where entries.indices.contains(row) {
            let entry = entries[row]
            guard wanted.contains(PathBox(entry.path)), let bar = bar(atRow: row) else { continue }
            let icon = bar.nameCell.iconView.convert(bar.nameCell.iconView.bounds, to: table)
            let label = bar.nameLabel
            var nameRect = label.convert(label.bounds, to: table)
            nameRect.size.width = min(nameRect.width, ceil(label.textWidth))
            placements[entry.path] = FileDragPlacement(
                iconRect: icon, nameRect: nameRect, nameFontSize: Double(label.font?.pointSize ?? 13),
                nameCentered: false, thumbnail: false,
                inSight: FileDragImages.isInSight(icon, within: [visible]))
        }
        return placements
    }

    // MARK: Drag in

    /// The folder row under the drag, or nil for the folder on screen (a file or empty space).
    func dropEntry(_ info: any NSDraggingInfo) -> DirectoryEntry? {
        let point = table.convert(info.draggingLocation, from: nil)
        guard let entry = entry(at: point), entry.kind == .directory || entry.kind == .symlinkDirectory else {
            return nil
        }
        return entry
    }

    /// The table asks this only when the row or the source's mask changes. The tab hears every drag-over from
    /// `ListTableView` and its answer is what AppKit gets, so the table is only told to go on, and to call
    /// `acceptDrop` whatever the tab said on the way in.
    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)
        return info.draggingSourceOperationMask
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        host?.dragHooks.performDrop?(info, dropEntry(info)) ?? false
    }
}

extension ListTableView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        _ = super.draggingEntered(sender)
        return dragOver(sender)
    }

    // Drag-overs come many times a second with the pointer still: the hold on a folder and its highlight live on them.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        _ = super.draggingUpdated(sender)
        return dragOver(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func dragOver(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let pane else { return [] }
        return pane.host?.dragHooks.dragUpdated?(info, pane.dropEntry(info)) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        pane?.host?.dragHooks.dragExited?()
    }
}

/// A path as a key, spelled exactly.
struct PathBox: Hashable {
    let bytes: [UInt8]

    init(_ path: String) {
        bytes = Array(path.utf8)
    }
}

extension FTFileSystem.EntryKind {
    /// The same kind, as the rules of FTFoundation name it.
    var rules: FTFoundation.EntryKind { FTFoundation.EntryKind(rawValue: rawValue) ?? .other }
}
