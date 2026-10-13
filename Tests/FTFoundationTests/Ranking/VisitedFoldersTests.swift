// Port of apps/desktop/src/shared/visitedFolders.test.ts and apps/desktop/src/renderer/lib/folderVisitTracker.test.ts
import Foundation
import Testing

@testable import FTFoundation

struct VisitedFoldersTests {
    static let hour = 60.0 * 60 * 1000
    static let day = 24 * hour
    static let now = 1_800_000_000_000.0

    private func folder(_ visits: [(age: Double, kind: FolderVisit.Kind)]) -> VisitedFolder {
        VisitedFolder(path: "/x", visits: visits.map { FolderVisit(at: Self.now - $0.age, kind: $0.kind) })
    }

    // T-74b40c9a F-026
    @Test func keepsEachVisitNewestFirstAndMovesTheFolderToTheFront() {
        let day = Self.day
        let now = Self.now
        let once = VisitedFolders.record([], path: "/Users/demo/work", kind: .stay, now: now - day)
        #expect(once == [VisitedFolder(path: "/Users/demo/work", visits: [FolderVisit(at: now - day, kind: .stay)])])

        let twice = VisitedFolders.record(once, path: "/Users/demo/work", kind: .goTo, now: now)
        #expect(
            twice == [
                VisitedFolder(
                    path: "/Users/demo/work",
                    visits: [FolderVisit(at: now, kind: .goTo), FolderVisit(at: now - day, kind: .stay)])
            ])

