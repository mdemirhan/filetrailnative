// Port of getNextSelectionIndex, getPageStepLineCount and getPagedLineMove of apps/desktop/src/renderer/lib/explorerNavigation.ts
import Foundation

/// The keys that move the selection by items.
public enum SelectionKey: String, Sendable, Codable, CaseIterable {
    case up = "ArrowUp"
    case down = "ArrowDown"
    case left = "ArrowLeft"
    case right = "ArrowRight"
    case home = "Home"
    case end = "End"
}

public enum SelectionNavigation {
    /// Arrow-key movement differs by view mode: the Compact List uses columns for left/right jumps, the Icon view
    /// uses them for up/down jumps, and the List behaves as a single vertical sequence.
    ///
    /// - `columns`: icons per row (Icons) or rows per column (Compact List); 1 for the List.
    /// - `gapIndex`: with nothing selected, where the selected items were before they left the list.
    public static func nextIndex(
        itemCount: Int, currentIndex: Int, key: SelectionKey, columns: Int, viewMode: ExplorerViewMode,
        gapIndex: Int? = nil
    ) -> Int {
        guard itemCount > 0 else { return -1 }
        switch key {
        case .home: return 0
        case .end: return itemCount - 1
        default: break
        }
        if currentIndex < 0 {
            guard let gapIndex else { return 0 }
            // A step to the next item goes to the one that took the gone item's place, a step back to the one before it.
            // A step by a row (icons) or a column (list) goes from that place.
            let movesByStep: Bool
            switch viewMode {
            case .icons: movesByStep = key == .up || key == .down
            case .list: movesByStep = key == .left || key == .right
            case .details: movesByStep = false
            }
            if !movesByStep {
                let forward = key == .down || key == .right
                return clamp(forward ? gapIndex : gapIndex - 1, itemCount)
            }
            return clamp(
                nextIndex(
                    itemCount: itemCount, currentIndex: gapIndex, key: key, columns: columns, viewMode: viewMode),
                itemCount)
        }

        let index = currentIndex
        let step = max(1, columns)
        switch viewMode {
        case .details:
            return clamp(key == .up || key == .left ? index - 1 : index + 1, itemCount)
        case .icons:
            // Icon view reads left to right, then down: Left and Right move one item, Up and Down one row. Down from the
            // row above a shorter last row goes to the last item.
            switch key {
            case .left: return clamp(index - 1, itemCount)
            case .right: return clamp(index + 1, itemCount)
            case .up: return index - step >= 0 ? index - step : index
            default:
                if index + step < itemCount { return index + step }
                let last = itemCount - 1
                return index / step < last / step ? last : index
            }
        case .list:
            switch key {
            case .up: return clamp(index - 1, itemCount)
            case .down: return clamp(index + 1, itemCount)
            case .left: return clamp(index - step, itemCount)
            default: return clamp(index + step, itemCount)
            }
        }
    }

    /// How many lines (rows, or Compact List columns) a page moves.
    public enum PageSize: String, Sendable, Codable {
        case half, full
    }

    /// `getPageStepLineCount`: a full page is one less than fit on screen, so the last one stays in view; half a page is
    /// half of those that fit.
    public static func pageStepLineCount(viewportSize: Double, lineExtent: Double, size: PageSize) -> Int {
        let fits = (max(0, viewportSize) / max(1, lineExtent)).rounded(.down)
        let visible = max(1, fits.isFinite ? Int(min(fits, 1e9)) : 1)
        return max(1, size == .full ? visible - 1 : visible / 2)
    }

    public enum PageDirection: String, Sendable, Codable {
        case backward, forward
    }

    /// `getPagedLineMove`: where a step of `lines` lines from `currentIndex` lands, stopping at the first and last
    /// items, and how many lines the selection moved, for the view to scroll as far. A line holds `itemsPerLine`
    /// items: a row of icons, or a Compact List column.
    public static func pagedLineMove(
        itemCount: Int, currentIndex: Int, lines: Int, itemsPerLine: Int, direction: PageDirection
    ) -> (index: Int, movedLines: Int) {
        guard itemCount > 0 else { return (-1, 0) }
        let perLine = max(1, itemsPerLine)
        let from = max(0, currentIndex)
        let step = max(1, lines) * perLine
        let index = clamp(direction == .forward ? from + step : from - step, itemCount)
        return (index, index / perLine - from / perLine)
    }

    private static func clamp(_ index: Int, _ itemCount: Int) -> Int {
        max(0, min(itemCount - 1, index))
    }

    /// `flattenVisibleTreePaths`: the expanded tree in the order it shows, a pre-order walk that keyboard navigation and
    /// paged movement depend on.
    public static func flattenVisibleTreePaths(rootPath: String, nodes: [String: TypeaheadTreeNode]) -> [String] {
        var ordered: [String] = []
        func visit(_ path: String) {
            guard let node = nodes[path] else { return }
            ordered.append(path)
            guard node.expanded else { return }
            for child in node.childPaths { visit(child) }
        }
        visit(rootPath)
        return ordered
    }
}
