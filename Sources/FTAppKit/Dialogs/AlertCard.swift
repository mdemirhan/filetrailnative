// Port of apps/desktop/src/renderer/components/Alert.tsx (with useDialogFocus.ts) and the .alert, .alert-* and
// .copy-paste-detail-list rules of apps/desktop/src/renderer/styles.css (1459-1558, 1779-1792)
import AppKit
import FTFoundation

/// One button of an alert, and what pressing it does.
struct AlertButton {
    var title: String
    var variant: PushButtonVariant = .plain
    var action: @MainActor () -> Void
}

/// What sits under an alert's message: a field, a list.
@MainActor
protocol AlertAccessory: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

/// What an alert shows (`Alert`'s props).
struct AlertContent {
    var title: String
    var message: String?
    /// Left to right; the default (Return) is drawn in the accent, on the right, or on top when they are stacked.
    var buttons: [AlertButton]
    /// Three or more are stacked, each as wide as the panel; nil decides by the count.
    var stacked: Bool?
    /// The wide form (520, left aligned, the buttons in a row on the right) for alerts that show more.
    var wide = false
    /// A button apart from the answers (`alert-button-aside`): at the left of a wide alert's row (Stop Copying), or in
    /// the first cell of a compact alert's row, as wide as its title (Cancel).
    var aside: AlertButton?
    var accessory: (any AlertAccessory)?
    /// Escape and ⌘.; nil leaves them doing nothing.
    var onEscape: (@MainActor () -> Void)?
    /// What Return does when no button or field takes it; nil presses the default button.
    var onReturn: (@MainActor () -> Void)?

    var isStacked: Bool { stacked ?? AlertButtons.isStacked(count: buttons.count) }
}

/// A macOS alert as the original draws it: a bold title and a short message centred on a compact panel over the
/// window, the buttons across the bottom, no icon. A click outside does nothing; it is answered with a button, Return
/// or Escape.
@MainActor
final class AlertCard: NSView, DialogPanel, ThemeApplying {
    let content: AlertContent
    let titleLabel: ThemedText
    let messageLabel: ThemedText?
    let buttons: [SystemButton]
    let asideButton: SystemButton?
    private var theme = AppearanceModel.shared.theme
    /// Whether Tab has moved the focus: until then the default button shows no focus ring.
    private(set) var keyboardMoved = false

