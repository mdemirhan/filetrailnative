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
        load.ask("/a")
        #expect(load.isLoading && load.target == "/a" && load.shown == nil)
        #expect(!load.needsAsking("/a"))
        let shown = load.answered("/a", item("/a"))
        #expect(shown)
        #expect(!load.isLoading && load.shown == item("/a"))
        #expect(load.phase == .answered(path: "/a"))
        #expect(!load.needsAsking("/a"))
    }

    // What is shown stays while the next item is asked for, and an answer that came too late is kept, not shown.
    @Test func aLateAnswerIsKeptButNotShown() {
        var load = InfoPropertiesLoad(recentLimit: 3)
        load.ask("/a")
        _ = load.answered("/a", item("/a"))
        load.ask("/b")
        #expect(load.shown == item("/a"))
        let lateShown = load.answered("/c", item("/c"))
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
            load.ask(path)
            _ = load.answered(path, item(path))
        }
        load.ask("/b")
        #expect(load.shown == item("/b") && !load.isLoading)
        let shownAgain = load.answered("/b", item("/b", size: 9))
        #expect(shownAgain)
        #expect(load.shown == item("/b", size: 9))
        load.ask("/a")
        #expect(load.isLoading)
    }

    // Closed, nothing loads: opening again over nothing at all shows the panel empty, not waiting.
    @Test func stoppingLeavesNothingLoading() {
        var load = InfoPropertiesLoad(recentLimit: 2)
        load.ask("/a")
        load.stop()
        #expect(!load.isLoading && load.target == nil)
        #expect(load.needsAsking("/a"))
        let shownAfterStop = load.answered("/a", item("/a"))
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
