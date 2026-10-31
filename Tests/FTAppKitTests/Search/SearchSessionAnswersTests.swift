// Ports by behavior row what App.search.test.tsx and useExplorerSearchController.ts say of a search's answers over one
// session: results that come late or twice, searches that fail, and what each new search does to the selection
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// A runtime whose start or whose answers fail.
@MainActor
private final class FailingSearchEngine: SearchEngine {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "fd is gone" }
    }

    var startFails = false
    var updateFails = false
    private(set) var updates = 0

    func start(_ request: SearchRequest) throws -> String {
        if startFails { throw Failure() }
        return "search-1"
    }

    func update(jobID: String, cursor: Int) throws -> TabSearchUpdate {
        updates += 1
        if updateFails { throw Failure() }
        return TabSearchUpdate(
            jobID: jobID, status: .running, items: [], nextCursor: cursor, done: false, truncated: false, error: nil)
    }

    func cancel(jobID: String) {}
}

@MainActor
@Suite struct SearchSessionAnswersTests {
    let engine = FakeSearchEngine()
    let host = FakeSearchHost()
    let timers = ManualTimers()

    private func session(_ engine: (any SearchEngine)? = nil) -> SearchSession {
        let made = SearchSession(
            preferences: .defaults(), includeHidden: false, engine: engine ?? self.engine, timers: timers, clock: { 0 })
        made.host = host
        return made
    }

    private func names(_ session: SearchSession) -> [String] { session.shownResults.map(\.name) }

    // B-SRCH-021: narrowing changes only the committed text; what was selected in the results goes, and the walk, its
    // base text and its results stay.
    @Test func refiningEmptiesTheSelectionAndLeavesTheWalkAlone() {
        engine.finds = { _ in (["source.txt", "sonar.txt"], true, false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        let found = search.results
        let job = search.jobID
        search.noteSelection(.single("/demo/sonar.txt"))
        let applied = host.applied.count
        search.updateDraft("sou")
        #expect(search.committedQuery == "sou")
        #expect(search.baseQuery == "so")
        #expect(search.results == found)
        #expect(search.jobID == job)
        #expect(engine.starts.count == 1)
        #expect(host.applied.count == applied + 1)
        #expect(host.applied.last == .empty)
        #expect(search.cachedSearchSelection == .empty)
    }

    // B-SRCH-150: a new search, an option, a scope and a run again each empty the results' selection, which doesn't
    // come back with them.
    @Test func everyNewSearchEmptiesTheSelection() {
        engine.finds = { _ in (["source.txt"], false, false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        let steps: [(String, () -> Void)] = [
            ("new text", { search.submit("xy") }),
            ("option", { search.setPatternMode(.glob) }),
            ("scope", { search.changeRoot("/Users/demo") }),
            ("run again", { search.rerun() }),
        ]
        for (name, step) in steps {
            search.noteSelection(.single("/demo/source.txt"))
            let applied = host.applied.count
            step()
            #expect(host.applied.count == applied + 1, "\(name)")
            #expect(host.applied.last == .empty, "\(name)")
            #expect(search.cachedSearchSelection == .empty, "\(name)")
        }
    }

    // B-SRCH-034: a result kept from before that the new walk finds again is listed once.
    @Test func aKeptResultFoundAgainIsListedOnce() {
        engine.finds = { request in
            request.query == "so"
                ? (["source.txt", "sonar.txt"], false, true) : (["source.txt", "soup.md"], false, false)
        }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        search.updateDraft("sou")
        timers.advance(0.4)
        #expect(engine.starts.count == 2)
        #expect(names(search).sorted() == ["soup.md", "source.txt"])
    }

    // B-SRCH-130: a search that can't start ends in an error with its message.
    @Test func aSearchThatCantStartEndsInAnError() {
        let failing = FailingSearchEngine()
        failing.startFails = true
        let search = session(failing)
        search.submit("so")
        #expect(search.status == .error)
        #expect(search.error == "fd is gone")
        #expect(search.jobID == nil)
        timers.advance(1)
        #expect(failing.updates == 0)
    }

    // B-SRCH-130: so does one whose answer fails, and it isn't asked again.
    @Test func aSearchWhoseAnswerFailsEndsInAnError() {
        let failing = FailingSearchEngine()
        let search = session(failing)
        search.submit("so")
        #expect(search.status == .running)
        timers.advance(0.12)
        let asked = failing.updates
        #expect(asked >= 2)
        failing.updateFails = true
        timers.advance(0.12)
        #expect(failing.updates == asked + 1)
        #expect(search.status == .error)
        #expect(search.error == "fd is gone")
        #expect(search.jobID == nil)
        timers.advance(1)
        #expect(failing.updates == asked + 1)
    }

    // B-SRCH-131 B-SRCH-134: starting a search cancels the one still walking, and what that one finds
    // afterwards reaches nothing: not asked about, not shown.
    @Test func aRunningSearchIsLetGoWhenAnotherStarts() {
        engine.finds = { _ in ([], true, false) }
        let search = session()
        search.updateDraft("so")
        timers.advance(0.4)
        let first = engine.lastJobID
        search.updateDraft("xy")
        timers.advance(0.4)
        let second = engine.lastJobID
        #expect(first != second)
        #expect(engine.cancels == [first])
        #expect(search.jobID == second)

        let asked = engine.updates.filter { $0.jobID == first }.count
        engine.progress(first, add: ["late.txt"], finish: true)
        timers.advance(0.12)
        #expect(engine.updates.filter { $0.jobID == first }.count == asked)
        #expect(names(search).isEmpty)
        #expect(search.isRunning)
        engine.progress(second, add: ["xylo.txt"], finish: true)
        timers.advance(0.12)
        #expect(names(search) == ["xylo.txt"])
    }
}
