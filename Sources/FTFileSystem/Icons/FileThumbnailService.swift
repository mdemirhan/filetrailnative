import AppKit
import Darwin
import FTFoundation
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os

/// Quick Look's picture of a file's content.
public struct ThumbnailPicture: @unchecked Sendable {
    public let image: NSImage
    /// Whether every pixel is fully opaque. Such pictures (photos, video frames) get an outline around
    /// them; one with transparency is a cut-out image or a page drawn with its own outline.
    public let isOpaque: Bool
    /// The bytes its pixels take in memory.
    public let bytes: Int

    /// A picture taken to have four bytes a pixel.
    public init(image: NSImage, isOpaque: Bool) {
        self.image = image
        self.isOpaque = isOpaque
        self.bytes = Int(image.size.width * image.size.height) * 4
    }

    /// The picture of `image`, which takes the bytes of its rows.
    public init(cgImage: CGImage, isOpaque: Bool) {
        self.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        self.isOpaque = isOpaque
        self.bytes = cgImage.bytesPerRow * cgImage.height
    }
}

/// The answer to a preview request.
public struct ThumbnailResponse: Sendable {
    /// The file's state the preview was made from; nil when the file could not be read.
    public var version: String?
    /// The caller already holds the preview for `version`.
    public var unchanged: Bool
    /// Nil when Quick Look has no preview for the file.
    public var picture: ThumbnailPicture?

    public init(version: String?, unchanged: Bool, picture: ThumbnailPicture?) {
        self.version = version
        self.unchanged = unchanged
        self.picture = picture
    }
}

public protocol ThumbnailProviding: Sendable {
    func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse
}

/// Makes the picture of a file that fits in a square of `size` pixels. A task cancelled stops after the step under way
/// and gives nil.
public protocol ThumbnailRendering: Sendable {
    func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture?
}

/// The preview of a file, with its version: the file's modification time and size, so a caller that already
/// holds the preview for that version is told so instead of being sent it again.
public struct FileThumbnailService: ThumbnailProviding {
    private let renderer: any ThumbnailRendering
    private let version: @Sendable (String) -> String?

    public init(
        renderer: any ThumbnailRendering = QuickLookThumbnailRenderer(),
        version: @escaping @Sendable (String) -> String? = FileThumbnailService.fileVersion
    ) {
        self.renderer = renderer
        self.version = version
    }

    public func response(path: String, size: Int, knownVersion: String?) async -> ThumbnailResponse {
        let version = self.version
        guard let version = await BlockingWork.run({ version(path) }) else {
            return ThumbnailResponse(version: nil, unchanged: false, picture: nil)
        }
        if knownVersion == version {
            return ThumbnailResponse(version: version, unchanged: true, picture: nil)
        }
        let picture = await renderer.renderThumbnail(path: path, size: size)
        return ThumbnailResponse(version: version, unchanged: false, picture: picture)
    }

    /// `"<mtimeMs>:<size>"`, or nil when the file can't be read.
    public static func fileVersion(ofPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let mtimeMs = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1e6
        return "\(javaScriptNumber(mtimeMs)):\(info.st_size)"
    }

    /// A number written into a string: no ".0" on a whole number.
    static func javaScriptNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }
}

/// The pixels of the pictures Quick Look has given and refused while the app runs. Quick Look makes no picture of a
/// photo, a video or a drawing above some number of pixels, and has no way to ask what that number is, so it is found
/// by asking: the largest picture given and the smallest refused close in on it.
final class QuickLookLimits: Sendable {
    private struct Seen {
        var given = 0
        var refused = Int.max
    }

    private let seen = OSAllocatedUnfairLock(initialState: Seen())

    /// The most pixels a picture given had.
    var given: Int { seen.withLock { $0.given } }
    /// The fewest pixels a picture refused would have had; `Int.max` while none was.
    var refused: Int { seen.withLock { $0.refused } }

    /// A picture given at a size refused before shows that refusal was not for the size.
    func gave(pixels: Int) {
        seen.withLock {
            $0.given = max($0.given, pixels)
            if $0.given >= $0.refused { $0.refused = Int.max }
        }
    }

    /// A picture of this many pixels or fewer is never refused for its size: as many as a square
    /// `QuickLookThumbnailRenderer.alwaysGivenSide` across.
    static let alwaysGivenPixels =
        QuickLookThumbnailRenderer.alwaysGivenSide * QuickLookThumbnailRenderer.alwaysGivenSide

    /// A refusal at a size given before, or at one never refused for its size, is not for the size (a file that cannot
    /// be read, Quick Look busy).
    func refused(pixels: Int) {
        guard pixels > Self.alwaysGivenPixels else { return }
        seen.withLock { if pixels > $0.given { $0.refused = min($0.refused, pixels) } }
    }
}

