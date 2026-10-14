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
            try "x".write(toFile: real + "/made.txt", atomically: false, encoding: .utf8)
            #expect(await wait { told.changes.contains { $0.changedPaths?.contains(root + "/made.txt") == true } })

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
            try await Task.sleep(for: .milliseconds(1_200))
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

    @Test func stopsWatchingWhenAsked() async throws {
        try await withTemporaryDirectory { directory in
            let told = Told()
            let stop = FSEventsFolderWatcher.watchFolder(
                path: directory.path, onChange: { _ in told.changes.append(FolderChange(path: "", changedPaths: nil)) },
                onFail: {})
            try await Task.sleep(for: .milliseconds(300))
            stop()
            stop()
            let before = told.changes.count
            try "x".write(toFile: directory.path + "/late.txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(800))
            #expect(told.changes.count == before)
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

    @Test func stoppedBeforeTheStreamIsStartedLeavesNoStream() async throws {
        try await withTemporaryDirectory { directory in
            let told = Told()
            let stop = FSEventsFolderWatcher.watchFolder(
                path: directory.path, onChange: { _ in told.changes.append(FolderChange(path: "", changedPaths: nil)) },
                onFail: {})
            stop()
            try await Task.sleep(for: .milliseconds(300))
            try "x".write(toFile: directory.path + "/late.txt", atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(800))
            #expect(told.changes.isEmpty)
        }
    }
}
