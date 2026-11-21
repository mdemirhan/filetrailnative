import AppKit
import FTFoundation

/// Markdown as the viewer's Preview shows it: the system's parser, drawn in the viewer's theme. A picture on the disk
/// shows once it has been read (`MarkdownImages`), from Markdown or an HTML `<img>` (`MarkdownHTML`); one on the web
/// is never fetched and shows as its text, as does one not read. Links stay links. A table is a table: each cell a paragraph in its own
/// block of an `NSTextTable`, the header row bold on the code background, each column aligned as the Markdown says,
/// which the Preview's text view draws as it lays out with TextKit 1.
@MainActor
enum MarkdownRendering {
    /// The line of the Markdown a piece of the Preview comes from, counted from 1: the source and the Preview keep
    /// their place between them by it.
    static let sourceLine = NSAttributedString.Key("FileTrail.markdownSourceLine")

    static func render(_ markdown: String, theme: TextViewerTheme, fontSize: Double) -> NSAttributedString {
        render(markdown, theme: theme, fontSize: fontSize, file: nil, images: MarkdownImages()).text
    }

    /// `file`: the Markdown file's own address, which a picture's relative path is read from; `images`: the pictures
    /// read so far. `untried`: the pictures on the disk it names that `images` hasn't tried, each once, in order.
    static func render(
        _ markdown: String, theme: TextViewerTheme, fontSize: Double, file: URL?, images: MarkdownImages
    ) -> (text: NSAttributedString, untried: [URL]) {
        var untried: [URL] = []
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible,
            appliesSourcePositionAttributes: true)
        guard let parsed = try? AttributedString(markdown: markdown, options: options, baseURL: file) else {
            return (NSAttributedString(string: markdown, attributes: [.foregroundColor: NSColor(theme.text)]), [])
        }
        let result = NSMutableAttributedString()
        let text = NSColor(theme.text)
        let body = ThemeFonts.sans(fontSize + 1)
        let codeBackground = NSColor(theme.currentLine)
        var previousBlock: Int?
        var previousListItem: Int?
        var previousAttributes: [NSAttributedString.Key: Any] = [:]
        var previousWasCell = false
        /// The picture the run before showed, and its block.
        var previousImage: (url: URL, block: Int?)?
        var tables: [Int: NSTextTable] = [:]
        var runNumber = 0

        for run in parsed.runs {
            runNumber += 1
            let piece = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let components = intent?.components ?? []
            let inlineHTML = run.inlinePresentationIntent?.contains(.inlineHTML) ?? false
            let blockHTML = run.inlinePresentationIntent?.contains(.blockHTML) ?? false
            // A block of HTML comes with no block of its own: it is given one, so it is a paragraph of its own.
            let block = components.first?.identity ?? (blockHTML ? -runNumber : nil)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: text, .font: body]
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = CGFloat(fontSize) * 0.6
            paragraph.lineHeightMultiple = 1.15
            var prefix = ""
            var listDepth = 0
            var cell: (table: Int, columns: [PresentationIntent.TableColumn], row: Int, column: Int)?

