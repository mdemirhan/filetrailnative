import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// Counts what it is asked to draw.
private final class CountingIcons: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []

    func count(of path: String) -> Int { lock.withLock { asked.filter { $0 == path }.count } }

    func icon(atPath path: String) -> NSImage? {
        lock.withLock { asked.append(path) }
        return NSImage(size: NSSize(width: 2, height: 2))
    }
}

// The icon of the Info panel and the Info Row asks again for a folder's icon once the store dropped it as System
// Settings' colors changed, and leaves an icon no accent colors alone.
@MainActor @Suite struct InfoIconAccentTests {
    @Test func aFoldersIconIsAskedForAgainOnceDropped() async throws {
        try await withTemporaryDirectory { directory in
            let source = CountingIcons()
            let store = FileIconStore(source: source, samples: IconSamples(root: directory.appending("samples")))
            let view = InfoIconView()
            let users = IconEntry(path: "/Users", name: "Users", kind: .directory)
            view.show(users, store: store, deferLoad: false)
            #expect(await waitUntil { source.count(of: "/Users") == 1 })

            store.dropAccentDrawnIcons()
            #expect(await waitUntil { source.count(of: "/Users") == 2 })
            #expect(view.shown == IconRequest(entry: users).cacheKey)
        }
    }

    // A folder of a tag's color is drawn in the tag's color whatever the accent; another store's drop says nothing
    // about this one's icons.
    @Test func aTaggedFoldersIconAndAnotherStoresDropLeaveTheIconAlone() async throws {
        try await withTemporaryDirectory { directory in
            let source = CountingIcons()
            let samples = IconSamples(root: directory.appending("samples"))
            let store = FileIconStore(source: source, samples: samples)
            let view = InfoIconView()
            let tagged = IconEntry(path: "/a/Photos", name: "Photos", kind: .directory, tagColor: .green)
            view.show(tagged, store: store, deferLoad: false)
            let sample = try samples.path(forTint: .green)
            #expect(await waitUntil { source.count(of: sample) == 1 })

            store.dropAccentDrawnIcons()
            FileIconStore(source: source, samples: samples).dropAccentDrawnIcons()
            try await Task.sleep(for: .milliseconds(100))
            #expect(source.count(of: sample) == 1)

            let users = IconEntry(path: "/Users", name: "Users", kind: .directory)
            view.show(users, store: store, deferLoad: false)
            #expect(await waitUntil { source.count(of: "/Users") == 1 })
            FileIconStore(source: source, samples: samples).dropAccentDrawnIcons()
            try await Task.sleep(for: .milliseconds(100))
            #expect(source.count(of: "/Users") == 1)
        }
    }
}
