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

    // What the result's Skipped section says of each kind of skip: Replace Older's two, beside the person's own.
    @Test func saysWhyEachSkippedItemWasLeft() {
        let items = [
            ResultItem(sourcePath: "/src/a.txt", destinationPath: "/dest/a.txt", status: .completed),
            ResultItem(
                sourcePath: "/src/b.txt", destinationPath: "/dest/b.txt", status: .skipped, skippedAsNotNewer: true),
            ResultItem(
                sourcePath: "/src/Work.sparsebundle", destinationPath: "/dest/Work.sparsebundle", status: .skipped,
                skippedAsPackageNotCompared: true),
            ResultItem(sourcePath: "/src/c.txt", destinationPath: "/dest/c.txt", status: .skipped),
            ResultItem(
                sourcePath: "/src/d.txt", destinationPath: "/dest/d.txt", status: .skipped, skippedAfterChange: true),
        ]
        let text = CopyPasteResultText(action: .paste, targetPath: "/dest", error: nil, items: items, canRetry: true)
        #expect(text.message == "4 items were skipped.")
        #expect(text.sections.map(\.label) == ["Skipped"])
        #expect(
            text.sections.first?.rows.map(\.path) == ["b.txt", "Work.sparsebundle", "c.txt", "d.txt"])
        #expect(
            text.sections.first?.rows.map(\.detail) == [
                "Already there, as new or newer \u{B7} Replace Older left it",
                "Already there, a package, not compared \u{B7} Replace Older left it",
                "Already existed \u{B7} you chose Skip",
                "Skipped after it changed during the operation",
            ])
        #expect(text.retryLabel == nil)
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
