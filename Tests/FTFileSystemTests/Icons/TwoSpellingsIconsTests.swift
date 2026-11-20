import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

// Two files whose names differ only in how an accent is spelled, which a disk can keep side by side: each has its own
// preview and its own icon, asked for and kept apart
@testable import FTFileSystem

private let composed = "/x/caf\u{E9}.jpeg"
private let decomposed = "/x/cafe\u{301}.jpeg"

/// A preview provider whose calls wait until the test answers each path.
private final class HeldProvider: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var waiting: [(path: DiskPath, continuation: CheckedContinuation<ThumbnailResponse, Never>)] = []

    var paths: [DiskPath] { lock.withLock { asked.map(DiskPath.init) } }

    func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse {
        await withCheckedContinuation { continuation in
            lock.withLock {
                asked.append(path)
                waiting.append((DiskPath(path), continuation))
            }
        }
    }

    /// Answers the calls for `path`, and no other.
    func answer(_ path: String, _ picture: ThumbnailPicture) {
        let key = DiskPath(path)
        let mine = lock.withLock {
            let mine = waiting.filter { $0.path == key }
            waiting.removeAll { $0.path == key }
            return mine
        }
        for call in mine {
            call.continuation.resume(returning: ThumbnailResponse(version: "v1", unchanged: false, picture: picture))
        }
    }
}

private final class Listing {}

@MainActor
private final class Receiver {
    var answers: [ThumbnailPicture?] = []
    var last: ThumbnailPicture? { answers.last ?? nil }
}

private func picture() -> ThumbnailPicture {
    ThumbnailPicture(image: NSImage(size: NSSize(width: 4, height: 4)), isOpaque: true)
}

/// Gives every path an image of its own and remembers what it was asked for; the first call waits until let go.
private final class HeldIcons: IconSource, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var asked: [String] = []
    private var images: [DiskPath: NSImage] = [:]

    var paths: [DiskPath] { lock.withLock { asked.map(DiskPath.init) } }

    func image(for path: String) -> NSImage? { lock.withLock { images[DiskPath(path)] } }

    func letFirstAnswer() { gate.signal() }

    func icon(atPath path: String) -> NSImage? {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let first = lock.withLock {
            asked.append(path)
            images[DiskPath(path)] = image
            return asked.count == 1
        }
        if first { gate.wait() }
        return image
    }
}

@MainActor @Suite struct TwoSpellingsIconsTests {
    // Each file's preview is asked for and answered as its own; one being loaded doesn't stand for the other.
    @Test func eachFileHasItsOwnPreview() async throws {
        let provider = HeldProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let first = Receiver()
        let second = Receiver()
        store.load(path: composed, kind: .file, listing: listing) { first.answers.append($0) }
        store.load(path: decomposed, kind: .file, listing: listing) { second.answers.append($0) }
        // Two loads, one for each: the second didn't join the first.
        await pollUntil { provider.paths.count == 2 }
        #expect(provider.paths == [DiskPath(composed), DiskPath(decomposed)])
        #expect(!store.isKept(path: composed) && !store.isKept(path: decomposed))

        // One answers: its file has its picture, and the other is still waiting for its own.
        let one = picture()
        provider.answer(composed, one)
        await pollUntil { first.last != nil }
        #expect(first.last?.image === one.image)
        #expect(second.last == nil)
        #expect(store.isKept(path: composed) && !store.isKept(path: decomposed))
        #expect(store.loadedPicture(forPath: composed)?.image === one.image)
        #expect(store.loadedPicture(forPath: decomposed) == nil)

        let other = picture()
        provider.answer(decomposed, other)
        await pollUntil { second.last != nil }
        #expect(second.last?.image === other.image)
        #expect(store.loadedPicture(forPath: composed)?.image === one.image)
        #expect(store.loadedPicture(forPath: decomposed)?.image === other.image)
        #expect(store.count == 2)

        // One file changed: its preview is checked against the file again, and the other's is not.
        await pollUntil { queue.activeCount == 0 && queue.queuedCount == 0 }
        store.markChanged(["/x/caf\u{E9}.jpeg"])
        store.load(path: decomposed, kind: .file, listing: listing) { _ in }
        store.load(path: composed, kind: .file, listing: listing) { _ in }
        await pollUntil { provider.paths.count == 3 }
        #expect(provider.paths.last == DiskPath(composed))
        provider.answer(composed, one)
        await pollUntil { queue.activeCount == 0 && queue.queuedCount == 0 }
        #expect(provider.paths.count == 3)
    }

    // An item drawn with an icon of its own (a link, a bundle) is asked for and kept by its path.
    @Test func eachItemHasItsOwnIcon() async throws {
        try await withTemporaryDirectory { samples in
            let source = HeldIcons()
            let store = FileIconStore(source: source, samples: IconSamples(root: samples.appending("samples")))
            let first = IconRequest(entry: IconEntry(path: "/x/caf\u{E9}", name: "caf\u{E9}", kind: .symlinkFile))
            let second = IconRequest(
                entry: IconEntry(path: "/x/cafe\u{301}", name: "cafe\u{301}", kind: .symlinkFile))
            #expect(first.cacheKey == second.cacheKey)
            #expect(DiskPath(first.cacheKey) != DiskPath(second.cacheKey))

            var drawn: [NSImage?] = [nil, nil]
            var answered = 0
            store.load(first) {
                drawn[0] = $0
                answered += 1
            }
            store.load(second) {
                drawn[1] = $0
                answered += 1
            }
            // The first is still being drawn, and the second is asked for all the same: it didn't join the first.
            await pollUntil { source.paths.count == 2 }
            #expect(source.paths == [DiskPath("/x/caf\u{E9}"), DiskPath("/x/cafe\u{301}")])
            source.letFirstAnswer()
            await pollUntil { answered == 2 }
            #expect(drawn[0] != nil && drawn[0] === source.image(for: "/x/caf\u{E9}"))
            #expect(drawn[1] != nil && drawn[1] === source.image(for: "/x/cafe\u{301}"))
            #expect(drawn[0] !== drawn[1])
            #expect(store.cachedCount == 2)

            // Kept apart, and forgotten apart.
            guard case .image(let kept) = store.lookup(second) else {
                Issue.record("the second item's icon isn't kept")
                return
            }
            #expect(kept === drawn[1])
            store.forget(first)
            #expect(store.cachedCount == 1)
            guard case .missing = store.lookup(first), case .image = store.lookup(second) else {
                Issue.record("forgetting one item's icon should keep the other's")
                return
            }
        }
    }

    // The folders macOS draws itself are known by their paths' bytes.
    @Test func aFolderNamedLikeASpecialOneButSpelledOtherwiseIsOrdinary() {
        let special = IconCacheKey.specialFolderPaths(homePath: "/Users/jos\u{E9}")
        #expect(special.contains("/Users/jos\u{E9}/Desktop"))
        #expect(!special.contains("/Users/jose\u{301}/Desktop"))
    }
}
