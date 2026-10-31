// Port of apps/desktop/src/renderer/components/ListFilterPill.tsx and the .list-filter-pill rules of styles.css:1895-1934
import AppKit
import FTFoundation

/// What has been typed to narrow the list above it, how much of the list is left, and a way to bring the rest back. It
/// floats over the foot of the list so the first match, which is selected at the top, is never covered.
final class ListFilterPillView: NSView, TextStyleSource {
    private let label = ListLabel()
    private let value = ListLabel()
    private let count = ListLabel()
    private let clear = ClearButton()
    private var theme = AppearanceModel.shared.theme

    /// Told when the ✕ is pressed.
    var onClear: () -> Void = {}

    var styleTextField: NSTextField? { value }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        let font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        label.stringValue = "Filter"
        label.font = font
        label.setAccessibilityIdentifier("listFilter.label")
        value.font = ThemeFonts.sans(DesignTokens.typeScale.callout, .semibold)
        value.lineBreakMode = .byTruncatingTail
        value.setAccessibilityIdentifier("listFilter.value")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(DesignTokens.typeScale.callout), weight: .regular)
        count.setAccessibilityIdentifier("listFilter.count")
        clear.setAccessibilityLabel("Clear filter")
        clear.toolTip = "Clear Filter (Esc)"
        clear.setAccessibilityIdentifier("listFilter.clear")
        clear.target = self
        clear.action = #selector(cleared(_:))
        for view in [label, value, count, clear] as [NSView] { addSubview(view) }
        setAccessibilityIdentifier("listFilter")
        setAccessibilityLabel("Filter")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func cleared(_ sender: Any?) { onClear() }

    /// Shows the filter, or hides the pill when there is none.
    func show(query: String, shown: Int, total: Int, theme: Theme) {
        self.theme = theme
        isHidden = query.isEmpty
        guard !query.isEmpty else { return }
        value.stringValue = query
        count.stringValue = "\(shown) of \(total)"
        clear.applyTheme(theme)
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    private func applyColors() {
        let palette = theme.palette
        label.textColor = NSColor(palette.textSecondary)
        value.textColor = NSColor(palette.textPrimary)
        count.textColor = NSColor(palette.textSecondary)
    }

    // MARK: Layout

    /// The pill's size in a list `available` wide: as wide as its parts, at most the list less 32.
    func fittingSize(in available: CGFloat) -> NSSize {
        let layout = SelectionLayout.FilterPill.self
        let gap = CGFloat(layout.gap)
        let fixed =
            CGFloat(layout.borderWidth) * 2 + CGFloat(layout.paddingLeft) + CGFloat(layout.paddingRight)
            + label.textWidth + gap + gap + count.textWidth + gap + ClearButton.size
        let maxWidth = max(0, available - CGFloat(layout.maxWidthInset))
        let valueWidth = min(value.textWidth, max(0, maxWidth - fixed))
        let inner = max(label.lineHeight, value.lineHeight, count.lineHeight, ClearButton.size)
        let height =
            CGFloat(layout.borderWidth) * 2 + CGFloat(layout.paddingTop) + inner + CGFloat(layout.paddingBottom)
        return NSSize(width: min(maxWidth, fixed + valueWidth), height: height.rounded(.up))
    }

    override func layout() {
        super.layout()
        let layout = SelectionLayout.FilterPill.self
        let gap = CGFloat(layout.gap)
        let border = CGFloat(layout.borderWidth)
        let inner = bounds.height - 2 * border - CGFloat(layout.paddingTop) - CGFloat(layout.paddingBottom)
        let top = border + CGFloat(layout.paddingTop)
        func place(_ view: NSView, x: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
            view.frame = NSRect(x: x, y: top + (inner - height) / 2, width: width, height: height)
            return x + width + gap
        }
        var x = border + CGFloat(layout.paddingLeft)
        x = place(label, x: x, width: label.textWidth, height: label.lineHeight)
        let countWidth = count.textWidth
        let reserved = gap + countWidth + gap + ClearButton.size + CGFloat(layout.paddingRight) + border
        let valueWidth = min(value.textWidth, max(0, bounds.width - x - reserved))
        x = place(value, x: x, width: valueWidth, height: value.lineHeight)
        x = place(count, x: x, width: countWidth, height: count.lineHeight)
        _ = place(clear, x: x, width: ClearButton.size, height: ClearButton.size)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let layout = SelectionLayout.FilterPill.self
        let border = CGFloat(layout.borderWidth)
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: border / 2, dy: border / 2), xRadius: bounds.height / 2,
            yRadius: bounds.height / 2)
        NSColor(theme.palette.bgElevated.withAlpha(layout.backgroundAlpha)).setFill()
        shape.fill()
        NSColor(theme.accent.border).setStroke()
        shape.lineWidth = border
        shape.stroke()
    }

    /// The ✕ and the pill take the pointer; the list keeps the keyboard (a press here does not change who has it).
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {}
}
