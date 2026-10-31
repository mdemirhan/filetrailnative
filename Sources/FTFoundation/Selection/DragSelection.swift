// Port of apps/desktop/src/renderer/lib/dragSelection.ts
import Foundation

/// A rectangle in points. Each view's hit test takes it relative to the top-left corner of the view that holds its items.
public struct DragSelectionBox: Equatable, Sendable, Codable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    func intersects(_ other: DragSelectionBox) -> Bool {
        left < other.right && right > other.left && top < other.bottom && bottom > other.top
    }
}

public struct DragSelectionHit: Equatable, Sendable, Codable {
    public var path: String
    public var rect: DragSelectionBox

    public init(path: String, rect: DragSelectionBox) {
        self.path = path
        self.rect = rect
    }
}

/// The size of the part of an item that takes clicks and depends on its name (the name under an icon; a list item, as
/// wide as its icon and name), measured on screen. An item that has not been shown is taken at the largest size.
public struct DragSelectionSize: Equatable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Drag-to-select: a drag that starts on empty space in the content pane draws a box and selects the items it touches, as
/// in Finder. The views are virtualized, so the items under the box are worked out from the same layout tokens their
/// scrolling uses, not from the views.
public enum DragSelection {
    /// How far the pointer moves before a press on empty space becomes a drag.
    public static let threshold = 4.0

    /// ⇧ adds what the box touches to the selection the drag started with, ⌘ flips it, as in Finder; a plain drag
    /// selects only what the box touches.
    public enum Mode: String, Sendable, Codable {
        case replace, add, toggle
    }

    /// `getDragSelectionMode`: ⌘ wins when both are held.
    public static func mode(meta: Bool, shift: Bool) -> Mode {
        if meta { return .toggle }
        return shift ? .add : .replace
    }

    /// `makeDragSelectionBox`.
    public static func box(from start: (x: Double, y: Double), to end: (x: Double, y: Double)) -> DragSelectionBox {
        DragSelectionBox(
            left: min(start.x, end.x), top: min(start.y, end.y), right: max(start.x, end.x), bottom: max(start.y, end.y)
        )
    }

    private static func floorInt(_ value: Double) -> Int {
        guard value.isFinite else { return value < 0 ? Int.min / 4 : Int.max / 4 }
        return Int(max(-1e15, min(1e15, value.rounded(.down))))
    }

    private static func ceilInt(_ value: Double) -> Int {
        guard value.isFinite else { return value < 0 ? Int.min / 4 : Int.max / 4 }
        return Int(max(-1e15, min(1e15, value.rounded(.up))))
    }

    /// `getDetailsItemsInBox`: one row per item, at least as wide as the pane, so only the box's height matters.
    public static func detailsItems(box: DragSelectionBox, entryPaths: [String], rowHeight: Double)
        -> [DragSelectionHit]
    {
        let firstRow = max(0, floorInt(box.top / rowHeight))
        let lastRow = min(entryPaths.count - 1, ceilInt(box.bottom / rowHeight) - 1)
        guard firstRow <= lastRow else { return [] }
        return (firstRow...lastRow).map { index in
            DragSelectionHit(
                path: entryPaths[index],
                rect: DragSelectionBox(
                    left: box.left, top: Double(index) * rowHeight, right: box.right,
                    bottom: Double(index + 1) * rowHeight))
        }
    }

