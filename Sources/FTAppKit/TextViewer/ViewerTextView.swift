import AppKit
import FTFoundation

/// The viewer's text, and Markdown's Preview, which is always in Read: the window treats it as a text field while it
/// has the keyboard, so ⌘C, ⌘V, ⌘A and ⌘Z act on the text and not on files.
final class ViewerTextView: NSTextView {
    /// Esc: Read from Edit, and from Read the viewer closes.
    var onCancel: (() -> Bool)?
    /// The keyboard came to the text or left it.
    var onFocusChange: () -> Void = {}
    /// Tab while reading: the next pane, as from a list.
    var onTab: () -> Void = {}
    /// Return while reading: Edit, as Esc in Edit is Read.
    var onEdit: () -> Void = {}
    /// The command of the app's own keys a key press is: the page keys move the text in Read and in Edit.
    var commandForKey: (NSEvent) -> ShortcutCommandID? = { _ in nil }

    /// In Read, the keys a reader uses move the text, not an invisible caret: the arrows a line or a column, Space and
    /// Shift-Space a page, Home and End to the top and the bottom. The app's page and half-page keys move the text in
    /// Read, and the text and the caret with it in Edit.
    override func keyDown(with event: NSEvent) {
        switch commandForKey(event) {
        case .pageDown:
            page(1)
            return
        case .pageUp:
            page(-1)
            return
        case .halfPageDown:
            page(0.5)
            return
        case .halfPageUp:
            page(-0.5)
            return
        default:
            break
        }
        guard !isEditable else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers.flatMap(\.unicodeScalars.first).map { Int($0.value) } ?? 0
        switch (key, flags) {
        case (NSUpArrowFunctionKey, []): scroll(lines: -1)
        case (NSDownArrowFunctionKey, []): scroll(lines: 1)
        case (NSLeftArrowFunctionKey, []): scroll(columns: -4)
        case (NSRightArrowFunctionKey, []): scroll(columns: 4)
        case (0x20, []): scroll(pages: 1)
        case (0x20, [.shift]): scroll(pages: -1)
        case (NSHomeFunctionKey, []), (NSUpArrowFunctionKey, [.command]): scrollToEdge(top: true)
        case (NSEndFunctionKey, []), (NSDownArrowFunctionKey, [.command]): scrollToEdge(top: false)
        case (0x09, []), (0x19, _), (0x09, [.shift]): onTab()
        case (0x0D, []), (0x03, []):
            caretOnScreen()
            onEdit()
        default: super.keyDown(with: event)
        }
    }

    /// A caret left off screen while reading goes to the first line shown, where editing begins.
    private func caretOnScreen() {
        guard let manager = layoutManager, let container = textContainer else { return }
        let visible = visibleRect
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let shown = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caret = selectedRange()
        if caret.location < shown.location || caret.location > NSMaxRange(shown) {
            setSelectedRange(NSRange(location: shown.location, length: 0))
        }
    }

    private var lineHeight: CGFloat {
        guard let font, let manager = layoutManager else { return 16 }
        return manager.defaultLineHeight(for: font)
    }

    func scroll(lines: CGFloat) { scrollBy(dx: 0, dy: lines * lineHeight) }

    func scroll(pages: CGFloat) {
        scrollBy(dx: 0, dy: distance(pages: pages))
    }

    private func distance(pages: CGFloat) -> CGFloat {
        let height = enclosingScrollView?.contentView.bounds.height ?? 400
        return pages * max(lineHeight, height - lineHeight * 2)
    }

    /// The column a caret moved a page at a time keeps, across lines shorter than it.
    private var pageColumn: CGFloat?
    private var movingByPage = false