    init(_ content: AlertContent) {
        self.content = content
        let layout = DialogLayout.Alert.self
        let alignment: NSTextAlignment = content.wide ? .left : .center
        var titleStyle = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.body, .bold), color: { $0.palette.textPrimary },
            lineHeight: layout.titleLineHeight, alignment: alignment)
        titleStyle.background = { $0.palette.bgElevated }
        titleLabel = ThemedText(content.title, style: titleStyle, wrapping: true)
        titleLabel.setAccessibilityIdentifier("alert.title")
        if let message = content.message, !message.isEmpty {
            var style = TextStyle(
                font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.textSecondary },
                lineHeight: layout.messageLineHeight, alignment: alignment)
            style.background = { $0.palette.bgElevated }
            let label = ThemedText(message, style: style, wrapping: true)
            label.setAccessibilityIdentifier("alert.message")
            messageLabel = label
        } else {
            messageLabel = nil
        }
        let height = content.wide ? DesignTokens.controlHeights.regular : DesignTokens.controlHeights.large
        func make(_ button: AlertButton) -> SystemButton {
            let push = SystemButton(title: button.title)
            push.isDefault = button.variant == .default
            push.isDestructive = button.variant == .destructive
            push.controlHeight = height
            push.setAccessibilityIdentifier("alert.button")
            return push
        }
        buttons = content.buttons.map(make)
        asideButton = content.aside.map(make)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel(content.title)
        setAccessibilityIdentifier("alert")
        wantsLayer = true
        addSubview(titleLabel)
        if let messageLabel { addSubview(messageLabel) }
        if let accessory = content.accessory { addSubview(accessory) }
        for (index, button) in buttons.enumerated() {
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = index
            // The default opens focused, without a ring until Tab is used (styles.css:1462).
            button.suppressesFocusRing = button.isDefault
            addSubview(button)
        }
        if let asideButton {
            asideButton.target = self
            asideButton.action = #selector(pressedAside(_:))
            addSubview(asideButton)
        }
        applyTheme(theme)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var defaultButton: SystemButton? { buttons.first { $0.isDefault } }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.bgElevated).cgColor
        layer?.cornerRadius = CGFloat(DesignTokens.radii.dialog)
        layer?.masksToBounds = false
        // --elevation-dialog: the 0.5 edge; DialogScrim draws the drops under the panel.
        if let edge = palette.elevationDialog.first(where: { $0.blur == 0 && $0.spread > 0 }) {
            layer?.borderWidth = CGFloat(edge.spread)
            layer?.borderColor = NSColor(edge.color).cgColor
        }
    }

    // MARK: DialogPanel

    /// The default button, or the accessory's field.
    var initialResponder: NSView? {
        if let field = (content.accessory as? TextPromptAccessory)?.field { return field }
        return defaultButton ?? buttons.last
    }

    func panelSize(in size: NSSize) -> NSSize {
        let layout = DialogLayout.Alert.self
        let width =
            content.wide
            ? min(layout.wideWidth, max(0, size.width - layout.wideViewportInset))
            : min(layout.width, max(0, size.width - layout.viewportInset))
        return NSSize(width: width, height: measure(width: width))
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == KeyCode.tab {
            if !keyboardMoved {
                keyboardMoved = true
                for button in buttons { button.suppressesFocusRing = false }
            }
            return false
        }
        if KeyCode.isCancel(event) {
            // Escape while text is being composed cancels the composition, not the alert.
            if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            content.onEscape?()
            return true
        }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        guard KeyCode.isReturn(event), plain else {
            // The keys typed while an alert without a field is up go nowhere (B-NAV-217); Space presses the focused
            // button.
            guard plain, !(content.accessory is TextPromptAccessory) else { return false }
            if event.charactersIgnoringModifiers == " ", let button = window?.firstResponder as? SystemButton,
                button.isDescendant(of: self)
            {
                button.perform()
            }
            return true
        }
        // A focused button takes Return itself; a field submits its form.
        if let button = window?.firstResponder as? SystemButton, button.isDescendant(of: self) {
            button.perform()
            return true
        }
        if let prompt = content.accessory as? TextPromptAccessory, prompt.holdsKeyboard {
            prompt.submit()
            return true
        }
        if let onReturn = content.onReturn {
            onReturn()
        } else {
            defaultButton?.perform()
        }
        return true
    }

    /// Presses the button titled `title`, as a click on it does.
    func press(_ title: String) {
        (buttons + [asideButton].compactMap { $0 }).first { $0.title == title }?.perform()
    }

    @objc private func pressed(_ sender: SystemButton) {
        guard content.buttons.indices.contains(sender.tag) else { return }
        content.buttons[sender.tag].action()
    }

    @objc private func pressedAside(_ sender: SystemButton) {
        content.aside?.action()
    }

    // MARK: Layout

    private var padding: (top: CGFloat, horizontal: CGFloat, bottom: CGFloat) {
        let layout = DialogLayout.Alert.self
        return content.wide
            ? (CGFloat(layout.widePadding), CGFloat(layout.widePadding), CGFloat(layout.widePadding))
            : (CGFloat(layout.paddingTop), CGFloat(layout.paddingHorizontal), CGFloat(layout.paddingBottom))
    }

    private var buttonHeight: CGFloat {
        CGFloat(content.wide ? DesignTokens.controlHeights.regular : DesignTokens.controlHeights.large)
    }

    /// The panel's height at `width`: the texts wrapped, the accessory, the buttons.
    private func measure(width: CGFloat) -> CGFloat {
        let layout = DialogLayout.Alert.self
        let inner = max(0, width - 2 * padding.horizontal)
        var height = padding.top + titleLabel.height(forWidth: inner)
        if let messageLabel { height += CGFloat(layout.messageGap) + messageLabel.height(forWidth: inner) }
        if let accessory = content.accessory {
            height +=
                CGFloat(content.wide ? layout.wideAccessoryGap : layout.accessoryGap)
                + accessory.height(forWidth: inner)
        }
        height += CGFloat(layout.buttonsGap)
        let rows =
            content.isStacked && !content.wide
            ? buttons.count + (asideButton == nil ? 0 : 1) : (buttons.isEmpty && asideButton == nil ? 0 : 1)
        height += CGFloat(rows) * buttonHeight + CGFloat(max(0, rows - 1)) * CGFloat(layout.buttonSpacing)
        return ceil(height + padding.bottom)
    }

    override func layout() {
        super.layout()
        let layout = DialogLayout.Alert.self
        let inner = max(0, bounds.width - 2 * padding.horizontal)
        let x = padding.horizontal
        var y = padding.top
        let titleHeight = titleLabel.height(forWidth: inner)
        titleLabel.frame = NSRect(x: x, y: y, width: inner, height: ceil(titleHeight))
        y += titleHeight
        if let messageLabel {
            y += CGFloat(layout.messageGap)
            let height = messageLabel.height(forWidth: inner)
            messageLabel.frame = NSRect(x: x, y: y, width: inner, height: ceil(height))
            y += height
        }
        if let accessory = content.accessory {
            y += CGFloat(content.wide ? layout.wideAccessoryGap : layout.accessoryGap)
            let height = accessory.height(forWidth: inner)
            accessory.frame = NSRect(x: x, y: y, width: inner, height: height)
            y += height
        }
        y += CGFloat(layout.buttonsGap)
        let spacing = CGFloat(layout.buttonSpacing)
        if content.wide {
            // A row on the right, each as wide as its title; the aside button at the left.
            var right = x + inner
            for button in buttons.reversed() {
                let width = button.preferredWidth
                right -= width
                button.frame = NSRect(x: right, y: y, width: width, height: buttonHeight)
                right -= spacing
            }
            if let asideButton {
                asideButton.frame = NSRect(x: x, y: y, width: asideButton.preferredWidth, height: buttonHeight)
            }
        } else if content.isStacked {
            if let asideButton {
                let fit = min(inner, titleWidth(asideButton) + CGFloat(2 * SystemButton.horizontalPadding))
                asideButton.frame = NSRect(x: x, y: y, width: fit, height: buttonHeight)
                y += buttonHeight + spacing
            }
            for button in buttons {
                button.frame = NSRect(x: x, y: y, width: inner, height: buttonHeight)
                y += buttonHeight + spacing
            }
        } else if !buttons.isEmpty || asideButton != nil {
            // The width split evenly (`grid-auto-columns: minmax(0, 1fr)`). The aside button takes the first cell but
            // not its width (`margin-right: auto`): it sits at the cell's left, as wide as its title.
            let cells = buttons.count + (asideButton == nil ? 0 : 1)
            let count = CGFloat(cells)
            let width = (inner - spacing * (count - 1)) / count
            if let asideButton {
                let fit = min(width, titleWidth(asideButton) + CGFloat(2 * SystemButton.horizontalPadding))
                asideButton.frame = NSRect(x: x, y: y, width: fit, height: buttonHeight)
            }
            for (index, button) in buttons.enumerated() {
                let cell = index + cells - buttons.count
                button.frame = NSRect(
                    x: x + CGFloat(cell) * (width + spacing), y: y, width: width, height: buttonHeight)
            }
        }
    }

    /// A push button's title as drawn (an alert's buttons have no minimum width, `min-width: 0`).
    private func titleWidth(_ button: SystemButton) -> CGFloat {
        guard let font = button.font else { return 0 }
        return (button.title as NSString).size(withAttributes: [.font: font]).width
    }
}

