// Where the items of the grouped Compact List go: the groups one after another down the columns
import Foundation

/// What the arrow keys ask of a grouped view's layout.
public protocol GroupNavigation {
    /// The item an arrow key moves to: by a line (the Icons view's Up and Down, the Compact List's Left and Right) or
    /// across the lines (the next or the previous item). Nil where there is none, so the key does nothing.
    func neighbor(of index: Int, byLine: Bool, forward: Bool) -> Int?
}

extension GroupedLines: GroupNavigation {}

/// The columns of the Compact List while its items are grouped (View ▸ Group By). The groups follow one another down
/// a column, each under its title, and go on in the next column only when there is no room left: a group starts right
/// under the item the one before it ends with. A title at the foot of a column with no room for an item under it goes
/// to the top of the next column with its items, and a column that goes on with a group from the column before starts
/// with that group's title again, so every column says what it holds.
///
/// Positions are along a column, from its top. A column holds its items in order, so the items of a column, and of
/// any run of columns, are a range.
public struct GroupedColumns: Equatable, Sendable, GroupNavigation {
    /// Items of one group in one column, a row apart.
    public struct Run: Equatable, Sendable {
        public var group: Int
        public var column: Int
        /// Its first item's index in the whole list.
        public var firstItem: Int
        public var count: Int
        /// Where its first item starts.
        public var top: Double

        public var items: Range<Int> { firstItem..<(firstItem + count) }
    }

    /// A group's title in a column.
    public struct Header: Equatable, Sendable {
        public var group: Int
        public var column: Int
        public var top: Double
        /// It goes on with the group from the column before.
        public var continued: Bool
    }

    public let runs: [Run]
    public let headers: [Header]
    public let columnCount: Int
    public let rowHeight: Double
    /// The room a title takes in a column, the space before its first item included.
    public let headerHeight: Double
    /// A column and the gap after it.
    public let columnStep: Double
    /// Where the first column starts.
    public let left: Double

    /// `height` is the room a column has for titles and items; a column holds at least a title and an item, however
    /// short it is.
    public init(
        counts: [Int], height: Double, rowHeight: Double, headerHeight: Double, columnStep: Double, left: Double = 0
    ) {
        let rowHeight = max(1, rowHeight)
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.columnStep = columnStep
        self.left = left
        var runs: [Run] = []
        var headers: [Header] = []
        var column = 0
        var at = 0.0
        var item = 0
        // A hair's room for sums of rows that land a rounding error over the height.
        let height = height + 1e-6
        for (group, count) in counts.enumerated() {
            let count = max(0, count)
            // The title, and one item under it, or the next column.
            if at > 0, at + headerHeight + (count > 0 ? rowHeight : 0) > height {
                column += 1
                at = 0
            }
            headers.append(Header(group: group, column: column, top: at, continued: false))
            at += headerHeight
            var placed = 0
            while placed < count {
                let fit = max(1, Int(((height - at) / rowHeight).rounded(.down)))
                let taken = min(fit, count - placed)
                runs.append(Run(group: group, column: column, firstItem: item + placed, count: taken, top: at))
                at += Double(taken) * rowHeight
                placed += taken
                if placed < count {
                    column += 1
                    headers.append(Header(group: group, column: column, top: 0, continued: true))
                    at = headerHeight
                }
            }
            item += count
        }
        self.runs = runs
        self.headers = headers
        columnCount = headers.isEmpty ? 0 : column + 1
    }

    public var itemCount: Int { runs.last.map { $0.firstItem + $0.count } ?? 0 }

    /// Where a column starts across the list.
    public func columnStart(_ column: Int) -> Double { left + Double(column) * columnStep }

    /// Where the last column ends, its gap included.
    public var end: Double { columnStart(columnCount) }

