import AppKit
import Foundation
import Testing

@testable import FTFileSystem

/// A provider the test answers by hand.
private final class ScriptedProvider: ThumbnailProviding, @unchecked Sendable {
    struct Call: Equatable {
        var path: String
        var size: Int
        var knownVersion: String?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var waiting: [CheckedContinuation<ThumbnailResponse, Never>] = []
    private let respond: (@Sendable (Call) -> ThumbnailResponse)?

    /// With `respond`, answers at once; without, every call waits for `release`.
    init(respond: (@Sendable (Call) -> ThumbnailResponse)? = nil) {
        self.respond = respond
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse {
        let call = Call(path: path, size: size, knownVersion: knownVersion)
        lock.withLock { recorded.append(call) }
        if let respond { return respond(call) }
        return await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
    }

    func release(_ response: ThumbnailResponse) {
        lock.lock()
        let continuations = waiting
        waiting = []
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: response) }
    }
}

private func picture(opaque: Bool = true) -> ThumbnailPicture {
    ThumbnailPicture(image: NSImage(size: NSSize(width: 4, height: 4)), isOpaque: opaque)
}

/// Waits until `condition` holds. The loads run as tasks on the main actor, so how long they take depends
/// on the machine's load: the tests wait for the state they expect, not for a fixed time.
@MainActor
private func wait(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
}

/// Waits until every load asked for has finished.
@MainActor
private func idle(_ queue: ThumbnailLoadQueue) async {
    await wait { queue.activeCount == 0 && queue.queuedCount == 0 }
}

private final class Listing {}

@MainActor
private final class Receiver {
    var answers: [ThumbnailPicture?] = []
    var last: ThumbnailPicture? { answers.last ?? nil }
}

@MainActor
private func request(
    _ store: ThumbnailStore, _ path: String, kind: IconEntryKind = .file, listing: Listing, into receiver: Receiver
) -> LoadHandle {
    store.load(path: path, kind: kind, listing: listing) { receiver.answers.append($0) }
}

@MainActor @Suite struct ThumbnailStoreTests {
    // T-0dec6037 F-227 F-226
    @Test func givesNothingUntilThePreviewArrivesThenThePreview() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let receiver = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await wait { provider.calls.count == 1 }

        #expect(provider.calls == [.init(path: "/Users/demo/photo.jpeg", size: 128, knownVersion: nil)])
        // The icon stays until the preview arrives.
        #expect(receiver.answers.count == 1 && receiver.last == nil)

