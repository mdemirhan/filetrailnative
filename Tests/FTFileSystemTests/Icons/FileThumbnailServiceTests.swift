import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTFileSystem

private final class FakeRenderer: ThumbnailRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let result: ThumbnailPicture?

    init(result: ThumbnailPicture?) {
        self.result = result
    }

    var rendered: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture? {
        lock.withLock { recorded.append("\(path)@\(size)") }
        return result
    }
}

private func service(_ renderer: FakeRenderer, version: String?) -> FileThumbnailService {
    FileThumbnailService(renderer: renderer, version: { _ in version })
}

private let sample = ThumbnailPicture(image: NSImage(size: NSSize(width: 1, height: 1)), isOpaque: true)

// F-147 F-226
@Suite struct FileThumbnailServiceTests {
    // T-e57f3c9f
    @Test func returnsThePreviewWithTheFilesVersion() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: "1700:42").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: nil)
        #expect(response.version == "1700:42")
        #expect(!response.unchanged)
        #expect(response.picture?.image === sample.image)
        #expect(renderer.rendered == ["/a/photo.jpeg@128"])
    }

    // T-b9916804
    @Test func passesOnWhetherThePreviewHasTransparency() async {
        let transparent = ThumbnailPicture(image: sample.image, isOpaque: false)
        let response = await service(FakeRenderer(result: transparent), version: "1700:42").response(
            path: "/a/logo.png", size: 128, knownVersion: nil)
        #expect(response.picture?.isOpaque == false)
    }

    // T-b5bd0c66
    @Test func doesNotMakeThePreviewAgainForAVersionTheCallerAlreadyHolds() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: "1700:42").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: "1700:42")
        #expect(response.version == "1700:42" && response.unchanged && response.picture == nil)
        #expect(renderer.rendered.isEmpty)
    }

    // T-b6b84124
    @Test func makesANewPreviewWhenTheFileHasChangedSince() async {
        let response = await service(FakeRenderer(result: sample), version: "1800:50").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: "1700:42")
        #expect(response.version == "1800:50")
        #expect(!response.unchanged)
        #expect(response.picture != nil)
    }

    // T-22414abc T-be9407bf
    @Test func reportsNoPreviewForAFileQuickLookCannotDrawKeepingItsVersion() async {
        let response = await service(FakeRenderer(result: nil), version: "5:10").response(
            path: "/a.bin", size: 64, knownVersion: nil)
        #expect(response.version == "5:10" && !response.unchanged && response.picture == nil)
    }

    // T-7d2e2494 T-be9407bf
    @Test func reportsNothingForAFileThatCannotBeRead() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: nil).response(path: "/a/gone.png", size: 128, knownVersion: nil)
        #expect(response.version == nil && !response.unchanged && response.picture == nil)
        #expect(renderer.rendered.isEmpty)
    }

    // F-226
    @Test func theVersionIsTheModificationTimeInMillisecondsAndTheSize() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending("a.txt")
            try Data("hello".utf8).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1700)], ofItemAtPath: file.path)
            #expect(FileThumbnailService.fileVersion(ofPath: file.path) == "1700000:5")

            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1700.5)], ofItemAtPath: file.path)
            #expect(FileThumbnailService.fileVersion(ofPath: file.path) == "1700500:5")
            #expect(FileThumbnailService.fileVersion(ofPath: directory.appending("missing").path) == nil)
        }
    }

    @Test func numbersAreWrittenTheWayJavaScriptWritesThem() {
        #expect(FileThumbnailService.javaScriptNumber(1700) == "1700")
        #expect(FileThumbnailService.javaScriptNumber(0) == "0")
        #expect(FileThumbnailService.javaScriptNumber(1700.25) == "1700.25")
    }
}

// F-157
@Suite struct QuickLookThumbnailTests {
    /// A one-pixel PNG.
    static let png = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

