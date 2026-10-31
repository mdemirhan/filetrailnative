// Port of apps/desktop/src/renderer/lib/virtualization.ts
import Foundation

/// A half-open `[startIndex, endIndex)` window of items to show.
public struct VirtualRange: Equatable, Sendable, Codable {
    public var startIndex: Int
    public var endIndex: Int

    public init(startIndex: Int, endIndex: Int) {
        self.startIndex = startIndex
        self.endIndex = endIndex
    }
}

/// The sizes of a Compact List as rows per column depend on them (`FlowListLayout` of `virtualization.ts`).
public struct FlowRowsLayout: Equatable, Sendable, Codable {
    public var rowHeight: Double
    public var rowGap: Double
    public var paddingTop: Double
    public var paddingBottom: Double

    public init(rowHeight: Double, rowGap: Double, paddingTop: Double, paddingBottom: Double) {
        self.rowHeight = rowHeight
        self.rowGap = rowGap
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
    }
}

public enum Virtualization {
    /// `getVirtualRange`: the items to show around the viewport. Tolerant of bad inputs (a size of zero or less, a
    /// scroll past the end of a shorter list), as live measurements can be.
    public static func range(
        itemCount: Int, itemSize: Double, viewportSize: Double, scrollOffset: Double, overscan: Int
    ) -> VirtualRange {
        guard itemCount > 0 else { return VirtualRange(startIndex: 0, endIndex: 0) }
        let size = max(1, itemSize)
        let viewport = max(size, viewportSize)
        let offset = max(0, scrollOffset)
        let extra = max(0, overscan)
        let visible = max(1, clampedInt((viewport / size).rounded(.up)))
        let unclampedStart = max(0, clampedInt((offset / size).rounded(.down)) - extra)
        let maxStart = max(0, itemCount - visible)
        let start = min(unclampedStart, maxStart)
        let end = min(itemCount, start + visible + extra * 2)
        return VirtualRange(startIndex: start, endIndex: end)
    }

    /// `chunkItemsIntoRows`: rows of `columns` items, in order; the last may be shorter.
    public static func chunkIntoRows<T>(_ items: [T], columns: Int) -> [[T]] {
        let step = max(1, columns)
        return stride(from: 0, to: items.count, by: step).map { Array(items[$0..<min(items.count, $0 + step)]) }
    }

    /// `computeRowsPerColumn`: how many rows of a Compact List fit in a pane this tall. The height is the pane's; a
    /// height of zero or less (not measured yet) gives one row.
    public static func rowsPerColumn(containerHeight: Double, layout: FlowRowsLayout) -> Int {
        guard containerHeight > 0 else { return 1 }
        let content = containerHeight - layout.paddingTop - layout.paddingBottom + layout.rowGap
        return max(1, clampedInt((max(content, layout.rowHeight) / layout.rowHeight).rounded(.down)))
    }

    /// `buildColumnMajorRows`: the Compact List's rows, filled top to bottom first and then on in the next column.
    public static func columnMajorRows<T>(_ items: [T], rowsPerColumn: Int) -> [[T]] {
        let rows = max(1, rowsPerColumn)
        let columnCount = max(1, (items.count + rows - 1) / rows)
        var built = Array(repeating: [T](), count: min(rows, max(1, items.count)))
        for column in 0..<columnCount {
            for row in 0..<rows {
                let index = column * rows + row
                guard index < items.count, row < built.count else { continue }
                built[row].append(items[index])
            }
        }
        return built
    }

    private static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite else { return value < 0 ? Int.min / 4 : Int.max / 4 }
        return Int(max(-1e15, min(1e15, value)))
    }
}
