import Foundation
import Testing

// Port of apps/desktop/src/main/folderWatch.test.ts
@testable import FTFileSystem

/// A clock and timers the test moves by hand, as vi.useFakeTimers does.
@MainActor
final class ManualScheduler: FolderWatchScheduler {
    private struct Timer {
        let id: Int
        let due: Double
        let work: @MainActor () -> Void
    }

    private(set) var time = 0.0
    private var timers: [Timer] = []
    private var nextID = 0

    func now() -> Double { time }

    func schedule(afterMilliseconds milliseconds: Double, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        timers.append(Timer(id: id, due: time + milliseconds, work: work))
        return { [weak self] in
            MainActor.assumeIsolated { self?.timers.removeAll { $0.id == id } }
        }
    }

    /// Runs the timers due within `milliseconds`, in order, each at its time.
    func advance(by milliseconds: Double) {
        let target = time + milliseconds
        while let next = timers.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            timers.removeAll { $0.id == next.id }
            time = max(time, next.due)
            next.work()
        }
        time = target
    }

    var pending: Int { timers.count }
}

/// Lets the tasks the watches start run (their reads of the modification time).
@MainActor
func drain() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
private final class Harness {
    let scheduler = ManualScheduler()
    var listeners: [String: @MainActor (String?) -> Void] = [:]
    var failures: [String: @MainActor () -> Void] = [:]
    var stopped: [String] = []
    // Folders a watch can't be started on.
    var unwatchable: Set<String> = []
    var started = 0
    var modifiedTimes: [String: Double] = [:]
    // Reads of the modification time held back until the test lets them go.
    var heldReads: [CheckedContinuation<Void, Never>]?
    var changes: [(windowID: Int, change: FolderChange)] = []
    var forgotten: [(path: String, changed: [String]?)] = []
    var watches: FolderWatches!

    init() {
        watches = FolderWatches(
            FolderWatches.Dependencies(
                watchFolder: { [self] path, onChange, onFail in
                    if unwatchable.contains(path) { return nil }
                    started += 1
                    listeners[path] = onChange
                    failures[path] = onFail
                    return { [self] in
                        MainActor.assumeIsolated {
                            listeners[path] = nil
                            stopped.append(path)
                        }
                    }
                },
                readModifiedTime: { [self] path in await read(path) },
                onFolderChanged: { [self] windowID, change in changes.append((windowID, change)) },
                forgetCachedListings: { [self] path, changed in forgotten.append((path, changed)) },
                scheduler: scheduler))
    }

    private func read(_ path: String) async -> Double? {
        if heldReads != nil {
            await withCheckedContinuation { heldReads?.append($0) }
        }
        return modifiedTimes[path]
    }

    var watched: [String] { listeners.keys.sorted() }

    func change(_ path: String, _ name: String?) { listeners[path]?(name) }

    /// The watch stops by itself, as Node closes one on its first error.
    func fail(_ path: String) {
        listeners[path] = nil
        failures[path]?()
    }

    func holdReads() { heldReads = [] }

    func releaseReads() {
        let held = heldReads ?? []
        heldReads = nil
        for continuation in held { continuation.resume() }
    }
}

@MainActor
struct FolderWatchesTests {
    // T-929e8af9 F-200 B-VIEW-185
    // T-4272a158 T-5a8447d3 T-e42b2463
    @Test func followsEachWindowFromFolderToFolderAndStopsWhenAsked() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        harness.watches.watch(windowID: 2, path: "/b")
        #expect(harness.watched == ["/a", "/b"])

        // The same folder again keeps the watch it has.
        harness.watches.watch(windowID: 1, path: "/a")
        #expect(harness.stopped.isEmpty)

        harness.watches.watch(windowID: 1, path: "/c")
        #expect(harness.stopped == ["/a"])
        harness.watches.watch(windowID: 2, path: nil)
        #expect(harness.watched == ["/c"])

