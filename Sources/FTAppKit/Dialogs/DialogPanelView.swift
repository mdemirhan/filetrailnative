import AppKit
import FTFoundation

/// What the dialogs drawn in the window share: the panel on the elevated background with the dialog's half-point edge
/// (DialogScrim draws the drops under it), the row of buttons at a footer's right, and Tab going round the panel's
/// controls. Each panel says its own size, keys and where the keyboard starts.
@MainActor
class DialogPanelView: NSView, DialogPanel, ThemeApplying {
    private(set) var theme = AppearanceModel.shared.theme
    /// Whether Tab has moved the keyboard: until then a button that opens focused shows no focus ring (it is already
    /// marked by its fill).
    private(set) var keyboardMoved = false
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: DialogPanel

    var initialResponder: NSView? { nil }

    func handleKey(_ event: NSEvent) -> Bool { false }

    func panelSize(in size: NSSize) -> NSSize { size }

    var keepsPaneFocus: Bool { false }

    // MARK: Look

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        let palette = theme.palette
        layer?.backgroundColor = NSColor(palette.bgElevated).cgColor
        layer?.cornerRadius = cornerRadius
        if let edge = palette.elevationDialog.first(where: { $0.blur == 0 && $0.spread > 0 }) {
            layer?.borderWidth = CGFloat(edge.spread)
            layer?.borderColor = NSColor(edge.color).cgColor
        }
    }

    /// Lays `buttons` out left to right in a row that ends at `right`, each as wide as it asks, `gap` apart. Returns
    /// where the room at the row's left ends, a gap before its first button.
    @discardableResult
    func layoutButtonRow(_ buttons: [SystemButton], right: CGFloat, y: CGFloat, height: CGFloat, gap: CGFloat)
        -> CGFloat
    {
        var right = right
        for button in buttons.reversed() {
            let width = button.preferredWidth
            right -= width
            button.frame = NSRect(x: right, y: y, width: width, height: height)
            right -= gap
        }
        return right
    }

    // MARK: Tab

    /// The views Tab goes round, in order: the panel's editable fields and enabled buttons, in the order they are
    /// drawn.
    func focusOrder() -> [NSView] { Self.focusable(in: self) }

    /// The control of the panel that has the keyboard: a field, for its field editor.
    var focusedControl: NSView? {
        guard let window else { return nil }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return window.firstResponder as? NSView
    }

    /// Puts the keyboard in `view`, as Tab does.
    func moveKeyboard(to view: NSView) {
        window?.makeFirstResponder(view)
    }

    /// Tab and ⇧Tab go round `focusOrder()`, wrapping at either end. From the first Tab on, the panel's buttons show
    /// their focus ring.
    func cycleFocus(backward: Bool) {
        if !keyboardMoved {
            keyboardMoved = true
            showFocusRings(in: self)
        }
        let order = focusOrder()
        guard window != nil, !order.isEmpty else { return }
        let focused = focusedControl
        let current = order.firstIndex { $0 === focused }
        let next: Int =
            if backward {
                current.map { $0 == 0 ? order.count - 1 : $0 - 1 } ?? order.count - 1
            } else {
                current.map { $0 == order.count - 1 ? 0 : $0 + 1 } ?? 0
            }
        moveKeyboard(to: order[next])
    }

    private func showFocusRings(in view: NSView) {
        (view as? SystemButton)?.suppressesFocusRing = false
        for child in view.subviews { showFocusRings(in: child) }
    }

    /// The editable fields and enabled buttons under `root`, in the order they are drawn.
    static func focusable(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let field = view as? NSTextField, field.isEditable, field.isEnabled {
                found.append(field)
            } else if let button = view as? NSButton {
                if button.isEnabled { found.append(button) }
            } else if view !== root, view.acceptsFirstResponder, view is GoToRowView || view is ClearButton {
                found.append(view)
            }
            for child in view.subviews { visit(child) }
        }
        visit(root)
        return found.sorted { a, b in
            let ra = a.convert(a.bounds, to: root)
            let rb = b.convert(b.bounds, to: root)
            if abs(ra.minY - rb.minY) > 1 { return root.isFlipped ? ra.minY < rb.minY : ra.minY > rb.minY }
            return ra.minX < rb.minX
        }
    }
}

/// A footer's top line: 1 pt in the light border color.
@MainActor
final class DialogFooterLine: NSView, ThemeApplying {
    private var theme = AppearanceModel.shared.theme
    private let thickness: CGFloat

    init(thickness: Double) {
        self.thickness = CGFloat(thickness)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.palette.borderLight).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: thickness).fill(using: .sourceOver)
    }
}