        let other = VisitedFolders.record(twice, path: "/Users/demo/music", kind: .stay, now: now)
        #expect(other.map(\.path) == ["/Users/demo/music", "/Users/demo/work"])
        #expect(VisitedFolders.record(other, path: "", kind: .stay, now: now) == other)
    }

    // T-5d1ef9e3 F-026
    @Test func keepsOnlyTheLatestVisitsOfAFolder() {
        var folders: [VisitedFolder] = []
        let limit = VisitedFolders.maxVisitsPerFolder
        for index in 0..<(limit + 5) {
            folders = VisitedFolders.record(folders, path: "/a", kind: .stay, now: Self.now + Double(index))
        }
        let visits = folders.first?.visits ?? []
        #expect(visits.count == limit)
        #expect(visits.first?.at == Self.now + Double(limit + 4))
        #expect(visits.last?.at == Self.now + 5)
    }

    // T-1f07a6cc F-026
    @Test func onlyMakesAFolderPassedThroughKnownWithoutAVisit() {
        let known = VisitedFolders.record([], path: "/a", kind: .passThrough, now: Self.now)
        #expect(known == [VisitedFolder(path: "/a", visits: [])])

        // A folder already known is left as it is, in its place.
        let folders = VisitedFolders.record(
            VisitedFolders.record([], path: "/b", kind: .stay, now: Self.now), path: "/c", kind: .stay, now: Self.now)
        #expect(VisitedFolders.record(folders, path: "/b", kind: .passThrough, now: Self.now) == folders)
    }

    // T-405c4507 F-027
    @Test func weighsEachVisitByHowItWasMadeAndHowLongAgo() {
        let hour = Self.hour
        let day = Self.day
        func score(_ visits: [(age: Double, kind: FolderVisit.Kind)]) -> Double {
            VisitedFolders.score(folder(visits), now: Self.now)
        }
        #expect(score([(hour, .stay)]) == 1)
        #expect(score([(hour, .goTo)]) == 3)
        #expect(abs(score([(10 * day, .stay)]) - 0.7) < 1e-9)
        #expect(abs(score([(20 * day, .stay)]) - 0.5) < 1e-9)
        #expect(abs(score([(60 * day, .stay)]) - 0.3) < 1e-9)
        #expect(abs(score([(200 * day, .stay)]) - 0.1) < 1e-9)
        #expect(VisitedFolders.score(VisitedFolder(path: "/x", visits: []), now: Self.now) == 0)
        // A clock set back does not produce a negative age.
        #expect(score([(-day, .stay)]) == 1)

        // Opened daily this week outranks opened constantly months ago, as only the latest visits
        // are kept.
        let thisWeek = (0..<5).map { (age: Double($0) * day, kind: FolderVisit.Kind.stay) }
        let lastSpring = (0..<VisitedFolders.maxVisitsPerFolder).map { _ in
            (age: 150 * day, kind: FolderVisit.Kind.stay)
        }
        #expect(score(thisWeek) > score(lastSpring))
    }

    // T-71b23b8a F-027
    @Test func forgetsTheLeastUsedFoldersPastTheLimitNeverTheOneJustOpened() {
        var folders = (0..<VisitedFolders.maxFolders).map { index in
            VisitedFolder(
                path: "/folders/\(index)",
                // Folder 0 has the fewest visits.
                visits: (0..<min(index, VisitedFolders.maxVisitsPerFolder)).map { _ in
                    FolderVisit(at: Self.now - Self.day, kind: .stay)
                })
        }
        folders = VisitedFolders.record(folders, path: "/new", kind: .passThrough, now: Self.now)

        #expect(folders.count == VisitedFolders.maxFolders)
        #expect(folders.first == VisitedFolder(path: "/new", visits: []))
        #expect(!folders.contains { $0.path == "/folders/0" })
        #expect(folders.contains { $0.path == "/folders/\(VisitedFolders.maxFolders - 1)" })
    }

    // T-3b35105d
    @Test func forgetsAFolderOnRequest() {
        let folders = VisitedFolders.record(
            VisitedFolders.record([], path: "/a", kind: .stay, now: Self.now), path: "/b", kind: .stay, now: Self.now)
        #expect(VisitedFolders.forget(folders, path: "/a").map(\.path) == ["/b"])
        #expect(VisitedFolders.forget(folders, path: "/missing") == folders)
    }

    // T-75b06913 F-124
    @Test func writesOneFolderPerLineAndReadsItBack() throws {
        let now = Self.now
        let folders = [
            VisitedFolder(
                path: "/a", visits: [FolderVisit(at: now, kind: .goTo), FolderVisit(at: now - Self.day, kind: .stay)]),
            VisitedFolder(path: "/b", visits: []),
        ]
        let text = VisitedFolders.serialize(folders)
        let nowText = String(Int64(now))
        let dayAgoText = String(Int64(now - Self.day))
        #expect(
            text
                == "{\"folders\":[\n{\"path\":\"/a\",\"visits\":[[\(nowText),\"goTo\"],[\(dayAgoText),\"stay\"]]},\n{\"path\":\"/b\",\"visits\":[]}\n]}\n"
        )
        #expect(VisitedFolders.parse(text) == folders)
        #expect(VisitedFolders.serialize([]) == "{\"folders\":[]}\n")
    }

    @Test func quotesPathsAsJSONDoes() {
        let folders = [VisitedFolder(path: "/a \"b\"\\c\n\u{1}é🎉/", visits: [])]
        #expect(
            VisitedFolders.serialize(folders)
                == "{\"folders\":[\n{\"path\":\"/a \\\"b\\\"\\\\c\\n\\u0001é🎉/\",\"visits\":[]}\n]}\n")
        #expect(VisitedFolders.parse(VisitedFolders.serialize(folders)) == folders)
    }

    // T-a135762b F-027
    @Test func readsSavedVisitsLeniently() throws {
        #expect(VisitedFolders.sanitize(nil).isEmpty)
        #expect(VisitedFolders.sanitize("nope").isEmpty)
        let now = Int64(Self.now)
        let day = Int64(Self.day)
        let text = """
            [
              {"path": "/ok", "visits": [[\(now - day), "stay"], [\(now), "goTo"], [\(now), "fly"], ["today", "stay"], null, [true, "stay"], [-1, "stay"]]},
              {"path": "/ok", "visits": []},
              {"path": "relative", "visits": []},
              {"path": "/no-visits"},
              null,
              42
            ]
            """
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        #expect(
            VisitedFolders.sanitize(value) == [
                VisitedFolder(
                    path: "/ok",
                    visits: [
                        FolderVisit(at: Double(now), kind: .goTo), FolderVisit(at: Double(now - day), kind: .stay),
                    ])
            ])
    }

    @Test func readsAtMostTheLimitOfFoldersAndKeepsTheTiedVisitsInOrder() throws {
        let many = (0..<(VisitedFolders.maxFolders + 20)).map { "{\"path\":\"/f\($0)\",\"visits\":[]}" }.joined(
            separator: ",")
        let value = try JSONSerialization.jsonObject(with: Data("[\(many)]".utf8))
        #expect(VisitedFolders.sanitize(value).count == VisitedFolders.maxFolders)

        let tied = try JSONSerialization.jsonObject(
            with: Data("[{\"path\":\"/t\",\"visits\":[[5,\"stay\"],[5,\"goTo\"]]}]".utf8))
        #expect(VisitedFolders.sanitize(tied).first?.visits.map(\.kind) == [.stay, .goTo])
    }

    @Test func nfcAndNfdPathsAreTwoFolders() {
        let folders = VisitedFolders.record([], path: "/Caf\u{E9}", kind: .stay, now: Self.now)
        #expect(VisitedFolders.record(folders, path: "/Cafe\u{301}", kind: .stay, now: Self.now).count == 2)
    }
}