/// Asks Quick Look for a picture of the file's content (an image, a PDF page, a video frame, a document
/// page) that fits in a square of `size` pixels (at most 8192), keeping its proportions. Gives nil when Quick Look has no
/// preview; the system icon is not returned as a stand-in (see `FileIconStore` for that).
///
/// Pictures and videos come back as they are. Everything else (text, PDFs, documents) is drawn the way
/// Finder draws its icons: a page with its own outline and shadow on a clear background, so a white page
/// stays visible on a white window.
///
/// Quick Look refuses a picture of too many pixels (about 3.5 million: a wide photo 2500 across, a square one 1870).
/// An image larger than that is read by ImageIO instead, at the size asked for. Of any other file the largest picture
/// Quick Look gives is found by asking at sizes between one it gives and one it refuses.
public struct QuickLookThumbnailRenderer: ThumbnailRendering {
    public init() {}

    /// A picture this size across or smaller is never refused for its size: one refused has no preview at all.
    static let alwaysGivenSide = 1024
    /// How close to the largest size Quick Look gives the search comes.
    static let searchStep = 128

    /// How many pictures ImageIO decodes at once.
    static let maxDecodes = 2
    static let decodes = DecodeGate(limit: maxDecodes)

    private static let pictureLimits = QuickLookLimits()
    private static let iconLimits = QuickLookLimits()

    public func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture? {
        let side = min(max(size, 16), 8192)
        // The file is read outside Swift's shared pool, as its disk may have stopped answering; Quick Look answers in
        // its own time.
        let (url, showsPicture, imagePixels) = await BlockingWork.run {
            let url = DiskPath(path).fileURL()
            let showsPicture = Self.showsPicture(url)
            return (url, showsPicture, showsPicture ? Self.imagePixels(url, side: side) : nil)
        }
        var image: CGImage?
        if let pixels = imagePixels {
            image = await Self.imagePicture(
                side: side, pixels: pixels, limits: Self.pictureLimits,
                request: { await Self.quickLookImage(url, side: $0, iconMode: false) },
                decode: { await Self.decodes.run { Self.decodedImage(url, side: side) } })
        }
        if image == nil, !Task.isCancelled {
            image = await Self.largestPicture(
                side: side, limits: showsPicture ? Self.pictureLimits : Self.iconLimits
            ) { await Self.quickLookImage(url, side: $0, iconMode: !showsPicture) }
        }
        guard let image, !Task.isCancelled, let kept = Self.eightBitImage(image) else { return nil }
        return ThumbnailPicture(cgImage: kept, isOpaque: Self.isOpaque(kept))
    }

