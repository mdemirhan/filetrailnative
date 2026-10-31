// Port of apps/desktop/src/renderer/lib/pagedScroll.ts
import Foundation

/// Scrolling by the amount a page of lines moved.
public enum PagedScroll {
    /// Where a scroll by `delta` lands, stopping at either end, or nil when nothing would scroll: the view can't scroll
    /// that way, or it moves by a point or less (`scrollElementByAmount`).
    public static func nextOffset(viewportSize: Double, scrollSize: Double, currentOffset: Double, delta: Double)
        -> Double?
    {
        let maxOffset = max(0, scrollSize - viewportSize)
        if viewportSize <= 0 || maxOffset <= 0 { return nil }
        let next = max(0, min(maxOffset, currentOffset + delta))
        if abs(next - currentOffset) <= 1 { return nil }
        return next
    }
}