        let delivered = picture()
        provider.release(ThumbnailResponse(version: "10:20", unchanged: false, picture: delivered))
        await idle(queue)
        #expect(receiver.last?.image === delivered.image)
    }

    // T-116cbc3d
    @Test func keepsTheIconForAFileQuickLookHasNoPreviewFor() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "10:20", unchanged: false, picture: nil) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let receiver = Receiver()
        _ = request(store, "/Users/demo/archive.zip", listing: Listing(), into: receiver)
        await idle(queue)
        #expect(receiver.answers.count == 2)
        #expect(receiver.last == nil)
        #expect(store.loadedPicture(forPath: "/Users/demo/archive.zip") == nil)
    }

    // T-7bbee55b F-762
    @Test func tellsAPhotoFromAPictureWithTransparency() async {
        let provider = ScriptedProvider { call in
            ThumbnailResponse(version: "1:1", unchanged: false, picture: picture(opaque: call.path.hasSuffix(".jpeg")))
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let photo = Receiver()
        let page = Receiver()
        let listing = Listing()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: photo)
        _ = request(store, "/Users/demo/notes.txt", listing: listing, into: page)
        await idle(queue)
        // An opaque picture (JPEG data in the original) gets an outline; the other is a cut-out or a page
        // drawn with its own outline.
        #expect(photo.last?.isOpaque == true)
        #expect(page.last?.isOpaque == false)
    }

    // T-07b0947c
    @Test func asksForPreviewsOfFilesOnly() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        _ = request(store, "/Users/demo/Folder", kind: .directory, listing: listing, into: receiver)
        _ = request(store, "/Users/demo/Tool.app", kind: .bundle, listing: listing, into: receiver)
        _ = request(store, "/Users/demo/alias", kind: .symlinkDirectory, listing: listing, into: receiver)
        _ = request(store, "/Users/demo/other", kind: .other, listing: listing, into: receiver)
        _ = request(store, "/Users/demo/link.png", kind: .symlinkFile, listing: listing, into: receiver)
        await idle(queue)
        #expect(provider.calls.map(\.path) == ["/Users/demo/link.png"])
    }

    // T-60dc09cd F-227
    @Test func givesACachedPreviewAtOnceAndDoesNotAskAgainForTheSameListing() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "10:20", unchanged: false, picture: picture())
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let first = Receiver()
        let handle = request(store, "/Users/demo/photo.jpeg", listing: listing, into: first)
        await idle(queue)
        handle.cancel()

        // Scrolled away and back: the item is shown again while the folder is the same.
        let second = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: second)
        #expect(second.answers.count == 1 && second.last != nil)
        await idle(queue)
        #expect(provider.calls.count == 1)
    }

    // T-ddc3b1bd F-226
    @Test func checksACachedPreviewAgainstTheFileWhenTheFolderIsReadAgain() async {
        let responses = ResponseQueue([
            ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()),
            ThumbnailResponse(version: "10:20", unchanged: true, picture: nil),
            ThumbnailResponse(version: "11:25", unchanged: false, picture: picture()),
        ])
        let provider = ScriptedProvider { _ in responses.next() }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let receiver = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await idle(queue)
        let original = receiver.last

        // Unchanged: the version held is sent along, and the preview stays.
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await idle(queue)
        #expect(provider.calls[1] == .init(path: "/Users/demo/photo.jpeg", size: 128, knownVersion: "10:20"))
        #expect(receiver.last?.image === original?.image)

        // Changed since: the new preview replaces the old one.
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await idle(queue)
        #expect(provider.calls[2].knownVersion == "10:20")
        #expect(receiver.last?.image !== original?.image)
        #expect(store.loadedPicture(forPath: "/Users/demo/photo.jpeg")?.image === receiver.last?.image)
    }

    // T-ab9b358d F-227
    @Test func loadsAFewPreviewsAtATimeAndDropsQueuedOnesThatAreNoLongerShown() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        let names = (0..<6).map { "/Users/demo/photo-\($0).jpeg" }
        let handles = names.map { request(store, $0, listing: listing, into: receiver) }
        await wait { provider.calls.count == 4 }
        #expect(provider.calls.count == 4)

        // The last item scrolls away before its turn; the fifth takes the next free slot.
        handles[5].cancel()
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await wait { provider.calls.count == 5 }
        // The first four start together, in no fixed order; the fifth comes after them.
        #expect(Set(provider.calls.map(\.path)) == Set(names.prefix(5)))
        #expect(provider.calls.count == 5)
        #expect(provider.calls.last?.path == names[4])
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await idle(queue)
    }

    @Test func aCancelledRequestStillRemembersWhatItLoaded() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let receiver = Receiver()
        let handle = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await wait { provider.calls.count == 1 }
        handle.cancel()
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(receiver.answers.count == 1)
        #expect(store.loadedPicture(forPath: "/Users/demo/photo.jpeg") != nil)
    }

    @Test func keepsTheMostRecentlyUsedFiveHundred() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        for index in 0..<(ThumbnailStore.maxEntries + 1) {
            _ = request(store, "/p/\(index).png", listing: listing, into: receiver)
        }
        await idle(queue)
        let paths = (0...ThumbnailStore.maxEntries).map { "/p/\($0).png" }
        #expect(paths.filter { store.loadedPicture(forPath: $0) != nil }.count == ThumbnailStore.maxEntries)
        store.reset()
        #expect(paths.allSatisfy { store.loadedPicture(forPath: $0) == nil })
    }
}

private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [ThumbnailResponse]

    init(_ responses: [ThumbnailResponse]) {
        remaining = responses
    }

    func next() -> ThumbnailResponse {
        lock.lock()
        defer { lock.unlock() }
        return remaining.isEmpty
            ? ThumbnailResponse(version: nil, unchanged: false, picture: nil) : remaining.removeFirst()
    }
}
