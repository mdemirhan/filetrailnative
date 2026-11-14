import AppKit
import FTFoundation

/// The field an alert asks a name with (Rename, New Folder), and the reason under it when one was refused. Return
/// submits what is typed, trimmed; the submit button can't be pressed while it is empty. Given names to choose from (the
/// saved workspaces), a button at the field's end, or ↓, lists them, and the one chosen replaces what is typed.
@MainActor
final class TextPromptAccessory: NSView, AlertAccessory, ThemeApplying, NSTextFieldDelegate {
    let field: PromptField
    let errorLabel: ThemedText
    /// Told each name submitted, trimmed and not empty.
    var onSubmit: (String) -> Void = { _ in }
    /// Told whether something can be submitted, as the text changes.
    var onCanSubmit: (Bool) -> Void = { _ in }
    /// Told the text as it changes, by typing or by a name chosen.
    var onTextChange: (String) -> Void = { _ in }
    /// The names the button lists; with none there is no button.
    let names: [String]
    let namesButton: NSButton?
    private var theme = AppearanceModel.shared.theme
    private let selectsAll: Bool
    private static let font = ThemeFonts.sans(DesignTokens.typeScale.body)

    init(text: String, label: String, selectsAll: Bool, names: [String] = [], namesLabel: String = "") {
        field = PromptField()
        self.selectsAll = selectsAll
        self.names = names
        if names.isEmpty {
            namesButton = nil
        } else {
            let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: namesLabel)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = namesLabel
            button.setAccessibilityLabel(namesLabel)
            button.setAccessibilityIdentifier("prompt.names")
            namesButton = button
        }
        let style = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.dangerText },
            lineHeight: DialogLayout.TextPrompt.errorLineHeight)
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
        field.onFocus = { [weak self] in self?.focused() }
        addSubview(field)
        addSubview(errorLabel)
        if let namesButton {
            namesButton.target = self
            namesButton.action = #selector(showNames(_:))
            addSubview(namesButton)
        }
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
        TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.dangerText },
            lineHeight: DialogLayout.TextPrompt.errorLineHeight)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        field.textColor = NSColor(theme.palette.textPrimary)
        namesButton?.contentTintColor = NSColor(theme.palette.textSecondary)
        needsDisplay = true
    }

    func submit() {
        let name = trimmed
        guard !name.isEmpty else { return }
        onSubmit(name)
    }

    func controlTextDidChange(_ obj: Notification) {
        textChanged()
    }

    private func textChanged() {
        onCanSubmit(!trimmed.isEmpty)
        onTextChange(text)
        needsDisplay = true
    }

    /// ↓ lists the names, as the button does.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), namesButton != nil else { return false }
        showNames(nil)
        return true
    }

    /// The list of names, under the field, as wide as it.
    func namesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        return menu
    }

    @objc private func showNames(_ sender: Any?) {
        let below = NSPoint(x: 0, y: CGFloat(DesignTokens.controlHeights.regular) + 2)
        namesMenu().popUp(positioning: nil, at: below, in: self)
    }

    @objc private func chose(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        choose(name)
    }

    /// `name` replaces what is typed, selected, and the field has the keyboard.
    func choose(_ name: String) {
        field.stringValue = name
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (name as NSString).length)
        textChanged()
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
        let buttonWidth: CGFloat = namesButton == nil ? 0 : fieldHeight
        field.frame = NSRect(
            x: inset, y: ((fieldHeight - lineHeight) / 2).rounded(),
            width: max(0, bounds.width - 2 * inset - buttonWidth), height: lineHeight)
        namesButton?.frame = NSRect(x: bounds.width - buttonWidth, y: 0, width: buttonWidth, height: fieldHeight)
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
        // The field's edge (the theme's `fieldEdge`), and the focus ring while it has the keyboard.
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
