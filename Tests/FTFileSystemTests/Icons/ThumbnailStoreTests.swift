import AppKit
import FTTestSupport
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

/// A provider whose calls the test answers one size at a time, in any order.
private final class SizedProvider: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<ThumbnailResponse, Never>] = [:]

    var waitingSizes: Set<Int> { lock.withLock { Set(waiting.keys) } }

    func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting[size] = continuation }
        }
    }

    func release(size: Int, _ response: ThumbnailResponse) {
        let continuation = lock.withLock { waiting.removeValue(forKey: size) }
        continuation?.resume(returning: response)
    }
}

private func picture(opaque: Bool = true, side: Int = 4) -> ThumbnailPicture {
    ThumbnailPicture(image: NSImage(size: NSSize(width: side, height: side)), isOpaque: opaque)
}

/// Waits until every load asked for has finished.
@MainActor
private func idle(_ queue: ThumbnailLoadQueue, sourceLocation: SourceLocation = #_sourceLocation) async {
    await pollUntil(sourceLocation: sourceLocation) { queue.activeCount == 0 && queue.queuedCount == 0 }
}

private final class Listing {}

/// One turn of the main loop: what was put on the main queue before has run.
private func mainLoopTurn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

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
    // Icons up to 64 points take 128-pixel previews; larger ones 256.
    @Test func largerIconsAskForLargerPreviews() {
        #expect(ThumbnailStore.pixelSize(forIconSize: 32) == 128)
        #expect(ThumbnailStore.pixelSize(forIconSize: 64) == 128)
        #expect(ThumbnailStore.pixelSize(forIconSize: 72) == 256)
        #expect(ThumbnailStore.pixelSize(forIconSize: 128) == 256)
    }

    // The Previews view asks for its size in the screen's pixels, in steps of 256, at most the screen's longer side.
    @Test func previewsAskForTheirSizeInTheScreensPixelsUpToTheScreen() {
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 100, limit: 5120) == 256)
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 240, limit: 5120) == 512)
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 300, limit: 5120) == 768)
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 2400, limit: 5120) == 4864)
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 3000, limit: 5120) == 5120)
        #expect(ThumbnailStore.pixelSize(forPreviewSize: 900, scale: 1, limit: 1920) == 1024)
    }

    // A store with a memory limit drops the least recently used previews once those it keeps would take more; one
    // without keeps as many as it may count.
    @Test func aMemoryLimitDropsTheOldestPreviewsFirst() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1", unchanged: false, picture: picture()) }
        let queue = ThumbnailLoadQueue()
        // Room for two pictures of 4 by 4 pixels (64 bytes each) and not three.
        let store = ThumbnailStore(provider: provider, queue: queue, memoryLimit: 2 * 4 * 4 * 4 + 1)
        let listing = Listing()
        for name in ["a", "b", "c"] {
            _ = store.load(path: "/\(name).png", kind: .file, size: 512, listing: listing) { _ in }
            await idle(queue)
        }
        #expect(store.count == 2)
        #expect(store.memoryUsed == 2 * 4 * 4 * 4)
        #expect(store.loadedPicture(forPath: "/a.png") == nil)
        #expect(store.loadedPicture(forPath: "/c.png") != nil)
        store.reset()
        #expect(store.memoryUsed == 0)
    }

    // A preview counts the bytes of its picture's rows, as its picture has them.
    @Test func aPreviewCountsTheBytesOfItsPicture() async throws {
        let image = try #require(
            CGContext(
                data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )?.makeImage())
        let made = ThumbnailPicture(cgImage: image, isOpaque: false)
        #expect(made.bytes == image.bytesPerRow * 20)
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1", unchanged: false, picture: made) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue, memoryLimit: 1 << 20)
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: Listing()) { _ in }
        await idle(queue)
        #expect(store.memoryUsed == image.bytesPerRow * 20)
    }

    // The Previews view's previews may take 1 GB, or a sixteenth of a Mac's memory when that is less.
    @Test func previewsMayTakeAGigabyteOrASixteenthOfTheMacsMemory() {
        let gigabyte = 1 << 30
        #expect(ThumbnailStore.previewMemoryLimit(physicalMemory: 128 << 30) == gigabyte)
        #expect(ThumbnailStore.previewMemoryLimit(physicalMemory: 16 << 30) == gigabyte)
        #expect(ThumbnailStore.previewMemoryLimit(physicalMemory: 8 << 30) == gigabyte / 2)
    }

    // Short of memory, every preview kept goes at once; a load under way still answers.
    @Test func memoryPressureLetsGoOfEveryPreview() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1", unchanged: false, picture: picture()) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue, memoryLimit: 1 << 20)
        let listing = Listing()
        for name in ["a", "b"] {
            _ = store.load(path: "/\(name).png", kind: .file, size: 512, listing: listing) { _ in }
        }
        await idle(queue)
        #expect(store.count == 2 && store.memoryUsed > 0)
        store.dropCached()
        #expect(store.count == 0 && store.memoryUsed == 0)
        let receiver = Receiver()
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: listing) { receiver.answers.append($0) }
        await idle(queue)
        #expect(receiver.last != nil && store.count == 1)
    }

    // A preview made again at a larger size takes the smaller one's place in the count of memory too.
    @Test func aLargerPreviewOfTheSameFileCountsOnce() async {
        let provider = ScriptedProvider { call in
            ThumbnailResponse(version: "1", unchanged: false, picture: picture(side: call.size == 256 ? 4 : 8))
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue, memoryLimit: 1 << 20)
        let listing = Listing()
        _ = store.load(path: "/a.png", kind: .file, size: 256, listing: listing) { _ in }
        await idle(queue)
        #expect(store.memoryUsed == 4 * 4 * 4)
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: listing) { _ in }
        await idle(queue)
        #expect(store.count == 1)
        #expect(store.memoryUsed == 8 * 8 * 4)
        // Asked for at the smaller size again: the larger one serves, counted once.
        _ = store.load(path: "/a.png", kind: .file, size: 256, listing: listing) { _ in }
        await idle(queue)
        #expect(store.count == 1 && store.memoryUsed == 8 * 8 * 4)
    }

    // One preview can push another out by the count and a second by the memory it takes: what is counted is what
    // is left.
    @Test func theCountAndTheMemoryLimitDropPreviewsTogether() async {
        let provider = ScriptedProvider { call in
            ThumbnailResponse(
                version: "1", unchanged: false, picture: picture(side: call.path == "/large.png" ? 8 : 4))
        }
        let queue = ThumbnailLoadQueue()
        // Two previews at most, and room for a large one (256 bytes) and not a small one (64) beside it.
        let store = ThumbnailStore(provider: provider, queue: queue, maxEntries: 2, memoryLimit: 300)
        let listing = Listing()
        for name in ["a", "b", "large"] {
            _ = store.load(path: "/\(name).png", kind: .file, size: 512, listing: listing) { _ in }
            await idle(queue)
        }
        #expect(store.count == 1)
        #expect(store.memoryUsed == 8 * 8 * 4)
        #expect(store.loadedPicture(forPath: "/large.png") != nil)
        // Small ones again: the count alone drops the oldest.
        for name in ["c", "d"] {
            _ = store.load(path: "/\(name).png", kind: .file, size: 512, listing: listing) { _ in }
            await idle(queue)
        }
        #expect(store.count == 2)
        #expect(store.memoryUsed == 2 * 4 * 4 * 4)
        #expect(store.loadedPicture(forPath: "/large.png") == nil)
    }

    // Every preview let go while one is being checked against its file, which is as it was: the check gives the
    // picture it began with, kept and counted again, once.
    @Test func aCheckUnderWayWhenThePreviewsAreLetGoKeepsItsPicture() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue, memoryLimit: 1 << 20)
        let first = picture()
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: Listing()) { _ in }
        await pollUntil { provider.calls.count == 1 }
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: first))
        await idle(queue)
        #expect(store.memoryUsed == 4 * 4 * 4)
        // Another reading of the folder checks it again.
        let receiver = Receiver()
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: Listing()) { receiver.answers.append($0) }
        await pollUntil { provider.calls.count == 2 }
        #expect(provider.calls.last?.knownVersion == "1")
        store.dropCached()
        #expect(store.count == 0 && store.memoryUsed == 0)
        provider.release(ThumbnailResponse(version: "1", unchanged: true, picture: nil))
        await idle(queue)
        #expect(receiver.last?.image === first.image)
        #expect(store.count == 1 && store.memoryUsed == 4 * 4 * 4)
        #expect(store.loadedPicture(forPath: "/a.png")?.image === first.image)
    }

    // A preview cached too small is given at once and made again at the larger size, the file being as it was; one
    // cached large enough serves a smaller size without asking again.
    @Test func aPreviewTooSmallIsMadeAgainAtTheLargerSize() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "10:20", unchanged: false, picture: picture())
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let path = "/Users/demo/photo.jpeg"
        _ = store.load(path: path, kind: .file, size: 128, listing: listing) { _ in }
        await idle(queue)
        let larger = Receiver()
        _ = store.load(path: path, kind: .file, size: 256, listing: listing) { larger.answers.append($0) }
        #expect(larger.answers.count == 1 && larger.last != nil)
        await idle(queue)
        #expect(
            provider.calls == [
                ScriptedProvider.Call(path: path, size: 128, knownVersion: nil),
                ScriptedProvider.Call(path: path, size: 256, knownVersion: nil),
            ])
        _ = store.load(path: path, kind: .file, size: 128, listing: listing) { _ in }
        await idle(queue)
        #expect(provider.calls.count == 2)
    }

    // No picture comes at the larger size of a file that is as it was: the smaller one stays, and is not asked for
    // again at that size.
    @Test func aLargerSizeWithNoPictureKeepsTheSmallerPreview() async {
        let provider = ScriptedProvider { call in
            ThumbnailResponse(version: "10:20", unchanged: false, picture: call.size > 128 ? nil : picture())
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let path = "/Users/demo/photo.jpeg"
        _ = store.load(path: path, kind: .file, size: 128, listing: listing) { _ in }
        await idle(queue)
        let larger = Receiver()
        _ = store.load(path: path, kind: .file, size: 4096, listing: listing) { larger.answers.append($0) }
        await idle(queue)
        #expect(larger.answers.count == 2 && larger.last != nil)
        #expect(store.loadedPicture(forPath: path) != nil)
        _ = store.load(path: path, kind: .file, size: 4096, listing: listing) { _ in }
        await idle(queue)
        #expect(provider.calls.count == 2)
    }

    // The Previews view filling a large screen got no picture; with more, smaller previews in the pane the file is
    // asked for again and shows. No picture at a small size is not asked for again at a larger one.
    @Test func aFileWithNoPictureAtALargeSizeIsAskedForAgainAtASmallerOne() async {
        let provider = ScriptedProvider { call in
            ThumbnailResponse(version: "10:20", unchanged: false, picture: call.size > 1024 ? nil : picture())
        }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let path = "/Users/demo/clip.mov"
        _ = store.load(path: path, kind: .file, size: 4096, listing: listing) { _ in }
        await idle(queue)
        #expect(store.loadedPicture(forPath: path) == nil)
        let smaller = Receiver()
        _ = store.load(path: path, kind: .file, size: 768, listing: listing) { smaller.answers.append($0) }
        await idle(queue)
        #expect(smaller.answers.count == 2 && smaller.last != nil)
        #expect(provider.calls.map(\.size) == [4096, 768])

        let none = ScriptedProvider { _ in ThumbnailResponse(version: "10:20", unchanged: false, picture: nil) }
        let other = ThumbnailStore(provider: none, queue: queue)
        _ = other.load(path: path, kind: .file, size: 256, listing: listing) { _ in }
        await idle(queue)
        _ = other.load(path: path, kind: .file, size: 4096, listing: listing) { _ in }
        await idle(queue)
        #expect(none.calls.map(\.size) == [256])
    }

    // Two loads of one file at different sizes, the larger ending first: the smaller one's picture never takes the
    // larger one's place.
    @Test func neverReplacesALargerPreviewWithASmallerOne() async {
        let provider = SizedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let path = "/Users/demo/photo.jpeg"
        let small = Receiver()
        _ = store.load(path: path, kind: .file, size: 128, listing: listing) { small.answers.append($0) }
        _ = store.load(path: path, kind: .file, size: 256, listing: listing) { _ in }
        await pollUntil { provider.waitingSizes == [128, 256] }
        let large = picture()
        provider.release(size: 256, ThumbnailResponse(version: "10:20", unchanged: false, picture: large))
        await pollUntil { provider.waitingSizes == [128] && store.loadedPicture(forPath: path) != nil }
        provider.release(size: 128, ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(store.loadedPicture(forPath: path)?.image === large.image)
        // The smaller load is given the larger picture, and nothing is asked again at 256.
        #expect(small.last?.image === large.image)
        let again = Receiver()
        _ = store.load(path: path, kind: .file, size: 256, listing: listing) { again.answers.append($0) }
        #expect(again.answers.count == 1 && again.last?.image === large.image)
        #expect(provider.waitingSizes.isEmpty)
    }

    @Test func givesNothingUntilThePreviewArrivesThenThePreview() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let receiver = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: receiver)
        await pollUntil { provider.calls.count == 1 }

        #expect(provider.calls == [.init(path: "/Users/demo/photo.jpeg", size: 128, knownVersion: nil)])
        // The icon stays until the preview arrives.
        #expect(receiver.answers.count == 1 && receiver.last == nil)

        let delivered = picture()
        provider.release(ThumbnailResponse(version: "10:20", unchanged: false, picture: delivered))
        await idle(queue)
        #expect(receiver.last?.image === delivered.image)
    }

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
        // An opaque picture gets an outline; the other is a cut-out or a page
        // drawn with its own outline.
        #expect(photo.last?.isOpaque == true)
        #expect(page.last?.isOpaque == false)
    }

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

    @Test func loadsAFewPreviewsAtATimeAndDropsQueuedOnesThatAreNoLongerShown() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        let names = (0..<6).map { "/Users/demo/photo-\($0).jpeg" }
        let handles = names.map { request(store, $0, listing: listing, into: receiver) }
        await pollUntil { provider.calls.count == 4 }
        #expect(provider.calls.count == 4)

        // The last item scrolls away before its turn; the fifth takes the next free slot.
        handles[5].cancel()
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await pollUntil { provider.calls.count == 5 }
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
        await pollUntil { provider.calls.count == 1 }
        handle.cancel()
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(receiver.answers.count == 1)
        #expect(store.loadedPicture(forPath: "/Users/demo/photo.jpeg") != nil)
    }

    // A load scrolled past once it started stops after the step under way and frees its place, so the next one starts;
    // it keeps nothing, and the file asked for again gets its preview.
    @Test func aLoadTakenBackOnceStartedStopsAndLetsTheNextOneStart() async {
        let renderer = SteppedRenderer(steps: 3)
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let store = ThumbnailStore(
            provider: FileThumbnailService(renderer: renderer, version: { _ in "1:1" }), queue: queue)
        let listing = Listing()
        let passed = Receiver()
        let shown = Receiver()
        let handle = request(store, "/a.mov", listing: listing, into: passed)
        _ = request(store, "/b.mov", listing: listing, into: shown)
        await pollUntil { renderer.waiting == 1 }
        #expect(renderer.started == ["/a.mov"])
        handle.cancel()
        // It is told to stop once the main loop turns, in case its file is asked for again at once.
        await mainLoopTurn()
        renderer.step()
        await pollUntil { renderer.started.count == 2 }
        #expect(renderer.started == ["/a.mov", "/b.mov"])
        #expect(renderer.stopped == ["/a.mov"])
        #expect(queue.activeCount == 1 && queue.queuedCount == 0)
        func finish() async {
            for _ in 0..<3 {
                await pollUntil { renderer.waiting == 1 }
                renderer.step()
            }
            await idle(queue)
        }
        await finish()
        #expect(shown.last != nil)
        #expect(passed.answers.count == 1 && passed.last == nil)
        #expect(store.loadedPicture(forPath: "/a.mov") == nil)

        let back = Receiver()
        _ = request(store, "/a.mov", listing: listing, into: back)
        await finish()
        #expect(renderer.started == ["/a.mov", "/b.mov", "/a.mov"])
        #expect(back.last != nil)
        #expect(store.loadedPicture(forPath: "/a.mov") != nil)
    }

    // A pane that shows its items again (its folder read again while a download adds files to it, a step of a window
    // being resized) takes every request back and makes it again at once, for a new listing: the load under way goes
    // on and answers it, where it was stopped, its picture thrown away, and begun again each time, so a preview slow
    // to make never came while the folder kept changing. The file is then checked for the new listing.
    @Test func aLoadUnderWayAnswersTheSameFileAskedForAgainForANewListing() async {
        let renderer = SteppedRenderer(steps: 2)
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let store = ThumbnailStore(
            provider: FileThumbnailService(renderer: renderer, version: { _ in "1:1" }), queue: queue)
        var handle = request(store, "/a.mov", listing: Listing(), into: Receiver())
        await pollUntil { renderer.waiting == 1 }
        var last = Receiver()
        // The folder is read again three times while the first step is under way.
        for _ in 0..<3 {
            handle.cancel()
            last = Receiver()
            handle = request(store, "/a.mov", listing: Listing(), into: last)
            await mainLoopTurn()
        }
        #expect(renderer.stopped.isEmpty)
        renderer.step()
        await pollUntil { renderer.waiting == 1 }
        renderer.step()
        await idle(queue)
        // Made once, never stopped, and given to the request that still waits.
        #expect(renderer.started == ["/a.mov"])
        #expect(renderer.stopped.isEmpty)
        #expect(last.last != nil)
        #expect(store.loadedPicture(forPath: "/a.mov") != nil)
        withExtendedLifetime(handle) {}
    }

    // The same of a preview asked for ahead of need: the next page's load goes on when the folder is read again.
    @Test func aLoadAheadUnderWayAnswersTheSameFileAskedForAheadForANewListing() async {
        let renderer = SteppedRenderer(steps: 2)
        let queue = ThumbnailLoadQueue(maxConcurrent: 2)
        let store = ThumbnailStore(
            provider: FileThumbnailService(renderer: renderer, version: { _ in "1:1" }), queue: queue)
        var handle = store.prefetch(path: "/a.mov", kind: .file, size: 256, listing: Listing())
        await pollUntil { renderer.waiting == 1 }
        for _ in 0..<3 {
            // The pane asks again for the folder as it is now, then takes the earlier request back.
            let again = store.prefetch(path: "/a.mov", kind: .file, size: 256, listing: Listing())
            handle.cancel()
            handle = again
            await mainLoopTurn()
        }
        renderer.step()
        await pollUntil { renderer.waiting == 1 }
        renderer.step()
        await idle(queue)
        #expect(renderer.started == ["/a.mov"])
        #expect(renderer.stopped.isEmpty)
        #expect(store.loadedPicture(forPath: "/a.mov") != nil)
        withExtendedLifetime(handle) {}
    }

    // What was taken back and not asked for again does stop, a turn of the main loop later.
    @Test func aLoadTakenBackAndNotAskedForAgainStopsOnceTheMainLoopTurns() async {
        let renderer = SteppedRenderer(steps: 2)
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let store = ThumbnailStore(
            provider: FileThumbnailService(renderer: renderer, version: { _ in "1:1" }), queue: queue)
        let handle = request(store, "/a.mov", listing: Listing(), into: Receiver())
        await pollUntil { renderer.waiting == 1 }
        handle.cancel()
        await mainLoopTurn()
        renderer.step()
        await idle(queue)
        #expect(renderer.stopped == ["/a.mov"])
        #expect(store.loadedPicture(forPath: "/a.mov") == nil)
    }

    // A file changed while its preview was being made is not answered by that load for a later listing: it is read
    // again.
    @Test func aLoadOfAFileSinceChangedDoesntAnswerALaterListing() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let store = ThumbnailStore(provider: provider, queue: queue)
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: Receiver())
        await pollUntil { provider.calls.count == 1 }
        store.markChanged(["/Users/demo/photo.jpeg"])
        let later = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: Listing(), into: later)
        // A load of its own waits its turn, rather than this request waiting on the first.
        #expect(queue.queuedCount == 1)
        provider.release(ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()))
        await pollUntil { provider.calls.count == 2 }
        await pollUntil { queue.queuedCount == 0 && queue.activeCount == 1 }
        provider.release(ThumbnailResponse(version: "2:2", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(later.last != nil)
    }

    // A file on a disk that stopped answering never comes back from being read, whatever it is told: a while after it
    // was told to stop its place goes to the next preview, so a few such files don't keep every folder's previews
    // waiting. Its work, when it does return, takes nothing back.
    @Test func aLoadToldToStopThatDoesntReturnGivesUpItsPlace() async {
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        queue.abandonAfter = 0.05
        let hung = DispatchSemaphore(value: 0)
        let started = Receiver()
        let handle = queue.enqueue {
            started.answers.append(nil)
            // Deaf to its task being cancelled, as a read of the disk is.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    hung.wait()
                    continuation.resume()
                }
            }
        }
        var ran = false
        queue.enqueue { ran = true }
        await pollUntil { started.answers.count == 1 }
        #expect(!ran && queue.activeCount == 1 && queue.queuedCount == 1)
        handle.cancel()
        await pollUntil { ran }
        #expect(queue.abandonedCount == 1)
        await pollUntil { queue.activeCount == 0 }
        // The disk gives up at last: nothing is counted twice.
        hung.signal()
        await pollUntil { queue.abandonedCount == 0 }
        #expect(queue.activeCount == 0 && queue.queuedCount == 0)
        var again = false
        queue.enqueue { again = true }
        await pollUntil { again }
    }

    // An edit changes nothing a listing shows: a file named as changed is checked again in the same listing, and gets
    // its new preview. One not named is not asked again.
    @Test func aFileNamedAsChangedIsCheckedAgainInTheSameListing() async {
        let responses = ResponseQueue([
            ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()),
            ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()),
            ThumbnailResponse(version: "11:20", unchanged: false, picture: picture()),
        ])
        let provider = ScriptedProvider { _ in responses.next() }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let edited = Receiver()
        let other = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: edited)
        _ = request(store, "/Users/demo/other.jpeg", listing: listing, into: other)
        await idle(queue)
        let original = edited.last

        store.markChanged(["/Users/demo/photo.jpeg"])
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: edited)
        _ = request(store, "/Users/demo/other.jpeg", listing: listing, into: other)
        // The picture kept shows until the new one comes.
        #expect(edited.last?.image === original?.image)
        await idle(queue)
        #expect(provider.calls.count == 3)
        #expect(provider.calls[2] == .init(path: "/Users/demo/photo.jpeg", size: 128, knownVersion: "10:20"))
        #expect(edited.last != nil && edited.last?.image !== original?.image)

        // Checked once: asked again in the same listing, it is not checked again.
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: edited)
        await idle(queue)
        #expect(provider.calls.count == 3)
    }

    // A file named as changed that is as it was is only looked at: Quick Look is not asked for its picture again.
    @Test func aFileNamedAsChangedThatIsAsItWasIsNotDrawnAgain() async {
        let renderer = CountingRenderer()
        let store = ThumbnailStore(
            provider: FileThumbnailService(renderer: renderer, version: { _ in "10:20" }), queue: ThumbnailLoadQueue())
        let listing = Listing()
        let receiver = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: receiver)
        await pollUntil { receiver.last != nil }
        let original = receiver.last

        store.markChanged(["/Users/demo/photo.jpeg"])
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: receiver)
        await pollUntil { receiver.answers.count == 3 }
        #expect(receiver.last?.image === original?.image)
        #expect(renderer.count == 1)
    }

    // Changes not named one by one (events lost, too many at once) have every preview checked again.
    @Test func anyFileMayHaveChangedChecksEveryPreviewAgain() async {
        let provider = ScriptedProvider { _ in ThumbnailResponse(version: "1:1", unchanged: false, picture: picture()) }
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        let paths = ["/Users/demo/a.png", "/Users/demo/b.png"]
        for path in paths { _ = request(store, path, listing: listing, into: receiver) }
        await idle(queue)

        store.markChanged(nil)
        for path in paths { _ = request(store, path, listing: listing, into: receiver) }
        await idle(queue)
        #expect(provider.calls.count == 4)
        #expect(provider.calls.suffix(2).allSatisfy { $0.knownVersion == "1:1" })
    }

    // A file named as changed while its preview was being made may have changed after it was read: the preview is
    // given, and checked again the next time it is asked for.
    @Test func aLoadUnderWayWhenItsFileChangesIsCheckedAgain() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let receiver = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: receiver)
        await pollUntil { provider.calls.count == 1 }
        store.markChanged(["/Users/demo/photo.jpeg"])
        provider.release(ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(receiver.last != nil)

        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: receiver)
        await pollUntil { provider.calls.count == 2 }
        #expect(provider.calls[1].knownVersion == "10:20")
        provider.release(ThumbnailResponse(version: "10:20", unchanged: true, picture: nil))
        await idle(queue)
    }

    // Of two loads of one file, the one asked for later read the file later: the earlier one ending last never puts
    // its older picture in its place.
    @Test func anEarlierLoadEndingLastNeverReplacesALaterOne() async {
        let provider = OrderedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let first = Receiver()
        let second = Receiver()
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: first)
        await pollUntil { provider.waitingCount == 1 }
        store.markChanged(["/Users/demo/photo.jpeg"])
        _ = request(store, "/Users/demo/photo.jpeg", listing: listing, into: second)
        await pollUntil { provider.waitingCount == 2 }

        let newer = picture()
        provider.release(1, ThumbnailResponse(version: "11:20", unchanged: false, picture: newer))
        await pollUntil { second.last != nil }
        provider.release(0, ThumbnailResponse(version: "10:20", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(store.loadedPicture(forPath: "/Users/demo/photo.jpeg")?.image === newer.image)
        #expect(first.last?.image === newer.image)
    }

    // MARK: Loads shared, and asked for ahead of need

    // A second request for a file being loaded, at no larger size and for the same reading of the folder, waits for
    // that load: Quick Look is asked once, and both are answered. One at a larger size asks again.
    @Test func aRequestForAFileBeingLoadedWaitsForThatLoad() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue()
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        let first = Receiver()
        let second = Receiver()
        _ = store.load(path: "/a.png", kind: .file, size: 512, listing: listing) { first.answers.append($0) }
        _ = store.load(path: "/a.png", kind: .file, size: 256, listing: listing) { second.answers.append($0) }
        await pollUntil { provider.calls.count == 1 }
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(provider.calls.count == 1)
        #expect(first.last != nil && second.last?.image === first.last?.image)

        _ = store.load(path: "/b.png", kind: .file, size: 256, listing: listing) { _ in }
        _ = store.load(path: "/b.png", kind: .file, size: 512, listing: listing) { _ in }
        await pollUntil { provider.calls.count == 3 }
        // The two run at once, in no fixed order.
        #expect(provider.calls.suffix(2).map(\.size).sorted() == [256, 512])
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
    }

    // A load several wait for stays in the queue until the last of them takes its request back.
    @Test func aSharedLoadLeavesTheQueueOnceNoOneWaitsForIt() async {
        let provider = ScriptedProvider()
        // One load at a time: the second file's waits in the queue.
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        _ = store.load(path: "/a.png", kind: .file, size: 256, listing: listing) { _ in }
        let shown = Receiver()
        let one = store.load(path: "/b.png", kind: .file, size: 256, listing: listing) { _ in }
        _ = store.load(path: "/b.png", kind: .file, size: 256, listing: listing) { shown.answers.append($0) }
        await pollUntil { provider.calls.count == 1 }
        #expect(queue.queuedCount == 1)
        one.cancel()
        #expect(queue.queuedCount == 1)
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await pollUntil { provider.calls.count == 2 }
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(shown.last != nil)

        _ = store.load(path: "/c.png", kind: .file, size: 256, listing: listing) { _ in }
        let first = store.load(path: "/d.png", kind: .file, size: 256, listing: listing) { _ in }
        let second = store.load(path: "/d.png", kind: .file, size: 256, listing: listing) { _ in }
        await pollUntil { provider.calls.count == 3 }
        first.cancel()
        second.cancel()
        #expect(queue.queuedCount == 0)
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(provider.calls.count == 3)
        // Taken back before it started, it is asked for anew.
        _ = store.load(path: "/d.png", kind: .file, size: 256, listing: listing) { _ in }
        await pollUntil { provider.calls.count == 4 }
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
    }

    // Previews asked for ahead of need wait behind every one wanted now and leave a load free for one, and the
    // preview is kept for when it is wanted; one wanted now while it waits moves up and is not asked again.
    @Test func aPrefetchWaitsBehindPreviewsWantedNow() async {
        let provider = ScriptedProvider()
        let queue = ThumbnailLoadQueue(maxConcurrent: 2)
        let store = ThumbnailStore(provider: provider, queue: queue)
        let listing = Listing()
        for name in ["n1", "n2", "n3"] {
            store.prefetch(path: "/\(name).png", kind: .file, size: 256, listing: listing)
        }
        // One load is left free: one of those ahead of need starts.
        await pollUntil { provider.calls.count == 1 }
        #expect(queue.activeCount == 1 && queue.queuedAheadCount == 2)
        let now = Receiver()
        _ = store.load(path: "/shown.png", kind: .file, size: 256, listing: listing) { now.answers.append($0) }
        await pollUntil { provider.calls.count == 2 }
        #expect(provider.calls.map(\.path) == ["/n1.png", "/shown.png"])
        // The third one ahead of need is wanted now: it goes before the second.
        let wanted = Receiver()
        _ = store.load(path: "/n3.png", kind: .file, size: 256, listing: listing) { wanted.answers.append($0) }
        #expect(queue.queuedAheadCount == 1 && queue.queuedCount == 2)
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await pollUntil { provider.calls.count == 3 }
        #expect(provider.calls.last?.path == "/n3.png")
        // The second one ahead of need starts once nothing else runs.
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await pollUntil { provider.calls.count == 4 }
        await pollUntil { queue.activeCount == 1 && queue.queuedCount == 0 }
        provider.release(ThumbnailResponse(version: "1", unchanged: false, picture: picture()))
        await idle(queue)
        #expect(provider.calls.map(\.path).sorted() == ["/n1.png", "/n2.png", "/n3.png", "/shown.png"])
        #expect(now.last != nil && wanted.last != nil)
        // What was asked for ahead of need is given at once and not asked again.
        let later = Receiver()
        _ = store.load(path: "/n2.png", kind: .file, size: 256, listing: listing) { later.answers.append($0) }
        #expect(later.answers.count == 1 && later.last != nil)
        #expect(provider.calls.count == 4)
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

/// A renderer that makes each picture in `steps` steps, each waiting for the test, and stops after a step once its task
/// is cancelled.
private final class SteppedRenderer: ThumbnailRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var startedPaths: [String] = []
    private var stoppedPaths: [String] = []
    private let steps: Int

    init(steps: Int) {
        self.steps = steps
    }

    var waiting: Int { lock.withLock { continuations.count } }
    var started: [String] { lock.withLock { startedPaths } }
    var stopped: [String] { lock.withLock { stoppedPaths } }

    func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture? {
        lock.withLock { startedPaths.append(path) }
        for _ in 0..<steps {
            await withCheckedContinuation { continuation in
                lock.withLock { continuations.append(continuation) }
            }
            if Task.isCancelled {
                lock.withLock { stoppedPaths.append(path) }
                return nil
            }
        }
        return picture()
    }

    /// Lets the steps waiting go on.
    func step() {
        let going = lock.withLock {
            let going = continuations
            continuations = []
            return going
        }
        for continuation in going { continuation.resume() }
    }
}

/// A renderer that counts the pictures it is asked for.
private final class CountingRenderer: ThumbnailRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture? {
        lock.withLock { calls += 1 }
        return picture()
    }
}

/// A provider whose calls wait until the test answers each one, by the order they were made in.
private final class OrderedProvider: ThumbnailProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<ThumbnailResponse, Never>] = [:]
    private var made = 0

    var waitingCount: Int { lock.withLock { waiting.count } }

    func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse {
        await withCheckedContinuation { continuation in
            lock.withLock {
                waiting[made] = continuation
                made += 1
            }
        }
    }

    func release(_ index: Int, _ response: ThumbnailResponse) {
        let continuation = lock.withLock { waiting.removeValue(forKey: index) }
        continuation?.resume(returning: response)
    }
}
