// What the Info panel shows of one item beyond its properties. Most of it comes from the file system's own attributes
// and Spotlight's record of the file, so the file isn't opened; what has to be read from the file itself (a picture's
// header or a PDF's pages where Spotlight has none, the lines of a text file) is never read from a file only in a
// cloud, which reading would download.
import AVFoundation
import CoreServices
import Darwin
import FTFoundation
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

public enum InfoDetailsReader {
    /// A text file larger than this isn't read to count its lines.
    static let textLimit = 10 * 1024 * 1024

    /// The details of the item at `path` (a link itself, not where it leads). Nil once `cancel` says the answer is no
    /// longer wanted; what it reads is cheap enough that it checks only between its parts.
    public static func read(_ path: String, cancel: ReadCancel = ReadCancel()) -> InfoDetails? {
        var details = InfoDetails()
        var info = stat()
        let stated = lstat(path, &info) == 0
        let url = URL(fileURLWithPath: path)
        let isFile = stated && (info.st_mode & S_IFMT) == S_IFREG
        let isDirectory = stated && (info.st_mode & S_IFMT) == S_IFDIR
        let dataless = stated && info.st_flags & UInt32(SF_DATALESS) != 0
        if stated {
            details.owner = owner(info, path: path)
            details.flags = InfoDetails.Flags(
                locked: info.st_flags & UInt32(UF_IMMUTABLE) != 0, hidden: info.st_flags & UInt32(UF_HIDDEN) != 0)
            details.more.fileID = UInt64(info.st_ino)
            details.more.linkCount = Int(info.st_nlink)
        }
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .contentTypeKey, .hasHiddenExtensionKey, .isUbiquitousItemKey,
        ]
        if stated {
            let disk = VolumeNames.of(path, device: info.st_dev, url: url)
            details.more.volumeName = disk.name
            details.more.volumeFormat = disk.format
        }
        if let values = try? url.resourceValues(forKeys: keys) {
            if isFile { details.sizeOnDisk = values.totalFileAllocatedSize.map(Int64.init) }
            details.more.contentType = values.contentType?.identifier
            details.flags.extensionHidden = values.hasHiddenExtension ?? false
            if dataless {
                details.more.cloud = .cloudOnly
            } else if values.isUbiquitousItem == true {
                details.more.cloud = .downloaded
            }
        }
        if cancel.isCancelled { return nil }
        // The home folder's Desktop, Documents and Downloads themselves aren't read: macOS would ask first.
        if !FinderTags.asksPermission(path) {
            details.more.attributes = (ExtendedAttributes.names(path) ?? []).sorted()
            details.download = download(path)
        }
        if cancel.isCancelled { return nil }
        // Finder's comment is one of the item's attributes: read only when it has one.
        if details.more.attributes.contains(commentAttribute) { details.comment = comment(path) }
        let type = details.more.contentType.flatMap(UTType.init)
        let kind = InfoContentKind.of(type)
        // A file on the disk is read for its own header (a picture's, a PDF's, a movie's), which costs less than asking
        // Spotlight and needs no index; Spotlight is asked for a file kept only in the cloud, which reading would
        // download, and for what only it reads (a Word or Pages document).
        switch kind {
        case .image: details.image = image(path: path, readFile: isFile && !dataless)
        case .movie, .sound: details.media = media(path: path, readFile: isFile && !dataless, cancel: cancel)
        case .pdf, .document:
            details.document = document(path: path, isPDF: kind == .pdf, readFile: isFile && !dataless)
        case .text, .other: break
        }
        if cancel.isCancelled { return nil }
        if isFile, !dataless, kind == .text, Int(info.st_size) <= textLimit {
            details.text = TextFacts.of(path, info, cancel: cancel) { text(path, cancel: cancel) }
        }
        if isDirectory, let type, type.conforms(to: .application) || type.conforms(to: .bundle) {
            let app = app(path)
            details.app = app.isEmpty ? nil : app
        }
        if VolumePaths.isVolumeRootPath(path) { details.volume = volume(path, url: url) }
        if cancel.isCancelled { return nil }
        return details
    }

    // MARK: Owner

    private static func owner(_ info: stat, path: String) -> InfoDetails.Owner {
        let user = getpwuid(info.st_uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? "\(info.st_uid)"
        let group = getgrgid(info.st_gid).flatMap { String(validatingCString: $0.pointee.gr_name) } ?? "\(info.st_gid)"
        let read = access(path, R_OK) == 0
        let write = access(path, W_OK) == 0
        let youCan =
            read && write ? "Read & Write" : read ? "Read only" : write ? "Write only" : "No Access"
        return InfoDetails.Owner(user: user, group: group, isYou: info.st_uid == getuid(), youCan: youCan)
    }

    // MARK: Downloads

    /// Where the file came from: the addresses Safari and the other browsers keep, and the quarantine mark's app and
    /// time (`flags;hex seconds;agent;id`). Nil for a file with neither.
    static func download(_ path: String) -> InfoDetails.Download? {
        let froms = DownloadMarks.whereFroms(path)
        var result = InfoDetails.Download(from: froms.first, page: froms.count > 1 ? froms[1] : nil)
        let size = getxattr(path, DownloadMarks.quarantine, nil, 0, 0, XATTR_NOFOLLOW)
        if size > 0, size < 4096 {
            var bytes = [UInt8](repeating: 0, count: size)
            if getxattr(path, DownloadMarks.quarantine, &bytes, size, 0, XATTR_NOFOLLOW) == size {
                let fields = String(decoding: bytes, as: UTF8.self).split(
                    separator: ";", omittingEmptySubsequences: false)
                if fields.count > 1, let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
                    result.date = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
                if fields.count > 2, !fields[2].isEmpty { result.agent = String(fields[2]) }
            }
        }
        return result == InfoDetails.Download() ? nil : result
    }

    /// Where Finder keeps an item's comment: a binary property list of one string.
    static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    static func comment(_ path: String) -> String? {
        let size = getxattr(path, commentAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 1 << 16 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(path, commentAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { return nil }
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Spotlight

    /// Spotlight's record of an item, asked one attribute at a time.
    struct Spotlight {
        let item: MDItem?

        init(_ path: String) { item = MDItemCreate(kCFAllocatorDefault, path as CFString) }

        func value(_ key: CFString) -> Any? { item.flatMap { MDItemCopyAttribute($0, key) } }
        func string(_ key: CFString) -> String? { value(key) as? String }
        func strings(_ key: CFString) -> [String] { (value(key) as? [String]) ?? [] }
        func number(_ key: CFString) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        func int(_ key: CFString) -> Int? { (value(key) as? NSNumber)?.intValue }
        func bool(_ key: CFString) -> Bool? { (value(key) as? NSNumber)?.boolValue }
        func date(_ key: CFString) -> Date? { value(key) as? Date }
    }

    // MARK: Pictures

    static func image(path: String, readFile: Bool) -> InfoDetails.Image? {
        var image = InfoDetails.Image()
        if readFile { fillFromHeader(&image, path: path) }
        if image.width == nil { fillFromSpotlight(&image, Spotlight(path)) }
        return image.isEmpty ? nil : image
    }

    private static func fillFromSpotlight(_ image: inout InfoDetails.Image, _ spotlight: Spotlight) {
        image.width = spotlight.int(kMDItemPixelWidth)
        image.height = spotlight.int(kMDItemPixelHeight)
        image.dpi = spotlight.number(kMDItemResolutionWidthDPI)
        image.colorProfile = spotlight.string(kMDItemProfileName)
        image.colorModel = spotlight.string(kMDItemColorSpace)
        image.bitsPerChannel = spotlight.int(kMDItemBitsPerSample)
        image.hasAlpha = spotlight.bool(kMDItemHasAlphaChannel)
        image.camera = camera(
            make: spotlight.string(kMDItemAcquisitionMake), model: spotlight.string(kMDItemAcquisitionModel))
        image.lens = spotlight.string(kMDItemLensModel)
        image.exposureSeconds = spotlight.number(kMDItemExposureTimeSeconds)
        image.fNumber = spotlight.number(kMDItemFNumber)
        image.iso = spotlight.int(kMDItemISOSpeed)
        image.flash = spotlight.bool(kMDItemFlashOnOff)
        image.focalLength35mm = spotlight.number(kMDItemFocalLength35mm)
        image.taken = spotlight.date(kMDItemContentCreationDate)
        image.latitude = spotlight.number(kMDItemLatitude)
        image.longitude = spotlight.number(kMDItemLongitude)
    }

    /// "Apple iPhone 16 Pro" reads "iPhone 16 Pro": a model that starts with its maker's name keeps it once.
    static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty
            || model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "")
        {
            return model
        }
        return make == "Apple" ? model : "\(make) \(model)"
    }

    private static func fillFromHeader(_ image: inout InfoDetails.Image, path: String) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return }
        image.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        image.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        image.dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        image.colorProfile = properties[kCGImagePropertyProfileName] as? String
        image.colorModel = properties[kCGImagePropertyColorModel] as? String
        image.bitsPerChannel = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        image.hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            image.camera = camera(
                make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String)
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            image.lens = exif[kCGImagePropertyExifLensModel] as? String
            image.exposureSeconds = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            image.fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            image.iso = ((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.intValue
            image.focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
            if let flash = (exif[kCGImagePropertyExifFlash] as? NSNumber)?.intValue { image.flash = flash & 1 == 1 }
            if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                image.taken = exifDate(taken, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            }
        }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
            let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        {
            image.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            image.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
    }

    /// EXIF's "2026:11:24 09:12:03", in its offset ("+03:00") where it has one, else in the Mac's time zone.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXX"
        return formatter.date(from: text + (offset ?? ""))
    }

    // MARK: Movies and sound

    static func media(path: String, readFile: Bool, cancel: ReadCancel = ReadCancel()) -> InfoDetails.Media? {
        var media = InfoDetails.Media()
        if readFile { fillFromAsset(&media, path: path, cancel: cancel) }
        if media.seconds == nil { fillFromSpotlight(&media, Spotlight(path)) }
        return media.isEmpty ? nil : media
    }

    private static func fillFromSpotlight(_ media: inout InfoDetails.Media, _ spotlight: Spotlight) {
        media.seconds = spotlight.number(kMDItemDurationSeconds)
        media.width = spotlight.int(kMDItemPixelWidth)
        media.height = spotlight.int(kMDItemPixelHeight)
        media.codecs = spotlight.strings(kMDItemCodecs)
        media.bitRate = spotlight.number(kMDItemTotalBitRate)
        media.sampleRate = spotlight.number(kMDItemAudioSampleRate)
        media.channels = spotlight.int(kMDItemAudioChannelCount)
        media.title = spotlight.string(kMDItemTitle)
        media.artist = spotlight.strings(kMDItemAuthors).first
        media.album = spotlight.string(kMDItemAlbum)
    }

    /// How long a wait for AVFoundation's answer may be before the panel goes on without it.
    static let assetPatience = 2.0

    private static func fillFromAsset(_ media: inout InfoDetails.Media, path: String, cancel: ReadCancel) {
        let box = AssetFacts()
        let done = DispatchSemaphore(value: 0)
        // This runs on a thread of its own (`BlockingWork`), not one of Swift's, so waiting here holds no one up.
        let load = Task.detached {
            await box.load(URL(fileURLWithPath: path))
            done.signal()
        }
        // Waited in steps, so a read no longer wanted lets go of its thread at once; AVFoundation is told to stop
        // too, so it lets go of the file instead of reading on for an answer no one takes.
        let deadline = DispatchTime.now() + assetPatience
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancel.isCancelled || DispatchTime.now() >= deadline {
                load.cancel()
                return
            }
        }
        guard let read = box.media else { return }
        media.seconds = media.seconds ?? read.seconds
        media.width = media.width ?? read.width
        media.height = media.height ?? read.height
        if media.codecs.isEmpty { media.codecs = read.codecs }
        media.bitRate = media.bitRate ?? read.bitRate
        media.sampleRate = media.sampleRate ?? read.sampleRate
        media.channels = media.channels ?? read.channels
        media.title = media.title ?? read.title
        media.artist = media.artist ?? read.artist
        media.album = media.album ?? read.album
    }

    /// What AVFoundation reads of a movie or a sound file, handed from its task to the waiting thread.
    private final class AssetFacts: @unchecked Sendable {
        private let lock = NSLock()
        private var value: InfoDetails.Media?
        var media: InfoDetails.Media? { lock.withLock { value } }

        func load(_ url: URL) async {
            let asset = AVURLAsset(url: url)
            var media = InfoDetails.Media()
            if let duration = try? await asset.load(.duration), duration.isNumeric {
                media.seconds = duration.seconds
            }
            var codecs: [String] = []
            var bits = 0.0
            for track in (try? await asset.load(.tracks)) ?? [] {
                bits += Double((try? await track.load(.estimatedDataRate)) ?? 0)
                for description in (try? await track.load(.formatDescriptions)) ?? [] {
                    let name = codecName(CMFormatDescriptionGetMediaSubType(description))
                    if !codecs.contains(name) { codecs.append(name) }
                    if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        media.sampleRate = media.sampleRate ?? basic.mSampleRate
                        media.channels = media.channels ?? Int(basic.mChannelsPerFrame)
                    }
                }
                if track.mediaType == .video, media.width == nil,
                    let size = try? await track.load(.naturalSize),
                    let transform = try? await track.load(.preferredTransform)
                {
                    let turned = size.applying(transform)
                    media.width = Int(abs(turned.width).rounded())
                    media.height = Int(abs(turned.height).rounded())
                }
            }
            media.codecs = codecs
            if bits > 0 { media.bitRate = bits }
            for item in (try? await asset.load(.commonMetadata)) ?? [] {
                guard let key = item.commonKey, let text = try? await item.load(.stringValue) else { continue }
                if key == .commonKeyTitle { media.title = text }
                if key == .commonKeyArtist { media.artist = text }
                if key == .commonKeyAlbumName { media.album = text }
            }
            lock.withLock { value = media }
        }
    }

    /// A codec's name as people know it, from its four letters.
    static func codecName(_ code: FourCharCode) -> String {
        let letters =
            String(
                bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
        let names: [String: String] = [
            "avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "apcn": "ProRes 422",
            "apch": "ProRes 422 HQ", "apcs": "ProRes 422 LT", "apco": "ProRes 422 Proxy", "ap4h": "ProRes 4444",
            "aac ": "AAC", "alac": "Apple Lossless", ".mp3": "MP3", "lpcm": "PCM", "ac-3": "AC-3", "ec-3": "E-AC-3",
            "opus": "Opus", "fLaC": "FLAC", "mp4a": "AAC",
        ]
        return names[letters] ?? letters.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Documents

    static func document(path: String, isPDF: Bool, readFile: Bool) -> InfoDetails.Document? {
        var document = InfoDetails.Document()
        if isPDF, readFile { fillFromPDF(&document, path: path) }
        if document.pages == nil { fillFromSpotlight(&document, Spotlight(path), isPDF: isPDF) }
        return document.isEmpty ? nil : document
    }

    private static func fillFromSpotlight(_ document: inout InfoDetails.Document, _ spotlight: Spotlight, isPDF: Bool) {
        document.pages = spotlight.int(kMDItemNumberOfPages)
        document.pageWidth = spotlight.number(kMDItemPageWidth)
        document.pageHeight = spotlight.number(kMDItemPageHeight)
        document.title = spotlight.string(kMDItemTitle).flatMap { $0.isEmpty ? nil : $0 }
        document.authors = spotlight.strings(kMDItemAuthors)
        document.madeWith = spotlight.string(kMDItemCreator) ?? spotlight.strings(kMDItemEncodingApplications).first
        document.version = isPDF ? spotlight.string(kMDItemVersion) : nil
        if isPDF, let method = spotlight.string(kMDItemSecurityMethod) { document.locked = method != "None" }
    }

    /// The PDF's own pages, from its cross-reference table, and what its information dictionary says.
    private static func fillFromPDF(_ document: inout InfoDetails.Document, path: String) {
        guard let pdf = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { return }
        do {
            document.pages = pdf.numberOfPages
            document.locked = pdf.isEncrypted
            var major: Int32 = 0
            var minor: Int32 = 0
            pdf.getVersion(majorVersion: &major, minorVersion: &minor)
            if major > 0 { document.version = "\(major).\(minor)" }
            if let page = pdf.page(at: 1) {
                let box = page.getBoxRect(.mediaBox)
                let turned = page.rotationAngle % 180 != 0
                document.pageWidth = Double(turned ? box.height : box.width)
                document.pageHeight = Double(turned ? box.width : box.height)
            }
        }
        if let info = pdf.info {
            func text(_ key: String) -> String? {
                var value: CGPDFStringRef?
                guard CGPDFDictionaryGetString(info, key, &value), let value,
                    let string = CGPDFStringCopyTextString(value) as String?, !string.isEmpty
                else { return nil }
                return string
            }
            document.title = text("Title")
            document.authors = text("Author").map { [$0] } ?? []
            document.madeWith = text("Creator") ?? text("Producer")
        }
    }

    // MARK: Text

    /// Its lines, encoding and line endings, decoded as the viewer decodes it. Nil for one that doesn't decode as text,
    /// or once `cancel` says the answer is no longer wanted.
    static func text(_ path: String, cancel: ReadCancel = ReadCancel()) -> InfoDetails.Text? {
        guard let data = contents(path, cancel: cancel) else { return nil }
        if data.isEmpty { return InfoDetails.Text(lines: 0, encoding: "UTF-8", lineEnding: "None") }
        guard let decoded = TextDecoding.decode(data) else { return nil }
        // Counted on its UTF-8 bytes: a line ends at LF, CRLF or a CR alone, and a last line with no ending counts.
        var lines = 0
        var previous: UInt8 = 0
        for byte in decoded.text.utf8 {
            if byte == 0x0A {
                if previous != 0x0D { lines += 1 }
            } else if byte == 0x0D {
                lines += 1
            }
            previous = byte
        }
        if previous != 0x0A, previous != 0x0D { lines += 1 }
        return InfoDetails.Text(
            lines: lines, encoding: decoded.format.encodingName,
            lineEnding: lines > 1 ? decoded.format.lineEnding.rawValue : "None")
    }

    /// The file's bytes, read a piece at a time so a read no longer wanted stops within a piece. Nil when it can't
    /// be read or was cancelled.
    private static func contents(_ path: String, cancel: ReadCancel) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while true {
            if cancel.isCancelled { return nil }
            do {
                // Nothing more, or nothing at all, at the file's end.
                guard let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty else { return data }
                data.append(piece)
            } catch {
                return nil
            }
        }
    }

    // MARK: Apps

    /// What the app's own Info.plist says, read from the file each time: `Bundle` keeps the one it read first for as
    /// long as the app runs, so an app updated meanwhile would go on showing its version of before.
    static func app(_ path: String) -> InfoDetails.App {
        var app = InfoDetails.App()
        let url = URL(fileURLWithPath: path)
        // A Mac app keeps it in Contents; one made for iPhone or iPad, in the app wrapped inside it.
        let lists = ["Contents/Info.plist", "WrappedBundle/Info.plist", "Info.plist"].map {
            url.appendingPathComponent($0)
        }
        guard
            let info = lists.lazy.compactMap({ list -> [String: Any]? in
                guard let data = try? Data(contentsOf: list) else { return nil }
                return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            }).first
        else { return app }
        app.version = info["CFBundleShortVersionString"] as? String
        app.build = info["CFBundleVersion"] as? String
        if app.build == app.version { app.build = nil }
        app.identifier = info["CFBundleIdentifier"] as? String
        app.minimumSystem = info["LSMinimumSystemVersion"] as? String
        app.copyright = info["NSHumanReadableCopyright"] as? String
        let architectures = Set(executableArchitectures(of: url, info: info))
        let arm = architectures.contains(NSBundleExecutableArchitectureARM64)
        let intel = architectures.contains(NSBundleExecutableArchitectureX86_64)
        app.runsOn = arm && intel ? "Apple Silicon and Intel" : arm ? "Apple Silicon" : intel ? "Intel" : nil
        return app
    }

    /// The processors the app's program is built for, read from the program itself.
    private static func executableArchitectures(of app: URL, info: [String: Any]) -> [Int] {
        guard let name = info["CFBundleExecutable"] as? String, !name.isEmpty else { return [] }
        let places = ["Contents/MacOS/\(name)", "WrappedBundle/\(name)", name].map { app.appendingPathComponent($0) }
        guard let program = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return [] }
        return (CFBundleCopyExecutableArchitecturesForURL(program as CFURL) as? [NSNumber])?.map(\.intValue) ?? []
    }

    /// Who signed the app and whether Apple notarized it, without checking its files or going online: a few
    /// milliseconds for most apps, up to a few hundred for a large one.
    public static func signing(_ path: String) -> InfoDetails.Signing? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        if status == errSecCSUnsigned { return InfoDetails.Signing(signedBy: "Not signed", notarized: nil) }
        guard status == errSecSuccess, let info = information as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        guard let leaf = certificates.first else {
            let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
            return InfoDetails.Signing(signedBy: adhoc ? "Ad hoc" : "Not signed", notarized: nil)
        }
        let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        let signedBy = signer(summary)
        guard signedBy.hasPrefix("Developer ID") else { return InfoDetails.Signing(signedBy: signedBy, notarized: nil) }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess else {
            return InfoDetails.Signing(signedBy: signedBy, notarized: nil)
        }
        let check = SecCSFlags(
            rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources | SecCSFlags.noNetworkAccess.rawValue
        )
        let notarized = SecStaticCodeCheckValidity(code, check, requirement) == errSecSuccess
        return InfoDetails.Signing(signedBy: signedBy, notarized: notarized)
    }

    /// The signer as the panel names it, from the signing certificate's name.
    static func signer(_ summary: String) -> String {
        if summary.hasPrefix("Developer ID Application: ") {
            var name = String(summary.dropFirst("Developer ID Application: ".count))
            // The team's ID in brackets is in More's place, not here.
            if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") {
                name = String(name[..<open.lowerBound])
            }
            return "Developer ID · \(name)"
        }
        if summary == "Apple Mac OS Application Signing" { return "Mac App Store" }
        if summary.hasPrefix("Apple Development: ") || summary.hasPrefix("Mac Developer: ") { return "Development" }
        if summary.hasSuffix("Software Signing") || summary.hasPrefix("Apple ") { return "Apple" }
        return summary
    }

    // MARK: Disks

    static func volume(_ path: String, url: URL) -> InfoDetails.Volume {
        var volume = InfoDetails.Volume()
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedFormatDescriptionKey, .volumeIsEncryptedKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            volume.format = values.volumeLocalizedFormatDescription
            volume.encrypted = values.volumeIsEncrypted
            volume.ejectable = values.volumeIsEjectable
            if values.volumeIsLocal == false {
                volume.connection = "Network"
            } else if values.volumeIsInternal == true {
                volume.connection = "Internal"
            } else if values.volumeIsInternal == false || values.volumeIsRemovable == true {
                volume.connection = "External"
            }
            if let important = values.volumeAvailableCapacityForImportantUsage,
                let available = values.volumeAvailableCapacity, important > Int64(available)
            {
                volume.purgeableBytes = important - Int64(available)
            }
        }
        var fs = statfs()
        if statfs(path, &fs) == 0 {
            volume.mountPoint = withUnsafeBytes(of: fs.f_mntonname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let device = withUnsafeBytes(of: fs.f_mntfromname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            volume.device = device.hasPrefix("/dev/") ? String(device.dropFirst(5)) : device
            volume.ignoresOwnership = fs.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0
        }
        return volume
    }
}

