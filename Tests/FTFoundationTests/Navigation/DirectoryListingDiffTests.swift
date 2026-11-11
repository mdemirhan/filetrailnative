import Testing

@testable import FTFoundation

struct DirectoryListingDiffTests {
    private struct Item: Equatable {
        var path: String
        var name: String
        var isHidden = false
        var sizeBytes: Int?
    }

    private func item(_ path: String, hidden: Bool = false) -> Item {
        Item(path: path, name: String(path.split(separator: "/").last ?? ""), isHidden: hidden)
    }

    @Test func keepsTheItemsOfAFolderReadAgainThatAreStillAsTheyWere() {
        let one = item("/a/one.txt")
        let two = item("/a/two.txt")
        let shown = [one, two]

        // Nothing changed: the listing on screen stays as it is.
        let same = DirectoryListingDiff.keepUnchanged(shown: shown, next: shown.map { $0 }, path: \.path)
        #expect(same.isUnchanged && same.entries == shown && same.changedPaths.isEmpty)

        // One item changed, one came: the one that didn't change is the one on screen.
        let changedTwo = item("/a/two.txt", hidden: true)
        let three = item("/a/three.txt")
        let next = DirectoryListingDiff.keepUnchanged(shown: shown, next: [one, changedTwo, three], path: \.path)
        #expect(!next.isUnchanged)
        #expect(next.entries == [one, changedTwo, three])
        #expect(next.keptPaths == ["/a/one.txt"])
        #expect(next.changedPaths == ["/a/two.txt", "/a/three.txt"])

        // The new order is kept, with the same items.
        let reordered = DirectoryListingDiff.keepUnchanged(shown: shown, next: [two, one], path: \.path)
        #expect(reordered.entries == [two, one])
        #expect(reordered.keptPaths == ["/a/one.txt", "/a/two.txt"] && reordered.changedPaths.isEmpty)
    }

    private final class Details {
        let size: Int
        init(size: Int) { self.size = size }
    }
}
