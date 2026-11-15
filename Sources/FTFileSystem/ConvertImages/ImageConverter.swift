import CoreGraphics
import FTFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts one picture with ImageIO: into another format, smaller, without its metadata or its location.
public enum ImageConverter {
    public enum Failure: Error, Equatable, Sendable {
        /// The disk refused: its reason.
        case unreadable(String)
        /// Named as an image, and not one ImageIO can open.
        case notAnImage
        /// Smaller than the exact size asked for, which only enlarging could meet.
        case tooSmall(PixelSize)
        /// ImageIO couldn't write it in that format.
        case notWritten
    }

    /// The picture's size turned upright, and what the sheet notes of it, read from the file's header (and a gain
    /// map's description); nil when it isn't an image ImageIO opens.
    public static func info(ofImageAt path: String) -> ImageInfo? {
        guard let source = openSource(path), let header = header(source) else { return nil }
        return ImageInfo(
            size: uprightSize(header), hasAlpha: header.properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasGainMap: hasGainMap(source, header.index), frameCount: CGImageSourceGetCount(source))
    }

    /// The infos of many pictures, in order, read on a queue of their own: a slow disk then holds none of Swift's
    /// cooperative threads, which ImageIO's AV1 encoder needs for AVIF.
    public static func infos(_ paths: [String]) async -> [ImageInfo?] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: paths.map(info(ofImageAt:)))
            }
        }
    }

    /// The new file's bytes.
    public static func convert(_ path: String, _ options: ImageConversionOptions) throws(Failure) -> Data {
        guard access(path, R_OK) == 0 else { throw .unreadable(String(cString: strerror(errno))) }
        guard let source = openSource(path), let header = header(source) else { throw .notAnImage }
        let upright = uprightSize(header)
        guard let target = ImageConversion.targetSize(upright, options.size) else { throw .tooSmall(upright) }
        let format = options.format
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, format.typeIdentifier as CFString, 1, nil)
        else { throw .notWritten }

        var properties: [CFString: Any] = [:]
        if format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality, 0), 1)
        }
        if !format.keepsTransparency {
            properties[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
        }
        let hdr = format.keepsHDR && hasGainMap(source, header.index)
        // AVIF keeps no orientation: an upright copy is written instead, or a portrait photo comes out on its side.
        // An HDR photo is decoded to its full range and its gain map made again, as ImageIO's own carrying of a gain
        // map from one format to another loses an ISO one (HEIC to JPEG).
        // A place named only in the XMP (the caption data's newer fields, which no dictionary of ImageIO's holds) is
        // carried along by a picture written from its file whatever it is told: the location goes with the tags then.
        let redraw =
            target != upright || (format == .avif && header.orientation != 1) || hdr
            || (options.keepMetadata && options.removeLocation && namesAPlaceInXMPAlone(source, header.index))

        if redraw {
            let image = try picture(source, header, upright: upright, target: target, hdr: hdr)
            properties[kCGImagePropertyOrientation] = 1
            if hdr { properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap }
            if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = tiffDictionary([:]) }
            if let metadata = metadata(source, header.index, options, newSize: target) {
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            }
        } else if options.keepMetadata {
            // The picture as it is, its metadata, orientation and color profile with it.
            properties.merge(removedLocation(options)) { _, new in new }
            if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = tiffDictionary(header.properties) }
            CGImageDestinationAddImageFromSource(destination, source, header.index, properties as CFDictionary)
        } else {
            // The picture alone, decoded at its size: written from its file, ImageIO carries over every kind of
            // metadata it holds, and keeps some (a TIFF's tags, a PNG's text, the XMP) even when each dictionary is
            // told to go. The decoded picture keeps its color profile and depth; its orientation and resolution are
            // written again.
            let decode = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, header.index, decode) else { throw .notAnImage }
            properties[kCGImagePropertyOrientation] = header.orientation
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let dpi = header.properties[key] { properties[key] = dpi }
            }
            if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = tiffDictionary([:]) }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw .notWritten }
        return out as Data
    }

    // MARK: Reading

    struct Header {
        var index: Int
        var width: Int
        var height: Int
        var orientation: Int
        var properties: [CFString: Any]
    }

    private static func openSource(_ path: String) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
            CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source) as String?, CopyContents.isImageType(type)
        else { return nil }
        return source
    }

    /// The primary picture's header: the first frame of an animation or the first page of a TIFF.
    private static func header(_ source: CGImageSource) -> Header? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return Header(index: index, width: width, height: height, orientation: orientation, properties: properties)
    }

    /// Orientations 5 to 8 turn the picture a quarter, so its width and height trade places.
    private static func uprightSize(_ header: Header) -> PixelSize {
        (5...8).contains(header.orientation)
            ? PixelSize(width: header.height, height: header.width)
            : PixelSize(width: header.width, height: header.height)
    }

    private static func hasGainMap(_ source: CGImageSource, _ index: Int) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    // MARK: The picture

    /// The picture upright at exactly `target`. ImageIO scales it as it decodes, keeping its shape, its longest side
    /// at the size asked; when its other side doesn't round as `target`'s does, or `target` is of another shape, it is
    /// drawn at `target` from a copy at least that large each way.
    private static func picture(
        _ source: CGImageSource, _ header: Header, upright: PixelSize, target: PixelSize, hdr: Bool
    ) throws(Failure) -> CGImage {
        func decoded(longestSide: Int) throws(Failure) -> CGImage {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(longestSide, 1), kCGImageSourceShouldCacheImmediately: true,
            ]
            if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, header.index, options as CFDictionary)
            else { throw .notAnImage }
            return image
        }
        let longest = upright.longestSide
        func ceiling(_ numerator: Int, _ denominator: Int) -> Int { (numerator + denominator - 1) / denominator }
        // `target`'s side along the picture's longest, and the longest side of the smallest copy each of whose sides
        // is at least `target`'s.
        let along = upright.width >= upright.height ? target.width : target.height
        let covering = min(
            longest,
            max(ceiling(target.width * longest, upright.width), ceiling(target.height * longest, upright.height)))
        var image = try decoded(longestSide: min(along, covering))
        if image.width == target.width, image.height == target.height { return image }
        // The shorter side rounded the other way, or another shape: drawn from a copy at least as large each way.
        if image.width < target.width || image.height < target.height {
            image = try decoded(longestSide: covering)
        }
        if image.width < target.width || image.height < target.height {
            image = try decoded(longestSide: min(covering + 1, longest))
        }
        return try drawn(image, at: target)
    }

    /// The picture drawn at `size`, whatever its shape. A bitmap to draw in holds red, green and blue with
    /// transparency, so a picture in gray or in CMYK is drawn in sRGB; one in RGB keeps its own color space.
    private static func drawn(_ image: CGImage, at size: PixelSize) throws(Failure) -> CGImage {
        let deep = image.bitsPerComponent > 8
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let space = own ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info: UInt32 =
            deep
            ? CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGImageByteOrderInfo.order16Little.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
                space: space, bitmapInfo: info)
        else { throw .notWritten }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw .notWritten }
        return result
    }

    // MARK: Metadata

    /// The tags that say how the source's own pixels are stored, which a picture drawn again doesn't keep: ImageIO
    /// writes its own (a TIFF's compression among them, which `tiffDictionary` asks for).
    private static var storageTags: [String] {
        [
            "tiff:ImageWidth", "tiff:ImageLength", "tiff:TileWidth", "tiff:TileLength", "tiff:Compression",
            "tiff:PhotometricInterpretation", "tiff:BitsPerSample", "tiff:SamplesPerPixel", "tiff:PlanarConfiguration",
            "tiff:YCbCrSubSampling", "tiff:YCbCrPositioning", "exif:ColorSpace",
        ]
    }

    /// Where a picture was taken, as its caption data names it (IPTC, and the XMP that mirrors it): the city, the
    /// state, the country and the place in the city. They go with the GPS position.
    private static var locationNameKeys: [CFString] {
        [
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCContentLocationName,
            kCGImagePropertyIPTCContentLocationCode,
        ]
    }

    /// For a picture written as it is with its metadata: the location to take out of it (null removes a key, in the
    /// caption data and in the XMP that says the same).
    private static func removedLocation(_ options: ImageConversionOptions) -> [CFString: Any] {
        var removed: [CFString: Any] = [:]
        if options.removeLocation {
            removed[kCGImagePropertyGPSDictionary] = kCFNull
            var names: [CFString: Any] = [:]
            for key in locationNameKeys { names[key] = kCFNull }
            removed[kCGImagePropertyIPTCDictionary] = names
        }
        return removed
    }

    /// For a picture drawn again: the source's metadata, now upright and of its new size, and without the location
    /// when it goes. It is read as XMP, which holds every kind ImageIO reads (the camera's, the caption data, a PNG's
    /// text, the XMP of its own), as the picture written as it is keeps them; nil when there is none to keep.
    private static func metadata(
        _ source: CGImageSource, _ index: Int, _ options: ImageConversionOptions, newSize: PixelSize
    ) -> CGImageMetadata? {
        guard options.keepMetadata, let read = CGImageSourceCopyMetadataAtIndex(source, index, nil),
            let metadata = CGImageMetadataCreateMutableCopy(read)
        else { return nil }
        var removed = storageTags
        var removedTags: [CGImageMetadataTag] = []
        if options.removeLocation {
            // The GPS position, the places only the XMP names, and the place names where ImageIO keeps the caption
            // data's in the XMP.
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
                if CGImageMetadataTagCopyNamespace(tag) as String? == kCGImageMetadataNamespaceExif as String,
                    (CGImageMetadataTagCopyName(tag) as String?)?.hasPrefix("GPS") == true
                {
                    removed.append(path as String)
                } else if isPlaceInXMPAlone(tag) {
                    removedTags.append(tag)
                }
                return true
            }
            for key in locationNameKeys {
                guard
                    let tag = CGImageMetadataCopyTagMatchingImageProperty(
                        metadata, kCGImagePropertyIPTCDictionary, key),
                    let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag)
                else { continue }
                removed.append("\(prefix):\(name)")
            }
        }
        for path in removed { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
        // By the prefix the tag itself has: its namespace is one ImageIO has no prefix of its own for.
        for tag in removedTags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag)
            else { continue }
            CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
        }
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        if CGImageMetadataCopyTagMatchingImageProperty(
            metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension) != nil
        {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension,
                newSize.width as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension,
                newSize.height as CFNumber)
        }
        return metadata
    }

    /// The caption data's newer fields for a place (IPTC Extension: the place shown, the place the picture was made
    /// in), which are kept in the XMP alone.
    private static let placeNamespace = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    private static let placeNames: Set<String> = ["LocationShown", "LocationCreated"]

    private static func isPlaceInXMPAlone(_ tag: CGImageMetadataTag) -> Bool {
        guard CGImageMetadataTagCopyNamespace(tag) as String? == placeNamespace,
            let name = CGImageMetadataTagCopyName(tag) as String?
        else { return false }
        return placeNames.contains(name)
    }

    /// Whether the picture's XMP names a place in one of those fields.
    private static func namesAPlaceInXMPAlone(_ source: CGImageSource, _ index: Int) -> Bool {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { return false }
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            found = isPlaceInXMPAlone(tag)
            return !found
        }
        return found
    }

    /// A TIFF's own dictionary, compressed with LZW: uncompressed, a photo is about 3 bytes a pixel.
    private static func tiffDictionary(_ properties: [CFString: Any]) -> [CFString: Any] {
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5
        return tiff
    }
}
