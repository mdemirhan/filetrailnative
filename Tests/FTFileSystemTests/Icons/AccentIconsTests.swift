import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

// When System Settings' colors change, macOS draws folders in the new accent: the icons drawn in it are drawn again,
// and those no accent touches (a tag's color, a document's, an app's) are kept.
@testable import FTFileSystem

/// Draws a new image each time it is asked.
private final class FreshSource: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var asked: Int { lock.withLock { count } }

    func icon(atPath path: String) -> NSImage? {
        lock.withLock { count += 1 }
        return NSImage(size: NSSize(width: 2, height: 2))
    }
}

@MainActor
private func fetch(_ store: FileIconStore, _ request: IconRequest) async -> NSImage? {
    await withCheckedContinuation { continuation in
        store.load(request) { continuation.resume(returning: $0) }
    }
}

@MainActor
private func cached(_ store: FileIconStore, _ request: IconRequest) -> NSImage? {
    if case .image(let image) = store.lookup(request) { return image }
    return nil
}

/// Counts the notices that the store dropped its icons.
@MainActor
private final class DropCounter {
    var count = 0
    private var token: (any NSObjectProtocol)?

    init(_ center: NotificationCenter, _ store: FileIconStore) {
        token = center.addObserver(forName: FileIconStore.accentDrawnIconsDropped, object: store, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
}

@MainActor @Suite struct AccentIconsTests {
    @Test func whatTheAccentColorsIsKnownByItsKey() {
        #expect(FileIconStore.isDrawnInAccent(key: GenericIconKind.folder.cacheKey))
        #expect(FileIconStore.isDrawnInAccent(key: GenericIconKind.emptyFolder.cacheKey))
        #expect(
            FileIconStore.isDrawnInAccent(key: IconRequest(entry: IconEntry(path: "/Users", kind: .directory)).cacheKey)
        )
        #expect(
            FileIconStore.isDrawnInAccent(
                key: IconRequest(entry: IconEntry(path: "/a/b", kind: .aliasDirectory)).cacheKey))
        #expect(!FileIconStore.isDrawnInAccent(key: IconRequest.tintedFolder(.red, isEmpty: false).cacheKey))
        #expect(!FileIconStore.isDrawnInAccent(key: IconRequest.tintedFolder(.blue, isEmpty: true).cacheKey))
        #expect(!FileIconStore.isDrawnInAccent(key: GenericIconKind.file.cacheKey))
        #expect(!FileIconStore.isDrawnInAccent(key: GenericIconKind.executable.cacheKey))
        #expect(!FileIconStore.isDrawnInAccent(key: IconRequest.app(path: "/Applications/Mail.app").cacheKey))
        #expect(
            !FileIconStore.isDrawnInAccent(
                key: IconRequest(entry: IconEntry(path: "/a/b.txt", extension: "txt")).cacheKey))
    }

    @Test func aChangeOfTheSystemsColorsDrawsTheFoldersAgainAndKeepsTheRest() async throws {
        try await withTemporaryDirectory { directory in
            let center = NotificationCenter()
            let source = FreshSource()
            let store = FileIconStore(
                source: source, samples: IconSamples(root: directory.appending("samples")), sleep: { _ in })
            store.followSystemColors(center: center)
            let drops = DropCounter(center, store)

            let folder = IconRequest.generic(.folder)
            let special = IconRequest(entry: IconEntry(path: "/Users", kind: .directory))
            let tagged = IconRequest.tintedFolder(.green, isEmpty: false)
            let document = IconRequest.generic(.file)
            let app = IconRequest.app(path: "/Applications/Mail.app")
            for request in [folder, special, tagged, document, app] { _ = await fetch(store, request) }
            let before = [folder, special, tagged, document, app].map { cached(store, $0) }
            #expect(before.allSatisfy { $0 != nil })

            center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
            await pollUntil { drops.count == 1 }

            // The plain folder is drawn again before anything is told; a folder drawn from its path is asked for anew.
            #expect(cached(store, folder) != nil && cached(store, folder) !== before[0])
            guard case .missing = store.lookup(special) else {
                Issue.record("a special folder's icon was kept in the old color")
                return
            }
            #expect(cached(store, tagged) === before[2])
            #expect(cached(store, document) === before[3])
            #expect(cached(store, app) === before[4])
        }
    }

    // A change of colors comes as several notices: the icons are dropped and the views told once.
    @Test func aBurstOfNoticesDropsOnce() async throws {
        try await withTemporaryDirectory { directory in
            let center = NotificationCenter()
            let store = FileIconStore(
                source: FreshSource(), samples: IconSamples(root: directory.appending("samples")), sleep: { _ in })
            store.followSystemColors(center: center)
            store.followSystemColors(center: center)
            let drops = DropCounter(center, store)
            for _ in 0..<3 { center.post(name: NSColor.systemColorsDidChangeNotification, object: nil) }
            await pollUntil { drops.count >= 1 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(drops.count == 1)
        }
    }

    // Quick Look keeps a folder's picture until the folder changes: the samples are dated now.
    @Test func thePlainFolderSamplesAreDatedNow() throws {
        try withTemporaryDirectory { directory in
            let samples = IconSamples(root: directory.appending("samples"))
            let folder = try samples.path(for: .folder)
            let empty = try samples.path(for: .emptyFolder)
            let old = Date(timeIntervalSinceNow: -86_400)
            for path in [folder, empty] {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
            }
            samples.markFoldersChanged()
            for path in [folder, empty] {
                let date = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
                #expect(date.map { $0.timeIntervalSince(old) > 3600 } == true)
            }
        }
    }
}
