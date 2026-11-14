import AppKit
import FTTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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

@Suite struct FileThumbnailServiceTests {
    @Test func returnsThePreviewWithTheFilesVersion() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: "1700:42").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: nil)
        #expect(response.version == "1700:42")
        #expect(!response.unchanged)
        #expect(response.picture?.image === sample.image)
        #expect(renderer.rendered == ["/a/photo.jpeg@128"])
    }

    @Test func passesOnWhetherThePreviewHasTransparency() async {
        let transparent = ThumbnailPicture(image: sample.image, isOpaque: false)
        let response = await service(FakeRenderer(result: transparent), version: "1700:42").response(
            path: "/a/logo.png", size: 128, knownVersion: nil)
        #expect(response.picture?.isOpaque == false)
    }

    @Test func doesNotMakeThePreviewAgainForAVersionTheCallerAlreadyHolds() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: "1700:42").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: "1700:42")
        #expect(response.version == "1700:42" && response.unchanged && response.picture == nil)
        #expect(renderer.rendered.isEmpty)
    }

    @Test func makesANewPreviewWhenTheFileHasChangedSince() async {
        let response = await service(FakeRenderer(result: sample), version: "1800:50").response(
            path: "/a/photo.jpeg", size: 128, knownVersion: "1700:42")
        #expect(response.version == "1800:50")
        #expect(!response.unchanged)
        #expect(response.picture != nil)
    }

    @Test func reportsNoPreviewForAFileQuickLookCannotDrawKeepingItsVersion() async {
        let response = await service(FakeRenderer(result: nil), version: "5:10").response(
            path: "/a.bin", size: 64, knownVersion: nil)
        #expect(response.version == "5:10" && !response.unchanged && response.picture == nil)
    }

    @Test func reportsNothingForAFileThatCannotBeRead() async {
        let renderer = FakeRenderer(result: sample)
        let response = await service(renderer, version: nil).response(path: "/a/gone.png", size: 128, knownVersion: nil)
        #expect(response.version == nil && !response.unchanged && response.picture == nil)
        #expect(renderer.rendered.isEmpty)
    }

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

    @Test func numbersAreWrittenShortestWithNoTrailingPointZero() {
        #expect(FileThumbnailService.javaScriptNumber(1700) == "1700")
        #expect(FileThumbnailService.javaScriptNumber(0) == "0")
        #expect(FileThumbnailService.javaScriptNumber(1700.25) == "1700.25")
    }
}

@Suite struct QuickLookThumbnailTests {
    /// A one-pixel PNG.
    static let png = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

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

