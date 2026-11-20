// Where the items of a grouped grid go: each group's header, then its items on lines of their own
import Foundation

/// The lines of a view whose items are grouped (View ▸ Group By): the Icons view's and Previews' rows (the Compact
/// List's columns are `GroupedColumns`). Each group starts on a line of its own after its header, so a line never holds two groups' items;
/// along the scrolling axis a group takes its header's extent, its lines, and the gap after it. A collapsed group has
/// no items, and keeps its header. Lines are numbered across the groups, and an item's place in its line is its slot.
public struct GroupedLines: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        /// Its first item's index in the whole list.
        public var firstItem: Int
        public var count: Int
        /// Where its header starts along the scrolling axis.
        public var headerStart: Double
        /// Where its first line starts.
        public var linesStart: Double
        /// The number of its first line, counted across the groups.
        public var firstLine: Int
        public var lineCount: Int

        public var items: Range<Int> { firstItem..<(firstItem + count) }
    }

    public let groups: [Group]
    public let perLine: Int
    public let lineExtent: Double
    public let headerExtent: Double
    /// Where the last group ends, its gap included.
    public let end: Double

    public init(
        counts: [Int], perLine: Int, lineExtent: Double, headerExtent: Double, groupGap: Double = 0, start: Double = 0
    ) {
        let perLine = max(1, perLine)
        self.perLine = perLine
        self.lineExtent = lineExtent
        self.headerExtent = headerExtent
        var made: [Group] = []
        made.reserveCapacity(counts.count)
        var at = start
        var item = 0
        var line = 0
        for count in counts {
            let lines = (max(0, count) + perLine - 1) / perLine
            made.append(
                Group(
                    firstItem: item, count: max(0, count), headerStart: at, linesStart: at + headerExtent,
                    firstLine: line, lineCount: lines))
            at += headerExtent + Double(lines) * lineExtent + groupGap
            item += max(0, count)
            line += lines
        }
        groups = made
        end = at
    }

    public var itemCount: Int { groups.last.map { $0.firstItem + $0.count } ?? 0 }
    public var lineCount: Int { groups.last.map { $0.firstLine + $0.lineCount } ?? 0 }

    /// The group an item is in; nil past the end.
    public func group(ofItem index: Int) -> Int? {
        guard index >= 0, index < itemCount else { return nil }
        var low = 0
        var high = groups.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if groups[middle].firstItem <= index { low = middle } else { high = middle - 1 }
        }
        // A collapsed group shares its first item with the next one, which is found as the last with it.
        return low
    }

    /// An item's place: its line, counted across the groups, its slot in that line, and where the line starts.
    public func place(ofItem index: Int) -> (line: Int, slot: Int, lineStart: Double)? {
        guard let number = group(ofItem: index) else { return nil }
        let group = groups[number]
        let offset = index - group.firstItem
        let line = offset / perLine
        return (group.firstLine + line, offset % perLine, group.linesStart + Double(line) * lineExtent)
    }

    /// The group whose lines hold `line`, and where the line starts.
    public func line(_ line: Int) -> (group: Int, start: Double)? {
        guard line >= 0, line < lineCount else { return nil }
        guard let number = groups.lastIndex(where: { $0.firstLine <= line && $0.lineCount > 0 }) else { return nil }
        let group = groups[number]
        return (number, group.linesStart + Double(line - group.firstLine) * lineExtent)
    }

    /// The items of a line, in order.
    public func items(onLine line: Int) -> Range<Int> {
        guard let (number, _) = self.line(line) else { return 0..<0 }
        let group = groups[number]
        let first = group.firstItem + (line - group.firstLine) * perLine
        return first..<min(group.firstItem + group.count, first + perLine)
    }

    /// The items whose lines meet the stretch from `from` to `to` along the scrolling axis.
    public func items(from: Double, to: Double) -> Range<Int> {
        var first: Int?
        var last: Int?
        for group in groups where group.count > 0 {
            let groupEnd = group.linesStart + Double(group.lineCount) * lineExtent
            guard groupEnd > from, group.linesStart < to else { continue }
            let firstLine = max(0, Int(((from - group.linesStart) / lineExtent).rounded(.down)))
            let lastLine = min(group.lineCount - 1, Int(((to - group.linesStart) / lineExtent).rounded(.up)) - 1)
            guard firstLine <= lastLine else { continue }
            let start = group.firstItem + firstLine * perLine
            let stop = min(group.firstItem + group.count, group.firstItem + (lastLine + 1) * perLine)
            if first == nil { first = start }
            last = stop
        }
        guard let first, let last, first < last else { return 0..<0 }
        return first..<last
    }

    /// The groups whose header or lines meet the stretch from `from` to `to`.
    public func groups(from: Double, to: Double) -> [Int] {
        groups.indices.filter { number in
            let group = groups[number]
            let groupEnd = group.linesStart + Double(group.lineCount) * lineExtent
            return groupEnd > from && group.headerStart < to
        }
    }

    /// The item an arrow key moves to. Along the lines (a step by a line: Up and Down), the item in the same slot of the
    /// next or the previous line, which may be another group's, or that line's last item when it is shorter; across
    /// them, the next or the previous item. Nil where there is none, so the key does nothing.
    public func neighbor(of index: Int, byLine: Bool, forward: Bool) -> Int? {
        guard let place = place(ofItem: index) else { return nil }
        if !byLine {
            let next = index + (forward ? 1 : -1)
            return next >= 0 && next < itemCount ? next : nil
        }
        let target = place.line + (forward ? 1 : -1)
        let items = items(onLine: target)
        guard !items.isEmpty else { return nil }
        return min(items.lowerBound + place.slot, items.upperBound - 1)
    }
}
