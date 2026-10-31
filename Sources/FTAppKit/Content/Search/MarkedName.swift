// Port of renderMarkedText (apps/desktop/src/renderer/lib/nameHighlight.tsx:60-86), FileNameLabel's marks
// (components/ContentPane.tsx:2422-2445) and the .search-result-match rules of styles.css:6605-6627
import AppKit
import FTFoundation

/// What a search matched, drawn in a name: a yellow box behind the text (`<mark>`), or on a selected item an underline
/// instead, which keeps the name's contrast.
@MainActor
enum MarkedName {
    private static var layout: SearchLayout { .standard }

    static var markColor: NSColor {
        let layout = layout
        return NSColor(
            srgbRed: layout.markRed / 255, green: layout.markGreen / 255, blue: layout.markBlue / 255,
            alpha: layout.markAlpha)
    }

    /// One line of text and its marks, measured with the marks' padding (which takes room, as inline padding does).
    struct Line {
        let text: NSAttributedString
        let marks: [HighlightRange]
        /// The room before the first character, when a mark starts the line.
        let leading: CGFloat
        let padding: CGFloat

        init(_ string: String, marks: [HighlightRange], attributes: [NSAttributedString.Key: Any], padding: CGFloat) {
            let made = NSMutableAttributedString(string: string, attributes: attributes)
            let units = string as NSString
            func addKern(at index: Int) {
                guard index >= 0, index < units.length else { return }
                let range = units.rangeOfComposedCharacterSequence(at: index)
                let current = (made.attribute(.kern, at: range.location, effectiveRange: nil) as? CGFloat) ?? 0
                made.addAttribute(.kern, value: current + padding, range: range)
            }
            if padding > 0 {
                for mark in marks {
                    addKern(at: mark.start - 1)
                    addKern(at: mark.end - 1)
                }
            }
            text = made
            self.marks = marks
            leading = padding > 0 && marks.first?.start == 0 ? padding : 0
            self.padding = padding
        }

        /// How far into the line a unit offset is.
        func offset(_ index: Int) -> CGFloat {
            guard index > 0 else { return leading }
            let length = min(index, text.length)
            return leading + ceil(text.attributedSubstring(from: NSRange(location: 0, length: length)).size().width)
        }

        var width: CGFloat { offset(text.length) }
    }

    /// Draws `line` from `origin` in a box `width` wide, cut with an ellipsis at its end when it does not fit; the
    /// marks behind the text, or underlines under it.
    static func draw(
        _ line: Line, at origin: NSPoint, width: CGFloat, lineHeight: CGFloat, font: NSFont, color: NSColor,
        underlined: Bool, truncates: Bool, in view: NSView
    ) {
        let layout = layout
        let clipRight = origin.x + width
        let boxHeight = font.ascender - font.descender
        if !underlined {
            markColor.setFill()
            for mark in line.marks {
                let left = origin.x + line.offset(mark.start) - line.padding
                let right = min(clipRight, origin.x + line.offset(mark.end))
                guard right > left else { continue }
                let rect = NSRect(x: left, y: origin.y, width: right - left, height: boxHeight)
                let radius = CGFloat(DesignTokens.radii.xs)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
        var text = line.text
        if truncates {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let copy = NSMutableAttributedString(attributedString: line.text)
            copy.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: copy.length))
            text = copy
        }
        text.draw(
            with: NSRect(
                x: origin.x + line.leading, y: TextBaseline.lineTop(origin.y, font: font, in: view),
                width: max(0, width - line.leading), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        guard underlined else { return }
        color.setFill()
        let baseline = origin.y + font.ascender
        for mark in line.marks {
            let left = origin.x + line.offset(mark.start)
            let right = min(clipRight, origin.x + line.offset(mark.end) - line.padding)
            guard right > left else { continue }
            NSRect(
                x: left, y: baseline + CGFloat(layout.underlineOffset), width: right - left,
                height: CGFloat(layout.underlineThickness)
            ).fill()
        }
    }

    /// `FileNameLabel` with marks: the stem, cut short with an ellipsis when the room is too small, then the extension,
    /// which always shows; `ranges` are counted in the whole name.
    static func drawSplitName(
        stem: String, suffix: String, ranges: [HighlightRange], in bounds: NSRect, of view: NSView,
        lineHeight: CGFloat, font: NSFont, color: NSColor, suffixColor: NSColor, underlined: Bool
    ) {
        let padding = CGFloat(layout.markPaddingHorizontal)
        let stemLine = Line(
            stem, marks: NameHighlight.marks(in: stem, ranges: ranges),
            attributes: [.font: font, .foregroundColor: color], padding: padding)
        let suffixLine = Line(
            suffix, marks: NameHighlight.marks(in: suffix, ranges: ranges, offset: stem.utf16.count),
            attributes: [.font: font, .foregroundColor: suffixColor], padding: padding)
        let suffixWidth = suffixLine.width
        let stemRoom = max(0, bounds.width - suffixWidth)
        let drawn = min(stemLine.width, stemRoom)
        let y = bounds.minY + (bounds.height - lineHeight) / 2
        draw(
            stemLine, at: NSPoint(x: bounds.minX, y: y), width: drawn, lineHeight: lineHeight, font: font,
            color: color, underlined: underlined, truncates: true, in: view)
        if !suffix.isEmpty {
            draw(
                suffixLine, at: NSPoint(x: bounds.minX + drawn, y: y), width: suffixWidth, lineHeight: lineHeight,
                font: font, color: suffixColor, underlined: underlined, truncates: false, in: view)
        }
    }
}
