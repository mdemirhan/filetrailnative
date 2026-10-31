// Port of the rows, the field shell and their glyphs of apps/desktop/src/renderer/components/GoToFolderDialog.tsx and
// the .go-to-folder-input-* and .go-to-folder-suggestion* rules of apps/desktop/src/renderer/styles.css (3481-3654)
import AppKit
import FTFoundation

/// One folder of the Go To list: a star or a folder, the name with the typed letters bold, and where it is, cut at its
/// start. The selected one is filled with the accent, as a menu row.
@MainActor
final class GoToRowView: NSView, TextStyleSource, ThemeApplying {
    let index: Int
    let row: GoToRow
    let glyph = GoToGlyphView()
    let nameLabel = NSTextField(labelWithString: "")
    let pathLabel = PlainLabel(labelWithString: "")
    weak var box: GoToFolderBox?
    var isSelected = false { didSet { if isSelected != oldValue { applyColors() } } }
    private var theme = AppearanceModel.shared.theme
    private var trackingArea: NSTrackingArea?
    private static let nameFont = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let matchFont = ThemeFonts.sans(DesignTokens.typeScale.body, .bold)
    private static let pathFont = ThemeFonts.sans(DesignTokens.typeScale.callout)

    init(index: Int, row: GoToRow, theme: Theme) {
        self.index = index
        self.row = row
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.name)
        setAccessibilityIdentifier("goToFolder.suggestion")
        toolTip = row.path
        glyph.isFavorite = row.isFavorite
        glyph.setAccessibilityIdentifier("goToFolder.suggestion.glyph")
        for label in [nameLabel, pathLabel] {
            label.isBordered = false
            label.drawsBackground = false
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.isScrollable = false
        }
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = Self.nameFont
        nameLabel.setAccessibilityIdentifier("goToFolder.suggestion.name")
        // Shortened at its start: the end of a long path says most.
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.font = Self.pathFont
        pathLabel.stringValue = row.detail
        pathLabel.setAccessibilityIdentifier("goToFolder.suggestion.location")
        addSubview(glyph)
        addSubview(nameLabel)
        addSubview(pathLabel)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var styleTextField: NSTextField? { nameLabel }

    /// A row is in the Tab cycle as the original's buttons are, but a click leaves the keyboard in the field.
    override var acceptsFirstResponder: Bool {
        NSApp.currentEvent?.type != .leftMouseDown
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        applyColors()
    }

    private func applyColors() {
        let accent = theme.accent
        let palette = theme.palette
        let text = isSelected ? accent.onSolid : palette.textPrimary
        let name = NSMutableAttributedString(
            string: row.name, attributes: [.font: Self.nameFont, .foregroundColor: NSColor(text)])
        let length = (row.name as NSString).length
        for range in row.nameRanges where range.lowerBound < length {
            let clipped = NSRange(location: range.lowerBound, length: min(range.upperBound, length) - range.lowerBound)
            name.addAttribute(.font, value: Self.matchFont, range: clipped)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        name.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
        nameLabel.attributedStringValue = name
        nameLabel.textColor = NSColor(text)
        pathLabel.textColor = NSColor(
            isSelected ? accent.onSolid.withAlpha(DialogLayout.GoTo.selectedPathAlpha) : palette.textSecondary)
        glyph.color = isSelected ? accent.onSolid : palette.textSecondary
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = DialogLayout.GoTo.self
        let padding = CGFloat(layout.rowPaddingHorizontal)
        let gap = CGFloat(layout.rowGap)
        let glyphSize = CGFloat(layout.rowGlyphSize)
        let inner = max(0, bounds.width - 2 * padding)
        glyph.frame = NSRect(
            x: padding, y: ((bounds.height - glyphSize) / 2).rounded(), width: glyphSize, height: glyphSize)
        // The name takes its own width up to 55% of the row; the location the rest. A label's cell draws its text 2 in
        // from each side, so each frame reaches 2 past where the original's text box is.
        let natural = ceil(nameLabel.attributedStringValue.size().width)
        let nameWidth = min(natural, (inner * CGFloat(layout.nameMaxFraction)).rounded(.down))
        let nameHeight = Self.lineHeight(Self.nameFont)
        let inset = Self.cellInset
        let x = padding + glyphSize + gap
        nameLabel.frame = NSRect(
            x: x - inset, y: ((bounds.height - nameHeight) / 2).rounded(), width: nameWidth + 2 * inset,
            height: nameHeight)
        let pathX = x + nameWidth + gap
        let pathHeight = Self.lineHeight(Self.pathFont)
        let pathWidth = max(0, padding + inner - pathX)
        pathLabel.frame = NSRect(
            x: pathX - inset, y: ((bounds.height - pathHeight) / 2).rounded(), width: pathWidth + 2 * inset,
            height: pathHeight)
        // `direction: rtl; text-align: left`: a path that fits starts by the name; one cut short ends at the margin,
        // whatever whole characters are left.
        pathLabel.alignment = pathLabel.attributedStringValue.size().width > pathWidth ? .right : .left
    }

    /// How far in from its frame a label's (or a field's) cell draws its text.
    static let cellInset: CGFloat = 2

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        if isSelected {
            NSColor(theme.accent.solidButton).setFill()
            shape.fill()
        }
        if window?.firstResponder === self {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        box?.pointerMoved(over: index, at: event.locationInWindow)
    }

    // The field keeps the keyboard while the list is used with the mouse.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        box?.rowClicked(index)
    }
}

