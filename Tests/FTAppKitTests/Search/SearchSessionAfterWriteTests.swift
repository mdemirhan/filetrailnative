// A search session after a write that acted on its results: changed in place, never searched again, and saying when
// it may be missing something
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SearchSessionAfterWriteTests {
    let engine = FakeSearchEngine()
    let host = FakeSearchHost()
    let timers = ManualTimers()

    /// A session that searched "/demo" for "no" and found `names`.
    private func searched(_ names: [String], running: Bool = false) -> SearchSession {
        engine.finds = { _ in (names, running, false) }
        let session = SearchSession(preferences: .defaults(), includeHidden: false, engine: engine, timers: timers)
        session.host = host
        session.submit("no")
        return session
    }

    private func write(
        _ action: WriteOperationAction, _ moves: [(String?, String?)], target: String? = nil
    ) -> SearchAfterWrite {
        let started = Date(timeIntervalSince1970: 0)
        let items = moves.map { WriteOperationItem(sourcePath: $0.0, destinationPath: $0.1, status: .completed) }
        return SearchAfterWrite(
            WriteOperationResult(
                operationId: "op", action: action, status: .completed, targetPath: target, startedAt: started,
                finishedAt: started,
                summary: CopyPasteOperationSummary(
                    topLevelItemCount: items.count, totalItemCount: items.count, completedItemCount: items.count,
                    failedItemCount: 0, skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0,
                    totalBytes: nil),
                items: items, error: nil),
            homePath: "/Users/demo")
    }

    private func names(_ session: SearchSession) -> [String] { session.shownResults.map(\.name).sorted() }

    // Trashed results leave the list at once, nothing is searched, and nothing says the list may be missing anything.
    @Test func trashedResultsLeaveWithoutASearch() {
        let session = searched(["note.txt", "notes/", "notes/a.txt", "nobody.md"])
        let searches = engine.starts.count
        session.applyWrite(write(.trash, [("/demo/notes", "/Users/demo/.Trash/notes")]))
        #expect(names(session) == ["nobody.md", "note.txt"])
        #expect(engine.starts.count == searches)
        #expect(!session.mayBeMissingItems)
        #expect(host.changes.last == .results)
    }

    // A renamed result keeps its place under its new name, though it no longer matches; nothing is searched.
    @Test func aRenamedResultIsRenamedInPlace() {
        let session = searched(["note.txt", "nobody.md"])
        let searches = engine.starts.count
        session.applyWrite(write(.rename, [("/demo/note.txt", "/demo/zzz.txt")]))
        #expect(names(session) == ["nobody.md", "zzz.txt"])
        #expect(session.results.map(\.path).contains("/demo/zzz.txt"))
        #expect(engine.starts.count == searches)
        #expect(!session.mayBeMissingItems)
    }

    // Results put away (Done) change too, and their selection follows what was renamed and lets go of what left.
    @Test func resultsPutAwayChangeTooAndTheirSelectionFollows() {
        let session = searched(["note.txt", "nobody.md", "notes/"])
        session.noteSelection(
            ContentSelection(
                paths: ["/demo/note.txt", "/demo/nobody.md"], anchorPath: "/demo/note.txt", leadPath: "/demo/note.txt"))
        session.hideResults()
        #expect(!session.isSearchMode)
        session.applyWrite(write(.rename, [("/demo/note.txt", "/demo/renamed.txt")]))
        #expect(session.cachedSearchSelection.paths == ["/demo/renamed.txt", "/demo/nobody.md"])
        #expect(session.cachedSearchSelection.leadPath == "/demo/renamed.txt")
        #expect(session.cachedSearchSelection.anchorPath == "/demo/renamed.txt")
        session.applyWrite(write(.trash, [("/demo/nobody.md", "/Users/demo/.Trash/nobody.md")]))
        #expect(names(session) == ["notes", "renamed.txt"])
        session.showCachedResults()
        #expect(host.applied.last?.paths == ["/demo/renamed.txt"])
    }

    // Something put inside the folder searched isn't added: the results say they may be missing it.
    @Test func whatArrivesInsideIsNotAddedButTold() {
        let session = searched(["notes/", "nobody.md"])
        let searches = engine.starts.count
        session.applyWrite(write(.copyTo, [("/elsewhere/new.txt", "/demo/notes/new.txt")], target: "/demo/notes"))
        #expect(names(session) == ["nobody.md", "notes"])
        #expect(session.mayBeMissingItems)
        #expect(engine.starts.count == searches)
        #expect(host.changes.last == .status)
    }

    // A result moved into a folder found leaves where it was, and the results say they may be missing it.
    @Test func aResultMovedIntoAFolderFoundLeavesAndIsTold() {
        let session = searched(["note.txt", "notes/"])
        session.applyWrite(write(.moveTo, [("/demo/note.txt", "/demo/notes/note.txt")], target: "/demo/notes"))
        #expect(names(session) == ["notes"])
        #expect(session.mayBeMissingItems)
        #expect(host.changes.last == [.results, .status])
    }

    // What arrives outside the folder searched, or in the Trash, says nothing.
    @Test func whatArrivesOutsideSaysNothing() {
        let session = searched(["note.txt", "nobody.md"])
        session.applyWrite(write(.moveTo, [("/demo/note.txt", "/elsewhere/note.txt")], target: "/elsewhere"))
        #expect(names(session) == ["nobody.md"])
        #expect(!session.mayBeMissingItems)
        session.applyWrite(write(.copyTo, [("/demo/nobody.md", "/elsewhere/nobody.md")], target: "/elsewhere"))
        #expect(names(session) == ["nobody.md"])
        #expect(!session.mayBeMissingItems)
    }

    // A search still running when a write changes its results may yet give what the write changed: it says so.
    @Test func aRunningSearchThatAWriteChangedSaysItMayBeMissingItems() {
        let session = searched(["note.txt", "nobody.md"], running: true)
        #expect(session.isRunning)
        session.applyWrite(write(.trash, [("/demo/note.txt", "/Users/demo/.Trash/note.txt")]))
        #expect(names(session) == ["nobody.md"])
        #expect(session.mayBeMissingItems)
    }

    // Searching again, another scope, a new search or clearing it lets go of what was told; the search runs only
    // when asked.
    @Test func searchingAgainLetsGoOfIt() {
        let session = searched(["notes/"])
        let tell = write(.copyTo, [("/x/new.txt", "/demo/notes/new.txt")], target: "/demo/notes")
        session.applyWrite(tell)
        #expect(session.mayBeMissingItems)
        let searches = engine.starts.count
        session.rerun()
        #expect(engine.starts.count == searches + 1)
        #expect(!session.mayBeMissingItems)

        session.applyWrite(tell)
        session.changeRoot("/")
        #expect(!session.mayBeMissingItems)

        engine.finds = { _ in (["notes/"], false, false) }
        session.changeRoot("/demo")
        session.applyWrite(tell)
        session.submit("other")
        #expect(!session.mayBeMissingItems)

        session.applyWrite(write(.copyTo, [("/x/new.txt", "/demo/new.txt")], target: "/demo"))
        session.updateDraft("")
        #expect(!session.hasCachedSearch)
        #expect(!session.mayBeMissingItems)
    }

    // Put away and shown again, the results still say they may be missing something.
    @Test func itIsStillToldWhenTheResultsComeBack() {
        let session = searched(["notes/"])
        session.applyWrite(write(.copyTo, [("/x/new.txt", "/demo/notes/new.txt")], target: "/demo/notes"))
        session.hideResults()
        session.showCachedResults()
        #expect(session.isSearchMode)
        #expect(session.mayBeMissingItems)
    }

    // With no search, a write does nothing.
    @Test func noSearchNothingChanges() {
        let session = SearchSession(preferences: .defaults(), includeHidden: false, engine: engine, timers: timers)
        session.host = host
        session.applyWrite(write(.trash, [("/demo/note.txt", "/Users/demo/.Trash/note.txt")]))
        #expect(host.changes.isEmpty)
        #expect(!session.mayBeMissingItems)
    }

    // The selection on screen follows what was renamed, a folder's items too.
    @Test func aSelectionFollowsRenames() {
        let selection = ContentSelection(
            paths: ["/demo/Docs/a.txt", "/demo/b.txt", "/demo/c.txt"], anchorPath: "/demo/b.txt",
            leadPath: "/demo/Docs/a.txt")
        let next = SearchSession.selection(
            selection,
            after: [
                SearchResultRename(from: "/demo/Docs", to: "/demo/Papers"),
                SearchResultRename(from: "/demo/b.txt", to: "/demo/B.txt"),
            ])
        #expect(next.paths == ["/demo/Papers/a.txt", "/demo/B.txt", "/demo/c.txt"])
        #expect(next.anchorPath == "/demo/B.txt")
        #expect(next.leadPath == "/demo/Papers/a.txt")
        #expect(SearchSession.selection(selection, after: []) == selection)
    }
}
