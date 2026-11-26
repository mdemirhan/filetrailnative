// The text of the List view's cells: laid out by hand, with no inset, drawn in the theme's fonts
import AppKit
import FTFileSystem
import FTFoundation

/// A line of text in a cell. The text starts at the left edge of its frame, and the pointer
/// goes through it to the row.
class ListLabel: NSTextField {
    override class var cellClass: AnyClass? {
        get { ThemedTextCell.self }
        set {}
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        cell?.isScrollable = false
        cell?.truncatesLastVisibleLine = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The height one line of the text takes: the font's own line (ascent, descent and leading).
    var lineHeight: CGFloat {
        guard let font else { return 0 }
        return font.ascender - font.descender + font.leading
    }

    /// The width the text takes on one line.
    var textWidth: CGFloat {
        guard let font else { return 0 }
        return (stringValue as NSString).size(withAttributes: [.font: font]).width
    }
}

/// The name of a file: the stem, which ends in an ellipsis when the column is too narrow, and the extension after it,
/// which always shows. The field holds the whole name, and draws it itself.
final class NameLabel: ListLabel {
    /// The stored extension, where the name is split.
    var fileExtension = "" {
        didSet { needsDisplay = true }
    }
    /// What a search matched, in the whole name; underlined instead of boxed on a selected row.
    var marks: [HighlightRange] = [] {
        didSet { needsDisplay = true }
    }
    var marksUnderlined = false {
        didSet { needsDisplay = true }
    }

    override var textWidth: CGFloat {
        SplitName.width(stringValue, extension: fileExtension, marks: marks, font: font)
    }

    override func draw(_ dirtyRect: NSRect) {
        let parts = DisplayName.split(stringValue, extension: fileExtension)
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = textColor ?? .labelColor
        let height = lineHeight
        if !marks.isEmpty {
            MarkedName.drawSplitName(
                stem: parts.stem, suffix: parts.extensionSuffix, ranges: marks, in: bounds, of: self,
                lineHeight: height,
                font: font, color: color, suffixColor: color, underlined: marksUnderlined)
            return
        }
        let y = (bounds.height - height) / 2
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let suffixWidth = ceil((parts.extensionSuffix as NSString).size(withAttributes: plain).width)
        let stemRoom = max(0, bounds.width - suffixWidth)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var stemAttributes = plain
        stemAttributes[.paragraphStyle] = paragraph
        let stemWidth = ceil((parts.stem as NSString).size(withAttributes: plain).width)
        let drawn = min(stemWidth, stemRoom)
        (parts.stem as NSString).draw(
            with: NSRect(x: 0, y: y, width: drawn, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: stemAttributes)
        if !parts.extensionSuffix.isEmpty {
            (parts.extensionSuffix as NSString).draw(
                with: NSRect(x: drawn, y: y, width: suffixWidth, height: height), options: [.usesLineFragmentOrigin],
                attributes: plain)
        }
    }
}

/// The width of a name drawn as its stem and then its extension, each measured on its own and rounded up to whole
/// points. That can be a point more than the name measured whole: a label only that wide would cut the stem short.
@MainActor
enum SplitName {
    static func width(_ name: String, extension fileExtension: String, marks: [HighlightRange], font: NSFont?)
        -> CGFloat
    {
        guard let font else { return 0 }
        let parts = DisplayName.split(name, extension: fileExtension)
        if !marks.isEmpty {
            return MarkedName.splitNameWidth(
                stem: parts.stem, suffix: parts.extensionSuffix, ranges: marks, font: font)
        }
        func measure(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        return measure(parts.stem) + measure(parts.extensionSuffix)
    }
}

/// What a search result's folder shows in its column: whole and from the left when it fits; otherwise it loses its
/// start, whole characters at a time, and what is left ends flush with the right edge after an ellipsis.
@MainActor
enum FolderColumnText {
    struct Fit: Equatable {
        var text: String
        var isCut: Bool
    }