/// The star of a favorite, or a folder, stroked 1.3 on a 14 by 14 grid.
@MainActor
final class GoToGlyphView: NSView {
    var isFavorite = false { didSet { needsDisplay = true } }
    var color = RGBA(r: 0, g: 0, b: 0) { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / 14
        let path = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
        if isFavorite {
            // M7 1.6l1.6 3.4 3.7.5-2.7 2.6.7 3.7L7 10l-3.3 1.8.7-3.7L1.7 5.5l3.7-.5L7 1.6z
            let points: [(CGFloat, CGFloat)] = [
                (7, 1.6), (8.6, 5), (12.3, 5.5), (9.6, 8.1), (10.3, 11.8), (7, 10), (3.7, 11.8), (4.4, 8.1),
                (1.7, 5.5), (5.4, 5),
            ]
            path.move(to: point(points[0].0, points[0].1))
            for next in points.dropFirst() { path.line(to: point(next.0, next.1)) }
        } else {
            // M1.5 3.5h4l1.2 1.4h5.8v6.6h-11z
            path.move(to: point(1.5, 3.5))
            path.line(to: point(5.5, 3.5))
            path.line(to: point(6.7, 4.9))
            path.line(to: point(12.5, 4.9))
            path.line(to: point(12.5, 11.5))
            path.line(to: point(1.5, 11.5))
        }
        path.close()
        path.lineWidth = CGFloat(DialogLayout.GoTo.rowGlyphStroke) * scale
        path.lineJoinStyle = .round
        NSColor(color).setStroke()
        path.stroke()
    }
}

/// The field's rounded shell: the magnifier, the field, and the ✕ once something is typed. It draws the focus ring
/// while the field has the keyboard.
@MainActor
final class GoToFieldShell: NSView, ThemeApplying {
    let field: GoToField
    let clearButton: ClearButton
    private var theme = AppearanceModel.shared.theme
    static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(label: String) {
        field = GoToField()
        clearButton = ClearButton()
        super.init(frame: .zero)
        setAccessibilityIdentifier("goToFolder.fieldShell")
        field.font = Self.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = GoToFolderBox.placeholder
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("goToFolder.field")
        // No spelling, completion or correction in a path.
        field.isAutomaticTextCompletionEnabled = false
        field.onFocusChange = { [weak self] in self?.needsDisplay = true }
        clearButton.setAccessibilityLabel("Clear")
        clearButton.setAccessibilityIdentifier("goToFolder.clear")
        clearButton.toolTip = "Clear"
        // A plain button of the dialog: Tab goes from the field to here (GoToFolderDialog.tsx:408-416, focusUtils.ts).
        clearButton.isTabStop = true
        clearButton.isHidden = true
        addSubview(field)
        addSubview(clearButton)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var holdsKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        clearButton.applyTheme(theme)
        field.textColor = NSColor(theme.palette.textPrimary)
        field.placeholderAttributedString = NSAttributedString(
            string: GoToFolderBox.placeholder,
            attributes: [.font: Self.font, .foregroundColor: NSColor(theme.palette.textPlaceholder)])
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let layout = DialogLayout.GoTo.self
        let padding = CGFloat(layout.fieldPaddingHorizontal)
        let gap = CGFloat(layout.fieldGap)
        let icon = CGFloat(layout.fieldIconSize)
        let clear = CGFloat(ClearButton.size)
        let left = padding + icon + gap
        let right = clearButton.isHidden ? padding : padding + clear + gap
        let lineHeight = GoToRowView.lineHeight(Self.font)
        // The field's cell draws its text 2 in: the frame starts 2 early so the text starts where the original's does.
        let inset = GoToRowView.cellInset
        field.frame = NSRect(
            x: left - inset, y: ((bounds.height - lineHeight) / 2).rounded(),
            width: max(0, bounds.width - left - right + inset), height: lineHeight)
        clearButton.frame = NSRect(
            x: bounds.width - padding - clear, y: ((bounds.height - clear) / 2).rounded(), width: clear, height: clear)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        for layer in palette.fieldEdge where layer.blur == 0 && layer.spread > 0 {
            let inset = CGFloat(layer.spread) / 2
            let edge = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
            edge.lineWidth = CGFloat(layer.spread)
            NSColor(layer.color).setStroke()
            edge.stroke()
        }
        if holdsKeyboard {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
        // The magnifier: a circle of 4.5 at 7,7 and a line to 14,14 on a 16 grid, stroked 1.5.
        let layout = DialogLayout.GoTo.self
        let size = CGFloat(layout.fieldIconSize)
        let origin = NSPoint(
            x: CGFloat(layout.fieldPaddingHorizontal), y: ((bounds.height - size) / 2).rounded())
        let scale = size / 16
        let glass = NSBezierPath(
            ovalIn: NSRect(
                x: origin.x + 2.5 * scale, y: origin.y + 2.5 * scale, width: 9 * scale, height: 9 * scale))
        glass.move(to: NSPoint(x: origin.x + 10.5 * scale, y: origin.y + 10.5 * scale))
        glass.line(to: NSPoint(x: origin.x + 14 * scale, y: origin.y + 14 * scale))
        glass.lineWidth = CGFloat(layout.fieldIconStroke)
        glass.lineCapStyle = .round
        NSColor(palette.textSecondary).setStroke()
        glass.stroke()
    }
}

/// The box's field: tells when it takes or leaves the keyboard, for the shell's focus ring.
@MainActor
final class GoToField: NSTextField {
    var onFocusChange: (() -> Void)?

    /// The placeholder's words, also while it is drawn from the theme's attributed string.
    override var placeholderString: String? {
        get { super.placeholderString ?? placeholderAttributedString?.string }
        set { super.placeholderString = newValue }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        onFocusChange?()
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}