@MainActor
struct FolderVisitTrackerTests {
    // A tracker whose timers only run when the test says so, with the visits it records.
    private final class Recorded {
        var visits: [String] = []
    }

    private func makeTracker() -> (tracker: FolderVisitTracker, recorded: Recorded, timers: VirtualTimers) {
        let recorded = Recorded()
        let timers = VirtualTimers(start: Date(timeIntervalSince1970: 0))
        let tracker = FolderVisitTracker(scheduler: timers) { path, kind in
            recorded.visits.append("\(path) \(kind.rawValue)")
        }
        return (tracker, recorded, timers)
    }

    // T-e100b72c F-094
    @Test func countsAFolderPickedInGoToAtOnce() {
        let (tracker, recorded, timers) = makeTracker()
        tracker.arrive("/a", viaGoTo: true)
        #expect(recorded.visits == ["/a goTo"])
        #expect(timers.pendingDelays.isEmpty)
    }

    // T-5f1923af F-094
    @Test func countsAFolderOpenedAnotherWayOnceItHasStayedOnScreen() {
        let (tracker, recorded, timers) = makeTracker()
        tracker.arrive("/a", viaGoTo: false)
        #expect(recorded.visits.isEmpty)
        #expect(timers.pendingDelays == [FolderVisitTracker.stayDelay])
        // Still on screen: nothing is decided yet.
        tracker.showing("/a")
        timers.advance(by: FolderVisitTracker.stayDelay)
        #expect(recorded.visits == ["/a stay"])
        // Decided once: leaving it later changes nothing.
        tracker.showing("/b")
        #expect(recorded.visits == ["/a stay"])
    }

    // T-0540857f F-094
    @Test func onlyPassesThroughAFolderLeftBeforeItStayed() {
        let (tracker, recorded, timers) = makeTracker()
        // Going on to another folder.
        tracker.arrive("/a", viaGoTo: false)
        tracker.arrive("/a/b", viaGoTo: false)
        #expect(recorded.visits == ["/a passThrough"])
        // Back, or another tab.
        tracker.showing("/a")
        #expect(recorded.visits == ["/a passThrough", "/a/b passThrough"])
        // Going on through Go To.
        tracker.arrive("/c", viaGoTo: false)
        tracker.arrive("/d", viaGoTo: true)
        #expect(Array(recorded.visits.dropFirst(2)) == ["/c passThrough", "/d goTo"])
        #expect(timers.pendingDelays.isEmpty)
    }

    // T-7d304c05 F-094
    @Test func countsAFolderUsedBeforeItStayed() {
        let (tracker, recorded, timers) = makeTracker()
        tracker.arrive("/a", viaGoTo: false)
        tracker.use()
        #expect(recorded.visits == ["/a stay"])
        #expect(timers.pendingDelays.isEmpty)
        // Used again, or with nothing being decided: no second visit.
        tracker.use()
        #expect(recorded.visits == ["/a stay"])
    }

    // T-b692dcd0 F-094
    @Test func passesThroughAFolderStillBeingDecidedOnWhenTheWindowGoes() {
        let (tracker, recorded, timers) = makeTracker()
        tracker.arrive("/a", viaGoTo: false)
        tracker.dispose()
        #expect(recorded.visits == ["/a passThrough"])
        #expect(timers.pendingDelays.isEmpty)
    }
}
