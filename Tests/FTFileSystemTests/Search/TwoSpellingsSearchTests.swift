import FTFoundation
import Foundation
import Testing

// Two folders whose names differ only in how an accent is spelled, which a disk can keep side by side: a search tells
// what it finds under one from what it finds under the other
@testable import FTFileSystem

private let root = "/x"
private let composed = "/x/caf\u{E9}"
private let decomposed = "/x/cafe\u{301}"

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

private func request(_ rootPath: String = root, hidden: Bool = false) -> SearchRequest {
    SearchRequest(
        rootPath: rootPath, query: "a", patternMode: .regex, matchScope: .name, recursive: true,
        includeHidden: hidden, skipGitFolders: false, skipGitIgnored: false)
}

@Suite struct TwoSpellingsSearchTests {
    /// A runtime whose stand-in fd writes what the test says; the folders of `flagged` have the flag that hides one.
    private func make(flagged: [String]) -> (FdSearchRuntime, MockSearchProcess) {
        let process = MockSearchProcess()
        let hidden = Set(flagged.map(DiskPath.init))
        let runtime = FdSearchRuntime(
            fdBinaryPath: "/tmp/fd", spawn: process.spawn, hasHiddenFlag: { hidden.contains(DiskPath($0)) },
            realPath: { $0 })
        return (runtime, process)
    }

    // A hidden folder hides what is in it, and not what is in the folder spelled the other way, whichever is found
    // first.
    @Test func aHiddenFolderHidesItsOwnItemsOnly() throws {
        for (hiddenFolder, shownFolder) in [(composed, decomposed), (decomposed, composed)] {
            let (runtime, process) = make(flagged: [hiddenFolder])
            let job = runtime.startSearch(request()).jobId
            process.write(
                [hiddenFolder + "/in/a.txt", shownFolder + "/in/a.txt", hiddenFolder + "/in/b.txt"]
                    .map { $0 + "\0" }.joined())
            process.close(code: 0)
            let found = try runtime.getUpdate(jobId: job, cursor: 0).items
            #expect(bytes(found.map(\.path)) == bytes([shownFolder + "/in/a.txt"]))
            #expect(bytes(found.map(\.parentPath)) == bytes([shownFolder + "/in"]))
        }
    }

    // What is found under each folder is a result of its own, with its own folder.
    @Test func aResultUnderEachFolderIsItsOwn() throws {
        let (runtime, process) = make(flagged: [])
        let job = runtime.startSearch(request()).jobId
        process.write([composed + "/a.txt", decomposed + "/a.txt"].map { $0 + "\0" }.joined())
        process.close(code: 0)
        let found = try runtime.getUpdate(jobId: job, cursor: 0).items
        #expect(bytes(found.map(\.path)) == bytes([composed + "/a.txt", decomposed + "/a.txt"]))
        #expect(bytes(found.map(\.relativeParentPath)) == bytes(["caf\u{E9}", "cafe\u{301}"]))
    }

    // A search started in one folder doesn't take the folder spelled the other way for its own: an item there is
    // outside what was asked, and the search's own folder isn't looked at for the flag.
    @Test func theSearchsFolderIsKnownByItsBytes() {
        var filter = FdSearchRuntime.HiddenFilter(rootPath: composed, realRootPath: nil) { _ in true }
        let inside = filter.isInHiddenFolder(composed + "/in/a.txt")
        let atTheTop = filter.isInHiddenFolder(composed + "/a.txt")
        let beside = filter.isInHiddenFolder(decomposed + "/in/a.txt")
        #expect(inside && !atTheTop && !beside)
    }

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