            for component in components {
                switch component.kind {
                case .header(let level):
                    let sizes: [Double] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.95]
                    attributes[.font] = ThemeFonts.sans(fontSize * sizes[min(level, 6) - 1] + 1, .bold)
                    attributes[.foregroundColor] = NSColor(theme.color(for: .heading))
                    paragraph.paragraphSpacingBefore = CGFloat(fontSize) * 0.8
                case .codeBlock:
                    attributes[.font] = ThemeFonts.mono(fontSize)
                    attributes[.backgroundColor] = codeBackground
                    attributes[.foregroundColor] = NSColor(theme.color(for: .code))
                case .blockQuote:
                    attributes[.foregroundColor] = NSColor(theme.color(for: .comment))
                    paragraph.headIndent += 16
                    paragraph.firstLineHeadIndent += 16
                case .listItem(let ordinal):
                    if previousListItem != component.identity {
                        previousListItem = component.identity
                        let ordered = components.contains { if case .orderedList = $0.kind { true } else { false } }
                        prefix = ordered ? "\(ordinal).\t" : "•\t"
                    }
                case .orderedList, .unorderedList:
                    listDepth += 1
                case .thematicBreak:
                    attributes[.foregroundColor] = NSColor(theme.gutterText)
                case .tableCell(let column):
                    cell = (0, [], 0, column)
                case .tableHeaderRow:
                    cell?.row = 0
                case .tableRow(let row):
                    cell?.row = row
                case .table(let columns):
                    cell?.table = component.identity
                    cell?.columns = columns
                default:
                    break
                }
            }
            if listDepth > 0 {
                let indent = CGFloat(listDepth) * 22
                paragraph.headIndent = indent
                paragraph.firstLineHeadIndent = indent - 18
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            if let cell {
                let table =
                    tables[cell.table]
                    ?? {
                        let table = NSTextTable()
                        table.numberOfColumns = max(cell.columns.count, 1)
                        table.collapsesBorders = true
                        tables[cell.table] = table
                        return table
                    }()
                let place = NSTextTableBlock(
                    table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column, columnSpan: 1)
                place.setWidth(0.5, type: .absoluteValueType, for: .border)
                place.setBorderColor(NSColor(theme.gutterText).withAlphaComponent(0.5))
                place.setWidth(5, type: .absoluteValueType, for: .padding)
                if cell.row == 0 {
                    place.backgroundColor = codeBackground
                    attributes[.font] = ThemeFonts.sans(fontSize + 1, .bold)
                }
                paragraph.textBlocks = [place]
                paragraph.paragraphSpacing = 0
                paragraph.alignment =
                    switch cell.columns.indices.contains(cell.column) ? cell.columns[cell.column].alignment : .left {
                    case .center: .center
                    case .right: .right
                    default: .natural
                    }
            }
            attributes[.paragraphStyle] = paragraph
            if let line = run.markdownSourcePosition?.startLine { attributes[Self.sourceLine] = line }

            if let inline = run.inlinePresentationIntent {
                let size = (attributes[.font] as? NSFont)?.pointSize ?? body.pointSize
                if inline.contains(.code) {
                    attributes[.font] = ThemeFonts.mono(Double(size) - 1)
                    attributes[.foregroundColor] = NSColor(theme.color(for: .code))
                    attributes[.backgroundColor] = codeBackground
                }
                if inline.contains(.stronglyEmphasized) {
                    attributes[.font] = NSFontManager.shared.convert(
                        attributes[.font] as? NSFont ?? body, toHaveTrait: .boldFontMask)
                }
                if inline.contains(.emphasized) {
                    attributes[.font] = NSFontManager.shared.convert(
                        attributes[.font] as? NSFont ?? body, toHaveTrait: .italicFontMask)
                }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(theme.color(for: .link))
            }

            if let previousBlock, block != previousBlock {
                // The line break ends the paragraph before it: next to a table it is that paragraph's, so a cell's
                // block ends with its cell, and the paragraph before a table doesn't end in the table's first cell.
                // It carries no code background, link or strikethrough: TextKit paints a line break's background to
                // the end of its line. Nor a line of the Markdown, so the next block is found at its own first line.
                let nearTable = previousWasCell || cell != nil
                var lineBreak = nearTable ? previousAttributes : attributes
                for key in [NSAttributedString.Key.backgroundColor, .link, .strikethroughStyle, Self.sourceLine] {
                    lineBreak[key] = nil
                }
                result.append(NSAttributedString(string: "\n", attributes: lineBreak))
            }
            previousBlock = block
            previousWasCell = cell != nil
            previousAttributes = attributes
            if inlineHTML || blockHTML, let parts = MarkdownHTML.parts(of: piece, file: file) {
                if blockHTML && MarkdownHTML.isCentered(piece) { paragraph.alignment = .center }
                paragraph.lineHeightMultiple = 1
                var shown = prefix
                for part in parts {
                    switch part {
                    case .text(let words):
                        shown += words
                    case .picture(let picture):
                        let image = picture.url.flatMap { $0.isFileURL ? images[$0] : nil }
                        if let url = picture.url, url.isFileURL, image == nil, !images.tried(url),
                            !untried.contains(url)
                        {
                            untried.append(url)
                        }
                        guard let image else {
                            shown += picture.alt
                            continue
                        }
                        result.append(NSAttributedString(string: shown, attributes: attributes))
                        shown = ""
                        let sized = (image.copy() as? NSImage) ?? image
                        sized.size = picture.size(of: image.size)
                        let attachment = NSTextAttachment()
                        attachment.attachmentCell = MarkdownImageCell(picture: sized)
                        var pictured = attributes
                        pictured[.attachment] = attachment
                        result.append(NSAttributedString(string: "\u{FFFC}", attributes: pictured))
                    }
                }
                if !shown.isEmpty { result.append(NSAttributedString(string: shown, attributes: attributes)) }
                continue
            }
            // A picture read takes the place of its text. Its text may be several runs (`![a *b*](c.png)`): the
            // picture goes in once, for the first.
            let named = run.imageURL.flatMap { $0.isFileURL ? $0.absoluteURL.standardizedFileURL : nil }
            let image = named.flatMap { images[$0] }
            if let named, image == nil, !images.tried(named), !untried.contains(named) { untried.append(named) }
            defer { previousImage = image == nil ? nil : named.map { ($0, block) } }
            if let image {
                guard previousImage?.url != named || previousImage?.block != block else { continue }
                let attachment = NSTextAttachment()
                // Starting a list item, it hangs from the bullet's line, so the bullet is at its top.
                let ascent = prefix.isEmpty ? nil : ((attributes[.font] as? NSFont) ?? body).ascender
                attachment.attachmentCell = MarkdownImageCell(picture: image, hangsFrom: ascent)
                // The line is the picture's height: the text's line spacing under a tall picture is a gap.
                let tight = (paragraph.copy() as? NSMutableParagraphStyle) ?? paragraph
                tight.lineHeightMultiple = 1
                attributes[.paragraphStyle] = tight
                if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
                attributes[.attachment] = attachment
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                continue
            }
            let shown =
                components.contains { if case .thematicBreak = $0.kind { true } else { false } }
                ? String(repeating: "─", count: 24) : piece
            result.append(NSAttributedString(string: prefix + shown, attributes: attributes))
        }
        return (result, untried)
    }

    /// Where the Preview `text` shows the Markdown's line `line` (from 1): the start of the last piece that begins on
    /// it or before it, the block the line is in.
    static func location(ofSourceLine line: Int, in text: NSAttributedString) -> Int {
        var found = 0
        text.enumerateAttribute(sourceLine, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let start = value as? Int else { return }
            if start > line {
                stop.pointee = true
            } else {
                found = range.location
            }
        }
        return found
    }

    /// The Markdown's line (from 1) the Preview `text` shows at `location`, or the next piece's; nil with none.
    static func sourceLine(at location: Int, in text: NSAttributedString) -> Int? {
        guard location < text.length else { return nil }
        var found: Int?
        let rest = NSRange(location: location, length: text.length - location)
        text.enumerateAttribute(sourceLine, in: rest) { value, _, stop in
            guard let line = value as? Int else { return }
            found = line
            stop.pointee = true
        }
        return found
    }
}
