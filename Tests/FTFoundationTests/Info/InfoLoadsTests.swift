// What the Info panel shows while its item's properties and Open With apps are asked for
import Testing

@testable import FTFoundation

struct InfoPropertiesLoadTests {
    private func item(_ path: String, size: Int64 = 1) -> InfoItem {
        InfoItem(
            path: path, name: String(path.split(separator: "/").last ?? ""), fileExtension: "", kind: .file,
            kindLabel: "Document", isHidden: false, isSymlink: false, createdAt: nil, modifiedAt: nil, sizeBytes: size,
            sizeStatus: .ready, permissionMode: nil)
    }

    @Test func anItemNotSeenBeforeLoadsUntilItsAnswerComes() {
        var load = InfoPropertiesLoad(recentLimit: 3)
        #expect(load.needsAsking("/a"))
        let request = load.ask("/a")
        #expect(load.isLoading && load.target == "/a" && load.shown == nil)
        #expect(!load.needsAsking("/a"))
        let shown = load.answered("/a", item("/a"), request: request)
        #expect(shown)
        #expect(!load.isLoading && load.shown == item("/a"))
        #expect(load.phase == .answered(path: "/a"))
        #expect(!load.needsAsking("/a"))
    }

    // What is shown stays while the next item is asked for, and an answer that came too late is kept, not shown.
    @Test func aLateAnswerIsKeptButNotShown() {
        var load = InfoPropertiesLoad(recentLimit: 3)
        _ = load.answered("/a", item("/a"), request: load.ask("/a"))
        let late = load.ask("/c")
        load.ask("/b")
        #expect(load.shown == item("/a"))
        let lateShown = load.answered("/c", item("/c"), request: late)
        #expect(!lateShown)
        #expect(load.shown == item("/a"))
        load.ask("/c")
        #expect(load.shown == item("/c"))
        #expect(!load.isLoading)
    }

    // An item seen again shows what was kept of it at once while it is read again, and drops out after a few others.
    @Test func anItemSeenAgainShowsAtOnceWhileReadAgain() {
        var load = InfoPropertiesLoad(recentLimit: 2)
        for path in ["/a", "/b", "/c"] {
            _ = load.answered(path, item(path), request: load.ask(path))
        }
        let again = load.ask("/b")
        #expect(load.shown == item("/b") && !load.isLoading)
        let shownAgain = load.answered("/b", item("/b", size: 9), request: again)
        #expect(shownAgain)
        #expect(load.shown == item("/b", size: 9))
        load.ask("/a")
        #expect(load.isLoading)
    }

    // The item asked for again while its first read is still on its way (its folder changed): answers that come out of
    // order leave the later one shown and kept, and the first answer still shows when it is the only one so far.
    @Test func anOlderAnswerForTheSameItemDoesntReplaceANewerOne() {
        var load = InfoPropertiesLoad(recentLimit: 2)
        let older = load.ask("/a")
        let newer = load.ask("/a")
        let newerShown = load.answered("/a", item("/a", size: 200), request: newer)
        let olderShown = load.answered("/a", item("/a", size: 100), request: older)
        #expect(newerShown && !olderShown)
        #expect(load.shown == item("/a", size: 200))
        load.ask("/b")
        load.ask("/a")
        #expect(load.shown == item("/a", size: 200))

        let first = load.ask("/c")
        let second = load.ask("/c")
        let firstShown = load.answered("/c", item("/c", size: 100), request: first)
        #expect(firstShown && load.shown == item("/c", size: 100))
        let secondShown = load.answered("/c", item("/c", size: 200), request: second)
        #expect(secondShown)
        #expect(load.shown == item("/c", size: 200))
    }

    // Closed, nothing loads: opening again over nothing at all shows the panel empty, not waiting.
    @Test func stoppingLeavesNothingLoading() {
        var load = InfoPropertiesLoad(recentLimit: 2)
        let request = load.ask("/a")
        load.stop()
        #expect(!load.isLoading && load.target == nil)
        #expect(load.needsAsking("/a"))
        let shownAfterStop = load.answered("/a", item("/a"), request: request)
        #expect(!shownAfterStop)
        load.ask("/a")
        #expect(!load.isLoading && load.shown == item("/a"))
    }
}

struct OpenWithLookupLoadTests {
    private typealias Load = OpenWithLookupLoad<String>
    private let always: (String?) -> Bool = { $0 == "editor" }

    @Test func pendingUntilAnsweredThenAvailableIfItsKindCanAlwaysOpenInAnApp() throws {
        var load = Load()
        let firstRequest = load.request("/a.txt")
        let first = try #require(firstRequest)
        let askedAgain = load.request("/a.txt")
        #expect(askedAgain == nil)
        #expect(load.opensWith(for: "/a.txt", isFile: true, canAlways: always) == .pending)
        #expect(load.opensWith(for: "/folder", isFile: false, canAlways: always) == .hidden)
        let taken = load.answered(first, "editor")
        #expect(taken)
        #expect(load.answer(for: "/a.txt") == "editor")
        #expect(load.opensWith(for: "/a.txt", isFile: true, canAlways: always) == .available)
        #expect(load.opensWith(for: "/b.txt", isFile: true, canAlways: always) == .pending)
    }

    // A slow answer stops holding the panel up; if it still comes, it is taken.
    @Test func aSlowAnswerIsGivenUpOnAndStillTaken() throws {
        var load = Load()
        let firstRequest = load.request("/a.txt")
        let first = try #require(firstRequest)
        let gaveUp = load.patienceRanOut(first)
        #expect(gaveUp)
        #expect(load.opensWith(for: "/a.txt", isFile: true, canAlways: always) == .hidden)
        let takenLate = load.answered(first, "editor")
        #expect(takenLate)
        #expect(load.opensWith(for: "/a.txt", isFile: true, canAlways: always) == .available)
        let gaveUpAgain = load.patienceRanOut(first)
        #expect(!gaveUpAgain)
    }

    // An answer or a wait from a request before is dropped, the same item asked again after forgetting included.
    @Test func answersToEarlierRequestsAreDropped() throws {
        var load = Load()
        let firstRequest = load.request("/a.txt")
        let first = try #require(firstRequest)
        let secondRequest = load.request("/b.txt")
        let second = try #require(secondRequest)
        let firstTaken = load.answered(first, "editor")
        #expect(!firstTaken)
        let firstGaveUp = load.patienceRanOut(first)
        #expect(!firstGaveUp)
        let toAskAgain = load.forget()
        #expect(toAskAgain == "/b.txt")
        let thirdRequest = load.request("/b.txt")
        let third = try #require(thirdRequest)
        let secondTaken = load.answered(second, "old")
        #expect(!secondTaken)
        #expect(load.answer(for: "/b.txt") == nil)
        let thirdTaken = load.answered(third, "editor")
        #expect(thirdTaken)
        #expect(load.answer(for: "/b.txt") == "editor")
    }
}