    /// A page or part of one: in Edit the caret moves as far as the text, keeping its place on screen and its column;
    /// at the top or the bottom it goes to the first or the last line. In Read only the text moves.
    func page(_ pages: CGFloat) {
        let dy = distance(pages: pages)
        guard isEditable, let manager = layoutManager, let container = textContainer else {
            scrollBy(dx: 0, dy: dy)
            return
        }
        caretOnScreen()
        let text = string as NSString
        let location = min(selectedRange().location, text.length)
        let caret: NSPoint
        if manager.numberOfGlyphs == 0 {
            caret = .zero
        } else if location >= text.length, !manager.extraLineFragmentRect.isEmpty {
            caret = NSPoint(x: manager.extraLineFragmentRect.minX, y: manager.extraLineFragmentRect.midY)
        } else {
            let glyph = min(manager.glyphIndexForCharacter(at: location), manager.numberOfGlyphs - 1)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x =
                location >= text.length
                ? manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
                : line.minX + manager.location(forGlyphAt: glyph).x
            caret = NSPoint(x: x, y: line.midY)
        }
        let column = pageColumn ?? caret.x
        let y = caret.y + dy
        let used = manager.usedRect(for: container)
        let target: Int
        if y < used.minY {
            target = 0
        } else if y > used.maxY {
            target = text.length
        } else {
            let origin = textContainerOrigin
            target = characterIndexForInsertion(at: NSPoint(x: column + origin.x, y: y + origin.y))
        }
        scrollBy(dx: 0, dy: dy)
        movingByPage = true
        setSelectedRange(NSRange(location: min(target, text.length), length: 0))
        movingByPage = false
        pageColumn = column
        scrollRangeToVisible(selectedRange())
    }

    func scroll(columns: CGFloat) {
        let width = (font.map { ("8" as NSString).size(withAttributes: [.font: $0]).width }) ?? 8
        scrollBy(dx: columns * width, dy: 0)
    }

    private func scrollToEdge(top: Bool) {
        scrollBy(dx: 0, dy: top ? -.greatestFiniteMagnitude / 4 : .greatestFiniteMagnitude / 4)
    }

    /// Moves what is shown within the text, its left edge kept beside the line numbers.
    private func scrollBy(dx: CGFloat, dy: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let inset = clip.contentInsets
        var origin = clip.bounds.origin
        let lowestX = -inset.left
        let lowestY = -inset.top
        origin.x = min(max(lowestX, origin.x + dx), max(lowestX, frame.width - clip.bounds.width + inset.right))
        origin.y = min(max(lowestY, origin.y + dy), max(lowestY, frame.height - clip.bounds.height + inset.bottom))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
    var currentLineColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() == true { return }
        super.cancelOperation(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange() }
        return resigned
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: flag)
        if !movingByPage { pageColumn = nil }
        needsDisplay = true
    }

    /// The caret's line under the text, while editing.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, selectedRange().length == 0, let manager = layoutManager, let container = textContainer,
            currentLineColor.alphaComponent > 0
        else { return }
        let text = string as NSString
        let location = min(selectedRange().location, text.length)
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let glyphs = manager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        var bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        if line.length == 0 || location == text.length && text.length > 0 && text.character(at: text.length - 1) == 10 {
            bounds = manager.extraLineFragmentRect
            if bounds.isEmpty, glyphs.length == 0, text.length == 0 {
                bounds.size.height = font?.boundingRectForFont.height ?? 16
            }
        }
        bounds.origin.x = 0
        bounds.size.width = self.bounds.width
        bounds.origin.y += textContainerOrigin.y
        currentLineColor.setFill()
        bounds.intersection(rect).fill()
    }
}

/// The line numbers beside the text, from the coloring's line starts.
final class LineNumberRuler: NSRulerView {
    weak var coloring: SyntaxColoring?
    var textColor: NSColor = .secondaryLabelColor
    var backgroundColor: NSColor = .clear
    var font: NSFont = ThemeFonts.mono(11)

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func linesChanged() {
        let count = coloring?.lineStarts.count ?? 1
        let digits = max(3, String(count).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits)) + 20
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
            scrollView?.tile()
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard let textView = clientView as? NSTextView, let manager = textView.layoutManager,
            let container = textView.textContainer, let coloring
        else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let length = text.length
        var line = coloring.line(at: characters.location)
        while line < coloring.lineStarts.count {
            let start = coloring.lineStarts[line]
            if start > NSMaxRange(characters) && start > characters.location { break }
            let glyph: Int
            var lineRect: NSRect
            if start >= length {
                // The empty last line after a final line break.
                guard start == length, length > 0 else { break }
                lineRect = manager.extraLineFragmentRect
                guard !lineRect.isEmpty else { break }
            } else {
                glyph = manager.glyphIndexForCharacter(at: start)
                lineRect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = lineRect.minY + offset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: y), withAttributes: attributes)
            line += 1
        }
    }
}
