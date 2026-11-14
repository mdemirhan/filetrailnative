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

    // A picture no larger than one never refused for its size, refused all the same (Quick Look busy), is read by
    // ImageIO and teaches nothing: the next image is asked of Quick Look again.
    @Test func aRefusalOfASmallPictureIsNotTakenForTheLimit() async throws {
        let limits = QuickLookLimits()
        let decoded = try #require(Budget(width: 256, height: 256, limit: .max).picture(256))
        var asked: [Int] = []
        let image = await QuickLookThumbnailRenderer.imagePicture(
            side: 256, pixels: 256 * 256, limits: limits,
            request: {
                asked.append($0)
                return nil
            }, decode: { decoded })
        #expect(image === decoded)
        #expect(asked == [256])
        #expect(limits.refused == Int.max)
        // At no size: nothing is learned either.
        limits.refused(pixels: QuickLookLimits.alwaysGivenPixels)
        #expect(limits.refused == Int.max)
    }

    // A large picture refused is taken for the limit once Quick Look gives the same file's picture at a size it never
    // refuses; refused there too, the file is one Quick Look does not draw now, and nothing is learned.
    @Test func aRefusalOfALargePictureIsTakenForTheLimitOnlyWhenASmallOneIsGiven() async throws {
        let limits = QuickLookLimits()
        let photo = Budget(width: 4000, height: 3000)
        let decoded = try #require(Budget(width: 4, height: 3, limit: .max).picture(4))
        let pixels = 4096 * 3072
        let unread = await QuickLookThumbnailRenderer.imagePicture(
            side: 4096, pixels: pixels, limits: limits, request: { _ in nil }, decode: { decoded })
        #expect(unread === decoded)
        #expect(limits.refused == Int.max)

        let read = await QuickLookThumbnailRenderer.imagePicture(
            side: 4096, pixels: pixels, limits: limits, request: { photo.picture($0) }, decode: { decoded })
        #expect(read === decoded)
        #expect(photo.asked == [4096, QuickLookThumbnailRenderer.alwaysGivenSide])
        #expect(limits.refused == pixels)
        // The next image as large goes to ImageIO at once.
        let next = await QuickLookThumbnailRenderer.imagePicture(
            side: 4096, pixels: pixels, limits: limits, request: { photo.picture($0) }, decode: { decoded })
        #expect(next === decoded)
        #expect(photo.asked.count == 2)
    }

    /// An image of one color, 400 by 300 pixels, of `bits` a color (floating-point at 32), written to `file`.
    private static func writeDeepImage(
        _ file: URL, type: UTType, bits: Int, space: CGColorSpace, alpha: Bool = true
    ) throws {
        var info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        if bits == 32 {
            info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        } else if bits == 16 {
            info |= CGBitmapInfo.byteOrder16Little.rawValue
        }
        let context = try #require(
            CGContext(
                data: nil, width: 400, height: 300, bitsPerComponent: bits, bytesPerRow: 0, space: space,
                bitmapInfo: info))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// Whether `image` is kept as previews are: 8 bits a color, 4 bytes a pixel, in a color space of the standard range.
    private static func isKept(_ image: CGImage, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(image.bitsPerComponent == 8, sourceLocation: sourceLocation)
        #expect(image.bitsPerPixel == 32, sourceLocation: sourceLocation)
        #expect(!image.bitmapInfo.contains(.floatComponents), sourceLocation: sourceLocation)
        #expect(image.colorSpace.map { !CGColorSpaceUsesExtendedRange($0) } == true, sourceLocation: sourceLocation)
        #expect(image.colorSpace.map { !CGColorSpaceUsesITUR_2100TF($0) } == true, sourceLocation: sourceLocation)
    }

    // Images of 16 bits a color, of floating-point colors and of a high dynamic range are kept at 8 bits a color and 4
    // bytes a pixel, whether Quick Look or ImageIO read them, and a picture takes the bytes of its rows.
    @Test func everyPictureIsKeptAtFourBytesAPixel() async throws {
        let extended = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let files: [(name: String, type: UTType, bits: Int, space: CGColorSpace)] = [
            ("deep.png", .png, 16, try #require(CGColorSpace(name: CGColorSpace.sRGB))),
            ("deep.tiff", .tiff, 16, try #require(CGColorSpace(name: CGColorSpace.displayP3))),
            ("float.tiff", .tiff, 32, extended),
            ("float.exr", try #require(UTType("com.ilm.openexr-image")), 32, extended),
            ("bright.heic", .heic, 16, try #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ))),
        ]
        try await withTemporaryDirectory { directory in
            for file in files {
                let url = directory.appending(file.name)
                try Self.writeDeepImage(url, type: file.type, bits: file.bits, space: file.space)
                // As ImageIO reads it, for a size Quick Look refuses.
                let decoded = try #require(QuickLookThumbnailRenderer.decodedImage(url, side: 256))
                let kept = try #require(QuickLookThumbnailRenderer.eightBitImage(decoded))
                Self.isKept(kept)
                #expect(kept.width == 256 && kept.height == 192)
                // As the renderer gives it.
                let picture = try #require(
                    await QuickLookThumbnailRenderer().renderThumbnail(path: url.path, size: 256), "\(file.name)")
                let image = try #require(picture.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                Self.isKept(image)
                #expect(picture.bytes == image.bytesPerRow * image.height)
                #expect(image.bytesPerRow >= image.width * 4 && image.bytesPerRow < image.width * 4 + 64)
            }
        }
    }

    // A picture of 8 bits a color is kept as it is, and one with no transparency is drawn with none, and is opaque.
    @Test func aPictureAtEightBitsIsKeptAsItIs() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let deep = try #require(
            CGContext(
                data: nil, width: 40, height: 30, bitsPerComponent: 16, bytesPerRow: 0,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            )?.makeImage())
        let kept = try #require(QuickLookThumbnailRenderer.eightBitImage(deep))
        Self.isKept(kept)
        #expect(kept.colorSpace?.name == CGColorSpace.sRGB)
        #expect(kept.alphaInfo == .noneSkipFirst)
        #expect(QuickLookThumbnailRenderer.isOpaque(kept))
        #expect(QuickLookThumbnailRenderer.eightBitImage(kept) === kept)
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
