import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture's size in pixels, turned upright.
public struct PixelSize: Hashable, Sendable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var longestSide: Int { max(width, height) }

    /// "4783 × 7174".
    public var text: String { "\(width) \u{00D7} \(height)" }
}

/// What the sheet reads of each picture's header, for its sizes and its notes.
public struct ImageInfo: Hashable, Sendable {
    /// Turned upright.
    public var size: PixelSize
    public var hasAlpha: Bool
    /// An HDR photo, its brightness kept in a gain map.
    public var hasGainMap: Bool
    /// An animation's frames or a TIFF's pages: only the first is converted.
    public var frameCount: Int

    public init(size: PixelSize, hasAlpha: Bool = false, hasGainMap: Bool = false, frameCount: Int = 1) {
        self.size = size
        self.hasAlpha = hasAlpha
        self.hasGainMap = hasGainMap
        self.frameCount = frameCount
    }
}

/// The formats Convert Images writes. ImageIO reads many more (WebP, JPEG XL, camera RAW…) but writes only these
/// among the ones people share.
public enum ImageFormat: String, CaseIterable, Sendable, Codable {
    case jpeg, heic, png, tiff, avif

    public var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .avif: "AVIF"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        case .png: UTType.png.identifier
        case .tiff: UTType.tiff.identifier
        case .avif: "public.avif"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        case .tiff: "tiff"
        case .avif: "avif"
        }
    }

    /// Whether it is saved at a chosen quality, losing some detail.
    public var hasQuality: Bool { self == .jpeg || self == .heic || self == .avif }
    /// JPEG has none: a transparent picture gets a white background.
    public var keepsTransparency: Bool { self != .jpeg }
    /// Whether an HDR photo's gain map goes with it; PNG and TIFF get the standard-range picture.
    public var keepsHDR: Bool { self == .jpeg || self == .heic || self == .avif }
}

/// How big the new pictures are. None is ever larger than its original, in its width or its height.
public enum ImageSize: Hashable, Sendable, Codable {
    /// The original's size.
    case actual
    /// A longest side of at most this many pixels.
    case fitWithin(Int)
    /// This percentage of the original, at most 100.
    case scale(Int)
    /// A box each picture fits inside in its own shape (proportional), or a size each becomes exactly.
    case custom(width: Int, height: Int, unit: ImageSizeUnit, proportional: Bool)

    public static let fitWithinSides = [3840, 2560, 1920, 1280, 640]
    public static let scalePercentages = [75, 50, 25]
}

public enum ImageSizeUnit: String, Hashable, Sendable, Codable, CaseIterable {
    case pixels, percent
}

/// What the sheet chose.
public struct ImageConversionOptions: Hashable, Sendable, Codable {
    public var format: ImageFormat
    /// 0 to 1, for the formats with a quality.
    public var quality: Double
    public var size: ImageSize
    public var keepMetadata: Bool
    /// The GPS position goes even when the rest of the metadata is kept.
    public var removeLocation: Bool

    public init(
        format: ImageFormat = .jpeg, quality: Double = ImageConversion.defaultQuality, size: ImageSize = .actual,
        keepMetadata: Bool = true, removeLocation: Bool = false
    ) {
        self.format = format
        self.quality = quality
        self.size = size
        self.keepMetadata = keepMetadata
        self.removeLocation = removeLocation
    }
}

/// The rules of Convert Images: which files it takes, the size each becomes, and the new names.
public enum ImageConversion {
    public static let defaultQuality = 0.8

    // MARK: Which files

    /// The kinds ImageIO can open, which are what can be converted. SVG and PDF are images to the system but not to
    /// ImageIO.
    private static let readableTypes: [UTType] = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        .compactMap { UTType($0) }

