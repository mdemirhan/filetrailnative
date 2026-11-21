import AppKit
import FTFileSystem
import FTFoundation
import UniformTypeIdentifiers

/// A file as the viewer reads it. Unchecked for its picture, which is made off the main actor and only read on it.
struct ViewerFile: @unchecked Sendable {
    enum Content: Sendable {
        case text(String, TextFormat, TextLanguage, Indentation?)
        /// Not text: Quick Look shows it.
        case other
        case folder
        /// Text, but more than the viewer reads.
        case tooLarge(Int64)
        case unreadable(String)
    }

    let path: String
    let content: Content
    let modified: Date?
    let size: Int64
    /// A picture's image, read with the file.
    var image: NSImage?

    /// A file up to this size is shown and can be edited.
    static let viewLimit: Int64 = 50 * 1024 * 1024

    /// What Quick Look shows better than text: pictures, movies, sound, PDFs, fonts, archives, apps, documents.
    private static let previewTypes: [UTType] = [
        .image, .audiovisualContent, .pdf, .font, .archive, .diskImage, .application, .bundle, .presentation,
        .spreadsheet, .executable,
    ]

    /// Reads `path`, off the main actor.
    static func read(_ path: String) async -> ViewerFile {
        await Task.detached(priority: .userInitiated) { readNow(path) }.value
    }

    /// A symbolic link or an alias is read as its original, which its `path` is then: what is saved goes there, not
    /// over the link.
    static func readNow(_ shownPath: String) -> ViewerFile {
        guard let path = Links.original(of: shownPath) else {
            return ViewerFile(
                path: shownPath,
                content: .unreadable(
                    "The original of \u{201C}\(NodePath.basename(shownPath))\u{201D} can\u{2019}t be found."),
                modified: nil, size: 0)
        }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
        ])
        let modified = values?.contentModificationDate
        let size = Int64(values?.fileSize ?? 0)
        func file(_ content: Content) -> ViewerFile {
            ViewerFile(path: path, content: content, modified: modified, size: size)
        }
        guard let values else { return file(.unreadable("The file can’t be read.")) }
        if values.isDirectory == true { return file(values.isPackage == true ? .other : .folder) }
        // A name the viewer knows is read as text, whatever the system takes it for: `.ts` is a video to it.
        let named = TextLanguage.detect(fileName: url.lastPathComponent) != .plainText
        if !named, let type = values.contentType, !type.conforms(to: .text),
            previewTypes.contains(where: { type.conforms(to: $0) })
        {
            var picture = file(.other)
            if type.conforms(to: .image), let image = NSImage(contentsOf: url), image.isValid {
                picture.image = image
            }
            return picture
        }
        if size > viewLimit {
            let prefix = (try? FileHandle(forReadingFrom: url))
                .flatMap { handle in
                    defer { try? handle.close() }
                    return try? handle.read(upToCount: TextDecoding.sniffLength)
                }
            return file(prefix.map(TextDecoding.looksLikeText) == true ? .tooLarge(size) : .other)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return file(.unreadable("The file can’t be read. \(error.localizedDescription)"))
        }
        guard let (text, format) = TextDecoding.decode(data) else { return file(.other) }
        let firstLine = text.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        let language = TextLanguage.detect(fileName: url.lastPathComponent, firstLine: firstLine)
        return file(.text(text, format, language, TextDecoding.indentation(of: text)))
    }

    /// Writes `text` over the file at `path` as `format` says. The file is written beside its original and then put in
    /// its place, which keeps the original's permissions, tags and dates as the system's replace does; a link is
    /// followed to the file it names.
    static func write(_ text: String, as format: TextFormat, to path: String) throws -> Date? {
        guard let data = TextDecoding.encode(text, as: format) else {
            throw ViewerSaveError.encoding(format.encodingName)
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let manager = FileManager.default
        let folder = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

enum ViewerSaveError: LocalizedError {
    case encoding(String)

    var errorDescription: String? {
        switch self {
        case .encoding(let name): "Some characters can’t be written in \(name), the file’s encoding."
        }
    }
}
