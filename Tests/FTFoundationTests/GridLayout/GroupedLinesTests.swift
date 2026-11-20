import Foundation
import Testing

@testable import FTFoundation

struct GroupedLinesTests {
    // Three groups of 5, 0 (collapsed) and 3 items, 3 to a line: header 28, lines 100, a gap of 4, from 10.
    static let lines = GroupedLines(
        counts: [5, 0, 3], perLine: 3, lineExtent: 100, headerExtent: 28, groupGap: 4, start: 10)

    @Test func eachGroupStartsOnALineOfItsOwnAfterItsHeader() {
        let groups = Self.lines.groups
        let first: Double = 10
        let second: Double = first + 28 + 200 + 4
        let third: Double = second + 28 + 4
        #expect(groups.map(\.headerStart) == [first, second, third])
        #expect(groups.map(\.lineCount) == [2, 0, 1])
        #expect(groups.map(\.firstLine) == [0, 2, 2])
        let end: Double = third + 28 + 100 + 4
        #expect(Self.lines.end == end)
        #expect(Self.lines.place(ofItem: 4)?.line == 1 && Self.lines.place(ofItem: 4)?.slot == 1)
        #expect(Self.lines.place(ofItem: 5)?.line == 2 && Self.lines.place(ofItem: 5)?.slot == 0)
        #expect(Self.lines.place(ofItem: 5)?.lineStart == groups[2].linesStart)
        #expect(Self.lines.group(ofItem: 5) == 2)
        #expect(Self.lines.group(ofItem: 8) == nil)
    }

    @Test func theItemsOfAStretchAreThoseOfTheLinesItMeets() {
        let third = Self.lines.groups[2].linesStart
        #expect(Self.lines.items(from: 0, to: 40) == 0..<3)
        #expect(Self.lines.items(from: 150, to: third + 1) == 3..<8)
        // A stretch over the headers alone holds no item.
        #expect(Self.lines.items(from: 250, to: 270).isEmpty)
        #expect(Self.lines.groups(from: 250, to: 270) == [1])
    }

    @Test func arrowsCrossFromOneGroupToTheNext() {
        // Down from the first line's second item: the second line's; from there, the next group's first line.
        #expect(Self.lines.neighbor(of: 1, byLine: true, forward: true) == 4)
        #expect(Self.lines.neighbor(of: 4, byLine: true, forward: true) == 6)
        // A slot past a shorter line's end goes to its last item.
        #expect(Self.lines.neighbor(of: 2, byLine: true, forward: true) == 4)
        #expect(Self.lines.neighbor(of: 7, byLine: true, forward: false) == 4)
        #expect(Self.lines.neighbor(of: 0, byLine: true, forward: false) == nil)
        #expect(Self.lines.neighbor(of: 7, byLine: true, forward: true) == nil)
        // Across the lines, one item at a time, over the groups.
        #expect(Self.lines.neighbor(of: 4, byLine: false, forward: true) == 5)
        #expect(Self.lines.neighbor(of: 0, byLine: false, forward: false) == nil)
    }
}
