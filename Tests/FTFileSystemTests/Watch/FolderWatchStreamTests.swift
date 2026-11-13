import FTTestSupport
import Foundation
import Testing

// The FSEvents stream and the app's wiring of the folder watch, on real folders (no windows are involved)
@testable import FTFileSystem

@MainActor
private final class Told {
    var changes: [FolderChange] = []
}

@MainActor
struct FolderWatchStreamTests {
    /// Waits up to `seconds` for `condition`.
    private func wait(seconds: Double = 8, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// Writes `path` every 250 ms until `told`, for up to 8 s. A watch's stream is started off the main actor, in its
    /// own time, and a change made before it runs is never told: once one is told, the stream runs.
    private func probe(_ path: String, until told: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        var attempt = 0
        repeat {
            try "probe \(attempt)".write(toFile: path, atomically: false, encoding: .utf8)
            attempt += 1
            if await wait(seconds: 0.25, until: told) { return true }
        } while ContinuousClock.now < deadline
        return told()
    }

    @Test func tellsOfATagOrCustomizationSetOnAnItemWithNothingElseChanged() async throws {
        try await withTemporaryDirectory { directory in
            let root = directory.path
            let item = root + "/item"
            try FileManager.default.createDirectory(atPath: item, withIntermediateDirectories: true)
            let told = Told()
            let watches = FolderWatches(.app(cache: ResponseCache()) { _, change in told.changes.append(change) })
            watches.watch(windowID: 1, path: root)
            defer { watches.stopAll() }
            // Once the stream runs, what was told before (the item being made, had it been) is over with.
            #expect(
                try await probe(root + "/probe") {
                    told.changes.contains { $0.changedPaths?.contains(root + "/probe") == true }
                })
            told.changes = []
            try FinderTags.write([FinderTag(name: "Tag", color: .red)], to: item)
            #expect(
                await wait {
                    told.changes.contains { $0.changedPaths?.contains(item) == true || $0.changedPaths == nil }
                })
        }
    }

    @Test func tellsOfItemsMadeRenamedAndRemovedInsideTheFolder() async throws {
        try await withTemporaryDirectory { directory in
            // Paths are named as the window gave the folder, whatever FSEvents calls it.
            let root = directory.path
            let cache = ResponseCache()
            let told = Told()
            let watches = FolderWatches(.app(cache: cache) { _, change in told.changes.append(change) })
            watches.watch(windowID: 1, path: directory.path)
            defer { watches.stopAll() }

            let real = try NativeFileSystem().realpath(directory.path)
            #expect(
                try await probe(real + "/made.txt") {
                    told.changes.contains { $0.changedPaths?.contains(root + "/made.txt") == true }
                })

            try FileManager.default.moveItem(atPath: real + "/made.txt", toPath: real + "/renamed.txt")
            #expect(
                await wait {
                    told.changes.contains { $0.changedPaths?.contains(root + "/renamed.txt") == true }
                })

            try FileManager.default.removeItem(atPath: real + "/renamed.txt")
            let removedTold = told.changes.count
            #expect(await wait { told.changes.count > removedTold })
            #expect(told.changes.allSatisfy { $0.path == directory.path })
        }
    }

    @Test func ignoresChangesDeeperInsideTheFolder() async throws {
        try await withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                atPath: directory.path + "/inner", withIntermediateDirectories: false)
            let told = Told()
            let watches = FolderWatches(.app(cache: ResponseCache()) { _, change in told.changes.append(change) })
            watches.watch(windowID: 1, path: directory.path)
            defer { watches.stopAll() }
            let root = directory.path
            @MainActor func named() -> [String] { told.changes.compactMap(\.changedPaths).flatMap { $0 } }
            #expect(try await probe(root + "/probe") { named().contains(root + "/probe") })

            try "x".write(toFile: root + "/inner/deep.txt", atomically: false, encoding: .utf8)
            // A change that is told, made after: had the deeper one been told, it would have been by then.
            try "x".write(toFile: root + "/after.txt", atomically: false, encoding: .utf8)
            #expect(await wait { named().contains(root + "/after.txt") })
            // Told, it would be by its leaf name: the watch names what it hears as children of the folder.
            #expect(!named().contains { $0.hasSuffix("/deep.txt") })
        }
    }

    @Test func letsGoOfCachedListingsBeforeTellingTheWindow() async throws {
        try await withTemporaryDirectory { directory in
            let cache = ResponseCache()
            let service = DirectoryService(cache: cache)
            _ = try await service.snapshot(path: directory.path)
            #expect(cache.sizes.directorySnapshots == 1)

            let sizesWhenTold = Told()
            var sizeSeen: Int?
            let watches = FolderWatches(
                .app(cache: cache) { _, change in
                    sizeSeen = cache.sizes.directorySnapshots
                    sizesWhenTold.changes.append(change)
                })
            watches.watch(windowID: 1, path: directory.path)
            defer { watches.stopAll() }
            #expect(try await probe(directory.path + "/new.txt") { !sizesWhenTold.changes.isEmpty })
            #expect(sizeSeen == 0)
        }
    }

    @Test func cannotWatchAFolderThatIsNotThere() async throws {
        let failed = Told()
        let stop = FSEventsFolderWatcher.watchFolder(
            path: "/nonexistent-filetrail-folder", onChange: { _ in },
            onFail: { failed.changes.append(FolderChange(path: "", changedPaths: nil)) })
        defer { stop() }
        #expect(await wait { !failed.changes.isEmpty })
    }

    // A watch stopped once its stream runs (twice: the second does nothing), and one stopped before its stream is
    // started, on one folder: neither is told of a change made afterwards. A third watch, left running, is.
    @Test func stopsWatchingWhenAskedAlsoBeforeTheStreamIsStarted() async throws {
        try await withTemporaryDirectory { directory in
            let told = Told()
            let toldEarly = Told()
            var toldRunning: [String?] = []
            let stopEarly = FSEventsFolderWatcher.watchFolder(
                path: directory.path,
                onChange: { _ in toldEarly.changes.append(FolderChange(path: "", changedPaths: nil)) }, onFail: {})
            stopEarly()
            let stop = FSEventsFolderWatcher.watchFolder(
                path: directory.path, onChange: { _ in told.changes.append(FolderChange(path: "", changedPaths: nil)) },
                onFail: {})
            let stopRunning = FSEventsFolderWatcher.watchFolder(
                path: directory.path, onChange: { toldRunning.append($0) }, onFail: {})
            defer { stopRunning() }
            // Both streams run, as the first's would have had it not been stopped.
            #expect(
                try await probe(directory.path + "/probe") {
                    !told.changes.isEmpty && toldRunning.contains("probe")
                })
            stop()
            stop()
            let before = told.changes.count
            try "x".write(toFile: directory.path + "/late.txt", atomically: false, encoding: .utf8)
            #expect(await wait { toldRunning.contains("late.txt") })
            #expect(told.changes.count == before)
            #expect(toldEarly.changes.isEmpty)
        }
    }

    @Test func tellsWhenTheFolderItselfIsRemoved() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let told = Told()
        let watches = FolderWatches(.app(cache: ResponseCache()) { _, change in told.changes.append(change) })
        watches.watch(windowID: 1, path: directory.path)
        defer { watches.stopAll() }
        #expect(try await probe(directory.path + "/probe") { !told.changes.isEmpty })
        told.changes = []
        try FileManager.default.removeItem(atPath: directory.path)
        #expect(await wait { told.changes.contains { $0.changedPaths == nil } })
    }
}
