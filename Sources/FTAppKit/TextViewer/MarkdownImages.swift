import AppKit
import FTFileSystem
import UniformTypeIdentifiers

/// The pictures a Markdown file's Preview shows, read from the disk: a path relative to the file, or a `file:` address.
/// One on the web is never fetched and shows as its text, as does one that can't be read.
struct MarkdownImages: Sendable {
    /// A picture is read at most this many pixels on its longer side: as wide as a pane at full width on a large
    /// screen. Its size in the text is its pixels as points, as a browser shows it, shrunk to fit the pane.
    static let side = 2048
    /// What one file's pictures may take in memory, decoded: those past it show as their text, so a file of a hundred
    /// photos can't take gigabytes.
    static let budget = 256 * 1024 * 1024

    private var images: [URL: NSImage] = [:]
    /// Tried and not read: not there, not a picture, or past the budget.
    private var unread: Set<URL> = []
    private(set) var bytes = 0

    subscript(url: URL) -> NSImage? { images[url.standardizedFileURL] }

    /// Whether `url` (standardized) has been read or found unreadable.
    func tried(_ url: URL) -> Bool { images[url] != nil || unread.contains(url) }

    /// The pictures on the disk that `markdown` names, each once, in order, read off the main actor with the file, so
    /// its Preview shows them from the first; `file`: the Markdown file's own address.
    nonisolated static func read(in markdown: String, file: URL) -> MarkdownImages {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options, baseURL: file) else {
            return MarkdownImages()
        }
        var named: [URL] = []
        for run in parsed.runs {
            let inline = run.inlinePresentationIntent ?? []
            let urls =
                inline.contains(.blockHTML) || inline.contains(.inlineHTML)
                ? MarkdownHTML.files(in: String(parsed[run.range].characters), file: file)
                : run.imageURL.flatMap { $0.isFileURL ? [$0.absoluteURL.standardizedFileURL] : nil } ?? []
            for url in urls where !named.contains(url) { named.append(url) }
        }
        return read(named, spent: 0)
    }

    /// Reads `urls`, off the main actor, as long as what is read stays within the budget with `spent` already taken.
    nonisolated static func read(_ urls: [URL], spent: Int) -> MarkdownImages {
        var read = MarkdownImages()
        read.bytes = spent
        for url in urls {
            guard let (image, cost) = picture(at: url), read.bytes + cost <= budget else {
                read.unread.insert(url)
                continue
            }
            read.images[url] = image
            read.bytes += cost
        }
        read.bytes -= spent
        return read
    }

    /// What `other` read, added: pictures read meanwhile for the same file.
    mutating func add(_ other: MarkdownImages) {
        images.merge(other.images) { mine, _ in mine }
        unread.formUnion(other.unread)
        bytes += other.bytes
    }

    /// The picture at `url`, upright and its longer side at most `side`, with what it takes in memory decoded; a
    /// drawing (SVG, PDF) as the system draws it, which takes next to nothing until it is drawn.
    private nonisolated static func picture(at url: URL) -> (NSImage, Int)? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values?.isRegularFile == true else { return nil }
        if let image = QuickLookThumbnailRenderer.decodedImage(url, side: side) {
            return (
                NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
                image.bytesPerRow * image.height
            )
        }
        // ImageIO reads no drawing; NSImage does, and draws it at any size. Only these are read whole by it.
        guard let type = values?.contentType, type.conforms(to: .svg) || type.conforms(to: .pdf),
            let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0
        else { return nil }
        return (image, 0)
    }
}

/// A picture in the Preview's text: at its own size, shrunk to fit what is left of the line from where it starts (after
/// a list's bullet), never enlarged, so it follows the pane's width as it is laid out again. It stands on the line's
/// baseline, or, starting a list item, hangs from the top of the bullet's line so the bullet is at its top. It can't be
/// dragged out of the text. TextKit asks its frame where it lays out, so the picture is kept where any thread can read
/// it.
final class MarkdownImageCell: NSTextAttachmentCell {
    private let picture: NSImage
    /// The height above the baseline of the text it hangs beside, or nil to stand on the baseline.
    let hangsFrom: CGFloat?

    init(picture: NSImage, hangsFrom ascent: CGFloat? = nil) {
        self.picture = picture
        hangsFrom = ascent
        super.init(imageCell: picture)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override nonisolated func cellSize() -> NSSize { picture.size }

    override nonisolated func cellFrame(
        for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        // The position is from where the text starts, inside the padding.
        let room = max(1, lineFrag.width - position.x - 2 * textContainer.lineFragmentPadding - 1)
        let scale = min(1, room / max(picture.size.width, 1))
        let height = picture.size.height * scale
        // Below the baseline by all but the text's height above it: the line's baseline stays the text's.
        let below = hangsFrom.map { min(0, $0 - height) } ?? 0
        return NSRect(x: 0, y: below, width: picture.size.width * scale, height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(
            in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func wantsToTrackMouse() -> Bool { false }
}