extension SecCSFlags {
    /// `kSecCSNoNetworkAccess` (CSCommon.h), which Swift doesn't bring in: the check never goes online.
    static let noNetworkAccess = SecCSFlags(rawValue: 1 << 29)
}

/// A disk's name and format, kept for each disk while the app runs: macOS takes about 6 ms to say them, more than
/// everything else the Info panel reads of an item together, and they don't change while the disk is mounted.
enum VolumeNames {
    private struct Key: Hashable {
        var device: dev_t
        /// Where it is mounted: a device number can come back for another disk after an eject and a mount, and a disk
        /// renamed is mounted again at its new name.
        var mountPoint: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [Key: (name: String?, format: String?)] = [:]

    static func of(_ path: String, device: dev_t, url: URL) -> (name: String?, format: String?) {
        var fs = statfs()
        let mountPoint =
            statfs(path, &fs) == 0
            ? withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
        let key = Key(device: device, mountPoint: mountPoint)
        if let kept = lock.withLock({ known[key] }) { return kept }
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeLocalizedFormatDescriptionKey])
        let read = (values?.volumeLocalizedName, values?.volumeLocalizedFormatDescription)
        lock.withLock { known[key] = read }
        return read
    }
}

/// The lines, encoding and line endings counted of text files, kept while the app runs by the file as it was then (its
/// file ID, size and the time it changed): a folder read again asks for its selected item's details again, and a file
/// that hasn't changed isn't read whole a second time for the same answer.
enum TextFacts {
    private struct Stamp: Equatable {
        var file: ino_t
        var device: dev_t
        var size: off_t
        var seconds: Int
        var nanoseconds: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: (stamp: Stamp, text: InfoDetails.Text?)] = [:]
    static let limit = 64

    /// What was counted of the file as `info` describes it, else what `count` answers, kept unless `count` was
    /// cancelled (it answers nil then, as for a file that isn't text; the next ask counts again).
    static func of(_ path: String, _ info: stat, cancel: ReadCancel = ReadCancel(), count: () -> InfoDetails.Text?)
        -> InfoDetails.Text?
    {
        let stamp = Stamp(
            file: info.st_ino, device: info.st_dev, size: info.st_size, seconds: info.st_mtimespec.tv_sec,
            nanoseconds: info.st_mtimespec.tv_nsec)
        if let kept = lock.withLock({ known[path] }), kept.stamp == stamp { return kept.text }
        let text = count()
        if cancel.isCancelled { return text }
        lock.withLock {
            if known.count >= limit { known.removeAll() }
            known[path] = (stamp, text)
        }
        return text
    }
}
