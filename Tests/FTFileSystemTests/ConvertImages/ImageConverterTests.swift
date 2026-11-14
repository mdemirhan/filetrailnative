import CoreGraphics
import FTFoundation
import FTTestSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FTFileSystem

/// Pictures made here, in the formats and with the metadata each test needs.
private enum Pictures {
    /// A picture whose left half is red and right half blue, its top half transparent when `alpha`.
    static func image(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        if alpha { context.clear(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2)) }
        return context.makeImage()!
    }

    /// A picture brighter than white, as an HDR photo is.
    static func bright(width: Int, height: Int) -> CGImage? {
        let info =
            CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGImageByteOrderInfo.order16Little.rawValue
        guard
            let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                bitmapInfo: info)
        else { return nil }
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.2, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(colorSpace: space, components: [4, 4, 4, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return context.makeImage()
    }

    static let exifDate = "2026:05:14 18:02:11"

    static func cameraMetadata(orientation: Int) -> [CFString: Any] {
        [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
    }

    static func write(
        _ images: [CGImage], as type: UTType, to url: URL, properties: [CFString: Any] = [:]
    ) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
    }
}

/// What a converted file holds.
private struct Written {
    let source: CGImageSource
    let properties: [CFString: Any]

    init(_ data: Data) throws {
        source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    var type: String? { CGImageSourceGetType(source) as String? }
    var count: Int { CGImageSourceGetCount(source) }
    var size: PixelSize {
        PixelSize(
            width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
    var orientation: Int { properties[kCGImagePropertyOrientation] as? Int ?? 1 }
    var exifDate: String? {
        (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal]
            as? String
    }
    var hasLocation: Bool { properties[kCGImagePropertyGPSDictionary] != nil }
    var hasGainMap: Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    /// The picture as it shows, turned upright.
    var upright: CGImage {
        get throws {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            ]
            return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        }
    }

    /// The color near the top left of the picture as stored, red, green, blue and alpha.
    var topLeft: [UInt8] {
        get throws {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return pixel(image, x: 2, y: 2)
        }
    }
}

/// The color of the pixel `x`, `y` from the top left of `image`.
private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
    return bytes
}

/// The converter run as the app runs it, on a queue of its own: ImageIO's AV1 encoder (AVIF) does its work on Swift's
/// cooperative threads, so a test that held one of them while it waited could take the last one the encoder needs, and
/// wait for it as long as the other tests hold the rest.
private func converted(_ path: String, _ options: ImageConversionOptions) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try ImageConverter.convert(path, options) })
        }
    }
}

@Suite struct ImageConverterTests {
    private func photo(
        _ folder: TemporaryDirectory, orientation: Int = 6, width: Int = 400, height: Int = 300
    ) throws -> String {
        let url = folder.appending("photo.jpg")
        try Pictures.write(
            [Pictures.image(width: width, height: height)], as: .jpeg, to: url,
            properties: Pictures.cameraMetadata(orientation: orientation))
        return url.path
    }

