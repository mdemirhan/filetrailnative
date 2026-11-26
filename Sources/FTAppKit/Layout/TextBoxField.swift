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

    // A click that selects text that can't be edited puts it in the field editor, which lays it out 2 pt in from the
    // frame it is given, where this cell draws it at its text frame's edge: given that frame 2 wider on each side,
    // the text stays where it was drawn. A field that is typed in keeps the system's placing.
    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: editorFrame(rect, in: controlView), in: controlView, editor: textObj, delegate: delegate,
            start: selStart, length: selLength)
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: editorFrame(rect, in: controlView), in: controlView, editor: textObj, delegate: delegate,
            event: event)
    }

    /// Text that can only be read is selected in an editor that copies it plain (`PlainCopyFieldEditor`); a field that
    /// is typed in has its window's own.
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let field = controlView as? NSTextField, !field.isEditable, let window = field.window else {
            return super.fieldEditor(for: controlView)
        }
        return PlainCopyFieldEditor.editor(for: window)
    }

    /// Where the field editor goes. Read-only text also keeps its runs (code, a mark) in it: without
    /// `allowsEditingTextAttributes` the editor shows it plain, in the field's one font. It still can't be edited.
    private func editorFrame(_ rect: NSRect, in controlView: NSView) -> NSRect {
        guard let field = controlView as? NSTextField, !field.isEditable else { return rect }
        field.allowsEditingTextAttributes = true
        // Lines wrap where they were drawn: with the slack, on the side the text grows toward.
        let frame = textFrame(forBounds: rect)
        let text = drawnText()
        let box = isMultiline && text.length > 0 ? Self.box(frame, alignment: drawnAlignment(text)) : frame
        return box.insetBy(dx: -2, dy: 0)
    }

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

/// The field editor of text that can only be read. It shows the text with its runs (code, emphasis, the label's own
/// color), and copies or drags it out as plain text: with its runs, text copied from a label in the dark look pasted
/// near-white into Mail or Notes, where it couldn't be seen.
final class PlainCopyFieldEditor: NSTextView {
    /// One for each window, as a window has one field editor, for as long as the window is there.
    private static let editors = NSMapTable<NSWindow, PlainCopyFieldEditor>.weakToStrongObjects()

    static func editor(for window: NSWindow) -> PlainCopyFieldEditor {
        if let editor = editors.object(forKey: window) { return editor }
        let editor = PlainCopyFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        // Lines as far apart as the label drew them: a text view of its own would add the font's leading, where the
        // paragraph says how tall a line is.
        editor.textLayoutManager?.usesFontLeading = false
        editors.setObject(editor, forKey: window)
        return editor
    }

    /// The plain-text types among those a text view writes, under the names it knows them by.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { Self.plainTypes.contains($0) }
    }

    /// A right-click in a value of the Info panel being selected selects the whole value, as a right-click on it does
    /// before (`SelectableTextField`): not the word under the pointer. Where keeps the system's way.
    override func rightMouseDown(with event: NSEvent) {
        if let field = (delegate as AnyObject?) as? SelectableTextField, field.lineBreakMode != .byTruncatingHead {
            selectAll(nil)
            if let menu = menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
        }
        super.rightMouseDown(with: event)
    }

    static let plainTypes: Set<NSPasteboard.PasteboardType> = [
        .string, NSPasteboard.PasteboardType("NSStringPboardType"),
    ]
}
