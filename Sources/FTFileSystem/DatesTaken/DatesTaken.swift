// Port of packages/native-fs/src/native_datestaken.m (and nativeDatesTaken in packages/native-fs/index.js)
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// When photos were taken, for renaming by date.
public enum DatesTaken {
    /// One answer per path, in order: "2026-05-14T18:02:11" on the clock of this Mac, or nil when the item has no
    /// such date (it isn't a photo, has no metadata, or can't be read). Reading many files takes a while, so it
    /// runs off the caller's thread.
    public static func read(_ paths: [String]) async -> [String?] {
        await Task.detached(priority: .userInitiated) { paths.map(dateTaken) }.value
    }

    /// "2026:05:14 18:02:11" (EXIF) becomes "2026-05-14T18:02:11"; nil for anything else.
    static func localDate(fromExif value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count >= 19 else { return nil }
        for position in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) else { return nil }
        }
        // Cameras that don't know the date write zeros, or spaces.
        if bytes.starts(with: Array("0000".utf8)) { return nil }
        func part(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        return "\(part(0..<4))-\(part(5..<7))-\(part(8..<10))T\(part(11..<13)):\(part(14..<16)):\(part(17..<19))"
    }

    /// The date the camera wrote into the file: EXIF DateTimeOriginal, else DateTimeDigitized. A local time
    /// without a zone, passed on as it is. Only the file's header is read, not its picture.
    private static func photoDate(_ url: URL) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return localDate(fromExif: exif[kCGImagePropertyExifDateTimeOriginal])
            ?? localDate(fromExif: exif[kCGImagePropertyExifDateTimeDigitized])
    }

    private static func dateTaken(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) else { return nil }
        return photoDate(url)
    }
}
