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
