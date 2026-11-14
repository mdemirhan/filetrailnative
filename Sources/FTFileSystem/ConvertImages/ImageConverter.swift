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
        let redraw = target != upright || (format == .avif && header.orientation != 1) || hdr

        if redraw {
            let image = try picture(source, header, upright: upright, target: target, hdr: hdr)
            properties.merge(metadata(header.properties, options, newSize: target)) { _, new in new }
            properties[kCGImagePropertyOrientation] = 1
            if hdr { properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap }
            if format == .tiff { properties[kCGImagePropertyTIFFDictionary] = tiffDictionary(properties) }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
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

    /// The picture upright at `target`. ImageIO scales it as it decodes, keeping its shape; an exact size of another
    /// shape is then drawn from a copy at least that large each way.
    private static func picture(
        _ source: CGImageSource, _ header: Header, upright: PixelSize, target: PixelSize, hdr: Bool
    ) throws(Failure) -> CGImage {
        let factor = max(
            Double(target.width) / Double(upright.width), Double(target.height) / Double(upright.height))
        let side = min(upright.longestSide, Int((Double(upright.longestSide) * factor).rounded(.up)))
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, 1), kCGImageSourceShouldCacheImmediately: true,
        ]
        if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, header.index, options as CFDictionary)
        else { throw .notAnImage }
        // A pixel either way is the rounding of the shorter side: drawing again for it would only blur.
        if abs(decoded.width - target.width) <= 1, abs(decoded.height - target.height) <= 1,
            proportionalTo(upright, target)
        {
            return decoded
        }
        return try drawn(decoded, at: target)
    }

    private static func proportionalTo(_ upright: PixelSize, _ target: PixelSize) -> Bool {
        let ratio = Double(upright.width) / Double(upright.height)
        let targetRatio = Double(target.width) / Double(target.height)
        return abs(ratio - targetRatio) * Double(max(target.width, target.height)) <= 1.5
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

    /// The dictionaries that hold the camera's metadata, which a picture drawn again keeps from its source.
    private static var metadataKeys: [CFString] {
        [
            kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerAppleDictionary,
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

    /// For a picture drawn again: the metadata to write with it, now upright and of its new size.
    private static func metadata(
        _ source: [CFString: Any], _ options: ImageConversionOptions, newSize: PixelSize
    ) -> [CFString: Any] {
        guard options.keepMetadata else { return [:] }
        var kept: [CFString: Any] = [:]
        for key in metadataKeys where !(key == kCGImagePropertyGPSDictionary && options.removeLocation) {
            if let value = source[key] { kept[key] = value }
        }
        if options.removeLocation, var caption = kept[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in locationNameKeys { caption[key] = nil }
            kept[kCGImagePropertyIPTCDictionary] = caption.isEmpty ? nil : caption
        }
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = newSize.width
            exif[kCGImagePropertyExifPixelYDimension] = newSize.height
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        return kept
    }

    /// A TIFF's own dictionary, compressed with LZW: uncompressed, a photo is about 3 bytes a pixel.
    private static func tiffDictionary(_ properties: [CFString: Any]) -> [CFString: Any] {
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5
        return tiff
    }
}
