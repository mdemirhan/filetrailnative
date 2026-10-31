// Port of the field and the error line of apps/desktop/src/renderer/components/TextPromptDialog.tsx and the
// .text-prompt-* rules of apps/desktop/src/renderer/styles.css (1740-1768)
import AppKit
import FTFoundation

/// The field an alert asks a name with (Rename, New Folder), and the reason under it when one was refused. Return
/// submits what is typed, trimmed; the submit button can't be pressed while it is empty.
@MainActor
final class TextPromptAccessory: NSView, AlertAccessory, ThemeApplying, NSTextFieldDelegate {
    let field: PromptField
    let errorLabel: ThemedText
    /// Told each name submitted, trimmed and not empty.
    var onSubmit: (String) -> Void = { _ in }
    /// Told whether something can be submitted, as the text changes.
    var onCanSubmit: (Bool) -> Void = { _ in }
    private var theme = AppearanceModel.shared.theme
    private let selectsAll: Bool
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(text: String, label: String, placeholder: String? = nil, selectsAll: Bool) {
        field = PromptField()
        self.selectsAll = selectsAll
        var style = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.dangerText },
            lineHeight: DialogLayout.TextPrompt.errorLineHeight)
        style.background = { $0.palette.bgElevated }
        errorLabel = ThemedText("", style: style, wrapping: true)
        super.init(frame: .zero)
        setAccessibilityIdentifier("alert.accessory")
        errorLabel.setAccessibilityIdentifier("prompt.error")
        errorLabel.isHidden = true
        field.stringValue = text
        field.font = Self.font
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("prompt.field")
        if let placeholder { field.placeholderString = placeholder }
        field.onFocus = { [weak self] in self?.focused() }
        addSubview(field)
        addSubview(errorLabel)
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var text: String { field.stringValue }
    var trimmed: String { InlineRenameRules.trimmedName(text) }

    /// Whether the field has the keyboard.
    var holdsKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    /// The reason the last name was refused, shown under the field; nil takes it away.
    var error: String? {
        didSet {
            errorLabel.content = { [style = errorStyle, error] theme in style.string(error ?? "", theme) }
            errorLabel.isHidden = error == nil
            (superview as? AlertCard)?.needsLayout = true
            superview?.superview?.needsLayout = true
        }
    }

    private var errorStyle: TextStyle {
        var style = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.dangerText },
            lineHeight: DialogLayout.TextPrompt.errorLineHeight)
        style.background = { $0.palette.bgElevated }
        return style
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        field.textColor = NSColor(theme.palette.textPrimary)
        needsDisplay = true
    }

    func submit() {
        let name = trimmed
        guard !name.isEmpty else { return }
        onSubmit(name)
    }

    func controlTextDidChange(_ obj: Notification) {
        onCanSubmit(!trimmed.isEmpty)
        needsDisplay = true
    }

    /// The first focus selects the whole name, or puts the caret at its end.
    private func focused() {
        guard let editor = field.currentEditor() else { return }
        let length = (field.stringValue as NSString).length
        editor.selectedRange = selectsAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = CGFloat(DesignTokens.controlHeights.regular)
        if !errorLabel.isHidden {
            height += CGFloat(DialogLayout.TextPrompt.errorGap) + ceil(errorLabel.height(forWidth: width))
        }
        return height
    }

    override func layout() {
        super.layout()
        let fieldHeight = CGFloat(DesignTokens.controlHeights.regular)
        let inset = CGFloat(DialogLayout.TextPrompt.fieldPaddingHorizontal)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        field.frame = NSRect(
            x: inset, y: ((fieldHeight - lineHeight) / 2).rounded(), width: max(0, bounds.width - 2 * inset),
            height: lineHeight)
        let errorTop = fieldHeight + CGFloat(DialogLayout.TextPrompt.errorGap)
        errorLabel.frame = NSRect(
            x: 0, y: errorTop, width: bounds.width, height: ceil(errorLabel.height(forWidth: bounds.width)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: CGFloat(DesignTokens.controlHeights.regular))
        let palette = theme.palette
        NSColor(palette.fieldBg).setFill()
        NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
        // --field-edge, and --field-focus (the edge and the focus ring) while it has the keyboard.
        for layer in palette.fieldEdge where layer.blur == 0 && layer.spread > 0 {
            let edge = NSBezierPath(
                roundedRect: box.insetBy(dx: CGFloat(layer.spread) / 2, dy: CGFloat(layer.spread) / 2),
                xRadius: radius, yRadius: radius)
            edge.lineWidth = CGFloat(layer.spread)
            NSColor(layer.color).setStroke()
            edge.stroke()
        }
        if holdsKeyboard {
            let ring = NSBezierPath(
                roundedRect: box.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 1.5, yRadius: radius + 1.5)
            ring.lineWidth = CGFloat(DesignTokens.focusRingWidth)
            NSColor(theme.accent.solid.withAlpha(0.5)).setStroke()
            ring.stroke()
        }
    }
}

/// The prompt's field: tells when it takes the keyboard, once, so the name is selected as the prompt opens.
@MainActor
final class PromptField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let onFocus {
            self.onFocus = nil
            onFocus()
        }
        return became
    }
}
