import Foundation
import Testing

@testable import FTAppKit

@Suite struct FoldersLabelBoxTests {
    private let line = 13.0
    private let room = 428.0

    // A tree that fits leaves the box whole.
    @Test func aTreeThatFitsLeavesTheBoxWhole() {
        #expect(FoldersLabelBox.contentHeight(line: line, treeHeight: 400, room: room) == line)
        #expect(FoldersLabelBox.contentHeight(line: line, treeHeight: 415, room: room) == line)
    }

    // A tree that only just overflows takes 0.66 pt off the box.
    @Test func aTreeThatJustOverflowsTakesItsShareOffTheBox() {
        let content = FoldersLabelBox.contentHeight(line: line, treeHeight: 438, room: room)
        #expect(abs(content - 12.34) < 0.01)
    }

    // A very long tree leaves 0.7 pt.
    @Test func aVeryLongTreeLeavesAlmostNothing() {
        let content = FoldersLabelBox.contentHeight(line: line, treeHeight: 7936, room: room)
        #expect(abs(content - 0.7) < 0.01)
        #expect(FoldersLabelBox.contentHeight(line: line, treeHeight: 500, room: 0) == 0)
    }
}