    /// The run an item is in; nil past the end.
    public func run(ofItem index: Int) -> Int? {
        guard index >= 0, index < itemCount else { return nil }
        // The first run that ends after the item.
        let number = firstRun { $0.firstItem + $0.count > index }
        return number < runs.count ? number : nil
    }

    /// An item's column and where it starts along the column.
    public func place(ofItem index: Int) -> (column: Int, top: Double)? {
        guard let number = run(ofItem: index) else { return nil }
        let run = runs[number]
        return (run.column, run.top + Double(index - run.firstItem) * rowHeight)
    }

    /// The column whose step (the column and its gap) holds `x`, which may be outside the columns.
    private func column(at x: Double) -> Int {
        let column = ((x - left) / columnStep).rounded(.down)
        guard column.isFinite else { return column > 0 ? Int.max / 2 : -1 }
        return Int(max(-1, min(Double(Int.max / 2), column)))
    }

    /// The columns that meet the stretch from `from` to `to` across the list.
    public func columns(from: Double, to: Double) -> ClosedRange<Int>? {
        guard columnCount > 0, to > from else { return nil }
        let first = max(0, column(at: from))
        let last = min(columnCount - 1, Int((((to - left) / columnStep).rounded(.up)).clamped(-1, 1e15)) - 1)
        return first <= last ? first...last : nil
    }

    /// The runs of the columns that meet the stretch, in order.
    public func runs(from: Double, to: Double) -> ArraySlice<Run> {
        guard let columns = columns(from: from, to: to) else { return [] }
        let first = firstRun { $0.column >= columns.lowerBound }
        let stop = firstRun { $0.column > columns.upperBound }
        return runs[first..<stop]
    }

    /// The items of the columns that meet the stretch.
    public func items(from: Double, to: Double) -> Range<Int> {
        let shown = runs(from: from, to: to)
        guard let first = shown.first, let last = shown.last else { return 0..<0 }
        return first.firstItem..<(last.firstItem + last.count)
    }

    /// The titles of the columns that meet the stretch.
    public func headers(from: Double, to: Double) -> [Header] {
        guard let columns = columns(from: from, to: to) else { return [] }
        return headers.filter { columns.contains($0.column) }
    }

    /// Left and Right go to the item beside this one in the next column that has items, or the one before: the one at
    /// the height of its middle, or the nearest, as the columns' titles put their items at different heights. Up and Down go to the next
    /// and the previous item, from a group into the next.
    public func neighbor(of index: Int, byLine: Bool, forward: Bool) -> Int? {
        guard let number = run(ofItem: index) else { return nil }
        if !byLine {
            let next = index + (forward ? 1 : -1)
            return next >= 0 && next < itemCount ? next : nil
        }
        let run = runs[number]
        let middle = run.top + (Double(index - run.firstItem) + 0.5) * rowHeight
        var column = run.column + (forward ? 1 : -1)
        while column >= 0, column < columnCount {
            let first = firstRun { $0.column >= column }
            let stop = firstRun { $0.column > column }
            var best: (item: Int, distance: Double)?
            for candidate in runs[first..<stop] {
                // The row at the height of the item's middle, or the run's nearest end.
                let row = ((middle - candidate.top) / rowHeight).rounded(.down)
                let clamped = Int(max(0, min(Double(candidate.count - 1), row.isFinite ? row : 0)))
                let distance = abs(candidate.top + (Double(clamped) + 0.5) * rowHeight - middle)
                if best.map({ distance < $0.distance }) ?? true { best = (candidate.firstItem + clamped, distance) }
            }
            if let best { return best.item }
            column += forward ? 1 : -1
        }
        return nil
    }

    /// The index of the first run that meets `test`, which holds for every run after one it holds for.
    private func firstRun(where test: (Run) -> Bool) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let middle = (low + high) / 2
            if test(runs[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}

extension Double {
    fileprivate func clamped(_ lower: Double, _ upper: Double) -> Double { Swift.min(upper, Swift.max(lower, self)) }
}
