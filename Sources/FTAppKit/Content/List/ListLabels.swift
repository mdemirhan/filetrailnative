// The text of the List view's cells: laid out by hand, with no inset, drawn in the stylesheet's fonts
import AppKit
import FTFoundation

/// A line of text in a cell. The text starts at the left edge of its frame, as a web page's does, and the pointer
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

    /// The height one line of the text takes: the font's own line (ascent, descent and leading), as the browser's
    /// `line-height: normal` makes it.
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
/// which always shows (`FileNameLabel`). The field holds the whole name, and draws it itself.
final class NameLabel: ListLabel {
    /// The stored extension, to split the name where the original does.
    var fileExtension = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let parts = DisplayName.split(stringValue, extension: fileExtension)
        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = textColor ?? .labelColor
        let height = lineHeight
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

/// The fonts of the List's rows and header.
@MainActor
enum ListFonts {
    /// A row's text: the name size, with tabular figures (`font-variant-numeric: tabular-nums`).
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