    /// Whether a file of this name can be converted, judged by its extension alone so the menus stay instant. A file
    /// that turns out not to be an image fails when it is converted.
    public static func isConvertible(name: String) -> Bool {
        let ext = String(NodePath.extname(name).dropFirst()).lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    /// Whether every item is a file (or a link to one) that can be converted: one that isn't means none is.
    public static func canConvert(_ entries: [CommandEntry]) -> Bool {
        !entries.isEmpty
            && entries.allSatisfy { $0.kind.isEditableFile && isConvertible(name: NodePath.basename($0.path)) }
    }

    // MARK: Sizes

    /// The size a picture of `original` (upright) becomes; nil when `size` asks for an exact size it is smaller than,
    /// in its width or its height, which only enlarging could meet.
    public static func targetSize(_ original: PixelSize, _ size: ImageSize) -> PixelSize? {
        let width = max(original.width, 1)
        let height = max(original.height, 1)
        switch size {
        case .actual:
            return original
        case .fitWithin(let side):
            return scaled(original, by: Double(max(side, 1)) / Double(max(width, height)))
        case .scale(let percent):
            return scaled(original, by: Double(clampPercent(percent)) / 100)
        case .custom(let boxWidth, let boxHeight, .pixels, true):
            return scaled(
                original, by: min(Double(max(boxWidth, 1)) / Double(width), Double(max(boxHeight, 1)) / Double(height)))
        case .custom(let exactWidth, let exactHeight, .pixels, false):
            guard exactWidth >= 1, exactHeight >= 1, exactWidth <= width, exactHeight <= height else { return nil }
            return PixelSize(width: exactWidth, height: exactHeight)
        case .custom(let percent, _, .percent, true):
            return scaled(original, by: Double(clampPercent(percent)) / 100)
        case .custom(let widthPercent, let heightPercent, .percent, false):
            return PixelSize(
                width: rounded(Double(width) * Double(clampPercent(widthPercent)) / 100),
                height: rounded(Double(height) * Double(clampPercent(heightPercent)) / 100))
        }
    }

    /// `original` times `factor`, never larger than it was.
    private static func scaled(_ original: PixelSize, by factor: Double) -> PixelSize {
        guard factor < 1 else { return original }
        return PixelSize(
            width: rounded(Double(original.width) * factor), height: rounded(Double(original.height) * factor))
    }

    private static func rounded(_ value: Double) -> Int { max(1, Int(value.rounded())) }

    public static func clampPercent(_ percent: Int) -> Int { min(max(percent, 1), 100) }

    /// What a size does to the pictures chosen.
    public struct SizeOutcome: Equatable, Sendable {
        /// Made smaller.
        public var smaller = 0
        /// Already that size or inside the box: kept at their size, converted only.
        public var unchanged = 0
        /// Smaller than an exact size: none is converted while any is.
        public var tooSmall = 0

        public init(smaller: Int = 0, unchanged: Int = 0, tooSmall: Int = 0) {
            self.smaller = smaller
            self.unchanged = unchanged
            self.tooSmall = tooSmall
        }
    }

    public static func outcome(_ originals: [PixelSize], _ size: ImageSize) -> SizeOutcome {
        var outcome = SizeOutcome()
        for original in originals {
            switch targetSize(original, size) {
            case nil: outcome.tooSmall += 1
            case original: outcome.unchanged += 1
            default: outcome.smaller += 1
            }
        }
        return outcome
    }

    /// Whether the pictures differ in shape by more than a pixel's rounding, so that one exact size stretches them
    /// differently.
    public static func shapesDiffer(_ originals: [PixelSize]) -> Bool {
        let ratios = originals.filter { $0.width > 0 && $0.height > 0 }
            .map { Double($0.width) / Double($0.height) }
        guard let low = ratios.min(), let high = ratios.max() else { return false }
        return high / low > 1.01
    }

    // MARK: Names

    /// "Photo.HEIC" as JPEG is "Photo.jpg": the name's stem with the format's extension. When that is taken, the
    /// write numbers it ("Photo 2.jpg"), as it does for a new file.
    public static func newName(for name: String, format: ImageFormat) -> String {
        let ext = NodePath.extname(name)
        let stem = String(String.UnicodeScalarView(name.unicodeScalars.dropLast(ext.unicodeScalars.count)))
        return "\(stem).\(format.fileExtension)"
    }
}