    /// A JPEG of `width` by `height` pixels, written to `file`.
    private static func writeJPEG(width: Int, height: Int, to file: URL) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func aLargePhotoHasAPictureAtASizeAsLargeAsAScreen() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending("photo.jpg")
            try Self.writeJPEG(width: 6000, height: 3368, to: file)
            let picture = await QuickLookThumbnailRenderer().renderThumbnail(path: file.path, size: 4096)
            let image = try #require(picture?.image)
            #expect(Int(image.size.width) == 4096)
            #expect(picture?.isOpaque == true)
        }
    }

    @Test func anImageReadWithoutQuickLookFitsTheSizeAndIsNeverMadeLarger() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending("photo.jpg")
            try Self.writeJPEG(width: 600, height: 300, to: file)
            let smaller = try #require(QuickLookThumbnailRenderer.decodedImage(file, side: 256))
            #expect(smaller.width == 256 && smaller.height == 128)
            let whole = try #require(QuickLookThumbnailRenderer.decodedImage(file, side: 4096))
            #expect(whole.width == 600 && whole.height == 300)
            let text = directory.appending("notes.txt")
            try Data("hello".utf8).write(to: text)
            #expect(QuickLookThumbnailRenderer.decodedImage(text, side: 256) == nil)
        }
    }

    /// Quick Look as the search sees it: a file of `width` by `height` whose picture is given when it has at most
    /// `limit` pixels, and every size asked for.
    private final class Budget: @unchecked Sendable {
        let width: Int
        let height: Int
        let limit: Int
        var asked: [Int] = []

        init(width: Int, height: Int, limit: Int = 3_500_000) {
            self.width = width
            self.height = height
            self.limit = limit
        }

        func picture(_ side: Int) -> CGImage? {
            asked.append(side)
            let scale = Double(side) / Double(max(width, height))
            let size = (width: Int(Double(width) * scale), height: Int(Double(height) * scale))
            guard size.width * size.height <= limit else { return nil }
            return CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    @Test func theLargestPictureGivenIsFoundBetweenASizeGivenAndOneRefused() async throws {
        // A 16:9 video: 3.5 million pixels are 2494 across.
        let video = Budget(width: 3840, height: 2160)
        let limits = QuickLookLimits()
        let found = try #require(
            await QuickLookThumbnailRenderer.largestPicture(side: 4096, limits: limits) { video.picture($0) })
        #expect(found.width <= 2494 && found.width > 2494 - QuickLookThumbnailRenderer.searchStep)
        #expect(video.asked == [4096, 1024, 2560, 1792, 2176, 2368, 2464])

        // The next file, of another shape, starts from what that one was given: one request more.
        let square = Budget(width: 3000, height: 3000)
        let next = try #require(
            await QuickLookThumbnailRenderer.largestPicture(side: 4096, limits: limits) { square.picture($0) })
        #expect(next.width <= 1870 && next.width > 1870 - QuickLookThumbnailRenderer.searchStep)
        #expect(square.asked.count == 3)
    }

    @Test func aPictureGivenAtTheSizeAskedForIsNotSearchedFor() async throws {
        let page = Budget(width: 2000, height: 2000, limit: .max)
        let found = try #require(
            await QuickLookThumbnailRenderer.largestPicture(side: 8192, limits: QuickLookLimits()) {
                page.picture($0)
            })
        #expect(found.width == 8192 && page.asked == [8192])
    }

    @Test func aFileWithNoPictureAtAnySizeIsAskedForTwiceAtMost() async {
        let archive = Budget(width: 100, height: 100, limit: 0)
        let limits = QuickLookLimits()
        let large = await QuickLookThumbnailRenderer.largestPicture(side: 4096, limits: limits) { archive.picture($0) }
        #expect(large == nil && archive.asked == [4096, 1024])
        let small = await QuickLookThumbnailRenderer.largestPicture(side: 256, limits: limits) { archive.picture($0) }
        #expect(small == nil && archive.asked == [4096, 1024, 256])
        // Nothing learned from a file with no preview.
        #expect(limits.refused == Int.max)
    }

    @Test func aRefusalBelowASizeGivenIsNotTakenForTheLimit() {
        let limits = QuickLookLimits()
        limits.gave(pixels: 3_000_000)
        limits.refused(pixels: 1_000_000)
        #expect(limits.refused == Int.max)
        limits.refused(pixels: 4_000_000)
        #expect(limits.refused == 4_000_000)
        limits.gave(pixels: 5_000_000)
        #expect(limits.refused == Int.max && limits.given == 5_000_000)
    }

    @Test func anImagesPictureHasThePixelsOfItsSizeFittedAndNeverMoreThanTheImage() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending("photo.jpg")
            try Self.writeJPEG(width: 600, height: 300, to: file)
            #expect(QuickLookThumbnailRenderer.imagePixels(file, side: 200) == 200 * 100)
            #expect(QuickLookThumbnailRenderer.imagePixels(file, side: 4096) == 600 * 300)
            #expect(QuickLookThumbnailRenderer.imagePixels(directory.appending("missing.jpg"), side: 200) == nil)
        }
    }

    @Test func givesNothingForAFolderAndForAFileThatDoesNotExist() async throws {
        try await withTemporaryDirectory { directory in
            #expect(await QuickLookThumbnailRenderer().renderThumbnail(path: directory.path, size: 128) == nil)
            #expect(
                await QuickLookThumbnailRenderer().renderThumbnail(
                    path: directory.appending("missing.png").path, size: 128)
                    == nil)
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

    // A large preview is judged from a small copy of it: opaque all over stays opaque, and a clear corner or a clear
    // edge around a page still shows.
    @Test func judgesALargePictureFromASmallCopy() throws {
        func image(width: Int, height: Int, clear: CGRect?) throws -> CGImage {
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let clear { context.clear(clear) }
            return try #require(context.makeImage())
        }
        #expect(QuickLookThumbnailRenderer.opacitySampleSide == 64)
        #expect(QuickLookThumbnailRenderer.isOpaque(try image(width: 2048, height: 1365, clear: nil)))
        #expect(QuickLookThumbnailRenderer.isOpaque(try image(width: 333, height: 2047, clear: nil)))
        #expect(
            !QuickLookThumbnailRenderer.isOpaque(
                try image(width: 2048, height: 1365, clear: CGRect(x: 0, y: 0, width: 300, height: 300))))
        // A page's clear margin, a hundredth of its width.
        #expect(
            !QuickLookThumbnailRenderer.isOpaque(
                try image(width: 2048, height: 2048, clear: CGRect(x: 0, y: 0, width: 20, height: 2048))))
    }
}

@MainActor @Suite struct ThumbnailLoadQueueTests {
    @Test func aHandleTakesAJobOutOfTheQueueOnlyBeforeItStarts() async {
        let queue = ThumbnailLoadQueue(maxConcurrent: 1)
        let gate = Gate()
        let ran = Counter()
        let running = queue.enqueue {
            ran.count += 1
            await gate.wait()
        }
        let dropped = queue.enqueue { ran.count += 100 }
        await pollUntil { ran.count == 1 }
        dropped.cancel()
        running.cancel()  // already started: no effect
        gate.open()
        await pollUntil { queue.activeCount == 0 && queue.queuedCount == 0 }
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
