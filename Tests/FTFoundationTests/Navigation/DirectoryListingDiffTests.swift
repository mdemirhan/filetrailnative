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

    // Two items whose names differ only in how an accent is spelled, which a disk can keep side by side, are two
    // items: one is not kept as the other, and each is compared with itself.
    @Test func twoSpellingsOfANameAreToldApart() {
        let composed = Item(path: "/a/caf\u{E9}", name: "caf\u{E9}")
        let decomposed = Item(path: "/a/cafe\u{301}", name: "cafe\u{301}")
        #expect(composed == decomposed)
        func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

        // The item was renamed to its other spelling: the listing changed, and the row is drawn again.
        let renamed = DirectoryListingDiff.keepUnchanged(shown: [composed], next: [decomposed], path: \.path)
        #expect(!renamed.isUnchanged)
        #expect(renamed.keptPaths.isEmpty)
        #expect(bytes(renamed.changedPaths) == bytes([decomposed.path]))

        // Both are there, and one changed: that one is drawn again, the other kept.
        var larger = decomposed
        larger.sizeBytes = 7
        let one = DirectoryListingDiff.keepUnchanged(
            shown: [composed, decomposed], next: [composed, larger], path: \.path)
        #expect(!one.isUnchanged)
        #expect(one.keptPaths == [DiskPath(composed.path)])
        #expect(bytes(one.changedPaths) == bytes([decomposed.path]))

        // Both as they were, in the same order: nothing changed, and both are kept.
        let same = DirectoryListingDiff.keepUnchanged(
            shown: [composed, decomposed], next: [composed, decomposed], path: \.path)
        #expect(same.isUnchanged)
        #expect(same.keptPaths == [DiskPath(composed.path), DiskPath(decomposed.path)])
    }
}
