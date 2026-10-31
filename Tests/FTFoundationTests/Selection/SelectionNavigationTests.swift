// Port of the selection, paging and tree cases of apps/desktop/src/renderer/lib/explorerNavigation.test.ts
import Testing

@testable import FTFoundation

struct SelectionNavigationTests {
    private func next(
        _ key: SelectionKey, from index: Int, in mode: ExplorerViewMode, count: Int = 30, columns: Int = 4,
        gap: Int? = nil
    ) -> Int {
        SelectionNavigation.nextIndex(
            itemCount: count, currentIndex: index, key: key, columns: columns, viewMode: mode, gapIndex: gap)
    }

    // T-7216f450 F-785 B-SEL-038 B-SEL-041
    // B-NAV-145 B-NAV-146
    @Test func movesSelectionByVisualColumnsInListViewAndSingleRowsInDetailsView() {
        #expect(next(.down, from: 6, in: .list) == 7)
        #expect(next(.right, from: 6, in: .list) == 10)
        #expect(next(.down, from: 6, in: .details) == 7)
        // Home and End, in every view; the ends hold.
        #expect(next(.home, from: 6, in: .details) == 0)
        #expect(next(.end, from: 6, in: .list) == 29)
        #expect(next(.up, from: 0, in: .details) == 0)
        #expect(next(.down, from: 29, in: .details) == 29)
        #expect(next(.left, from: 2, in: .list) == 0)
        #expect(next(.right, from: 28, in: .list) == 29)
    }

    // T-70433c0d F-785 B-SEL-039 B-SEL-040
    // B-NAV-147
    @Test func movesByItemsSidewaysAndByRowsUpAndDownInIconView() {
        func move(_ index: Int, _ key: SelectionKey) -> Int {
            SelectionNavigation.nextIndex(
                itemCount: 10, currentIndex: index, key: key, columns: 4, viewMode: .icons)
        }
        // Ten items in rows of four: 0-3, 4-7, 8-9.
        #expect(move(5, .right) == 6)
        #expect(move(5, .left) == 4)
        #expect(move(5, .down) == 9)
        #expect(move(5, .up) == 1)
        // Sideways movement carries on into the next and the previous row.
        #expect(move(3, .right) == 4)
        #expect(move(4, .left) == 3)
        // The edges hold.
        #expect(move(1, .up) == 1)
        #expect(move(9, .right) == 9)
        #expect(move(8, .down) == 8)
        // Down from above the gap in a shorter last row lands on the last item.
        #expect(move(6, .down) == 9)
        #expect(move(7, .down) == 9)
    }

    // T-8888c974 B-SEL-043 B-NAV-149
    @Test func startsFromTheFirstItemWhenArrowNavigationBeginsWithNoContentSelection() {
        #expect(next(.down, from: -1, in: .list) == 0)
        #expect(next(.right, from: -1, in: .list) == 0)
        // Home and End still go to the first and last.
        #expect(next(.end, from: -1, in: .details) == 29)
        // Nothing to move through.
        #expect(next(.down, from: -1, in: .details, count: 0) == -1)
    }

    // T-dec54fc2 F-786 B-SEL-049 B-NAV-154
    // T-2df6b189
    @Test func movesAPageAsOneLineLessThanFitAndHalfAPageAsHalfOfThem() {
        func lines(_ viewport: Double, _ extent: Double, _ size: SelectionNavigation.PageSize) -> Int {
            SelectionNavigation.pageStepLineCount(viewportSize: viewport, lineExtent: extent, size: size)
        }
        // Seven rows fit.
        #expect(lines(400, 56, .full) == 6)
        #expect(lines(400, 56, .half) == 3)
        #expect(lines(120, 38, .full) == 2)
        #expect(lines(120, 38, .half) == 1)
        // A line or none fits: always at least one.
        #expect(lines(40, 38, .full) == 1)
        #expect(lines(20, 38, .half) == 1)
        #expect(lines(0, 0, .full) == 1)
    }

    // T-bfae9359 F-786 B-SEL-051 B-NAV-156
    @Test func movesByWholeLinesAndSaysHowManyLinesItMoved() {
        func move(_ index: Int, _ direction: SelectionNavigation.PageDirection, perLine: Int = 1) -> (Int, Int) {
            let result = SelectionNavigation.pagedLineMove(
                itemCount: 100, currentIndex: index, lines: 6, itemsPerLine: perLine, direction: direction)
            return (result.index, result.movedLines)
        }
        #expect(move(10, .forward) == (16, 6))
        #expect(move(10, .backward) == (4, -6))
        // Rows of four icons: the selection keeps its column.
        #expect(move(10, .forward, perLine: 4) == (34, 6))
        #expect(move(30, .backward, perLine: 4) == (6, -6))
    }

