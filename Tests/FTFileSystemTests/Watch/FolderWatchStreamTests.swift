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
    /// How long a change that should not be told is waited for: FSEvents hands events over after 0.05 s
    /// (`FSEventsFolderWatcher.latencySeconds`), then the main actor is told.
    private static let quietWait = Duration.milliseconds(250)

    /// Waits up to `seconds` for `condition`.
    private func wait(seconds: Double = 8, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
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
            // Let the stream start before changing anything.
            try await Task.sleep(for: .milliseconds(300))

            let real = try NativeFileSystem().realpath(directory.path)
            // FSEvents can start late on a busy machine and miss the first write, so touch the file again until it is told of.
            try "x".write(toFile: real + "/made.txt", atomically: false, encoding: .utf8)
            var madeTold = false
            for attempt in 0..<4 where !madeTold {
                madeTold = await wait(seconds: 4) {
                    told.changes.contains { $0.changedPaths?.contains(root + "/made.txt") == true }
                }
                if !madeTold { try "x\(attempt)".write(toFile: real + "/made.txt", atomically: false, encoding: .utf8) }
            }
            #expect(madeTold)

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
            try await Task.sleep(for: .milliseconds(300))

            try "x".write(toFile: directory.path + "/inner/deep.txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: Self.quietWait)
            let root = directory.path
            let named = told.changes.compactMap(\.changedPaths).flatMap { $0 }
            #expect(!named.contains(root + "/inner/deep.txt"))
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
            try await Task.sleep(for: .milliseconds(300))
            try "x".write(toFile: directory.path + "/new.txt", atomically: false, encoding: .utf8)
            #expect(await wait { !sizesWhenTold.changes.isEmpty })
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
    // started, on one folder: neither is told of a change made afterwards.
    @Test func stopsWatchingWhenAskedAlsoBeforeTheStreamIsStarted() async throws {
        try await withTemporaryDirectory { directory in
            let told = Told()
            let toldEarly = Told()
            let stopEarly = FSEventsFolderWatcher.watchFolder(
                path: directory.path,
                onChange: { _ in toldEarly.changes.append(FolderChange(path: "", changedPaths: nil)) }, onFail: {})
            stopEarly()
            let stop = FSEventsFolderWatcher.watchFolder(
                path: directory.path, onChange: { _ in told.changes.append(FolderChange(path: "", changedPaths: nil)) },
                onFail: {})
            // Long enough for both streams to start, had the first not been stopped.
            try await Task.sleep(for: .milliseconds(300))
            stop()
            stop()
            let before = told.changes.count
            try "x".write(toFile: directory.path + "/late.txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: Self.quietWait)
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
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.removeItem(atPath: directory.path)
        #expect(await wait { told.changes.contains { $0.changedPaths == nil } })
    }
}
