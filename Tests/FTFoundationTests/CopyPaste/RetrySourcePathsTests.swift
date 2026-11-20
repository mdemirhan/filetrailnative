import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

@Suite struct RetrySourcePathsTests {
    private func item(_ sourcePath: String, _ status: ResultItem.Status = .failed) -> ResultItem {
        ResultItem(sourcePath: sourcePath, destinationPath: nil, status: status)
    }

    @Test func retriesFailedAndNeverStartedTopLevelItemsNeverNestedOnesOnTheirOwn() {
        let items = [
            item("/src/a.txt", .completed), item("/src/photos"), item("/src/photos/raw/b.dng"), item("/src/c.txt"),
            item("/src/d.txt", .cancelled),
        ]
        #expect(CopyPasteResultText.retrySourcePaths(items) == ["/src/photos", "/src/c.txt", "/src/d.txt"])
    }

    // What the result's Skipped section says of each kind of skip: Replace Older's three and Add Missing's, beside
    // the person's own.
    // A clash of kinds Replace Older left says so, and not that the person chose Skip.
    @Test func saysWhyEachSkippedItemWasLeft() {
        let items = [
            ResultItem(sourcePath: "/src/a.txt", destinationPath: "/dest/a.txt", status: .completed),
            ResultItem(
                sourcePath: "/src/b.txt", destinationPath: "/dest/b.txt", status: .skipped, skippedAsNotNewer: true),
            ResultItem(
                sourcePath: "/src/Work.sparsebundle", destinationPath: "/dest/Work.sparsebundle", status: .skipped,
                skippedAsPackageNotCompared: true),
            ResultItem(
                sourcePath: "/src/Notes", destinationPath: "/dest/Notes", status: .skipped,
                skippedAsDifferentKind: true),
            ResultItem(sourcePath: "/src/c.txt", destinationPath: "/dest/c.txt", status: .skipped),
            ResultItem(
                sourcePath: "/src/e.txt", destinationPath: "/dest/e.txt", status: .skipped, leftByAddMissing: true),
            ResultItem(
                sourcePath: "/src/d.txt", destinationPath: "/dest/d.txt", status: .skipped, skippedAfterChange: true),
        ]
        let text = CopyPasteResultText(action: .paste, targetPath: "/dest", error: nil, items: items, canRetry: true)
        #expect(text.message == "6 items were skipped.")
        #expect(text.sections.map(\.label) == ["Skipped"])
        #expect(
            text.sections.first?.rows.map(\.path) == ["b.txt", "Work.sparsebundle", "Notes", "c.txt", "e.txt", "d.txt"])
        #expect(
            text.sections.first?.rows.map(\.detail) == [
                "Already there, as new or newer \u{B7} Replace Older left it",
                "Already there, a package, not compared \u{B7} Replace Older left it",
                "Already there, a different kind of item \u{B7} Replace Older left it",
                "Already existed \u{B7} you chose Skip",
                "Already there \u{B7} Add Missing left it",
                "Skipped after it changed during the operation",
            ])
        #expect(text.retryLabel == nil)
    }

    // A paste the disk ended wasn't stopped by anyone: the items it never reached say the disk was full, in the
    // message and on their rows. Those a Stop left read as they did.
    @Test func saysTheDiskWasFullOfTheItemsAFullDiskLeft() {
        func text(notStarted reason: String?) -> CopyPasteResultText {
            let done = (1...7).map {
                ResultItem(sourcePath: "/src/\($0).txt", destinationPath: "/dest/\($0).txt", status: .completed)
            }
            let failed = ResultItem(
                sourcePath: "/src/8.txt", destinationPath: "/dest/8.txt", status: .failed,
                error: "There isn't enough free space on the destination disk.")
            let left = (9...20).map {
                ResultItem(
                    sourcePath: "/src/\($0).txt", destinationPath: "/dest/\($0).txt", status: .cancelled, error: reason)
            }
            return CopyPasteResultText(
                action: .copyTo, targetPath: "/dest", error: nil, items: done + [failed] + left, canRetry: true)
        }
        func rows(_ text: CopyPasteResultText) -> [String] {
            text.sections.first { $0.label == "Not started" }?.rows.map(\.detail) ?? []
        }

        let full = text(notStarted: "Not started because the destination disk is full.")
        #expect(full.title == "Copied 7 of 20 items into \u{201C}dest\u{201D}")
        #expect(full.message == "1 item couldn\u{2019}t be copied. 12 items weren't started because the disk is full.")
        #expect(rows(full) == Array(repeating: "Not started because the destination disk is full.", count: 12))
        #expect(full.retryLabel == "Retry 13 Items")

        for reason in ["Not started because the operation was stopped.", nil] {
            let stopped = text(notStarted: reason)
            #expect(
                stopped.message
                    == "1 item couldn\u{2019}t be copied. 12 items weren't started because the operation was stopped.")
            #expect(rows(stopped) == Array(repeating: "The operation was stopped first.", count: 12))
        }
    }

    @Test func doesNotConfuseASiblingWithASharedNamePrefixForAParent() {
        #expect(
            CopyPasteResultText.retrySourcePaths([item("/src/photo"), item("/src/photos/a.jpg")]) == [
                "/src/photo", "/src/photos/a.jpg",
            ])
    }

    @Test func staysFastForVeryLargeResults() {
        var items = [item("/src/big")]
        for index in 0..<30_000 { items.append(item("/src/big/dir-\(index % 100)/file-\(index).txt")) }
        let (paths, seconds) = CPUTime.measureThread { CopyPasteResultText.retrySourcePaths(items) }
        #expect(paths == ["/src/big"])
        // The old pairwise scan took seconds of CPU time at this size.
        #expect(seconds < 0.5, "took \(seconds) s of CPU time")
    }
}
