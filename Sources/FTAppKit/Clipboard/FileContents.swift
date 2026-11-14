import AppKit
import FTFoundation
import ImageIO
import UniformTypeIdentifiers

/// A file's image or text, read for Copy Contents, and how it goes on the system's clipboard.
enum FileContents: Equatable {
    /// The file's bytes as they are, under the type ImageIO found them to be, and a PNG copy where one is needed.
    case image(type: String, data: Data, png: Data?)
    /// The text, and the file itself when it is RTF, which keeps its styles.
    case text(String, rtf: Data?)

    var kind: CopyContentsKind {
        switch self {
        case .image: .image
        case .text: .text
        }
    }

    /// Why a file wasn't read.
    enum Failure: Error, Equatable {
        /// Larger than what is copied of it.
        case tooLarge(CopyContentsKind)
        /// Nothing in it.
        case empty
        /// A file whose name didn't say, and that is neither.
        case notImageOrText
        /// Named as an image, and not one ImageIO can open.
        case notAnImage
        /// Named as text, and not in an encoding that is read.
        case unknownEncoding
        /// The disk refused: its reason.
        case unreadable(String)
    }

    /// Reads the file at `path` (a link's target, for a link), off the main thread. `guess` is what its name said.
    nonisolated static func read(_ path: String, guess: CopyContentsGuess) async -> Result<FileContents, Failure> {
        await Task.detached(priority: .userInitiated) { readNow(path, guess: guess) }.value
    }

    nonisolated static func readNow(_ path: String, guess: CopyContentsGuess) -> Result<FileContents, Failure> {
        var info = stat()
        guard stat(path, &info) == 0 else { return .failure(.unreadable(String(cString: strerror(errno)))) }
        let size = Int64(info.st_size)
        switch guess {
        case .text where size > CopyContents.textLimit: return .failure(.tooLarge(.text))
        case .image, .unknown, .other:
            if size > CopyContents.imageLimit { return .failure(.tooLarge(guess == .image ? .image : .text)) }
        case .text: break
        }
        if size == 0 { return .failure(.empty) }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failure(.unreadable((error as NSError).localizedFailureReason ?? error.localizedDescription))
        }
        if data.isEmpty { return .failure(.empty) }
        switch guess {
        case .image:
            return image(data).map { .success($0) } ?? .failure(.notAnImage)
        case .text:
            return text(data, rtf: isRTF(path)).map { .success($0) } ?? .failure(.unknownEncoding)
        case .unknown, .other:
            if let image = image(data) { return .success(image) }
            if let text = text(data, rtf: false) {
                return Int64(data.count) > CopyContents.textLimit ? .failure(.tooLarge(.text)) : .success(text)
            }
            return .failure(.notImageOrText)
        }
    }

    private nonisolated static func isRTF(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .rtf) ?? false
    }

    /// The image in `data`, with a PNG copy for any format but PNG and JPEG; nil when ImageIO can't open it.
    nonisolated static func image(_ data: Data) -> FileContents? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source) as String?, CopyContents.isImageType(type)
        else { return nil }
        guard CopyContents.needsPNGCopy(type) else { return .image(type: type, data: data, png: nil) }
        guard let png = png(source) else { return nil }
        return .image(type: type, data: data, png: png)
    }

    /// The first image of `source` as PNG, at its full size and turned the way its orientation says.
    private nonisolated static func png(_ source: CGImageSource) -> Data? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The text in `data`; an RTF file is read for its text and kept for its styles.
    nonisolated static func text(_ data: Data, rtf: Bool) -> FileContents? {
        if rtf {
            guard
                let styled = try? NSAttributedString(
                    data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil)
            else { return nil }
            return .text(styled.string, rtf: data)
        }
        return CopyContents.decodeText(data).map { .text($0, rtf: nil) }
    }

    /// Puts it on `pasteboard` as one item, its richest type first; `concealed` marks it as private, as password
    /// managers mark what they copy. False when the pasteboard refused it.
    @MainActor
    func write(to pasteboard: NSPasteboard, concealed: Bool) -> Bool {
        let item = NSPasteboardItem()
        switch self {
        case .image(let type, let data, let png):
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
            if let png { item.setData(png, forType: .png) }
        case .text(let string, let rtf):
            if let rtf { item.setData(rtf, forType: .rtf) }
            item.setString(string, forType: .string)
        }
        if concealed { item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteAsFile.concealedType)) }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
