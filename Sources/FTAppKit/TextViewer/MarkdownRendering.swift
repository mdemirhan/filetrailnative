import AppKit
import FTFoundation

/// Markdown as the viewer's Preview shows it: the system's parser, drawn in the viewer's theme. Nothing is loaded from
/// the network: images show as their text, links stay links.
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
                    if column > 0 && previousBlock == block { prefix = "\t" }
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
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            previousBlock = block
            let shown =
                components.contains { if case .thematicBreak = $0.kind { true } else { false } }
                ? String(repeating: "─", count: 24) : piece
            result.append(NSAttributedString(string: prefix + shown, attributes: attributes))
        }
        return result
    }
}