    /// `getFlowListItemsInBox`: items fill a column top to bottom, then go on in the next column. An item is as wide as
    /// its icon and name, at most its column's width.
    public static func flowListItems(
        box: DragSelectionBox, entryPaths: [String], rowsPerColumn: Int, rowHeight: Double, itemWidth: Double,
        columnGap: Double, sizes: [String: DragSelectionSize] = [:]
    ) -> [DragSelectionHit] {
        let rows = max(1, rowsPerColumn)
        let columnStep = itemWidth + columnGap
        let columnCount = (entryPaths.count + rows - 1) / rows
        let firstColumn = max(0, floorInt(box.left / columnStep))
        let lastColumn = min(columnCount - 1, floorInt(box.right / columnStep))
        let firstRow = max(0, floorInt(box.top / rowHeight))
        let lastRow = min(rows - 1, ceilInt(box.bottom / rowHeight) - 1)
        var hits: [DragSelectionHit] = []
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return hits }
        for column in firstColumn...lastColumn {
            for row in firstRow...lastRow {
                let index = column * rows + row
                guard index < entryPaths.count else { continue }
                let path = entryPaths[index]
                let left = Double(column) * columnStep
                let width = min(itemWidth, sizes[path]?.width ?? itemWidth)
                let top = Double(row) * rowHeight
                let rect = DragSelectionBox(left: left, top: top, right: left + width, bottom: top + rowHeight)
                if box.intersects(rect) { hits.append(DragSelectionHit(path: path, rect: rect)) }
            }
        }
        return hits
    }

    /// `getIconGridItemsInBox`: items read left to right in columns that share the grid's width, each item in the middle
    /// of its column. An item is touched on its icon's tile or on its name, not on the space around them.
    public static func iconGridItems(
        box: DragSelectionBox, entryPaths: [String], columns: Int, gridWidth: Double, layout: IconGridLayout,
        sizes: [String: DragSelectionSize] = [:]
    ) -> [DragSelectionHit] {
        let columnCount = max(1, columns)
        let columnWidth = gridWidth / Double(columnCount)
        let tileTop = layout.itemPaddingTop
        let labelTop = tileTop + layout.iconBoxSize + layout.labelGap
        // `.icon-item` is 2 px shorter than its row.
        let tallestLabel = layout.rowHeight - 2 - labelTop
        let rowCount = (entryPaths.count + columnCount - 1) / columnCount
        let firstRow = max(0, floorInt(box.top / layout.rowHeight))
        let lastRow = min(rowCount - 1, floorInt(box.bottom / layout.rowHeight))
        var hits: [DragSelectionHit] = []
        guard firstRow <= lastRow else { return hits }
        for row in firstRow...lastRow {
            for column in 0..<columnCount {
                let index = row * columnCount + column
                guard index < entryPaths.count else { continue }
                let path = entryPaths[index]
                let center = (Double(column) + 0.5) * columnWidth
                let top = Double(row) * layout.rowHeight
                let tile = DragSelectionBox(
                    left: center - layout.iconBoxSize / 2, top: top + tileTop, right: center + layout.iconBoxSize / 2,
                    bottom: top + tileTop + layout.iconBoxSize)
                let size = sizes[path]
                let labelWidth = min(layout.labelWidth, size?.width ?? layout.labelWidth)
                let label = DragSelectionBox(
                    left: center - labelWidth / 2, top: top + labelTop, right: center + labelWidth / 2,
                    bottom: top + labelTop + min(tallestLabel, size?.height ?? tallestLabel))
                if box.intersects(tile) || box.intersects(label) {
                    hits.append(
                        DragSelectionHit(
                            path: path,
                            rect: DragSelectionBox(
                                left: min(tile.left, label.left), top: tile.top, right: max(tile.right, label.right),
                                bottom: label.bottom)))
                }
            }
        }
        return hits
    }

    /// `combineDragSelection`: the selection while the box is drawn, what it touches combined with the selection the
    /// drag started with.
    public static func combine(startPaths: [String], hitPaths: [String], mode: Mode) -> [String] {
        if mode == .replace { return hitPaths }
        let hit = Set(hitPaths)
        if mode == .add { return startPaths.filter { !hit.contains($0) } + hitPaths }
        let start = Set(startPaths)
        return startPaths.filter { !hit.contains($0) } + hitPaths.filter { !start.contains($0) }
    }

    /// `getDragSelectionAutoScrollStep`: how far to scroll this frame while the pointer is `overshoot` points past an
    /// edge of the pane: faster the further out it is.
    public static func autoScrollStep(overshoot: Double) -> Double {
        if overshoot == 0 { return 0 }
        let sign: Double = overshoot < 0 ? -1 : 1
        return sign * min(40, 4 + abs(overshoot) / 3)
    }

    /// The selection's lead at button up (`handleMouseUp` of `useDragSelection`): the touched item nearest the pointer
    /// (the distance from the pointer to each item's box), or the last item selected when the box touches none.
    public static func nearestLead(hits: [DragSelectionHit], pointer: (x: Double, y: Double), shownPaths: [String])
        -> String?
    {
        var best: (path: String, distance: Double)?
        for hit in hits {
            let dx = max(hit.rect.left - pointer.x, 0, pointer.x - hit.rect.right)
            let dy = max(hit.rect.top - pointer.y, 0, pointer.y - hit.rect.bottom)
            let distance = (dx * dx + dy * dy).squareRoot()
            if let current = best, current.distance <= distance { continue }
            best = (hit.path, distance)
        }
        return best?.path ?? shownPaths.last
    }
}
