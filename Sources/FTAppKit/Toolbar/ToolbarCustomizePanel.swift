// Port of apps/desktop/src/renderer/components/ToolbarCustomizePanel.tsx and PushButton.tsx, with the
// .toolbar-customize-* rules of styles.css
import AppKit
import FTFoundation

/// The panel under the toolbar while it is customized: the items that can be put in the toolbar, to drag into it or
/// click to add at its far right, Restore Defaults and Done. While letting go would take a dragged item off, it says
/// so with a red dashed outline.
final class ToolbarCustomizePanel: NSView {
    static let maxWidth = 760.0
    static let sideMargin = 16.0
    static let gapBelowToolbar = 8.0
    static let padding = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
    static let columnMin = 76.0
    static let rowGap = 8.0
    static let columnGap = 4.0
    static let chip = 32.0
    static let itemPadding = (vertical: 4.0, horizontal: 2.0)
    static let itemGap = 4.0
    static let labelLineHeight = 1.2

    var onAdd: (ToolbarItemID) -> Void = { _ in }
    var onPress: (ToolbarItemID, NSPoint) -> Void = { _, _ in }
    var onDrag: (NSPoint) -> Void = { _ in }
    var onRelease: () -> Void = {}
    var onRestoreDefaults: () -> Void = {}
    var onDone: () -> Void = {}

    var items: [ToolbarItemID] = [] {
        didSet {
            guard items != oldValue else { return }
            rebuild()
        }
    }
    var draggedItem: ToolbarItemID? {
        didSet { for view in itemViews { view.alphaValue = view.id == draggedItem ? 0.35 : 1 } }
    }
    var removing = false {
        didSet { needsDisplay = true }
    }
    var restoreEnabled = true {
        didSet { restore.isEnabled = restoreEnabled }
    }

    private let title = NSTextField(labelWithString: "Drag items into the toolbar")
    private let note = NSTextField(
        labelWithString: "Drag an item out of the toolbar to remove it. Click an item to add it at the far right.")
    private(set) var itemViews: [ToolbarPaletteItemView] = []
    private let restore = PanelPushButton(title: "Restore Defaults", isDefault: false)
    private let done = PanelPushButton(title: "Done", isDefault: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag items into the toolbar")
        setAccessibilityIdentifier("toolbar.customize")
        title.font = ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600)
        title.setAccessibilityIdentifier("toolbar.customize.title")
        note.font = ChromeColors.font(size: DesignTokens.typeScale.small)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.setAccessibilityIdentifier("toolbar.customize.note")
        restore.onClick = { [weak self] in self?.onRestoreDefaults() }
        done.onClick = { [weak self] in self?.onDone() }
        for view in [title, note, restore, done] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func rebuild() {
        for view in itemViews { view.removeFromSuperview() }
        itemViews = items.map { id in
            let view = ToolbarPaletteItemView(id: id)
            view.onPress = { [weak self] point in self?.onPress(id, point) }
            view.onDrag = { [weak self] point in self?.onDrag(point) }
            view.onRelease = { [weak self] dragged in
                self?.onRelease()
                if !dragged { self?.onAdd(id) }
            }
            addSubview(view)
            return view
        }
        applyColors()
        needsLayout = true
    }

    /// `min(760, 100% − 32)` of the toolbar.
    static func width(forToolbarWidth width: Double) -> Double { min(maxWidth, width - 2 * sideMargin) }

    private var contentWidth: Double { bounds.width - Self.padding.left - Self.padding.right }

    /// The grid's columns: as many 76 pt (or wider) columns as fit, sharing the room.
    private func columns(width: Double) -> (count: Int, width: Double) {
        let count = max(1, Int(((width + Self.columnGap) / (Self.columnMin + Self.columnGap)).rounded(.down)))
        return (count, (width - Double(count - 1) * Self.columnGap) / Double(count))
    }

    private static func lineHeight(_ font: NSFont?) -> Double {
        // Chromium's "normal" line height for the system font.
        ((font?.pointSize ?? 13) * 1.2).rounded(.down)
    }