    // T-8b85b255
    @Test func returnsAPictureOfAnImageFile() async throws {
        let png = try #require(Self.png)
        try await withTemporaryDirectory { directory in
            let file = directory.appending("pixel.png")
            try png.write(to: file)
            let picture = await QuickLookThumbnailRenderer().renderThumbnail(path: file.path, size: 128)
            let image = try #require(picture?.image)
            #expect(image.size.width > 0 && image.size.height > 0)
        }
    }

    // T-96f815d3
    @Test func givesNothingForAFolderAndForAFileThatDoesNotExist() async throws {
        try await withTemporaryDirectory { directory in
            #expect(await QuickLookThumbnailRenderer().renderThumbnail(path: directory.path, size: 128) == nil)
            #expect(
                await QuickLookThumbnailRenderer().renderThumbnail(
                    path: directory.appending("missing.png").path, size: 128)
                    == nil)
        }
    }

    // T-be9407bf
    @Test func theRealServiceReportsNothingForAGoneFile() async throws {
        try await withTemporaryDirectory { directory in
            let response = await FileThumbnailService().response(
                path: directory.appending("gone.png").path, size: 64, knownVersion: nil)
            #expect(response.version == nil && !response.unchanged && response.picture == nil)
        }
    }

    @Test func picturesAndVideosShowTheirContentAndOtherFilesTheirIcon() throws {
        try withTemporaryDirectory { directory in
            let image = directory.appending("a.png")
            let text = directory.appending("a.txt")
            let movie = directory.appending("a.mov")
            let link = directory.appending("link")
            for file in [image, text, movie] { try Data().write(to: file) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
            #expect(QuickLookThumbnailRenderer.showsPicture(image))
            #expect(QuickLookThumbnailRenderer.showsPicture(movie))
            #expect(!QuickLookThumbnailRenderer.showsPicture(text))
            // A symlink counts as what it points to.
            #expect(QuickLookThumbnailRenderer.showsPicture(link))
            #expect(!QuickLookThumbnailRenderer.showsPicture(directory.url))
        }
    }

    @Test func tellsAnOpaquePictureFromOneWithTransparency() throws {
        func image(alpha: CGImageAlphaInfo, clear: Bool) throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            if clear { context.clear(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            return try #require(context.makeImage())
        }
        #expect(QuickLookThumbnailRenderer.isOpaque(try image(alpha: .noneSkipLast, clear: false)))
        #expect(QuickLookThumbnailRenderer.isOpaque(try image(alpha: .premultipliedLast, clear: false)))
        #expect(!QuickLookThumbnailRenderer.isOpaque(try image(alpha: .premultipliedLast, clear: true)))
    }
}

@MainActor @Suite struct ThumbnailLoadQueueTests {
    @Test func startsFourAtATimeAndStartsTheNextWhenOneEnds() async {
        let queue = ThumbnailLoadQueue()
        let gate = Gate()
        let started = Counter()
        for _ in 0..<6 {
            queue.enqueue {
                started.count += 1
                await gate.wait()
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(started.count == 4 && queue.activeCount == 4 && queue.queuedCount == 2)
        gate.open()
        for _ in 0..<50 { await Task.yield() }
        #expect(started.count == 6)
    }

    @Test func aHandleTakesAJobOutOfTheQueueOnlyBeforeItStarts() async {
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let gate = Gate()
        let ran = Counter()
        let running = queue.enqueue {
            ran.count += 1
            await gate.wait()
        }
        let dropped = queue.enqueue { ran.count += 100 }
        for _ in 0..<20 { await Task.yield() }
        dropped.cancel()
        running.cancel()  // already started: no effect
        gate.open()
        for _ in 0..<50 { await Task.yield() }
        #expect(ran.count == 1)
        #expect(queue.activeCount == 0 && queue.queuedCount == 0)
    }
}

@MainActor private final class Counter {
    var count = 0
}

@MainActor private final class Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
