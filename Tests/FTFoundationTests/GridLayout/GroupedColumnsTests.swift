import Foundation
import Testing

@testable import FTFoundation

struct GroupedColumnsTests {
    // Columns 100 tall, rows 10, titles 25, columns 50 apart from 5: a title and 7 rows fill a column (95).
    static func columns(_ counts: [Int], height: Double = 100) -> GroupedColumns {
        GroupedColumns(counts: counts, height: height, rowHeight: 10, headerHeight: 25, columnStep: 50, left: 5)
    }

    @Test func aGroupStartsUnderTheItemThePreviousOneEndsWith() {
        let columns = Self.columns([2, 3])
        #expect(columns.columnCount == 1)
        #expect(
            columns.headers == [
                .init(group: 0, column: 0, top: 0, continued: false),
                .init(group: 1, column: 0, top: 45, continued: false),
            ])
        #expect(columns.runs.map(\.top) == [25, 70])
        #expect(columns.place(ofItem: 1)! == (0, 35))
        #expect(columns.place(ofItem: 2)! == (0, 70))
        #expect(columns.place(ofItem: 4)! == (0, 90))
        #expect(columns.end == 55)
    }

    @Test func aGroupGoesOnInTheNextColumnUnderItsTitleAgain() {
        let columns = Self.columns([10])
        #expect(columns.columnCount == 2)
        #expect(columns.runs.map(\.count) == [7, 3])
        #expect(columns.headers.map(\.continued) == [false, true])
        #expect(columns.headers[1].top == 0 && columns.headers[1].column == 1)
        #expect(columns.place(ofItem: 7)! == (1, 25))
        #expect(columns.columnStart(1) == 55)
    }

    @Test func aTitleWithNoRoomForAnItemUnderItStartsTheNextColumn() {
        // The first group ends at 85: its title and a row need 35 more.
        let columns = Self.columns([6, 2])
        #expect(columns.headers[1] == .init(group: 1, column: 1, top: 0, continued: false))
        #expect(columns.place(ofItem: 6)! == (1, 25))
        // The title alone fits where a collapsed group has no item under it.
        let collapsed = Self.columns([5, 0, 1])
        #expect(collapsed.headers.map(\.column) == [0, 0, 1])
    }

    @Test func aColumnTooShortStillHoldsATitleAndAnItem() {
        let columns = Self.columns([3], height: 20)
        #expect(columns.columnCount == 3)
        #expect(columns.runs.map(\.count) == [1, 1, 1])
        #expect(columns.headers.map(\.continued) == [false, true, true])
    }

    @Test func theItemsOfAStretchAreThoseOfTheColumnsItMeets() {
        let columns = Self.columns([10, 2])
        // Column 0: items 0–6; column 1: 7–9, then the second group's 10–11 under its title.
        #expect(columns.runs.map(\.column) == [0, 1, 1])
        #expect(columns.items(from: 0, to: 20) == 0..<7)
        #expect(columns.items(from: 60, to: 70) == 7..<12)
        #expect(columns.items(from: 0, to: 200) == 0..<12)
        #expect(columns.items(from: 200, to: 300).isEmpty)
        #expect(columns.runs(from: 60, to: 70).map(\.group) == [0, 1])
        #expect(columns.headers(from: 60, to: 70).map(\.group) == [0, 1])
    }

    @Test func leftAndRightGoToTheItemNearestInHeightUpAndDownToTheNext() {
        let columns = Self.columns([10, 2])
        // Item 1 is at 35–45; in column 1 the nearest is item 8 (35–45).
        #expect(columns.neighbor(of: 1, byLine: true, forward: true) == 8)
        // Item 6 (85–95): its middle is at the top of the second group's 11 (90–100), under that group's title.
        #expect(columns.neighbor(of: 6, byLine: true, forward: true) == 11)
        // Item 4 (65–75): past the end of the run 7–9 (25–55) and above the next (80–100), the nearest is 10.
        #expect(columns.neighbor(of: 4, byLine: true, forward: true) == 10)
        // Item 0 (25–35) back from column 1's item 7 (25–35); nothing before the first column, after the last.
        #expect(columns.neighbor(of: 7, byLine: true, forward: false) == 0)
        #expect(columns.neighbor(of: 0, byLine: true, forward: false) == nil)
        #expect(columns.neighbor(of: 11, byLine: true, forward: true) == nil)
        // Down from a group's last item: the next group's first.
        #expect(columns.neighbor(of: 9, byLine: false, forward: true) == 10)
        #expect(columns.neighbor(of: 11, byLine: false, forward: true) == nil)
        #expect(columns.run(ofItem: 12) == nil)
    }
}
