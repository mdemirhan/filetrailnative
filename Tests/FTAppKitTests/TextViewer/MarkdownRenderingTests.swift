import AppKit
import FTFoundation
import FTTestSupport
import Testing

@testable import FTAppKit

/// The viewer's Markdown Preview.
@MainActor
struct MarkdownRenderingTests {
    /// Each paragraph of the rendered text, with its text and its style.
    private func paragraphs(_ text: NSAttributedString) -> [(text: String, style: NSParagraphStyle?, font: NSFont?)] {
        var found: [(String, NSParagraphStyle?, NSFont?)] = []
        let string = text.string as NSString
        var start = 0
        while start < string.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let line = string.substring(with: range).trimmingCharacters(in: .newlines)
            found.append(
                (
                    line, text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                    text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ))
            start = NSMaxRange(range)
        }
        return found
    }

    // A table is drawn as one: each cell a paragraph in its own block of one text table, at its row and column, the
    // header row bold, each column aligned as the Markdown says; the paragraphs around it are in no table.
    @Test func aTableIsDrawnAsATableOfItsRowsAndColumns() throws {
        let markdown = "Intro\n\n| Part | Where |\n|:---|---:|\n| **Web** app | `app/` |\n| API | `infra/` |\n\nAfter"
        let rendered = MarkdownRendering.render(markdown, theme: TextViewerTheme.light[0], fontSize: 13)
        let found = paragraphs(rendered)
        #expect(found.map(\.text) == ["Intro", "Part", "Where", "Web app", "app/", "API", "infra/", "After"])
        #expect(found.first?.style?.textBlocks.isEmpty == true)
        #expect(found.last?.style?.textBlocks.isEmpty == true)
        let cells = try found[1...6].map { paragraph in
            try #require(paragraph.style?.textBlocks.first as? NSTextTableBlock, "\(paragraph.text) is in a table")
        }
        #expect(Set(cells.map { ObjectIdentifier($0.table) }).count == 1, "one table")
        #expect(cells[0].table.numberOfColumns == 2)
        #expect(cells.map(\.startingRow) == [0, 0, 1, 1, 2, 2])
        #expect(cells.map(\.startingColumn) == [0, 1, 0, 1, 0, 1])
        #expect(found[1...6].map { $0.style?.alignment } == [.natural, .right, .natural, .right, .natural, .right])
        let bold = { (font: NSFont?) in font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } }
        #expect(bold(found[1].font) == true && bold(found[2].font) == true, "the header row is bold")
        #expect(bold(found[5].font) == false, "a body cell isn't")
    }

    // A line break between paragraphs carries no code background, link or strikethrough, which TextKit would paint
    // to the end of the line: after a paragraph ending in code, a cell in code, a link, and before a code block.
    @Test func noLineBreakCarriesAnInlineBackground() {
        let markdown =
            "Run `make`\n\n| A |\n|---|\n| `x` |\n\n[link](https://example.com)\n\nThen:\n\n```sh\nbun install\n```"
        let rendered = MarkdownRendering.render(markdown, theme: TextViewerTheme.light[0], fontSize: 13)
        let string = rendered.string as NSString
        for ending in ["make", "x", "link", "Then:"] {
            let found = string.range(of: ending)
            let index = NSMaxRange(found)
            let isBreak = found.location != NSNotFound && index < string.length && string.character(at: index) == 10
            #expect(isBreak, "a line break after \(ending)")
            guard found.location != NSNotFound, index < string.length else { continue }
            #expect(rendered.attribute(.backgroundColor, at: index, effectiveRange: nil) == nil, "after \(ending)")
            #expect(rendered.attribute(.link, at: index, effectiveRange: nil) == nil, "after \(ending)")
        }
    }

    /// A picture `width` by `height` pixels, as PNG.
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// The pictures of the rendered text, in order.
    private func pictures(_ text: NSAttributedString) -> [NSSize] {
        var found: [NSSize] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? MarkdownImageCell {
                found.append(cell.cellSize())
            }
        }
        return found
    }

    // A picture on the disk, by a path relative to the file or a `file:` address, takes the place of its text once it
    // is read; until then it is named as one to read. One on the web is never named, and it and one that isn't there
    // keep their text.
    @Test func aPictureOnTheDiskShowsOnceReadAndOneOnTheWebKeepsItsText() throws {
        let folder = try TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("images"), withIntermediateDirectories: false)
        let cat = folder.url.appendingPathComponent("images/cat.png")
        let dog = folder.url.appendingPathComponent("dog.png")
        try png(width: 40, height: 20).write(to: cat)
        try png(width: 10, height: 30).write(to: dog)
        let file = folder.url.appendingPathComponent("README.md")
        let markdown =
            "# Pets\n\n![a cat](images/cat.png)\n\n- ![the dog](\(dog.absoluteString))\n\n"
            + "![a badge](https://example.com/badge.svg) and ![gone](gone.png) and ![a cat again](./images/cat.png)"
        let theme = TextViewerTheme.light[0]

        let first = MarkdownRendering.render(
            markdown, theme: theme, fontSize: 13, file: file, images: MarkdownImages())
        let gone = folder.url.appendingPathComponent("gone.png")
        #expect(first.untried == [cat, dog, gone].map(\.standardizedFileURL), "each once, the web's not at all")
        #expect(pictures(first.text).isEmpty)
        #expect(first.text.string.contains("a cat"))

        let read = MarkdownImages.read(first.untried, spent: 0)
        #expect(read.bytes > 0)
        let second = MarkdownRendering.render(markdown, theme: theme, fontSize: 13, file: file, images: read)
        #expect(second.untried.isEmpty, "what wasn't read isn't asked for again")
        #expect(
            pictures(second.text) == [
                NSSize(width: 40, height: 20), NSSize(width: 10, height: 30), NSSize(width: 40, height: 20),
            ])
        let string = second.text.string
        for text in ["a cat", "the dog"] { #expect(!string.contains(text), "\(text) is its picture") }
        for text in ["a badge", "gone"] { #expect(string.contains(text), "\(text) keeps its text") }
        #expect(string.contains("•\t\u{FFFC}"), "a list item keeps its bullet before its picture")
        #expect(paragraphs(second.text).first { $0.text == "\u{FFFC}" }?.style?.lineHeightMultiple == 1)
    }

    // A picture is shrunk to fit what is left of its line from where it starts, and never made larger.
    @Test func aPictureFitsItsLineAndIsNeverEnlarged() throws {
        let cell = MarkdownImageCell(picture: NSImage(size: NSSize(width: 400, height: 200)))
        let container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 5
        func frame(_ width: CGFloat, at x: CGFloat = 0) -> NSSize {
            cell.cellFrame(
                for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: width, height: 20),
                glyphPosition: NSPoint(x: x, y: 0), characterIndex: 0
            ).size
        }
        #expect(frame(1000) == NSSize(width: 400, height: 200))
        #expect(frame(211) == NSSize(width: 200, height: 100))
        #expect(frame(231, at: 20) == NSSize(width: 200, height: 100), "after a list's bullet")

        // Hung from a line of text, it goes below the baseline by all but the text's height above it.
        let hung = MarkdownImageCell(picture: NSImage(size: NSSize(width: 400, height: 200)), hangsFrom: 15)
        let placed = hung.cellFrame(
            for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 211, height: 20), glyphPosition: .zero,
            characterIndex: 0)
        #expect(placed == NSRect(x: 0, y: -85, width: 200, height: 100))
    }

    // A picture that starts a list item has the bullet at its top, on the first line of the picture; one that starts
    // a paragraph of its own stands on its line as before.
    @Test func aListItemsBulletIsAtTheTopOfItsPicture() throws {
        let folder = try TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let lake = folder.url.appendingPathComponent("lake.png")
        try png(width: 100, height: 200).write(to: lake)
        let file = folder.url.appendingPathComponent("README.md")
        let markdown = "![lake](lake.png)\n\n- ![lake](lake.png)\n"
        let images = MarkdownImages.read([lake], spent: 0)
        let text = MarkdownRendering.render(
            markdown, theme: TextViewerTheme.light[0], fontSize: 13, file: file, images: images
        ).text
        var cells: [MarkdownImageCell] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? MarkdownImageCell { cells.append(cell) }
        }
        #expect(cells.map { $0.hangsFrom == nil } == [true, false])

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.textStorage?.setAttributedString(text)
        let layout = try #require(view.layoutManager)
        layout.ensureLayout(for: try #require(view.textContainer))
        let bullet = (text.string as NSString).range(of: "•").location
        let glyph = layout.glyphIndexForCharacter(at: bullet)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        #expect(line.height < 210, "the line is the picture's height: \(line)")
        #expect(layout.location(forGlyphAt: glyph).y < 25, "the bullet is on the picture's first line")
    }

    // Past the budget for one file's pictures, a picture isn't read and keeps its text.
    @Test func aPicturePastTheBudgetIsNotRead() throws {
        let folder = try TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let cat = folder.url.appendingPathComponent("cat.png")
        try png(width: 40, height: 20).write(to: cat)
        let read = MarkdownImages.read([cat], spent: MarkdownImages.budget - 100)
        #expect(read[cat] == nil)
        #expect(read.tried(cat))
        #expect(read.bytes == 0)
    }

    // An HTML `<img>`, as a README writes one to size or center a picture: its picture on the disk at the size given,
    // the tags around it left out, centered as the HTML says, in a paragraph of its own; read with the file too. One
    // on the web keeps its description, and HTML with no picture stays as it is written.
    @Test func anHTMLPictureShowsAtItsSizeCenteredAndTheTagsAroundItGo() throws {
        let folder = try TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        try FileManager.default.createDirectory(
            at: folder.url.appendingPathComponent("docs"), withIntermediateDirectories: false)
        let shot = folder.url.appendingPathComponent("docs/search.png")
        try png(width: 400, height: 200).write(to: shot)
        let file = folder.url.appendingPathComponent("README.md")
        let markdown = """
            Intro

            <p align="center">
              <img src="docs/search.png" alt="Search &amp; results" width="300">
            </p>

            ## Next

            <img src="https://example.com/x.png" alt="from the web"> and <b>bold</b>
            """
        let theme = TextViewerTheme.light[0]
        let first = MarkdownRendering.render(markdown, theme: theme, fontSize: 13, file: file, images: MarkdownImages())
        #expect(first.untried == [shot.standardizedFileURL])
        #expect(first.text.string.contains("Search & results"), "its description until it is read")
        #expect(!first.text.string.contains("<p"), "the tags around a picture go")

        let read = MarkdownImages.read(in: markdown, file: file)
        #expect(read[shot] != nil, "read with the file")
        let second = MarkdownRendering.render(markdown, theme: theme, fontSize: 13, file: file, images: read)
        #expect(pictures(second.text) == [NSSize(width: 300, height: 150)])
        let found = paragraphs(second.text)
        #expect(found.map(\.text) == ["Intro", "\u{FFFC}", "Next", "from the web and <b>bold</b>"])
        #expect(found[1].style?.alignment == .center)
        #expect(found[3].style?.alignment != .center)
    }

    // An `<img>` tag's attributes, in either quotes or none, a size in pixels only, the source read from the file's
    // folder; text between tags kept with its spaces made one.
    @Test func anHTMLPicturesAttributesAreRead() throws {
        let file = URL(fileURLWithPath: "/Users/me/notes/README.md")
        let parts = try #require(
            MarkdownHTML.parts(
                of: "<div>\n <IMG SRC='a b.png' width=120px height=\"50%\">\n  Caption <i>here</i>\n</div>",
                file: file))
        #expect(
            parts == [
                .picture(
                    MarkdownHTML.Picture(
                        url: URL(fileURLWithPath: "/Users/me/notes/a b.png"), alt: "", width: 120, height: nil)),
                .text("Caption here"),
            ])
        #expect(MarkdownHTML.parts(of: "<details><summary>More</summary>", file: file) == nil)
        #expect(MarkdownHTML.isCentered("<p align=center>"))
        #expect(!MarkdownHTML.isCentered("<p align=\"left\">"))
        let picture = MarkdownHTML.Picture(url: nil, alt: "", width: nil, height: 30)
        #expect(picture.size(of: NSSize(width: 40, height: 20)) == NSSize(width: 60, height: 30))
    }
}
