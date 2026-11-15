// Search results after a write: what it removed leaves them, what it renamed is renamed in them
import FTFoundation
import FTTestSupport
import Testing

@testable import FTFileSystem

private let root = "/r"

/// A result as fd gives it under `root`: a folder ends with a slash.
private func found(_ relative: String) -> SearchResultItem {
    SearchResults.item(rootPath: root, outputPath: root + "/" + relative)
}

private func rename(_ from: String, _ to: String) -> SearchResultRename {
    SearchResultRename(from: root + "/" + from, to: root + "/" + to)
}

private func paths(_ items: [SearchResultItem]?) -> [String]? {
    items?.map { String($0.path.dropFirst(root.count + 1)) }
}

@Suite struct SearchResultsAfterWriteTests {
    // MARK: Removed

    // An item removed leaves; so does everything found inside a removed folder, at any depth. A sibling whose name
    // only starts with the folder's stays.
    @Test func whatWasRemovedLeavesWithEverythingInsideIt() {
        let results = [
            found("a.txt"), found("Docs/"), found("Docs/b.txt"), found("Docs/Deep/"), found("Docs/Deep/c.txt"),
            found("Docs copy/"), found("Docsb.txt"), found("e.txt"),
        ]
        let after = SearchResults.afterWrite(
            results, rootPath: root, removed: [root + "/a.txt", root + "/Docs"], renamed: [])
        #expect(paths(after) == ["Docs copy", "Docsb.txt", "e.txt"])
    }

    // Removing an item inside a found folder leaves the folder.
    @Test func removingAnItemInsideAFolderLeavesTheFolder() {
        let results = [found("Docs/"), found("Docs/b.txt"), found("Docs/c.txt")]
        let after = SearchResults.afterWrite(results, rootPath: root, removed: [root + "/Docs/b.txt"], renamed: [])
        #expect(paths(after) == ["Docs", "Docs/c.txt"])
    }

    // Many items removed at once, the order of the rest kept.
    @Test func manyRemovedAtOnceKeepTheOrderOfTheRest() {
        let results = (0..<20).map { found("f\($0).txt") }
        let removed = stride(from: 0, to: 20, by: 2).map { root + "/f\($0).txt" }
        let after = SearchResults.afterWrite(results, rootPath: root, removed: removed, renamed: [])
        #expect(paths(after) == stride(from: 1, to: 20, by: 2).map { "f\($0).txt" })
    }

    // MARK: Renamed

