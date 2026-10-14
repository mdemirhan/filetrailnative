// Port of the toolbar items of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx (title block, view
// switch, search slot, clipboard button, separator) and their rules in styles.css
import AppKit
import FTFoundation

/// One item of the toolbar's row, as a box of its own (`[data-toolbar-slot]`): a button, the title block, the view
/// switch, the search slot. While the toolbar is customized it can be drawn faint (no room for it) or as the dashed
/// place a dragged item would land in.
final class ToolbarSlotView: NSView {
    let slot: TopToolbarSlot
    let content: NSView
    var edges: ToolbarCapsuleEdges? {
        didSet {
            (content as? ToolbarButton)?.onCapsule = edges != nil
            updateIdentifier()
        }
    }
    var faint = false {
        didSet { alphaValue = faint ? 0.35 : 1 }
    }
    /// Where the dragged item would land: its own room, empty, with a dashed accent edge.
    var placeholder = false {
        didSet {
            content.isHidden = placeholder
            needsDisplay = true
        }
    }
    /// An item added with a click flashes where it landed.
    private var flashLayer: CALayer?

    init(slot: TopToolbarSlot, content: NSView) {
        self.slot = slot
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        setAccessibilityElement(false)
        updateIdentifier()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func updateIdentifier() {
        // A separator has no width, and nothing on screen to compare, outside customizing.
        setAccessibilityIdentifier(edges != nil ? "toolbar.capsuleItem" : "toolbar.slot")
        setAccessibilityLabel(slot.key)
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    /// A right-click on an item is left alone (`handleToolbarContextMenu`): only the title offers Customize Toolbar…,
    /// and Back and Forward their history. The » button is not an item: its right-click reaches the toolbar.
    override func rightMouseDown(with event: NSEvent) {
        guard slot.key == TopToolbarRow.overflowKey else { return }
        super.rightMouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard placeholder else { return }
        let accent = ChromeColors.accent(for: self)
        let rect = bounds.insetBy(dx: 1.75, dy: 1.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        ChromeColors.color(accent.solid.withAlpha(0.75)).setStroke()
        path.stroke()
    }

    func flash(duration: Double) {
        flashLayer?.removeFromSuperlayer()
        let accent = ChromeColors.accent(for: self).solid
        let flash = CALayer()
        flash.frame = bounds.insetBy(dx: -1, dy: -1)
        flash.cornerRadius = flash.frame.height / 2
        flash.backgroundColor = ChromeColors.color(accent.withAlpha(0.14)).cgColor
        flash.borderColor = ChromeColors.color(accent.withAlpha(0.55)).cgColor
        flash.borderWidth = 2
        layer?.addSublayer(flash)
        flashLayer = flash
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.45, 1]
        fade.duration = duration / 1000
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        flash.add(fade, forKey: "flash")
    }
}

/// `.titlebar-divider`: nothing while the toolbar is used (a space ends one capsule and starts the next); a 10 × 22
/// dashed slot while it is customized.
final class ToolbarSeparatorView: NSView {
    var customizing = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard customizing else { return }
        let palette = ChromeColors.palette(for: self)
        let height = 22.0
        let rect = NSRect(x: 0.5, y: (bounds.height - height) / 2 + 0.5, width: bounds.width - 1, height: height - 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: DesignTokens.radii.xs, yRadius: DesignTokens.radii.xs)
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        ChromeColors.color(palette.borderStrong).setStroke()
        path.stroke()
    }
}

/// `.toolbar-title-block`: the folder's name in 15 pt semibold, cut short with an ellipsis, its full path as the
/// tooltip. It drags the window, and a right-click on it offers Customize Toolbar….
final class ToolbarTitleView: NSView, TextStyleSource {
    /// The `.toolbar-title` box: its text starts at the block's padding.
    let field = FlushTextField(labelWithString: "")
    var onRightClick: ((NSEvent) -> Void)?
    var isInert = false
    static let lineHeight = 1.2

    var styleTextField: NSTextField? { field }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.font = ChromeColors.font(size: DesignTokens.toolbar.titleFontSize, weight: 600)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setAccessibilityIdentifier("toolbar.title")
        addSubview(field)
        setAccessibilityIdentifier("toolbar.titleBlock")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The block's height: one line of the title.
    static var height: Double { (DesignTokens.toolbar.titleFontSize * lineHeight).rounded() }

