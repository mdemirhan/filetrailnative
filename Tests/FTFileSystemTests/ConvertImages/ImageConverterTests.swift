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
    static func image(
        width: Int, height: Int, alpha: Bool = false, space: CFString = CGColorSpace.sRGB
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: space)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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

    /// A picture in 16-bit gray, its left half dark and its right half light.
    static func deepGray(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGImageByteOrderInfo.order16Little.rawValue)
        else { return nil }
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()
    }

    /// A picture in CMYK, as a print shop's: its left half cyan and its right half yellow.
    static func cmyk(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(cyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(cyan: 0, magenta: 0, yellow: 1, black: 0, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()
    }

    /// Where a picture was taken, as its caption data names it, with a caption and keywords that say nothing of it.
    static var placeNames: [CFString: Any] {
        [
            kCGImagePropertyIPTCCity: "Cupertino", kCGImagePropertyIPTCProvinceState: "California",
            kCGImagePropertyIPTCCountryPrimaryLocationName: "United States",
            kCGImagePropertyIPTCCountryPrimaryLocationCode: "USA", kCGImagePropertyIPTCSubLocation: "The Park",
            kCGImagePropertyIPTCKeywords: ["one", "two"], kCGImagePropertyIPTCCaptionAbstract: "A caption",
        ]
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

    /// Every kind of metadata a picture can carry, each value of it marked "Mark", so a file that kept any of it
    /// says "Mark" somewhere: the camera's (TIFF, EXIF), the location, the caption data (IPTC) and a PNG's text.
    static var everyMetadata: [CFString: Any] {
        [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Mark Make", kCGImagePropertyTIFFModel: "Mark Model",
                kCGImagePropertyTIFFArtist: "Mark Artist", kCGImagePropertyTIFFCopyright: "Mark Copyright",
                kCGImagePropertyTIFFImageDescription: "Mark Description", kCGImagePropertyTIFFSoftware: "Mark App",
                kCGImagePropertyTIFFHostComputer: "Mark Mac", kCGImagePropertyTIFFOrientation: 6,
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: exifDate, kCGImagePropertyExifLensModel: "Mark Lens",
                kCGImagePropertyExifBodySerialNumber: "Mark Serial",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Mark City", kCGImagePropertyIPTCByline: ["Mark Byline"],
                kCGImagePropertyIPTCKeywords: ["Mark Keyword"],
            ],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGAuthor: "Mark Author", kCGImagePropertyPNGCopyright: "Mark Notice",
                kCGImagePropertyPNGDescription: "Mark Text", kCGImagePropertyPNGTitle: "Mark Title",
                kCGImagePropertyPNGComment: "Mark Comment",
            ],
        ]
    }

    /// XMP of its own, not mirrored by any dictionary ImageIO reads.
    static var xmp: CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(metadata, nil, "dc:creator" as CFString, ["Mark Creator"] as CFArray)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "Mark Tool" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Mark Label" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, 4 as CFNumber)
        return metadata
    }

    /// A picture in each format that holds metadata, 80 by 60 on its side (orientation 6), with every kind of it and
    /// XMP of its own, in Display P3.
    static func marked(in folder: TemporaryDirectory) throws -> [URL] {
        var sources: [URL] = []
        for type in [UTType.jpeg, .png, .tiff, .heic] {
            let url = folder.appending("marked.\(type.preferredFilenameExtension ?? "")")
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImageAndMetadata(
                destination, image(width: 80, height: 60, space: CGColorSpace.displayP3), xmp,
                everyMetadata as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            // Each carries some of it, as its format holds.
            #expect(try Written(Data(contentsOf: url)).everything.contains("Mark"), "\(type)")
            sources.append(url)
        }
        return sources
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
    var caption: [CFString: Any] { properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:] }
    var depth: Int { properties[kCGImagePropertyDepth] as? Int ?? 0 }
    var profileName: String? { properties[kCGImagePropertyProfileName] as? String }
    /// Everything the file says of itself: its properties and its XMP, as text.
    var everything: String {
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateXMPData($0, nil) as Data? }
            .flatMap { String(data: $0, encoding: .utf8) }
        return "\(properties)\n\(xmp ?? "")"
    }
    /// The names of the XMP tags the file carries, as "photoshop:City".
    var xmpTags: Set<String> {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [] }
        var tags: Set<String> = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            tags.insert(path as String)
            return true
        }
        return tags
    }
    /// The XMP tag at `path` ("xmp:Rating"), as text; the first item of a list ("dc:creator").
    func xmp(_ path: String) -> String? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
            ?? CGImageMetadataCopyStringValueWithPath(metadata, nil, "\(path)[0]" as CFString) as String?
    }
    func dictionary(_ key: CFString) -> [CFString: Any] { properties[key] as? [CFString: Any] ?? [:] }
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

    // The city, the state, the country and the place go with the location, from the caption data and from the XMP
    // that says the same; the caption and the keywords stay.
    @Test func removingTheLocationTakesThePlaceNamesToo() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("named.jpg")
        var properties = Pictures.cameraMetadata(orientation: 1)
        properties[kCGImagePropertyIPTCDictionary] = Pictures.placeNames
        try Pictures.write([Pictures.image(width: 400, height: 300)], as: .jpeg, to: url, properties: properties)
        let names: [CFString] = [
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            kCGImagePropertyIPTCSubLocation,
        ]
        let xmpNames: Set<String> = [
            "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location",
            "Iptc4xmpCore:CountryCode", "exif:GPSLatitude", "exif:GPSLongitude",
        ]
        for format in [ImageFormat.jpeg, .heic, .tiff] {
            for size in [ImageSize.actual, .fitWithin(200)] {
                // Kept with the rest unless the location goes.
                let kept = try await Written(converted(url.path, ImageConversionOptions(format: format, size: size)))
                #expect(kept.caption[kCGImagePropertyIPTCCity] as? String == "Cupertino", "\(format) \(size)")
                #expect(kept.hasLocation, "\(format) \(size)")

                let written = try await Written(
                    converted(url.path, ImageConversionOptions(format: format, size: size, removeLocation: true)))
                #expect(!written.hasLocation, "\(format) \(size)")
                for name in names { #expect(written.caption[name] == nil, "\(format) \(size) \(name)") }
                #expect(written.xmpTags.isDisjoint(with: xmpNames), "\(format) \(size) \(written.xmpTags)")
                #expect(written.caption[kCGImagePropertyIPTCCaptionAbstract] as? String == "A caption")
                #expect(written.caption[kCGImagePropertyIPTCKeywords] as? [String] == ["one", "two"])
                #expect(written.exifDate == Pictures.exifDate, "\(format) \(size)")
            }
        }
    }

    // The caption data's newer fields for a place (the place shown, the place the picture was made in) are kept in
    // the XMP alone, where no dictionary of ImageIO's reaches them: they go with the location too, at any size, and
    // the rest of the XMP stays.
    @Test func removingTheLocationTakesThePlacesOnlyTheXMPNames() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("placed.jpg")
        let metadata = CGImageMetadataCreateMutable()
        #expect(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://iptc.org/std/Iptc4xmpExt/2008-02-29/" as CFString, "Iptc4xmpExt" as CFString, nil))
        for (path, value) in [
            ("Iptc4xmpExt:LocationShown", "Shown Street 5"), ("Iptc4xmpExt:LocationCreated", "Made Square 9"),
            ("photoshop:City", "Kept City"), ("xmp:Rating", "4"), ("exif:GPSLatitude", "41,0.5N"),
        ] {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString), "\(path)")
        }
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, Pictures.image(width: 400, height: 300), metadata, nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = try Written(Data(contentsOf: url))
        #expect(source.everything.contains("Shown Street 5") && source.everything.contains("Made Square 9"))

        for format in ImageFormat.allCases {
            for size in [ImageSize.actual, .fitWithin(200)] {
                let label = "\(format) \(size)"
                let written = try await Written(
                    converted(url.path, ImageConversionOptions(format: format, size: size, removeLocation: true)))
                #expect(!written.everything.contains("Shown Street 5"), "\(label)")
                #expect(!written.everything.contains("Made Square 9"), "\(label)")
                #expect(!written.everything.contains("Kept City"), "\(label)")
                #expect(!written.hasLocation, "\(label)")
                #expect(written.xmp("xmp:Rating") == "4", "\(label)")
                let expected = size == .actual ? PixelSize(width: 400, height: 300) : PixelSize(width: 200, height: 150)
                #expect(written.size == expected, "\(label)")
            }
        }
        // With the location kept, a picture drawn again keeps them with the rest of its XMP.
        let kept = try await Written(
            converted(url.path, ImageConversionOptions(format: .jpeg, size: .fitWithin(200))))
        #expect(kept.everything.contains("Shown Street 5"))
    }

    // A position a camera wrote under a name of its own (a drone's, beside the standard one) goes with the location
    // too, at any size and in every format.
    @Test func removingTheLocationTakesAPositionACameraNamedItsOwnWay() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("drone.jpg")
        let metadata = CGImageMetadataCreateMutable()
        #expect(
            CGImageMetadataRegisterNamespaceForPrefix(
                metadata, "http://www.dji.com/drone-dji/1.0/" as CFString, "drone-dji" as CFString, nil))
        for (path, value) in [
            ("drone-dji:GpsLatitude", "+41.012345"), ("drone-dji:GpsLongitude", "+28.976543"),
            ("drone-dji:FlightYawDegree", "12.5"), ("exif:GPSLatitude", "41,0.5N"), ("xmp:Rating", "4"),
        ] {
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString), "\(path)")
        }
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, Pictures.image(width: 400, height: 300), metadata, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(try Written(Data(contentsOf: url)).everything.contains("41.012345"))
        for format in ImageFormat.allCases {
            for size in [ImageSize.actual, .fitWithin(200)] {
                let written = try await Written(
                    converted(url.path, ImageConversionOptions(format: format, size: size, removeLocation: true)))
                #expect(!written.everything.contains("41.012345"), "\(format) \(size)")
                #expect(!written.everything.contains("28.976543"), "\(format) \(size)")
                // What says nothing of where stays.
                #expect(written.everything.contains("12.5"), "\(format) \(size)")
                #expect(written.xmp("xmp:Rating") == "4", "\(format) \(size)")
            }
        }
    }

    // Nothing of the camera's, the location, the caption data, a PNG's text or the XMP is written, in any format,
    // whether the picture is written at its size or made smaller; its orientation and color profile still are.
    @Test func withoutMetadataNoneIsWritten() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        for url in try Pictures.marked(in: folder) {
            for format in ImageFormat.allCases {
                for size in [ImageSize.actual, .scale(50)] {
                    let label = "\(url.lastPathComponent) to \(format) \(size)"
                    let written = try await Written(
                        converted(url.path, ImageConversionOptions(format: format, size: size, keepMetadata: false)))
                    #expect(!written.everything.contains("Mark"), "\(label): \(written.everything)")
                    #expect(!written.hasLocation, "\(label)")
                    #expect(written.exifDate == nil, "\(label)")
                    #expect(written.profileName == "Display P3", "\(label)")
                    let upright = try written.upright
                    #expect(upright.height > upright.width, "\(label)")
                }
            }
        }
    }

    // Drawn again at a new size, a picture keeps what it keeps written as it is, in every format: the camera's tags,
    // the location, the caption data, a PNG's text and the XMP; upright and of its new size.
    @Test func withMetadataAPictureDrawnAgainKeepsWhatOneWrittenAsItIsKeeps() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        // What says how the pixels are stored, not what they show: written again for the new picture.
        let storage: Set<String> = [
            "iio:hasIIM", "iio:hasXMP", "exif:ColorSpace", "tiff:Compression", "tiff:PhotometricInterpretation",
            "tiff:TileWidth", "tiff:TileLength",
        ]
        let storageKeys = Set(
            [
                kCGImagePropertyTIFFOrientation, kCGImagePropertyExifPixelXDimension,
                kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace, kCGImagePropertyTIFFCompression,
                kCGImagePropertyTIFFPhotometricInterpretation, kCGImagePropertyTIFFTileWidth,
                kCGImagePropertyTIFFTileLength, kCGImagePropertyPNGInterlaceType,
            ].map { $0 as String })
        let dictionaries = [
            kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary,
        ]
        // A PNG with its text alone, as most apps write it.
        let text = folder.appending("text.png")
        try Pictures.write(
            [Pictures.image(width: 80, height: 60)], as: .png, to: text,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyPNGAuthor: "Text Author", kCGImagePropertyPNGCopyright: "Text Notice",
                    kCGImagePropertyPNGDescription: "Text Description", kCGImagePropertyPNGTitle: "Text Title",
                    kCGImagePropertyPNGComment: "Text Comment", kCGImagePropertyPNGSoftware: "Text App",
                ],
            ])
        for url in try Pictures.marked(in: folder) + [text] {
            for format in ImageFormat.allCases {
                let asIs = try await Written(converted(url.path, ImageConversionOptions(format: format)))
                for size in [ImageSize.scale(50), .fitWithin(50)] {
                    let label = "\(url.lastPathComponent) to \(format) \(size)"
                    let written = try await Written(
                        converted(url.path, ImageConversionOptions(format: format, size: size)))
                    let target = try #require(ImageConversion.targetSize(PixelSize(width: 60, height: 80), size))
                    #expect(written.size == target, "\(label)")
                    #expect(written.orientation == 1, "\(label)")
                    let upright = try written.upright
                    #expect(PixelSize(width: upright.width, height: upright.height) == target, "\(label)")
                    let missing = asIs.xmpTags.subtracting(storage).subtracting(written.xmpTags)
                    #expect(missing.isEmpty, "\(label): \(missing)")
                    for key in dictionaries {
                        for (name, value) in asIs.dictionary(key) where !storageKeys.contains(name as String) {
                            let kept = written.dictionary(key)[name].map { "\($0)" }
                            if key == kCGImagePropertyIPTCDictionary,
                                [kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated].contains(name),
                                kept == nil
                            {
                                // A HEIC's date as JPEG's caption data writes it from the XMP, which keeps it.
                                #expect(written.xmp("photoshop:DateCreated") == asIs.xmp("photoshop:DateCreated"))
                                #expect(written.xmp("photoshop:DateCreated") != nil, "\(label)")
                                continue
                            }
                            #expect(kept == "\(value)", "\(label) \(key) \(name)")
                        }
                    }
                    if let width = written.dictionary(kCGImagePropertyExifDictionary)[
                        kCGImagePropertyExifPixelXDimension]
                    {
                        #expect(width as? Int == target.width, "\(label)")
                    }
                    if let tiff = written.dictionary(kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFOrientation] {
                        #expect(tiff as? Int == 1, "\(label)")
                    }
                    let camera = written.dictionary(kCGImagePropertyTIFFDictionary)
                    // A TIFF's own compression doesn't come with its tags.
                    if format == .tiff {
                        #expect(camera[kCGImagePropertyTIFFCompression] as? Int == 5, "\(label)")
                    }
                    if url == text {
                        // The text, in what each format holds: its PNG text again, or the XMP that says the same.
                        #expect(written.xmp("dc:creator") == "Text Author", "\(label)")
                        #expect(written.xmp("dc:title") == "Text Title", "\(label)")
                        #expect(written.xmp("dc:description") == "Text Description", "\(label)")
                        #expect(written.xmp("dc:rights") == "Text Notice", "\(label)")
                        if format == .png {
                            let chunks = written.dictionary(kCGImagePropertyPNGDictionary)
                            #expect(chunks[kCGImagePropertyPNGAuthor] as? String == "Text Author", "\(label)")
                            #expect(chunks[kCGImagePropertyPNGTitle] as? String == "Text Title", "\(label)")
                            #expect(
                                chunks[kCGImagePropertyPNGDescription] as? String == "Text Description", "\(label)")
                        }
                        continue
                    }
                    // Kept whatever the formats, and the XMP of its own that only XMP says.
                    #expect(camera[kCGImagePropertyTIFFMake] as? String == "Mark Make", "\(label)")
                    #expect(camera[kCGImagePropertyTIFFModel] as? String == "Mark Model", "\(label)")
                    #expect(camera[kCGImagePropertyTIFFArtist] as? String == "Mark Artist", "\(label)")
                    #expect(written.exifDate == Pictures.exifDate, "\(label)")
                    #expect(written.hasLocation, "\(label)")
                    #expect(written.xmp("xmp:Rating") == "4", "\(label)")
                    #expect(written.xmp("xmp:Label") == "Mark Label", "\(label)")
                    #expect(written.xmp("dc:creator") == "Mark Artist", "\(label)")
                    if format == .png, url.pathExtension == "png" {
                        let chunks = written.dictionary(kCGImagePropertyPNGDictionary)
                        #expect(chunks[kCGImagePropertyPNGTitle] as? String == "Mark Title", "\(label)")
                        #expect(chunks[kCGImagePropertyPNGDescription] as? String == "Mark Description", "\(label)")
                    }
                }
            }
        }
    }

    // Drawn again with its metadata, a picture is still written at the quality asked for.
    @Test func withMetadataAPictureDrawnAgainKeepsItsQuality() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let path = try photo(folder, width: 800, height: 600)
        for format in [ImageFormat.jpeg, .heic] {
            let low = try await converted(path, ImageConversionOptions(format: format, quality: 0.1, size: .scale(50)))
            let high = try await converted(
                path, ImageConversionOptions(format: format, quality: 0.95, size: .scale(50)))
            #expect(low.count < high.count, "\(format) \(low.count) \(high.count)")
            #expect(try Written(low).exifDate == Pictures.exifDate, "\(format)")
        }
    }

    // Without the location, the GPS position and the place names go, from the caption data and from the XMP that
    // says the same, whether the picture is written as it is or drawn again; the rest stays.
    @Test func withoutTheLocationItGoesInEveryFormat() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let names: [CFString] = [
            kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
            kCGImagePropertyIPTCSubLocation,
        ]
        let xmpNames: Set<String> = [
            "photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location",
            "Iptc4xmpCore:CountryCode",
        ]
        for url in try Pictures.marked(in: folder) {
            for format in ImageFormat.allCases {
                for size in [ImageSize.actual, .scale(50)] {
                    let label = "\(url.lastPathComponent) to \(format) \(size)"
                    let written = try await Written(
                        converted(url.path, ImageConversionOptions(format: format, size: size, removeLocation: true)))
                    #expect(!written.hasLocation, "\(label)")
                    for name in names { #expect(written.caption[name] == nil, "\(label) \(name)") }
                    #expect(written.xmpTags.isDisjoint(with: xmpNames), "\(label) \(written.xmpTags)")
                    #expect(!written.xmpTags.contains { $0.hasPrefix("exif:GPS") }, "\(label) \(written.xmpTags)")
                    #expect(!written.everything.contains("Mark City"), "\(label)")
                    let camera = written.dictionary(kCGImagePropertyTIFFDictionary)
                    #expect(camera[kCGImagePropertyTIFFMake] as? String == "Mark Make", "\(label)")
                    #expect(written.exifDate == Pictures.exifDate, "\(label)")
                    #expect(written.xmp("xmp:Rating") == "4", "\(label)")
                }
            }
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

    // A picture comes out exactly the size worked out for it, though ImageIO's decoding rounds a side its own way: 60
    // by 80 within 50 is 38 by 50, not 38 by 51; on its side, with an odd side, a side of one pixel, at a scale and at an
    // exact size too.
    @Test func aPictureComesOutExactlyTheSizeWorkedOutForIt() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let cases: [(width: Int, height: Int, orientation: Int, size: ImageSize, expected: PixelSize)] = [
            (60, 80, 1, .fitWithin(50), PixelSize(width: 38, height: 50)),
            (80, 60, 6, .fitWithin(50), PixelSize(width: 38, height: 50)),
            (99, 37, 1, .fitWithin(13), PixelSize(width: 13, height: 5)),
            (200, 1, 1, .fitWithin(50), PixelSize(width: 50, height: 1)),
            (101, 37, 1, .scale(33), PixelSize(width: 33, height: 12)),
            (
                60, 80, 1, .custom(width: 30, height: 70, unit: .pixels, proportional: false),
                PixelSize(width: 30, height: 70)
            ),
        ]
        for (width, height, orientation, size, expected) in cases {
            let label = "\(width)×\(height) (\(orientation)) \(size)"
            let upright =
                orientation == 6 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
            #expect(ImageConversion.targetSize(upright, size) == expected, "\(label)")
            let url = folder.appending("\(width)x\(height)-\(orientation).jpg")
            try Pictures.write(
                [Pictures.image(width: width, height: height)], as: .jpeg, to: url,
                properties: [kCGImagePropertyOrientation: orientation])
            let written = try await Written(
                converted(url.path, ImageConversionOptions(format: .png, size: size, keepMetadata: false)))
            #expect(written.size == expected, "\(label)")
            #expect(written.orientation == 1, "\(label)")
        }
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

    // A picture in gray or in CMYK is drawn to an exact size of another shape as one in RGB is; a 16-bit one keeps
    // its depth where the format holds it.
    @Test func anExactSizeOfAnotherShapeIsDrawnFromGrayAndFromCMYK() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let exact = ImageSize.custom(width: 100, height: 80, unit: .pixels, proportional: false)

        let gray = folder.appending("gray.png")
        try Pictures.write([try #require(Pictures.deepGray(width: 200, height: 100))], as: .png, to: gray)
        #expect(try Written(Data(contentsOf: gray)).depth == 16)
        for format in [ImageFormat.png, .tiff, .jpeg, .heic] {
            let written = try await Written(converted(gray.path, ImageConversionOptions(format: format, size: exact)))
            #expect(written.size == PixelSize(width: 100, height: 80), "\(format)")
            let image = try written.upright
            let (dark, light) = (pixel(image, x: 10, y: 40), pixel(image, x: 90, y: 40))
            #expect(dark[0] < 90 && light[0] > 200, "\(format) \(dark) \(light)")
            // Gray all the same.
            #expect(abs(Int(light[0]) - Int(light[2])) < 6, "\(format) \(light)")
            if format == .png || format == .tiff { #expect(written.depth == 16, "\(format)") }
        }
        // In its own shape it was never drawn again, and still isn't; made smaller or written without its metadata,
        // it keeps its depth too.
        let fitted = try await Written(converted(gray.path, ImageConversionOptions(format: .png, size: .scale(50))))
        #expect(fitted.size == PixelSize(width: 100, height: 50))
        for format in [ImageFormat.png, .tiff] {
            for (size, keepMetadata) in [(ImageSize.scale(50), true), (.fitWithin(120), true), (.actual, false)] {
                let written = try await Written(
                    converted(
                        gray.path, ImageConversionOptions(format: format, size: size, keepMetadata: keepMetadata)))
                #expect(written.depth == 16, "\(format) \(size) \(keepMetadata)")
            }
        }

        let print = folder.appending("print.tiff")
        try Pictures.write([try #require(Pictures.cmyk(width: 200, height: 100))], as: .tiff, to: print)
        for format in [ImageFormat.jpeg, .png] {
            let written = try await Written(converted(print.path, ImageConversionOptions(format: format, size: exact)))
            #expect(written.size == PixelSize(width: 100, height: 80), "\(format)")
            let image = try written.upright
            // Cyan on the left (no red), yellow on the right (no blue).
            let (cyan, yellow) = (pixel(image, x: 10, y: 40), pixel(image, x: 90, y: 40))
            #expect(cyan[0] < 120 && cyan[2] > 150, "\(format) \(cyan)")
            #expect(yellow[0] > 200 && yellow[2] < 120, "\(format) \(yellow)")
        }
        // Made smaller it is still in CMYK where the format holds that, upright whichever way it was stored, and a
        // picture with no transparency gets none by being drawn again.
        for orientation in [1, 6] {
            let turned = folder.appending("print-\(orientation).jpg")
            try Pictures.write(
                [try #require(Pictures.cmyk(width: 200, height: 100))], as: .jpeg, to: turned,
                properties: [kCGImagePropertyOrientation: orientation])
            for format in [ImageFormat.jpeg, .tiff] {
                let written = try await Written(
                    converted(turned.path, ImageConversionOptions(format: format, size: .scale(50))))
                let label = "\(format) \(orientation)"
                #expect(written.properties[kCGImagePropertyColorModel] as? String == "CMYK", "\(label)")
                let expected = orientation == 1 ? PixelSize(width: 100, height: 50) : PixelSize(width: 50, height: 100)
                #expect(written.size == expected, "\(label)")
                #expect(written.orientation == 1, "\(label)")
            }
        }
        let opaque = folder.appending("opaque.jpg")
        try Pictures.write([Pictures.image(width: 200, height: 100)], as: .jpeg, to: opaque)
        for format in [ImageFormat.png, .tiff] {
            let written = try await Written(converted(opaque.path, ImageConversionOptions(format: format, size: exact)))
            #expect(written.properties[kCGImagePropertyHasAlpha] as? Bool != true, "\(format)")
        }
        // Written at its size without its metadata, it is decoded and written again, in every format.
        for format in ImageFormat.allCases {
            let written = try await Written(
                converted(print.path, ImageConversionOptions(format: format, keepMetadata: false)))
            #expect(written.size == PixelSize(width: 200, height: 100), "\(format)")
            let image = try written.upright
            let (cyan, yellow) = (pixel(image, x: 20, y: 50), pixel(image, x: 180, y: 50))
            #expect(cyan[0] < 120 && cyan[2] > 150, "\(format) \(cyan)")
            #expect(yellow[0] > 200 && yellow[2] < 120, "\(format) \(yellow)")
        }
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
        let exact = ImageSize.custom(width: 20, height: 20, unit: .pixels, proportional: false)
        // At its size, made smaller, drawn to another shape, and written without its metadata.
        for (size, keepMetadata) in [(ImageSize.actual, true), (.scale(50), true), (exact, true), (.actual, false)] {
            let white = try await Written(
                converted(url.path, ImageConversionOptions(format: .jpeg, size: size, keepMetadata: keepMetadata))
            ).topLeft
            #expect(white.allSatisfy { $0 >= 250 }, "\(size) \(keepMetadata) \(white)")
        }
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

    // A TIFF made from a HEIC with its metadata, at its size, is compressed too: written from the file as it is, it
    // came out uncompressed whatever was asked, some hundred times larger for a plain picture.
    @Test func aTIFFMadeFromAHEICIsCompressedToo() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let url = folder.appending("photo.heic")
        try Pictures.write(
            [Pictures.image(width: 800, height: 600)], as: .heic, to: url,
            properties: Pictures.cameraMetadata(orientation: 1))
        let data = try await converted(url.path, ImageConversionOptions(format: .tiff))
        let written = try Written(data)
        #expect(written.size == PixelSize(width: 800, height: 600))
        #expect(written.exifDate == Pictures.exifDate)
        // Uncompressed it is three bytes a pixel or more: 1.4 MB.
        #expect(data.count < 800 * 600)
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
