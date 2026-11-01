import AppKit
import FTFoundation

/// The bar above the Trash, as in Finder: its name, and Empty, which asks what Empty Trash asks. Search results take its
/// place while they show.
final class TrashHeaderView: NSView {
    var onEmpty: () -> Void = {}
    /// A press in the bar: the keyboard goes to the list.
    var onFocusList: () -> Void = {}
    /// Tab or Shift-Tab from Empty (`paneTabSwitch`).
    var onSwitchPane: () -> Void = {}

    private static var layout: SearchLayout { .standard }
    private let label = FlushTextField(labelWithString: "Trash")
    let emptyButton = SearchSmallButton(title: "Empty", spinner: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("trashHeader")
        label.setAccessibilityIdentifier("trashHeader.label")
        emptyButton.setAccessibilityIdentifier("trashHeader.empty")
        emptyButton.setAccessibilityLabel("Empty Trash")
        emptyButton.toolTip = "Empty Trash"
        emptyButton.onPress = { [weak self] in self?.onEmpty() }
        emptyButton.onMouseDown = { [weak self] in self?.onFocusList() }
        emptyButton.onTab = { [weak self] _ in self?.onSwitchPane() }
        addSubview(label)
        addSubview(emptyButton)
        label.font = SearchHeaderView.font(DesignTokens.typeScale.callout)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The bar, as tall as Finder's, then the 1 pt edge.
    static var height: Double { layout.scopeBarMinHeight + layout.headerBorderWidth }

    override func mouseDown(with event: NSEvent) { onFocusList() }

    override func draw(_ dirtyRect: NSRect) {
        ChromeColors.contentBackground(for: self).setFill()
        bounds.fill()
        let edge = CGFloat(Self.layout.headerBorderWidth)
        ChromeColors.color(infoTheme.palette.borderLight).setFill()
        NSRect(x: 0, y: bounds.height - edge, width: bounds.width, height: edge).fill()
    }

    override func layout() {
        super.layout()
        let theme = infoTheme
        label.textColor = ChromeColors.color(theme.palette.textSecondary)
        emptyButton.applyTheme(theme)
        let layout = Self.layout
        let centerY = layout.scopeBarMinHeight / 2
        let buttonWidth = emptyButton.preferredWidth
        emptyButton.frame = NSRect(
            x: bounds.width - layout.scopeBarPaddingHorizontal - buttonWidth, y: centerY - layout.smallButtonHeight / 2,
            width: buttonWidth, height: layout.smallButtonHeight)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: layout.scopeBarPaddingHorizontal, y: (centerY - labelHeight / 2).rounded(),
            width: max(0, emptyButton.frame.minX - layout.scopeBarGap - layout.scopeBarPaddingHorizontal),
            height: labelHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
    }
}