    /// The panel's height at `width`.
    func height(forWidth width: Double) -> Double {
        let inner = width - Self.padding.left - Self.padding.right
        return Self.padding.top + Self.lineHeight(title.font) + 2 + noteHeight(inner) + 12 + gridHeight(inner) + 14 + 0.5
            + 12 + PanelPushButton.height + Self.padding.bottom
    }

    private func noteHeight(_ width: Double) -> Double {
        let font = note.font ?? .systemFont(ofSize: DesignTokens.typeScale.small)
        let lines = Self.lines(note.stringValue, font: font, width: width)
        return Double(lines) * Self.lineHeight(font)
    }

    private static func lines(_ text: String, font: NSFont, width: Double) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            index = NSMaxRange(range)
            count += 1
        }
        return max(1, count)
    }

    /// Each row of items is as tall as its tallest item: the chip, the gap and the label's lines.
    private func rowHeights(_ width: Double) -> [Double] {
        let (count, columnWidth) = columns(width: width)
        let labelWidth = columnWidth - 2 * Self.itemPadding.horizontal
        let font = NSFont.systemFont(ofSize: DesignTokens.typeScale.small)
        let line = font.pointSize * Self.labelLineHeight
        var heights: [Double] = []
        for start in stride(from: 0, to: items.count, by: count) {
            let row = items[start..<min(items.count, start + count)]
            let tallest = row.map { Self.lines(ToolbarItems.definition($0).label, font: font, width: labelWidth) }.max() ?? 1
            heights.append(2 * Self.itemPadding.vertical + Self.chip + Self.itemGap + Double(tallest) * line)
        }
        return heights
    }

    private func gridHeight(_ width: Double) -> Double {
        let heights = rowHeights(width)
        return heights.reduce(0, +) + Double(max(0, heights.count - 1)) * Self.rowGap
    }

    override func layout() {
        super.layout()
        let inner = contentWidth
        var y = Self.padding.top
        let titleHeight = Self.lineHeight(title.font)
        title.frame = NSRect(x: Self.padding.left, y: y, width: inner, height: titleHeight)
        y += titleHeight + 2
        let noteHeight = noteHeight(inner)
        note.frame = NSRect(x: Self.padding.left, y: y, width: inner, height: noteHeight)
        y += noteHeight + 12
        let (count, columnWidth) = columns(width: inner)
        let heights = rowHeights(inner)
        for (index, view) in itemViews.enumerated() {
            let row = index / count
            let column = index % count
            let top = y + heights[..<row].reduce(0, +) + Double(row) * Self.rowGap
            view.frame = NSRect(
                x: Self.padding.left + Double(column) * (columnWidth + Self.columnGap), y: top, width: columnWidth,
                height: heights[row])
        }
        y += gridHeight(inner) + 14 + 0.5 + 12
        let restoreWidth = restore.naturalWidth
        restore.frame = NSRect(x: Self.padding.left, y: y, width: restoreWidth, height: PanelPushButton.height)
        let doneWidth = done.naturalWidth
        done.frame = NSRect(
            x: bounds.width - Self.padding.right - doneWidth, y: y, width: doneWidth, height: PanelPushButton.height)
        footerLineY = y - 12 - 0.5
        applyColors()
    }

    private var footerLineY = 0.0

    private func applyColors() {
        let palette = ChromeColors.palette(for: self)
        title.textColor = ChromeColors.color(palette.textPrimary)
        note.textColor = ChromeColors.color(palette.textSecondary)
        layer?.backgroundColor = ChromeColors.color(palette.bgElevated).cgColor
        layer?.cornerRadius = DesignTokens.radii.dialog
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 25
        layer?.shadowOffset = CGSize(width: 0, height: -20)
        layer?.borderWidth = 0.5
        layer?.borderColor = ChromeColors.color(palette.dialogEdge).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        ChromeColors.color(palette.dialogEdge).setFill()
        NSRect(x: Self.padding.left, y: footerLineY, width: contentWidth, height: 0.5).fill()
        if removing {
            let rect = bounds.insetBy(dx: 5.75, dy: 5.75)
            let radius = DesignTokens.radii.dialog - 4
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            ChromeColors.color(palette.danger.withAlpha(0.05)).setFill()
            path.fill()
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            ChromeColors.color(palette.danger.withAlpha(0.5)).setStroke()
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }
}

