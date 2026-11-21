import AppKit
import FTFoundation
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
}