    // A file renamed is the same result under its new name: its extension, hidden mark and folder as fd would give
    // them, its place in the list kept.
    @Test func aFileRenamedIsRenamedInPlace() throws {
        let results = [found("a.txt"), found("Docs/b.txt"), found("c.txt")]
        let after = try #require(
            SearchResults.afterWrite(
                results, rootPath: root, removed: [], renamed: [rename("Docs/b.txt", "Docs/.B.MD")]))
        #expect(paths(after) == ["a.txt", "Docs/.B.MD", "c.txt"])
        let renamed = after[1]
        #expect(renamed.name == ".B.MD")
        #expect(renamed.fileExtension == "md")
        #expect(renamed.isHidden)
        #expect(renamed.kind == .file)
        #expect(renamed.parentPath == root + "/Docs")
        #expect(renamed.relativeParentPath == "Docs")
        #expect(renamed == found("Docs/.B.MD"))
    }

    // A renamed result stays whatever its new name, though the search would no longer find it.
    @Test func aRenamedResultStaysThoughItNoLongerMatches() {
        let results = [found("invoice.pdf")]
        let after = SearchResults.afterWrite(
            results, rootPath: root, removed: [], renamed: [rename("invoice.pdf", "zzz")])
        #expect(paths(after) == ["zzz"])
        #expect(after?.first?.fileExtension == "")
    }

    // A folder renamed takes everything found inside it along, at any depth: their folders change, their names don't.
    @Test func aFolderRenamedTakesWhatIsInsideIt() throws {
        let results = [found("Docs/"), found("Docs/b.txt"), found("Docs/Deep/c.txt"), found("Docsb.txt")]
        let after = try #require(
            SearchResults.afterWrite(results, rootPath: root, removed: [], renamed: [rename("Docs", "Papers")]))
        #expect(paths(after) == ["Papers", "Papers/b.txt", "Papers/Deep/c.txt", "Docsb.txt"])
        #expect(after[0].kind == .directory)
        #expect(after[2].name == "c.txt")
        #expect(after[2].relativeParentPath == "Papers/Deep")
        #expect(after[2].parentPath == root + "/Papers/Deep")
    }

    // Results inside a renamed folder that isn't a result themselves are renamed too.
    @Test func itemsInsideARenamedFolderThatIsNoResultFollowIt() {
        let results = [found("Docs/b.txt")]
        let after = SearchResults.afterWrite(results, rootPath: root, removed: [], renamed: [rename("Docs", "Papers")])
        #expect(paths(after) == ["Papers/b.txt"])
    }

    // A folder renamed to a package's name is a package, as fd's results tell them; one renamed from it is a folder.
    @Test func aFolderRenamedToAPackagesNameIsAPackage() {
        let results = [found("Tool/"), found("Other.app/")]
        let after = SearchResults.afterWrite(
            results, rootPath: root, removed: [], renamed: [rename("Tool", "Tool.app"), rename("Other.app", "Other")])
        #expect(after?.map(\.kind) == [.bundle, .directory])
    }

    // A link stays a link, and a link to a folder stays one, under its new name.
    @Test func aLinkStaysALink() {
        var link = found("link")
        link.isSymlink = true
        link.kind = .symlinkDirectory
        let after = SearchResults.afterWrite([link], rootPath: root, removed: [], renamed: [rename("link", "other")])
        #expect(after?.first?.isSymlink == true)
        #expect(after?.first?.kind == .symlinkDirectory)
        #expect(after?.first?.name == "other")
    }

    // A folder and an item inside it renamed by one write end where both renames put them, whether the write gave the
    // inner item's new path under the folder's old name or its new one.
    @Test func aFolderAndAnItemInsideItRenamedTogether() {
        let results = [found("Docs/"), found("Docs/b.txt"), found("Docs/c.txt")]
        let underOld = SearchResults.afterWrite(
            results, rootPath: root, removed: [],
            renamed: [rename("Docs", "Papers"), rename("Docs/b.txt", "Docs/B.txt")])
        #expect(paths(underOld) == ["Papers", "Papers/B.txt", "Papers/c.txt"])
        let underNew = SearchResults.afterWrite(
            results, rootPath: root, removed: [],
            renamed: [rename("Docs/b.txt", "Papers/B.txt"), rename("Docs", "Papers")])
        #expect(paths(underNew) == ["Papers", "Papers/B.txt", "Papers/c.txt"])
    }

    // Two items swapping names in one write each end under the other's name.
    @Test func twoItemsSwappingNames() {
        let results = [found("a.txt"), found("b.txt")]
        let after = SearchResults.afterWrite(
            results, rootPath: root, removed: [], renamed: [rename("a.txt", "b.txt"), rename("b.txt", "a.txt")])
        #expect(paths(after) == ["b.txt", "a.txt"])
    }

    // Removed and renamed in one write.
    @Test func removedAndRenamedInOneWrite() {
        let results = [found("a.txt"), found("b.txt"), found("c.txt")]
        let after = SearchResults.afterWrite(
            results, rootPath: root, removed: [root + "/a.txt"], renamed: [rename("c.txt", "d.txt")])
        #expect(paths(after) == ["b.txt", "d.txt"])
    }

    // MARK: Nothing changed

    // A write that touched no result changes nothing.
    @Test func nothingTouchedIsNil() {
        let results = [found("a.txt"), found("Docs/")]
        #expect(SearchResults.afterWrite(results, rootPath: root, removed: [], renamed: []) == nil)
        #expect(
            SearchResults.afterWrite(
                results, rootPath: root, removed: [root + "/elsewhere.txt", root + "/Doc"],
                renamed: [rename("Do", "Re"), rename("a.tx", "z")]) == nil)
        #expect(SearchResults.afterWrite([], rootPath: root, removed: [root + "/a.txt"], renamed: []) == nil)
    }

    // Paths are compared byte for byte: a name spelled with a decomposed accent is not the same as one composed.
    @Test func pathsAreComparedByteForByte() {
        let composed = "caf\u{e9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let results = [found(composed)]
        let other = SearchResults.afterWrite(results, rootPath: root, removed: [root + "/" + decomposed], renamed: [])
        #expect(other == nil)
        let same = SearchResults.afterWrite(results, rootPath: root, removed: [root + "/" + composed], renamed: [])
        #expect(paths(same) == [])
    }

    // MARK: Paths

    @Test func whereAPathIsAfterRenames() {
        let renames = [rename("Docs", "Papers"), rename("a.txt", "b.txt")]
        #expect(SearchResults.path(root + "/Docs", after: renames) == root + "/Papers")
        #expect(SearchResults.path(root + "/Docs/x/y", after: renames) == root + "/Papers/x/y")
        #expect(SearchResults.path(root + "/a.txt", after: renames) == root + "/b.txt")
        #expect(SearchResults.path(root + "/Docsx", after: renames) == nil)
        #expect(SearchResults.path(root + "/c.txt", after: renames) == nil)
        #expect(SearchResults.path(root + "/c.txt", after: []) == nil)
    }

    // 5,000 results renamed at once are placed in a moment: each path is looked up by the folders above it, so the
    // cost doesn't grow with the renames times the results. Sorting the renames for every result took 34 s here.
    @Test func manyRenamesOfManyResultsArePlacedAtOnce() {
        let count = 5_000
        let results = (0..<count).map { found("Folder \($0 % 50)/old \($0).txt") }
        let renamed = (0..<count).map { rename("Folder \($0 % 50)/old \($0).txt", "Folder \($0 % 50)/new \($0).txt") }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (after, seconds) = CPUTime.measureThread {
            SearchResults.afterWrite(results, rootPath: root, removed: [], renamed: renamed)
        }
        #expect(after?.count == count)
        #expect(after?.last?.name == "new \(count - 1).txt")
        #expect(seconds < 1)
    }

    @Test func atOrInsideAFolder() {
        #expect(SearchResults.isAtOrInside("/r", "/r"))
        #expect(SearchResults.isAtOrInside("/r/a", "/r"))
        #expect(SearchResults.isAtOrInside("/r/a", "/r/"))
        #expect(SearchResults.isAtOrInside("/r/a", "/"))
        #expect(!SearchResults.isAtOrInside("/rr/a", "/r"))
        #expect(!SearchResults.isAtOrInside("/r", "/r/a"))
        let folders = Set(["/r/Docs", "/x"].map(FTFoundation.NameKeys.Exact.init))
        #expect(SearchResults.isAtOrInsideAny("/r/Docs", folders))
        #expect(SearchResults.isAtOrInsideAny("/r/Docs/a/b", folders))
        #expect(!SearchResults.isAtOrInsideAny("/r/Docsa", folders))
        #expect(!SearchResults.isAtOrInsideAny("/r", folders))
        #expect(!SearchResults.isAtOrInsideAny("/r/Docs", []))
    }
}
