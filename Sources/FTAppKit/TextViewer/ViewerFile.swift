import AppKit
import FTFileSystem
import FTFoundation
import PDFKit
import UniformTypeIdentifiers

/// A file as the viewer reads it. Unchecked for its picture and its PDF, which are made off the main actor and only read
/// on it.
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

    /// Where the file is: where it was read, and where it was found since if it was moved or renamed.
    var path: String
    let content: Content
    let modified: Date?
    let size: Int64
    /// A picture's image, read with the file.
    var image: NSImage?
    /// A PDF's pages, read with the file; none for one locked with a password, which Quick Look shows and asks for.
    var pdf: PDFDocument?
    /// The file as what it is, to find it again where it is moved or renamed; nil for one that can't be read.
    var identity: ViewerFileIdentity?

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
        let url = DiskPath(path).url(isDirectory: false)
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
        ])
        let modified = values?.contentModificationDate
        let size = Int64(values?.fileSize ?? 0)
        let identity = values == nil ? nil : ViewerFileIdentity(path: path)
        func file(_ content: Content) -> ViewerFile {
            ViewerFile(path: path, content: content, modified: modified, size: size, identity: identity)
        }
        guard let values else { return file(.unreadable("The file can’t be read.")) }
        if values.isDirectory == true { return file(values.isPackage == true ? .other : .folder) }
        // A name the viewer knows is read as text, whatever the system takes it for: `.ts` is a video to it.
        let named = TextLanguage.detect(fileName: NodePath.basename(path)) != .plainText
        if !named, let type = values.contentType, !type.conforms(to: .text),
            previewTypes.contains(where: { type.conforms(to: $0) })
        {
            var picture = file(.other)
            if type.conforms(to: .image), let image = NSImage(contentsOf: url), image.isValid {
                picture.image = image
            } else if type.conforms(to: .pdf), let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 {
                picture.pdf = pdf
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
        let language = TextLanguage.detect(fileName: NodePath.basename(path), firstLine: firstLine)
        return file(.text(text, format, language, TextDecoding.indentation(of: text)))
    }

    /// Writes `text` over the file at `path` as `format` says. The file is written beside its original and then put in
    /// its place, which keeps the original's permissions, tags and dates as the system's replace does; a link is
    /// followed to the file it names.
    static func write(_ text: String, as format: TextFormat, to path: String) throws -> Date? {
        guard let data = TextDecoding.encode(text, as: format) else {
            throw ViewerSaveError.encoding(format.encodingName)
        }
        // A link is followed to the file it names, as the disk spells it.
        let url = DiskPath(path).asOnDisk().url(isDirectory: false)
        let manager = FileManager.default
        let folder = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? manager.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(NodePath.basename(path))
        try data.write(to: temporary)
        if access(DiskPath(path).string, F_OK) == 0 {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            // A file that went (to the Trash, or deleted) is put back where it was: there is nothing to replace.
            try manager.moveItem(at: temporary, to: url)
        }
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

/// A file known by what it is rather than by its path, as a document app knows its file: moved or renamed on its
/// disk, by this app or another, it is found where it went. Not found once it is deleted or moved to another disk,
/// which makes another file of it. Held as a bookmark, which finds the file by its identity on the disk: a file
/// reference URL is the same, but Swift's `URL` turns one back into the path it had.
struct ViewerFileIdentity: Sendable {
    private let bookmark: Data

    init?(path: String) {
        guard let bookmark = try? DiskPath(path).url(isDirectory: false).bookmarkData(options: [.minimalBookmark])
        else { return nil }
        self.bookmark = bookmark
    }

    /// Where the file is now, as the disk spells it; nil once it is gone. Nothing is mounted or asked of the user to
    /// find it.
    var currentPath: String? {
        var stale = false
        guard
            let found = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
            let path = DiskPath(urlSpelling: found)
        else { return nil }
        let onDisk = path.asOnDisk()
        return access(onDisk.string, F_OK) == 0 ? onDisk.string : nil
    }
}
