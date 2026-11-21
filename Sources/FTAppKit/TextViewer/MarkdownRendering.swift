import AppKit
import FTFoundation

/// Markdown as the viewer's Preview shows it: the system's parser, drawn in the viewer's theme. Nothing is loaded from
/// the network: images show as their text, links stay links. A table is a table: each cell a paragraph in its own
/// block of an `NSTextTable`, the header row bold on the code background, each column aligned as the Markdown says,
/// which the Preview's text view draws as it lays out with TextKit 1.
enum MarkdownRendering {
    static func render(_ markdown: String, theme: TextViewerTheme, fontSize: Double) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.foregroundColor: NSColor(theme.text)])
        }
        let result = NSMutableAttributedString()
        let text = NSColor(theme.text)
        let body = ThemeFonts.sans(fontSize + 1)
        let codeBackground = NSColor(theme.currentLine)
        var previousBlock: Int?
        var previousListItem: Int?
        var previousAttributes: [NSAttributedString.Key: Any] = [:]
        var previousWasCell = false
        var tables: [Int: NSTextTable] = [:]

        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let components = intent?.components ?? []
            let block = components.first?.identity
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
                // the end of its line.
                let nearTable = previousWasCell || cell != nil
                var lineBreak = nearTable ? previousAttributes : attributes
                for key in [NSAttributedString.Key.backgroundColor, .link, .strikethroughStyle] {
                    lineBreak[key] = nil
                }
                result.append(NSAttributedString(string: "\n", attributes: lineBreak))
            }
            previousBlock = block
            previousWasCell = cell != nil
            previousAttributes = attributes
            let shown =
                components.contains { if case .thematicBreak = $0.kind { true } else { false } }
                ? String(repeating: "─", count: 24) : piece
            result.append(NSAttributedString(string: prefix + shown, attributes: attributes))
        }
        return result
    }
}