    static func fit(_ text: String, width: CGFloat, font: NSFont) -> Fit {
        func measure(_ string: String) -> CGFloat { (string as NSString).size(withAttributes: [.font: font]).width }
        if measure(text) <= width { return Fit(text: text, isCut: false) }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        // The most characters kept from the end that fit beside the ellipsis.
        while low < high {
            let middle = (low + high + 1) / 2
            if measure("…" + String(characters.suffix(middle))) <= width { low = middle } else { high = middle - 1 }
        }
        return Fit(text: "…" + String(characters.suffix(low)), isCut: true)
    }
}

/// The folder of a search result; the field holds the whole label, and draws what fits.
final class FolderColumnLabel: ListLabel {
    override func draw(_ dirtyRect: NSRect) {
        guard let font else { return }
        let fit = FolderColumnText.fit(stringValue, width: bounds.width, font: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = fit.isCut ? .right : .left
        paragraph.lineBreakMode = .byClipping
        // Slack past the left edge, so the fit above isn't cut again where its measure and the drawing differ.
        let slack = TextBoxCell.slack
        (fit.text as NSString).draw(
            with: NSRect(
                x: fit.isCut ? -slack : 0, y: 0,
                width: bounds.width + slack, height: bounds.height),
            options: [.usesLineFragmentOrigin],
            attributes: [
                .font: font, .foregroundColor: textColor ?? NSColor.labelColor, .paragraphStyle: paragraph,
            ])
    }
}

/// The fonts of the List's rows and header.
@MainActor
enum ListFonts {
    /// A row's text: the name size, with tabular figures, so the digits line up in a column.
    static func row(_ layout: DetailsLayout) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: CGFloat(layout.cellFontSize), weight: .regular)
    }

    /// Permissions: the monospace font, at the row's size.
    static func permissions(_ layout: DetailsLayout) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(layout.cellFontSize), weight: .regular)
    }

    /// A column title; the one the list is sorted by is semibold.
    static func header(_ layout: DetailsLayout, active: Bool) -> NSFont {
        ThemeFonts.sans(layout.headerFontSize, active ? .semibold : .regular)
    }
}

/// The Tags cell: each tag's dot and its name, one after another with commas, as Finder's Tags column has them. A tag
/// without a color has a ring in the text's color; the text ends in an ellipsis where the column is too narrow.
final class TagsLabel: ListLabel {
    var tags: [FinderTag] = [] {
        didSet { if tags != oldValue { needsDisplay = true } }
    }

    static let dotDiameter: CGFloat = 8
    /// The space after a dot, before its name.
    static let dotGap: CGFloat = 4

    override var textWidth: CGFloat {
        guard let font else { return 0 }
        return Self.text(tags, font: font, color: textColor ?? .labelColor).size().width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !tags.isEmpty, let font else { return }
        let text = Self.text(tags, font: font, color: textColor ?? .labelColor)
        let y = (bounds.height - lineHeight) / 2
        text.draw(
            with: NSRect(x: 0, y: y, width: bounds.width, height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The cell's text: dots drawn at the time they are drawn, so they take the appearance they are drawn in.
    static func text(_ tags: [FinderTag], font: NSFont, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()
        for (index, tag) in tags.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: ", ", attributes: attributes)) }
            // The dot and the space after it, one picture: a kern after an attachment isn't kept.
            let attachment = NSTextAttachment()
            attachment.image = dot(tag.color, ring: color)
            attachment.bounds = NSRect(
                x: 0, y: (font.capHeight - dotDiameter) / 2, width: dotDiameter + dotGap, height: dotDiameter)
            let dot = NSMutableAttributedString(attachment: attachment)
            dot.addAttributes(attributes, range: NSRange(location: 0, length: dot.length))
            result.append(dot)
            result.append(NSAttributedString(string: tag.name, attributes: attributes))
        }
        return result
    }

    private static func dot(_ color: FinderTagColor?, ring: NSColor) -> NSImage {
        NSImage(size: NSSize(width: dotDiameter + dotGap, height: dotDiameter), flipped: false) { _ in
            let rect = NSRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
            if let color {
                color.dotColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                ring.withAlphaComponent(0.7).setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
    }
}
