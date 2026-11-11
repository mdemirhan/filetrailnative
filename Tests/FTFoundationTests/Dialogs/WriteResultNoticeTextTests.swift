// The reasons a finished operation's alert lists: the first three different ones, found without reading every item
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

@Suite struct WriteResultNoticeTextTests {
    private func failed(_ errors: [String?]) -> WriteResultNoticeInput {
        WriteResultNoticeInput(
            error: nil, totalItemCount: errors.count, completedItemCount: 0, failedItemCount: errors.count,
            skippedItemCount: 0, cancelledItemCount: 0, itemErrors: errors)
    }

    @Test func listsTheFirstThreeDifferentReasonsOnce() {
        let lines = WriteResultNoticeText.detailLines(failed(["A", nil, "A", "", "B", "A", "C", "D"]))
        #expect(lines == ["0 of 8 items done", "8 items failed", "A", "B", "C"])
    }

    @Test func manyDifferentReasonsAreQuick() {
        let errors: [String?] = (0..<20_000).map { "Couldn\u{2019}t copy \u{201C}file \($0).txt\u{201D}" }
        let (lines, seconds) = CPUTime.measureThread { WriteResultNoticeText.detailLines(failed(errors)) }
        #expect(lines.suffix(3) == errors.prefix(3).compactMap { $0 })
        // Comparing each reason with every one kept took over 2 s of CPU time at this size.
        #expect(seconds < 0.1, "took \(seconds) s of CPU time")
    }
}