    /// `image` at 8 bits a color and at most 4 bytes a pixel, as previews are kept: as it is when it is so already,
    /// otherwise drawn again. A 16-bit or floating-point image, one of a high dynamic range (which shows its standard
    /// range) and one of another color model than RGB or gray are. It keeps its own color space when that is an RGB
    /// one of the standard range, and is drawn in Display P3 otherwise; one with no transparency has none. Nil when it
    /// can't be drawn.
    static func eightBitImage(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace
        let standardRange = space.map(isStandardRange) ?? false
        if image.bitsPerComponent == 8, image.bitsPerPixel <= 32, !image.bitmapInfo.contains(.floatComponents),
            standardRange, space?.model == .rgb || space?.model == .monochrome
        {
            return image
        }
        let opaque: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let target =
            space.flatMap { standardRange && $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: target, bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Whether colors in `space` are of the standard dynamic range and kept well in 8 bits: not of an extended range,
    /// not a high dynamic range one, not linear.
    private static func isStandardRange(_ space: CGColorSpace) -> Bool {
        guard space.supportsOutput, !CGColorSpaceUsesExtendedRange(space), !CGColorSpaceUsesITUR_2100TF(space)
        else { return false }
        let name = (space.name as String?) ?? ""
        return !name.localizedCaseInsensitiveContains("linear")
    }

    private static func quickLookImage(_ url: URL, side: Int, iconMode: Bool) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 1.0, representationTypes: .thumbnail)
        request.iconMode = iconMode
        // A task cancelled stops waiting for Quick Look, which drops the request.
        nonisolated(unsafe) let asked = request
        return await withTaskCancellationHandler {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: asked).cgImage
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(asked)
        }
    }

    /// An image's picture of `pixels` that fits in a square of `side`: Quick Look's (`request`), which it keeps on disk
    /// and gives again fast, unless it would have as many pixels as one Quick Look refused; then, and when Quick Look
    /// refuses this one, ImageIO's (`decode`).
    ///
    /// A refusal is taken for the size only when the picture would have more pixels than one never refused for its
    /// size and Quick Look gives the same file's picture at `alwaysGivenSide`: refused there too, it was refused for
    /// something else (Quick Look busy, a kind of image it does not read), which says nothing of other images.
    static func imagePicture(
        side: Int, pixels: Int, limits: QuickLookLimits, request: (Int) async -> CGImage?,
        decode: () async -> CGImage?
    ) async -> CGImage? {
        if pixels < limits.refused {
            if let image = await request(side) {
                limits.gave(pixels: image.width * image.height)
                return image
            }
            // Stopped: refused or not, Quick Look said nothing of the size.
            guard !Task.isCancelled else { return nil }
            if pixels > QuickLookLimits.alwaysGivenPixels, let small = await request(alwaysGivenSide) {
                limits.gave(pixels: small.width * small.height)
                limits.refused(pixels: pixels)
            }
        }
        guard !Task.isCancelled else { return nil }
        return await decode()
    }

    /// The file a URL leads to, every link followed, spelled as its disk has it: what ImageIO is given to read.
    static func linkTarget(of url: URL) -> URL {
        DiskPath(urlSpelling: url)?.asOnDisk().url(isDirectory: false) ?? url
    }

    /// The pixels the image file's picture has when it fits in a square of `side`, never larger than the image
    /// itself; nil when the file is not an image ImageIO reads (a video, a drawing).
    static func imagePixels(_ url: URL, side: Int) -> Int? {
        guard let source = CGImageSourceCreateWithURL(linkTarget(of: url) as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let longest = max(width, height)
        let scale = min(1, Double(side) / Double(longest))
        return Int(Double(width) * scale) * Int(Double(height) * scale)
    }

    /// The image file's picture read by ImageIO, upright, its longer side at most `side` and never larger than the
    /// image itself; nil when the file is not an image ImageIO reads. For the sizes Quick Look refuses. An image of a
    /// high dynamic range is read at its standard range, as previews show it.
    static func decodedImage(_ url: URL, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(linkTarget(of: url) as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The largest picture `request` gives that fits in a square of `side`; nil when it gives none at any size.
    ///
    /// Refused at `side`, it is asked at `alwaysGivenSide`: nothing there is a file with no preview, and a picture
    /// there shows the file's shape. The search then halves the sizes between that one and `side`, to within
    /// `searchStep`. `limits` holds what earlier files were given and refused, which a file of any shape starts
    /// from, so that after the first one a search is one more request.
    ///
    /// A task cancelled asks for nothing more, learns nothing from the request it stopped, and gives nil.
    static func largestPicture(
        side: Int, limits: QuickLookLimits, request: (Int) async -> CGImage?
    ) async -> CGImage? {
        if let image = await request(side) {
            limits.gave(pixels: image.width * image.height)
            return image
        }
        guard side > alwaysGivenSide, !Task.isCancelled, var best = await request(alwaysGivenSide),
            !Task.isCancelled
        else { return nil }
        // The pixels of this file's picture at a size, and the size of this file's picture of some pixels.
        let shape = Double(best.width * best.height) / Double(alwaysGivenSide * alwaysGivenSide)
        func pixels(_ side: Int) -> Int { Int(Double(side * side) * shape) }
        func across(pixels: Int) -> Int { Int((Double(pixels) / shape).squareRoot()) }
        limits.refused(pixels: pixels(side))
        var given = alwaysGivenSide
        var refused = side
        /// False once the task is cancelled.
        func ask(_ size: Int) async -> Bool {
            guard !Task.isCancelled else { return false }
            if let image = await request(size) {
                limits.gave(pixels: image.width * image.height)
                best = image
                given = size
            } else {
                guard !Task.isCancelled else { return false }
                limits.refused(pixels: pixels(size))
                refused = size
            }
            return true
        }
        // What other files were given and refused, when it is between this file's two sizes.
        let known = across(pixels: limits.given)
        if known > given, known < refused {
            guard await ask(known) else { return nil }
        }
        let knownRefused = limits.refused == Int.max ? refused : across(pixels: limits.refused)
        if given == known, knownRefused > given { refused = min(refused, knownRefused) }
        while refused - given > searchStep {
            guard await ask((given + refused) / 2) else { return nil }
        }
        return best
    }

    /// Whether the file is a picture or a video, whose preview is the content itself. A symlink counts as
    /// what it points to.
    static func showsPicture(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard let type = try? target.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return true
        }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
    }

    /// The longer side of the copy `isOpaque` looks at.
    static let opacitySampleSide = 64

    /// Whether the image is opaque all over: judged from a copy drawn at most 64 pixels a side, so a large preview
    /// costs a few kilobytes to judge and not a second bitmap of its own size. A cut-out picture or a page with its
    /// outline is clear over whole areas, which show in the small copy; a few clear pixels alone in a large picture
    /// do not.
    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }
        guard image.width > 0, image.height > 0 else { return false }
        let longest = max(image.width, image.height)
        let shrink = min(1, Double(opacitySampleSide) / Double(longest))
        let width = max(1, Int((Double(image.width) * shrink).rounded()))
        let height = max(1, Int((Double(image.height) * shrink).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] != 255 {
            return false
        }
        return true
    }
}
