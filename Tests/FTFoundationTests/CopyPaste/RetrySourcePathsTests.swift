// Port of the collectRetrySourcePaths cases of apps/desktop/src/renderer/lib/explorerAppUtils.test.ts
import Foundation
import Testing

@testable import FTFoundation

@Suite struct RetrySourcePathsTests {
    private func item(_ sourcePath: String, _ status: ResultItem.Status = .failed) -> ResultItem {
        ResultItem(sourcePath: sourcePath, destinationPath: nil, status: status)
    }

    // T-b8383134
    @Test func retriesFailedAndNeverStartedTopLevelItemsNeverNestedOnesOnTheirOwn() {
        let items = [
            item("/src/a.txt", .completed), item("/src/photos"), item("/src/photos/raw/b.dng"), item("/src/c.txt"),
            item("/src/d.txt", .cancelled),
        ]
        #expect(CopyPasteResultText.retrySourcePaths(items) == ["/src/photos", "/src/c.txt", "/src/d.txt"])
    }

    // T-729a0e9e
    @Test func doesNotConfuseASiblingWithASharedNamePrefixForAParent() {
        #expect(
            CopyPasteResultText.retrySourcePaths([item("/src/photo"), item("/src/photos/a.jpg")]) == [
                "/src/photo", "/src/photos/a.jpg",
            ])
    }

    // T-a4d18383
    @Test func staysFastForVeryLargeResults() {
        var items = [item("/src/big")]
        for index in 0..<30_000 { items.append(item("/src/big/dir-\(index % 100)/file-\(index).txt")) }
        let started = Date()
        #expect(CopyPasteResultText.retrySourcePaths(items) == ["/src/big"])
        // The old pairwise scan took seconds at this size.
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