    @Test func aPictureConvertedAtItsSizeKeepsItsMetadataAndOrientation() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let written = try await Written(converted(try photo(folder), ImageConversionOptions(format: .heic)))
        #expect(written.type == UTType.heic.identifier)
        #expect(written.size == PixelSize(width: 400, height: 300))
        #expect(written.orientation == 6)
        #expect(written.exifDate == Pictures.exifDate)
        #expect(written.hasLocation)
    }

    @Test func theUprightSizeTradesWidthAndHeightForAQuarterTurn() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        #expect(
            ImageConverter.info(ofImageAt: try photo(folder)) == ImageInfo(size: PixelSize(width: 300, height: 400)))
        #expect(ImageConverter.info(ofImageAt: folder.appending("missing.jpg").path) == nil)
    }

    @Test func avifIsWrittenUprightAsItKeepsNoOrientation() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let written = try await Written(converted(try photo(folder), ImageConversionOptions(format: .avif)))
        #expect(written.type == "public.avif")
        let upright = try written.upright
        #expect(PixelSize(width: upright.width, height: upright.height) == PixelSize(width: 300, height: 400))
        #expect(written.exifDate == Pictures.exifDate)
    }

    @Test func removingTheLocationKeepsTheRest() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let path = try photo(folder)
        for size in [ImageSize.actual, .fitWithin(200)] {
            let written = try await Written(
                converted(path, ImageConversionOptions(format: .jpeg, size: size, removeLocation: true)))
            #expect(!written.hasLocation, "\(size)")
            #expect(written.exifDate == Pictures.exifDate, "\(size)")
        }
    }

    @Test func withoutMetadataNoneIsWritten() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let path = try photo(folder)
        for size in [ImageSize.actual, .scale(50)] {
            let written = try await Written(
                converted(path, ImageConversionOptions(format: .jpeg, size: size, keepMetadata: false)))
            #expect(!written.hasLocation, "\(size)")
            #expect(written.exifDate == nil, "\(size)")
        }
    }

    @Test func aSmallerPictureIsDrawnUprightAtItsNewSize() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let written = try await Written(
            converted(try photo(folder), ImageConversionOptions(format: .png, size: .fitWithin(200))))
        #expect(written.size == PixelSize(width: 150, height: 200))
        #expect(written.orientation == 1)
        #expect(written.exifDate == Pictures.exifDate)
        let exif = written.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifPixelXDimension] as? Int == 150)
    }

    @Test func anExactSizeOfAnotherShapeIsDrawnToThatSize() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let path = try photo(folder, orientation: 1)
        let written = try await Written(
            converted(
                path,
                ImageConversionOptions(
                    format: .png, size: .custom(width: 100, height: 100, unit: .pixels, proportional: false))))
        #expect(written.size == PixelSize(width: 100, height: 100))
        let image = try written.upright
        #expect(pixel(image, x: 10, y: 50)[0] > 200)
        #expect(pixel(image, x: 90, y: 50)[2] > 200)
    }

    @Test func anExactSizeLargerThanThePictureIsRefused() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let options = ImageConversionOptions(
            format: .png, size: .custom(width: 350, height: 350, unit: .pixels, proportional: false))
        await #expect(throws: ImageConverter.Failure.tooSmall(PixelSize(width: 300, height: 400))) {
            try await converted(try photo(folder), options)
        }
    }

    @Test func jpegPutsATransparentPictureOnWhiteAndHEICKeepsItsTransparency() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("clear.png")
        try Pictures.write([Pictures.image(width: 40, height: 20, alpha: true)], as: .png, to: url)
        #expect(ImageConverter.info(ofImageAt: url.path)?.hasAlpha == true)
        let white = try await Written(converted(url.path, ImageConversionOptions(format: .jpeg))).topLeft
        #expect(white.allSatisfy { $0 >= 250 }, "\(white)")
        #expect(try await Written(converted(url.path, ImageConversionOptions(format: .heic))).topLeft[3] == 0)
    }

    @Test func tiffIsCompressed() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let path = try photo(folder)
        for size in [ImageSize.actual, .scale(50)] {
            let written = try await Written(converted(path, ImageConversionOptions(format: .tiff, size: size)))
            let tiff = written.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(tiff?[kCGImagePropertyTIFFCompression] as? Int == 5, "\(size)")
        }
    }

    @Test func anAnimationGivesItsFirstFrame() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("moving.gif")
        try Pictures.write(
            [Pictures.image(width: 30, height: 20), Pictures.image(width: 30, height: 20)], as: .gif, to: url)
        #expect(ImageConverter.info(ofImageAt: url.path)?.frameCount == 2)
        let written = try await Written(converted(url.path, ImageConversionOptions(format: .png)))
        #expect(written.count == 1)
        #expect(written.size == PixelSize(width: 30, height: 20))
    }

    @Test func anHDRPhotoKeepsItsGainMapInFormatsThatHoldOne() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("bright.heic")
        let hdr = try #require(Pictures.bright(width: 400, height: 300))
        try Pictures.write(
            [hdr], as: .heic, to: url,
            properties: [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap])
        try #require(try Written(Data(contentsOf: url)).hasGainMap)
        #expect(ImageConverter.info(ofImageAt: url.path)?.hasGainMap == true)
        for (format, size) in [(ImageFormat.jpeg, ImageSize.actual), (.heic, .fitWithin(200)), (.avif, .actual)] {
            let written = try await Written(
                converted(url.path, ImageConversionOptions(format: format, size: size)))
            #expect(written.hasGainMap, "\(format) \(size)")
        }
        for size in [ImageSize.actual, .fitWithin(200)] {
            let written = try await Written(
                converted(url.path, ImageConversionOptions(format: .png, size: size)))
            #expect(!written.hasGainMap)
        }
    }

    @Test func whatIsNotAPictureOrCantBeReadIsRefused() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let text = folder.appending("notes.jpg")
        try Data("not a picture".utf8).write(to: text)
        await #expect(throws: ImageConverter.Failure.notAnImage) {
            try await converted(text.path, ImageConversionOptions())
        }
        await #expect(throws: ImageConverter.Failure.unreadable("No such file or directory")) {
            try await converted(folder.appending("missing.jpg").path, ImageConversionOptions())
        }
    }
}