        harness.watches.stopAll()
        #expect(harness.watched.isEmpty)
    }

    // T-2ae9187d F-201 F-202 B-VIEW-188
    @Test func tellsOfABurstOfChangesOnceWhenItSettlesNamingWhatChanged() {
        let harness = Harness()
        harness.watches.watch(windowID: 7, path: "/a")
        harness.change("/a", "one.txt")
        harness.scheduler.advance(by: 100)
        harness.change("/a", "two.txt")
        harness.change("/a", "one.txt")
        harness.scheduler.advance(by: 200)
        #expect(harness.changes.isEmpty)

        harness.scheduler.advance(by: 50)
        #expect(harness.forgotten.count == 1)
        #expect(harness.forgotten.first?.path == "/a")
        #expect(harness.forgotten.first?.changed == ["/a/one.txt", "/a/two.txt"])
        #expect(harness.changes.count == 1)
        #expect(harness.changes.first?.windowID == 7)
        #expect(harness.changes.first?.change == FolderChange(path: "/a", changedPaths: ["/a/one.txt", "/a/two.txt"]))
    }

    // T-8039a474 F-201
    @Test func tellsOfAFolderThatKeepsChangingOnceASecond() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        var elapsed = 0.0
        while elapsed < 2_000 {
            harness.change("/a", "download.part")
            harness.scheduler.advance(by: 100)
            elapsed += 100
        }
        #expect(harness.changes.count == 2)
    }

    // T-fb04b248 F-201 B-NAV-137 B-VIEW-188
    @Test func saysAnythingMayHaveChangedWhenAChangeHasNoName() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        harness.change("/a", "one.txt")
        harness.change("/a", nil)
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: nil))

        // The next burst names its items again.
        harness.change("/a", "two.txt")
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: ["/a/two.txt"]))
    }

    // B-NAV-137 B-VIEW-188
    @Test func saysAnythingMayHaveChangedWhenMoreThanAThousandItemsChanged() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        for index in 0..<1_000 { harness.change("/a", "item \(index)") }
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change.changedPaths?.count == 1_000)

        for index in 0...1_000 { harness.change("/a", "item \(index)") }
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: nil))
    }

    // T-8b92b0be B-NAV-135 B-VIEW-186
    // T-859ecde4
    @Test func dropsAChangeStillSettlingWhenTheWindowMovesOn() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        harness.change("/a", "one.txt")
        harness.watches.watch(windowID: 1, path: "/b")
        harness.scheduler.advance(by: 1_000)
        #expect(harness.changes.isEmpty)
    }

    // T-9378b518 F-203
    @Test func catchesAChangeTheWatchMissedByTheFoldersModificationTime() async {
        let harness = Harness()
        harness.modifiedTimes["/share"] = 100
        harness.watches.watch(windowID: 1, path: "/share")
        await drain()

        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        #expect(harness.changes.isEmpty)

        harness.modifiedTimes["/share"] = 200
        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        #expect(harness.changes.last?.change == FolderChange(path: "/share", changedPaths: nil))

        // Told once: the time it was told at is the one compared to next.
        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        #expect(harness.changes.count == 1)
    }

    // T-defbeeca
    @Test func tellsOfAFolderGoneWhenTheWindowComesBack() async {
        let harness = Harness()
        harness.modifiedTimes["/a"] = 100
        harness.watches.watch(windowID: 1, path: "/a")
        await drain()

        harness.modifiedTimes["/a"] = nil
        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: nil))
    }

    // T-16b63448
    @Test func tellsOfAChangeToTheFolderItselfAsAnythingMayHaveChanged() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a/Project")
        // The folder renamed or removed is told of by its own name.
        harness.change("/a/Project", "Project")
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a/Project", changedPaths: nil))
        #expect(harness.forgotten.last?.path == "/a/Project")
        #expect(harness.forgotten.last?.changed == nil)
    }

    // T-53f2d960 F-202
    @Test func startsAWatchAgainWhenTheWindowAsksForTheFolderAfterItFailed() {
        let harness = Harness()
        harness.watches.watch(windowID: 1, path: "/a")
        harness.fail("/a")
        // The window is told, so it reads the folder again.
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: nil))
        #expect(harness.watched.isEmpty)

        harness.watches.watch(windowID: 1, path: "/a")
        #expect(harness.started == 2)
        #expect(harness.watched == ["/a"])
    }

    // T-fadbeb03
    @Test func startsAWatchAgainThatCouldNotStartOnceTheFolderCanBeWatched() {
        let harness = Harness()
        harness.unwatchable.insert("/a")
        harness.watches.watch(windowID: 1, path: "/a")
        #expect(harness.watched.isEmpty)

        harness.unwatchable.remove("/a")
        harness.watches.watch(windowID: 1, path: "/a")
        #expect(harness.started == 1)
        #expect(harness.watched == ["/a"])
    }

    // T-7b842cb9 F-203
    @Test func startsAFailedWatchAgainWhenTheWindowComesBackToTheFront() async {
        let harness = Harness()
        harness.modifiedTimes["/a"] = 100
        harness.watches.watch(windowID: 1, path: "/a")
        harness.fail("/a")
        harness.scheduler.advance(by: 250)
        await drain()
        harness.changes.removeAll()

        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        #expect(harness.watched == ["/a"])
        harness.change("/a", "one.txt")
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.last?.change == FolderChange(path: "/a", changedPaths: ["/a/one.txt"]))
    }

    // T-85a61f44
    @Test func tellsOfAChangeOnceWhenTheWindowComesToTheFrontWhileItIsStillNoted() async {
        let harness = Harness()
        harness.modifiedTimes["/a"] = 100
        harness.watches.watch(windowID: 1, path: "/a")
        await drain()

        harness.modifiedTimes["/a"] = 200
        harness.holdReads()
        harness.change("/a", "one.txt")
        harness.scheduler.advance(by: 250)
        #expect(harness.changes.count == 1)
        // The folder's new time is still being read when the window comes to the front.
        harness.watches.checkForMissedChanges(windowID: 1)
        await drain()
        harness.releaseReads()
        await drain()
        harness.releaseReads()
        await drain()
        #expect(harness.changes.count == 1)
    }

    // N/A T-4e9216a4 End-to-end scenario of the original's e2e suite, which needs the app window; the stream is
    // tested on real folders in FolderWatchStreamTests.
    // N/A T-ba2aad0d End-to-end scenario of the original's e2e suite, which needs the app window.
}
