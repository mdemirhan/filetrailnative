// Text drawn from its box's edges, whole when the box is as wide as the text
import AppKit

/// A label whose text starts right at its frame's edge, and a frame as wide as the text (the
/// measured width) draws the whole string. A plain label keeps 2 pt between its frame and its text on each side, and a
/// centered one cuts its text short even when that padding is moved outside the frame, so this cell draws the text
/// itself.
class TextBoxField: NSTextField {
    override class var cellClass: AnyClass? {
        get { TextBoxCell.self }
        set {}
    }
}

class TextBoxCell: NSTextFieldCell {
    /// How far past its frame a line may reach before it is cut. A width measured one way (Core Text, a typographic
    /// bound, a layout constant) can come out a fraction of a point short of the width AppKit lays the same text out at.
    static let slack = 1.0

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        // Where a field editor would go: the text stays at the frame's edge.
        super.drawingRect(forBounds: textFrame(forBounds: rect).insetBy(dx: -2, dy: 0))
    }

    /// The part of the frame the text is drawn in: all of it, unless a subclass keeps room before the text or
    /// centers it.
    func textFrame(forBounds rect: NSRect) -> NSRect { rect }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let field = controlView as? NSTextField, field.currentEditor() != nil {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let text = drawnText()
        guard text.length > 0 else { return }
        var options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if isMultiline { options.insert(.truncatesLastVisibleLine) }
        let frame = textFrame(forBounds: cellFrame)
        // Text that fits with the slack is whole; text that doesn't is cut at the frame's edge.
        let box =
            !isMultiline && text.size().width > frame.width + Self.slack
            ? frame : Self.box(frame, alignment: drawnAlignment(text))
        text.draw(with: box, options: options, context: nil)
    }

    /// Whether the text wraps onto more lines: a wrapping label, or one allowed more than one line.
    var isMultiline: Bool {
        !usesSingleLineMode && (wraps || (controlView as? NSTextField)?.maximumNumberOfLines ?? 0 > 1)
    }

    /// The string as drawn: wrapped by word when it has more lines (its last line truncated), on one line otherwise.
    func drawnText() -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: attributedStringValue)
        let whole = NSRange(location: 0, length: text.length)
        guard whole.length > 0 else { return text }
        let wrapping: Set<NSLineBreakMode> = [.byWordWrapping, .byCharWrapping]
        var styles: [(NSRange, NSParagraphStyle?)] = []
        text.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            styles.append((range, value as? NSParagraphStyle))
        }
        for (range, style) in styles {
            let paragraph = (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if style == nil {
                paragraph.alignment = alignment
                paragraph.lineBreakMode = lineBreakMode
            }
            if isMultiline {
                if !wrapping.contains(paragraph.lineBreakMode) { paragraph.lineBreakMode = .byWordWrapping }
            } else if wrapping.contains(paragraph.lineBreakMode) {
                paragraph.lineBreakMode = .byClipping
            }
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return text
    }

    private func drawnAlignment(_ text: NSAttributedString) -> NSTextAlignment {
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let alignment = style?.alignment ?? alignment
        if alignment == .natural {
            return userInterfaceLayoutDirection == .rightToLeft ? .right : .left
        }
        return alignment
    }

    /// The frame with the slack added on the side(s) the text grows toward, so the text stays where it is.
    static func box(_ frame: NSRect, alignment: NSTextAlignment) -> NSRect {
        var box = frame
        box.size.width += slack
        switch alignment {
        case .center: box.origin.x -= slack / 2
        case .right: box.origin.x -= slack
        default: break
        }
        return box
    }

    /// Whether the text, laid out as drawn in a frame of this size, is cut short.
    func truncates(in size: NSSize) -> Bool {
        let text = drawnText()
        guard text.length > 0 else { return false }
        let box = Self.box(NSRect(origin: .zero, size: size), alignment: .left)
        let unbounded = CGFloat.greatestFiniteMagnitude
        if isMultiline {
            let whole = text.boundingRect(
                with: NSSize(width: box.width, height: unbounded), options: [.usesLineFragmentOrigin])
            return ceil(whole.height) > ceil(box.height) + 0.5
        }
        return text.size().width > box.width
    }
}
