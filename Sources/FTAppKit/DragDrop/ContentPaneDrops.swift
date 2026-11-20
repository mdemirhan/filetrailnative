// What the pane's views draw for the clipboard and for a drag over them
import AppKit
import FTFileSystem
import FTFoundation

extension ContentPaneController {
    /// What a drop on the row of `path` would do, while a drag is over it.
    func dropState(for path: String) -> DropTargetState? {
        guard let dropTarget, samePath(dropTarget.path, path) else { return nil }
        return dropTarget.state
    }

    /// The clipboard changed: the rows show its marks again, and flash when it was just copied or cut.
    func clipboardMarksChanged(_ marks: ClipboardMarks?, flash: Bool) {
        guard marks != clipboardMarks || flash else { return }
        clipboardMarks = marks
        pane?.clipboardMarksChanged()
        if flash { pane?.flashClipboardMarks() }
    }

    /// The row a drag is over and what a drop there would do, and whether the folder on screen takes it (its ring).
    /// Drag-overs that change nothing don't redraw anything.
    func setDropTarget(_ path: String?, _ state: DropTargetState?, background: DropTargetState?) {
        let next = path.flatMap { path in state.map { (path, $0) } }
        let previous = dropTarget
        // By the path's bytes: a drag gone from a folder to one whose path differs only in how an accent is stored is
        // over another row.
        let sameRow = previous.map { PathBox($0.path) } == next.map { PathBox($0.0) }
        if !sameRow || previous?.state != next?.1 {
            dropTarget = next.map { (path: $0.0, state: $0.1) }
            var changed: [String] = []
            if let previous { changed.append(previous.path) }
            if let next, !sameRow { changed.append(next.0) }
            // Two such rows are one path to a set of strings: every row in view is drawn again then.
            let paths = Set(changed)
            pane?.refresh(paths: paths.count == changed.count ? paths : nil)
        }
        let ring = background == .valid
        if container.dropRing.isHidden == ring {
            container.dropRing.theme = theme
            container.dropRing.isHidden = !ring
        }
    }

    /// Where the rows of `paths` are drawn, for the drag's images, and the view the drag starts from.
    func dragPlacements(for paths: [String]) -> (view: NSView, placements: [PathBox: FileDragPlacement])? {
        guard let pane else { return nil }
        return (pane.dragView, pane.dragPlacements(for: paths))
    }
}

/// Two paths are the same path only spelled the same: NFC and NFD are two names (compared byte for byte).
func samePath(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
}