    override func layout() {
        super.layout()
        let toolbar = DesignTokens.toolbar
        field.frame = NSRect(
            x: toolbar.titlePaddingLeading, y: 0,
            width: max(0, bounds.width - toolbar.titlePaddingLeading - toolbar.titlePaddingTrailing),
            height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isInert else { return }
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The text is part of the block: a press on it drags the window.
        let hit = super.hitTest(point)
        return hit === field ? self : hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        field.textColor = ChromeColors.color(ChromeColors.palette(for: self).textPrimary)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        field.textColor = ChromeColors.color(ChromeColors.palette(for: self).textPrimary)
    }
}

/// The view switch (`.toolbar-segmented`): three 32 × 24 segments on a round track with 4 pt around them, the selected
/// one raised. Search results are one table: it is disabled in search mode.
final class ToolbarViewSwitch: NSView {
    static let modes: [(ExplorerViewMode, ToolbarIconName, String, ShortcutCommandID)] = [
        (.icons, .icons, "View as Icons", .viewAsIcons), (.details, .details, "View as List", .viewAsDetails),
        (.list, .list, "View as Compact List", .viewAsList),
    ]
    let track = NSView()
    private(set) var segments: [ToolbarSegmentButton] = []
    var onChoose: (ExplorerViewMode) -> Void = { _ in }
    var selected: ExplorerViewMode = .icons {
        didSet { for segment in segments { segment.isSelected = segment.mode == selected } }
    }
    var isEnabled = true {
        // The segments dim, as disabled buttons; the track stays.
        didSet { for segment in segments { segment.isEnabled = isEnabled } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.wantsLayer = true
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.radioGroup)
        track.setAccessibilityLabel("View")
        track.setAccessibilityIdentifier("toolbar.viewSwitch")
        addSubview(track)
        for (mode, icon, label, _) in Self.modes {
            let segment = ToolbarSegmentButton(mode: mode, icon: icon, label: label)
            segment.onClick = { [weak self] in self?.onChoose(mode) }
            segments.append(segment)
            track.addSubview(segment)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The switch with the inset it keeps on each side: 5 + 4 + 3 × 32 + 2 × 4 + 4 + 5.
    static var width: Double {
        let toolbar = DesignTokens.toolbar
        return 2 * toolbar.edgedItemInset + trackWidth
    }

    static var trackWidth: Double {
        let toolbar = DesignTokens.toolbar
        let count = Double(modes.count)
        return 2 * toolbar.segmentedTrackPadding + count * toolbar.segmentWidth
            + (count - 1) * toolbar.segmentedTrackPadding
    }

    func setTooltips(_ shortcuts: ShortcutDisplay) {
        for (index, (_, _, label, command)) in Self.modes.enumerated() {
            segments[index].tooltip = Tooltips.format(label, shortcut: shortcuts.written(command))
        }
    }

    override func layout() {
        super.layout()
        let toolbar = DesignTokens.toolbar
        track.frame = NSRect(x: toolbar.edgedItemInset, y: 0, width: Self.trackWidth, height: bounds.height)
        track.layer?.cornerRadius = bounds.height / 2
        track.layer?.backgroundColor = ChromeColors.color(ChromeColors.palette(for: self).segmentedTrackBg).cgColor
        for (index, segment) in segments.enumerated() {
            segment.frame = NSRect(
                x: toolbar.segmentedTrackPadding + Double(index)
                    * (toolbar.segmentWidth + toolbar.segmentedTrackPadding),
                y: (bounds.height - toolbar.segmentHeight) / 2, width: toolbar.segmentWidth,
                height: toolbar.segmentHeight)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// A segment of the view switch: a toolbar button drawn as the segmented control's segment.
final class ToolbarSegmentButton: ToolbarButton {
    let mode: ExplorerViewMode
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isSelected)
        }
    }

    init(mode: ExplorerViewMode, icon: ToolbarIconName, label: String) {
        self.mode = mode
        super.init(icon: icon, label: label, identifier: "toolbar.viewSwitch.segment")
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // `.toolbar-segmented-native .toolbar-icon`: 15 pt.
        let size = DesignTokens.toolbar.iconSize - 2
        icon.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        if isSelected {
            let radius = bounds.height / 2
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            ChromeColors.color(palette.segmentedSelectedBg).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let color =
            isSelected
            ? palette.segmentedSelectedText
            : isHovered && isEnabled
                ? palette.textPrimary
                : palette.textSecondary
        icon.color = ChromeColors.color(color)
    }
}

/// The clipboard button (`.clipboard-button`): the copy or cut icon and how many items wait to be pasted, in the
/// accent color. Its list is P5-08's.
final class ToolbarClipboardButton: ToolbarButton, TextStyleSource {
    let count = NSTextField(labelWithString: "")
    static let paddingInline = 8.0
    static let gap = 4.0

    var styleTextField: NSTextField? { count }

    init() {
        super.init(icon: .copy, label: "Clipboard", identifier: "toolbar.clipboard")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: DesignTokens.typeScale.small, weight: .semibold)
        count.setAccessibilityIdentifier("toolbar.clipboard.count")
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(count value: Int, cut: Bool) {
        icon.name = cut ? .cut : .copy
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        count.stringValue = formatter.string(from: NSNumber(value: value)) ?? String(value)
        count.isHidden = value == 0
        // With nothing copied it is only a stand-in, drawn while customizing so it can be moved.
        setAccessibilityIdentifier(value == 0 ? "toolbar.clipboard.standIn" : "toolbar.clipboard")
        icon.alphaValue = value == 0 ? DesignTokens.disabledOpacity : 1
    }

    var naturalWidth: Double {
        let iconSize = DesignTokens.toolbar.iconSize
        guard !count.isHidden else { return DesignTokens.toolbar.buttonWidth }
        return (2 * Self.paddingInline + iconSize + Self.gap + count.intrinsicContentSize.width).rounded(.up)
    }

    override func layout() {
        super.layout()
        guard !count.isHidden else { return }
        let iconSize = DesignTokens.toolbar.iconSize
        icon.frame = NSRect(x: Self.paddingInline, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let size = count.intrinsicContentSize
        count.frame = NSRect(
            x: Self.paddingInline + iconSize + Self.gap, y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        count.textColor = ChromeColors.color(ChromeColors.accent(for: self).solidButton)
    }
}

/// `.toolbar-search-slot`: the search field with the inset it keeps on each side.
final class ToolbarSearchSlot: NSView {
    let field = ToolbarSearchField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = DesignTokens.toolbar.edgedItemInset
        field.frame = bounds.insetBy(dx: inset, dy: 0)
    }
}

/// The toolbar's search field (`.toolbar-search`): a round capsule on the search surface, the magnifier with its small
/// chevron (the Search Options button, P5-07), 13 pt text and the placeholder "Search". What it searches is P5-07's.
final class ToolbarSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { ToolbarSearchFieldCell.self }
        set {}
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = ChromeColors.font(size: DesignTokens.typeScale.body)
        placeholderString = "Search"
        sendsSearchStringImmediately = true
        setAccessibilityIdentifier("toolbar.search")
        setAccessibilityLabel("Find files in current folder")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The placeholder's words, also when it is drawn from `placeholderAttributedString`.
    override var placeholderString: String? {
        get { placeholderAttributedString?.string ?? super.placeholderString }
        set { super.placeholderString = newValue }
    }

    func applyColors() {
        let palette = ChromeColors.palette(for: self)
        textColor = ChromeColors.color(palette.searchText)
        placeholderAttributedString = NSAttributedString(
            string: "Search",
            attributes: [
                .font: ChromeColors.font(size: DesignTokens.typeScale.body),
                .foregroundColor: ChromeColors.color(palette.textPlaceholder),
            ])
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }
}

final class ToolbarSearchFieldCell: NSSearchFieldCell {
    /// `.window-toolbar .toolbar-search-row`: 8 pt in from the 1 pt border; the options button (the magnifier, 1 pt
    /// gap, 8 pt chevron, 3 pt padding, −3 pt margins) then a 6 pt gap before the text.
    static let leading = 1 + 8 + (iconSize + 1 + 8) + 6.0
    static let trailing = 1 + 8.0
    /// `.window-toolbar .toolbar-icon` comes after `.toolbar-search-icon .toolbar-icon` in the stylesheet, so the
    /// magnifier is a toolbar icon: 17 pt, stroke 1.7 (not the 13 pt, 2.4 its own rule asks for).
    static var iconSize: Double { DesignTokens.toolbar.iconSize }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let height = (font?.boundingRectForFont.height ?? 16).rounded(.up)
        // The field draws its text 2 pt inside this rect: it starts that much sooner, so the text starts at `leading`.
        let inset = FlushTextFieldCell.inset
        return NSRect(
            x: rect.minX + Self.leading - inset, y: rect.midY - height / 2,
            width: max(0, rect.width - Self.leading - Self.trailing - 16 + 2 * inset), height: height)
    }

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { .zero }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let size = 16.0
        return NSRect(x: rect.maxX - Self.trailing - size, y: rect.midY - size / 2, width: size, height: size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let palette = ChromeColors.palette(for: controlView)
        let radius = cellFrame.height / 2
        ChromeColors.color(palette.searchSurface).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
        if controlView.window?.firstResponder === (controlView as? NSTextField)?.currentEditor() {
            let accent = ChromeColors.accent(for: controlView)
            let ring = NSBezierPath(
                roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
            ring.lineWidth = 1
            ChromeColors.color(accent.solid.withAlpha(0.7)).setStroke()
            ring.stroke()
        }
        // The Search Options button: the magnifier and its chevron.
        let iconColor = ChromeColors.color(palette.searchIcon)
        let flipped = controlView.isFlipped
        let iconSize = Self.iconSize
        let x = cellFrame.minX + 1 + 8
        let iconRect = NSRect(x: x, y: cellFrame.midY - iconSize / 2, width: iconSize, height: iconSize)
        ToolbarGlyph.draw(
            .search, in: iconRect, strokeWidth: DesignTokens.toolbar.iconStrokeWidth, color: iconColor,
            flipped: flipped)
        let chevron = NSRect(x: iconRect.maxX + 1, y: cellFrame.midY - 4, width: 8, height: 8)
        let path = SVGPath.path("M2 3l2 2 2-2")
        var transform = AffineTransform(translationByX: chevron.minX, byY: flipped ? chevron.minY : chevron.maxY)
        transform.scale(x: 1, y: flipped ? 1 : -1)
        path.transform(using: transform)
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        iconColor.setStroke()
        path.stroke()
        drawInterior(withFrame: cellFrame, in: controlView)
    }
}