/// The lines an alert lists under its message (`.copy-paste-detail-list`): a tinted box, the names one under another.
@MainActor
final class DetailListView: NSView, AlertAccessory, ThemeApplying {
    let rows: [ThemedText]
    private var theme = AppearanceModel.shared.theme

    init(lines: [String]) {
        var style = TextStyle(
            font: ThemeFonts.sans(DesignTokens.typeScale.small), color: { $0.palette.textSecondary },
            lineHeight: DialogLayout.DetailList.lineHeight)
        style.background = { $0.palette.bgElevated }
        rows = lines.map { ThemedText($0, style: style, wrapping: true) }
        super.init(frame: .zero)
        setAccessibilityIdentifier("alert.detailList")
        for row in rows {
            row.setAccessibilityIdentifier("alert.detailList.item")
            addSubview(row)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let list = DialogLayout.DetailList.self
        let inner = max(0, width - 2 * CGFloat(list.paddingHorizontal))
        let text = rows.reduce(0) { $0 + $1.height(forWidth: inner) }
        return ceil(text + CGFloat(max(0, rows.count - 1)) * CGFloat(list.rowGap) + 2 * CGFloat(list.paddingVertical))
    }

    override func layout() {
        super.layout()
        let list = DialogLayout.DetailList.self
        let inner = max(0, bounds.width - 2 * CGFloat(list.paddingHorizontal))
        var y = CGFloat(list.paddingVertical)
        for row in rows {
            let height = row.height(forWidth: inner)
            row.frame = NSRect(x: CGFloat(list.paddingHorizontal), y: y, width: inner, height: ceil(height))
            y += height + CGFloat(list.rowGap)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = CGFloat(DesignTokens.radii.control)
        NSColor(theme.palette.bgHover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}