/// `.toolbar-customize-item`: a 32 pt chip on a capsule of its own with the item's icon, and its name under it.
final class ToolbarPaletteItemView: NSView, TextStyleSource {
    let id: ToolbarItemID
    let chip = NSView()
    let icon: ToolbarIconView
    let label = NSTextField(wrappingLabelWithString: "")
    var onPress: (NSPoint) -> Void = { _ in }
    var onDrag: (NSPoint) -> Void = { _ in }
    /// Let go: whether it was dragged.
    var onRelease: (Bool) -> Void = { _ in }
    private var dragged = false

    var styleTextField: NSTextField? { label }

    init(id: ToolbarItemID) {
        self.id = id
        let definition = ToolbarItems.definition(id)
        icon = ToolbarIconView(definition.icon)
        super.init(frame: .zero)
        chip.wantsLayer = true
        chip.setAccessibilityIdentifier("toolbar.customize.chip")
        chip.addSubview(icon)
        addSubview(chip)
        label.stringValue = definition.label
        label.font = ChromeColors.font(size: DesignTokens.typeScale.small)
        label.alignment = .center
        label.isSelectable = false
        label.setAccessibilityIdentifier("toolbar.customize.label")
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add \(definition.label) to the toolbar")
        setAccessibilityIdentifier("toolbar.customize.item")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let chipSize = ToolbarCustomizePanel.chip
        let top = ToolbarCustomizePanel.itemPadding.vertical
        chip.frame = NSRect(x: (bounds.width - chipSize) / 2, y: top, width: chipSize, height: chipSize)
        let iconSize = DesignTokens.toolbar.iconSize
        icon.frame = NSRect(
            x: (chipSize - iconSize) / 2, y: (chipSize - iconSize) / 2, width: iconSize, height: iconSize)
        let labelTop = top + chipSize + ToolbarCustomizePanel.itemGap
        let side = ToolbarCustomizePanel.itemPadding.horizontal
        let width = bounds.width - 2 * side
        let height = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = NSRect(x: side, y: labelTop, width: width, height: height)
        let palette = ChromeColors.palette(for: self)
        chip.layer?.backgroundColor = ChromeColors.color(palette.toolbarToggleBg).cgColor
        chip.layer?.cornerRadius = chipSize / 2
        icon.color = ChromeColors.color(palette.toolbarNavIconActive)
        label.textColor = ChromeColors.color(palette.textSecondary)
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        onPress(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        onDrag(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        onRelease(dragged || !inside)
    }

    override func accessibilityPerformPress() -> Bool {
        onRelease(false)
        return true
    }
}

/// `PushButton` (`.push-button`): 24 tall, at least 76 wide, 12 pt in, radius 6, 13 pt text; the default one filled
/// with the accent.
final class PanelPushButton: NSView, TextStyleSource {
    static let height = 24.0
    static let minWidth = 76.0
    static let paddingInline = 12.0
    let label = NSTextField(labelWithString: "")
    let isDefault: Bool
    var onClick: () -> Void = {}
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : DesignTokens.disabledOpacity
            needsDisplay = true
        }
    }

    var styleTextField: NSTextField? { label }

    init(title: String, isDefault: Bool) {
        self.isDefault = isDefault
        super.init(frame: .zero)
        label.stringValue = title
        label.font = ChromeColors.font(size: DesignTokens.typeScale.body)
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("toolbar.customize.button")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var naturalWidth: Double {
        max(Self.minWidth, (label.intrinsicContentSize.width + 2 * Self.paddingInline).rounded(.up))
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let accent = ChromeColors.accent(for: self)
        let radius = DesignTokens.radii.control
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        ChromeColors.color(isDefault ? accent.solidButton : palette.pushButtonBg).setFill()
        path.fill()
        if !isDefault {
            path.lineWidth = 0.5
            ChromeColors.color(palette.pushButtonEdge).setStroke()
            path.stroke()
        }
        label.textColor = ChromeColors.color(isDefault ? accent.onSolid : palette.textPrimary)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick()
        return true
    }
}
