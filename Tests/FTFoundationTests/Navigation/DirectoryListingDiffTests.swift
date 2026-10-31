// Ports the folder-gone and listing-comparison cases of apps/desktop/src/renderer/lib/explorerNavigation.test.ts
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

    // T-4dd670bb
    // T-40e2d626
    @Test func tellsAFolderThatIsGoneFromOneThatCantBeRead() {
        let gone = DirectoryListingDiff.isFolderGone(message:)
        #expect(gone("ENOENT: no such file or directory, stat '/Users/demo/Old'"))
        #expect(gone("ENOTDIR: not a directory, stat '/Users/demo/a.txt/b'"))
        // Replaced by a file of the same name.
        #expect(gone("Path is not a directory: /Users/demo/Old"))
        #expect(!gone("EPERM: operation not permitted, scandir '/Users/demo/.Trash'"))
        #expect(!gone("EACCES: permission denied, scandir '/Users/demo/Locked'"))
    }

    // T-ab3e5d2f
    @Test func looksForWhyAFolderCouldntBeReadInTheReasonNotInItsPath() {
        for path in [
            "/Users/demo/ENOENT", "/Users/demo/ENOTDIR logs", "/Users/demo/no such file or directory",
            "/Users/demo/Not a Directory",
        ] {
            #expect(!DirectoryListingDiff.isFolderGone(message: "EACCES: permission denied, scandir '\(path)'"))
            #expect(!DirectoryListingDiff.isFolderGone(message: "EPERM: operation not permitted, scandir '\(path)'"))
            #expect(DirectoryListingDiff.isFolderGone(message: "ENOENT: no such file or directory, stat '\(path)'"))
        }
    }

    // T-444bcc56
    // B-NAV-133
    @Test func tellsWhetherAFolderReadAgainListsTheSameItemsTheSameWay() {
        let file = item("/a/one.txt")
        let listing = [file, item("/a/B")]
        #expect(DirectoryListingDiff.sameEntries(listing, listing.map { $0 }))
        #expect(!DirectoryListingDiff.sameEntries(listing, listing.reversed()))
        #expect(!DirectoryListingDiff.sameEntries(listing, [file]))
        #expect(!DirectoryListingDiff.sameEntries([file], [item("/a/one.txt", hidden: true)]))
        // A detail only one of them has (a size, when sorted by size).
        var sized = file
        sized.sizeBytes = 5
        #expect(!DirectoryListingDiff.sameEntries([file], [sized]))
    }

    // T-28f2d6e2
    // B-NAV-133 B-VIEW-191 T-06b7c994 T-998b0525
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

    // T-4b092cae
    @Test func tellsWhetherTwoSetsOfItemDetailsAreTheVerySame() {
        let details = Details(size: 5)
        #expect(DirectoryListingDiff.sameDetailsByPath(["/a/one.txt": details], ["/a/one.txt": details]))
        // Read again: the same values, but not the details on screen.
        #expect(!DirectoryListingDiff.sameDetailsByPath(["/a/one.txt": details], ["/a/one.txt": Details(size: 5)]))
        #expect(!DirectoryListingDiff.sameDetailsByPath(["/a/one.txt": details], [:]))
        #expect(!DirectoryListingDiff.sameDetailsByPath(["/a/one.txt": details], ["/a/two.txt": details]))
    }
}
