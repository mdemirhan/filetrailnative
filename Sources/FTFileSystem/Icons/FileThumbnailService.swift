// Port of nativeGetFileThumbnail (packages/native-fs/src/native_thumbnail.m) and getFileThumbnailHandler (apps/desktop/src/main/bootstrap/systemHandlers.ts)
import AppKit
import Darwin
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Quick Look's picture of a file's content.
public struct ThumbnailPicture: @unchecked Sendable {
    public let image: NSImage
    /// Whether every pixel is fully opaque. The original sends such pictures (photos, video frames) as
    /// JPEG and draws an outline around them; one with transparency is a cut-out image or a page drawn with
    /// its own outline.
    public let isOpaque: Bool

    public init(image: NSImage, isOpaque: Bool) {
        self.image = image
        self.isOpaque = isOpaque
    }
}

/// The answer to a preview request (`IpcResponse<"system:getFileThumbnail">`).
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

/// Makes the picture of a file that fits in a square of `size` pixels.
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
        guard let version = version(path) else {
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

    /// How JavaScript writes a number into a string: no ".0" on a whole number.
    static func javaScriptNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }
}

/// Asks Quick Look for a picture of the file's content (an image, a PDF page, a video frame, a document
/// page) that fits in a square of `size` pixels, keeping its proportions. Gives nil when Quick Look has no
/// preview; the system icon is not returned as a stand-in (see `FileIconStore` for that).
///
/// Pictures and videos come back as they are. Everything else (text, PDFs, documents) is drawn the way
/// Finder draws its icons: a page with its own outline and shadow on a clear background, so a white page
/// stays visible on a white window.
public struct QuickLookThumbnailRenderer: ThumbnailRendering {
    public init() {}

    public func renderThumbnail(path: String, size: Int) async -> ThumbnailPicture? {
        let side = CGFloat(min(max(size, 16), 1024))
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 1.0, representationTypes: .thumbnail)
        request.iconMode = !Self.showsPicture(url)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        let image = representation.cgImage
        return ThumbnailPicture(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            isOpaque: Self.isOpaque(image))
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

    /// Whether every pixel of the image is fully opaque.
    static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
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
