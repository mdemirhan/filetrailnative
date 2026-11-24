import FTFoundation
import Foundation
import Testing

// Two folders whose names differ only in how an accent is spelled, which a disk can keep side by side: a search's
// results tell what is under one from what is under the other
@testable import FTFileSystem

private let root = "/x"
private let composed = "/x/caf\u{E9}"
private let decomposed = "/x/cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

@Suite struct TwoSpellingsSearchTests {
    // A result's folder as seen from where the search started: the folder itself is ".", the one beside it spelled
    // the other way is another folder.
    @Test func theFolderBesideTheSearchsOwnIsAnotherFolder() {
        #expect(SearchResults.relative(from: composed, to: composed) == "")
        #expect(DiskPath(SearchResults.relative(from: composed, to: decomposed)) == DiskPath("../cafe\u{301}"))
        let item = SearchResults.item(rootPath: composed, outputPath: decomposed + "/a.txt")
        #expect(DiskPath(item.relativeParentPath) == DiskPath("../cafe\u{301}"))
    }

    // After a write, what was removed or renamed in one folder leaves the results of the other as they are.
    @Test func aWriteInOneFolderLeavesTheOthersResults() throws {
        let results = [composed + "/a.txt", decomposed + "/a.txt"].map {
            SearchResults.item(rootPath: root, outputPath: $0)
        }
        let removed = try #require(
            SearchResults.afterWrite(results, rootPath: root, removed: [composed], renamed: []))
        #expect(bytes(removed.map(\.path)) == bytes([decomposed + "/a.txt"]))
        let renamed = try #require(
            SearchResults.afterWrite(
                results, rootPath: root, removed: [],
                renamed: [SearchResultRename(from: decomposed, to: "/x/tea")]))
        #expect(bytes(renamed.map(\.path)) == bytes([composed + "/a.txt", "/x/tea/a.txt"]))
        #expect(SearchResults.isAtOrInsideAny(composed + "/a.txt", [DiskPath(composed)]))
        #expect(!SearchResults.isAtOrInsideAny(decomposed + "/a.txt", [DiskPath(composed)]))
    }
}