    // T-d17ebdc9 B-SEL-051 B-SEL-058
    @Test func stopsAtTheFirstAndLastItemsMovingOnlyTheLinesItCould() {
        func move(_ index: Int, _ direction: SelectionNavigation.PageDirection, perLine: Int = 1) -> (Int, Int) {
            let result = SelectionNavigation.pagedLineMove(
                itemCount: 22, currentIndex: index, lines: 3, itemsPerLine: perLine, direction: direction)
            return (result.index, result.movedLines)
        }
        #expect(move(20, .forward) == (21, 1))
        #expect(move(1, .backward) == (0, -1))
        #expect(move(21, .forward) == (21, 0))
        // Columns of five: from the 2nd column to the last one, which is short.
        #expect(move(7, .forward, perLine: 5) == (21, 3))
        // Nothing selected counts from the first item.
        #expect(move(-1, .forward) == (3, 3))
        let none = SelectionNavigation.pagedLineMove(
            itemCount: 0, currentIndex: 0, lines: 3, itemsPerLine: 1, direction: .forward)
        #expect(none.index == -1 && none.movedLines == 0)
    }

    // T-58ce0423 B-SEL-044 B-SEL-045 B-NAV-151
    // B-NAV-158
    @Test func carriesOnFromWhereTheSelectedItemLeftTheList() {
        func gap(_ key: SelectionKey, _ mode: ExplorerViewMode, _ gapIndex: Int) -> Int {
            SelectionNavigation.nextIndex(
                itemCount: 10, currentIndex: -1, key: key, columns: mode == .details ? 1 : 4, viewMode: mode,
                gapIndex: gapIndex)
        }
        // Details: Down is the item that took the gone item's place, Up the one before it.
        #expect(gap(.down, .details, 5) == 5)
        #expect(gap(.up, .details, 5) == 4)
        #expect(gap(.up, .details, 0) == 0)
        // The last item gone: both go to the new last item.
        #expect(gap(.down, .details, 10) == 9)
        #expect(gap(.up, .details, 10) == 9)
        // Icons: Left and Right step through the items, Up and Down by rows from the place.
        #expect(gap(.right, .icons, 5) == 5)
        #expect(gap(.left, .icons, 5) == 4)
        #expect(gap(.down, .icons, 5) == 9)
        #expect(gap(.up, .icons, 5) == 1)
        // List: Up and Down step through the items, Left and Right by columns.
        #expect(gap(.down, .list, 5) == 5)
        #expect(gap(.up, .list, 5) == 4)
        #expect(gap(.right, .list, 5) == 9)
        #expect(gap(.left, .list, 5) == 1)
    }

    // T-8c9d1cf6
    @Test func flattensVisibleTreePathsInExpandedOrder() {
        let nodes: [String: TypeaheadTreeNode] = [
            "/Users/demo": .init(
                path: "/Users/demo", name: "demo", expanded: true,
                childPaths: ["/Users/demo/Documents", "/Users/demo/Downloads"]),
            "/Users/demo/Documents": .init(
                path: "/Users/demo/Documents", name: "Documents", expanded: true,
                childPaths: ["/Users/demo/Documents/Notes"]),
            "/Users/demo/Documents/Notes": .init(
                path: "/Users/demo/Documents/Notes", name: "Notes", expanded: false, childPaths: []),
            "/Users/demo/Downloads": .init(
                path: "/Users/demo/Downloads", name: "Downloads", expanded: false,
                childPaths: ["/Users/demo/Downloads/Archive"]),
            "/Users/demo/Downloads/Archive": .init(
                path: "/Users/demo/Downloads/Archive", name: "Archive", expanded: false, childPaths: []),
        ]
        #expect(
            SelectionNavigation.flattenVisibleTreePaths(rootPath: "/Users/demo", nodes: nodes) == [
                "/Users/demo", "/Users/demo/Documents", "/Users/demo/Documents/Notes", "/Users/demo/Downloads",
            ])
        #expect(SelectionNavigation.flattenVisibleTreePaths(rootPath: "/nowhere", nodes: nodes) == [])
    }

    // T-4ab16ef0 B-NAV-057
    // B-NAV-058
    @Test func computesParentDirectories() {
        #expect(TreePaths.parent(of: "/Users/demo/Documents") == "/Users/demo")
        #expect(TreePaths.parent(of: "/Users") == "/")
        #expect(TreePaths.parent(of: "/") == nil)
        // Empty and repeated slashes are ignored.
        #expect(TreePaths.parent(of: "//Users//demo/") == "/Users")
    }
}
