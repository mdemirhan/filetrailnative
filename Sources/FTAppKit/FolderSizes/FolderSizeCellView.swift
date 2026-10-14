// Port of FolderSizeCell (components/GetInfoPanel.tsx) and InfoRowFolderSize (components/InfoRow.tsx), with the
// .folder-size-* rules of styles.css:3340-3430 and 6263-6275
import AppKit
import FTFoundation

/// Text that acts as a link: the accent color, underlined under the pointer.
final class TextLinkView: NSView {
    let label = FlushTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var color: (Theme) -> RGBA = { $0.accent.solid } {
        didSet { applyStyle() }
    }
    var underlinesOnHover = true
    private var isHovered = false { didSet { applyStyle() } }

    init(identifier: String) {
        super.init(frame: .zero)
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    var font: NSFont = ThemeFonts.sans(DesignTokens.typeScale.callout) { didSet { applyStyle() } }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            applyStyle()
        }
    }

    var naturalWidth: Double { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    var naturalHeight: Double { ceil(font.ascender - font.descender + font.leading) }

    func applyStyle() {
        let theme = AppearanceModel.shared.theme
        let ink = NSColor(color(theme))
        label.font = font
        label.textColor = ink
        if isHovered && underlinesOnHover {
            label.attributedStringValue = NSAttributedString(
                string: label.stringValue,
                attributes: [
                    .font: font, .foregroundColor: ink, .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
        } else {
            label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [.font: font, .foregroundColor: ink])
        }
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

/// The folder size as the Info panel and the Info Row show it: Calculate, then a spinner and Stop, then the size over
/// the counts (one line in the row) with a refresh button.
final class FolderSizeCellView: NSView {
    enum Style { case panel, row }

    let style: Style
    private(set) var entry = FolderSizeEntry.idle
    var onCalculate: () -> Void = {}
    var onRecalculate: () -> Void = {}
    var onCancel: () -> Void = {}

    private let calculate: TextLinkView
    private let sizeLine = FlushTextField(labelWithString: "")
    private let itemsLine = FlushTextField(labelWithString: "")
    private let refresh: InfoIconButton
    private let spinner = InfoSpinnerView()
    private let stop = ClearButton()
    private let delay = DelayedFlag()

    /// `.folder-size-value`/`.folder-size-calculating`: a 6 pt gap.
    static let gap = 6.0
    static let refreshSize = 11.0

    init(style: Style, identifier: String) {
        self.style = style
        calculate = TextLinkView(identifier: identifier + ".calculate")
        refresh = InfoIconButton(
            glyph: .refresh, iconSize: Self.refreshSize, strokeWidth: 2, cornerRadius: 0,
            identifier: identifier + ".refresh", label: "Recalculate folder size")
        super.init(frame: .zero)
        setAccessibilityIdentifier(identifier)
        calculate.text = style == .panel ? "Calculate" : "Calculate size"
        calculate.font = ThemeFonts.sans(DesignTokens.typeScale.callout, style == .panel ? .semibold : .regular)
        for field in [sizeLine, itemsLine] {
            field.lineBreakMode = .byTruncatingTail
            field.alignment = style == .panel ? .right : .left
        }
        sizeLine.font = ThemeFonts.sans(DesignTokens.typeScale.callout)
        itemsLine.font = ThemeFonts.sans(DesignTokens.typeScale.small)
        sizeLine.setAccessibilityIdentifier(identifier + ".size")
        itemsLine.setAccessibilityIdentifier(identifier + ".items")
        refresh.tooltip = "Calculate Size Again"
        refresh.normalColor = { $0.palette.textDim }
        refresh.hoverColor = { $0.accent.solid }
        refresh.onClick = { [weak self] in self?.onRecalculate() }
        calculate.onClick = { [weak self] in self?.onCalculate() }
        stop.toolTip = "Stop Calculating"
        stop.setAccessibilityLabel("Cancel folder size calculation")
        stop.setAccessibilityIdentifier(identifier + ".stop")
        stop.target = self
        stop.action = #selector(stopPressed)
        for view in [calculate, sizeLine, itemsLine, refresh, spinner, stop] as [NSView] { addSubview(view) }
        delay.onChange = { [weak self] in
            self?.relayout()
            self?.onSizeChange?()
        }
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// Told when the cell's natural size changes, so its owner lays it out again.
    var onSizeChange: (() -> Void)?

    @objc private func stopPressed() { onCancel() }

    func update(_ next: FolderSizeEntry) {
        guard next != entry else { return }
        entry = next
        apply()
        onSizeChange?()
    }

    private func apply() {
        var calculating = false
        if case .calculating = entry { calculating = true }
        delay.update(active: calculating, delay: InfoMetrics.calculatingDelay)
        switch entry {
        case .ready(let size, let disk, let files, let folders):
            let lines = InfoPanelModel.folderSizeLines(sizeBytes: size, diskBytes: disk, fileCount: files, folderCount: folders)
            if style == .panel {
                sizeLine.stringValue = lines.top
                itemsLine.stringValue = lines.items
            } else {
                sizeLine.stringValue = "\(lines.top) · \(lines.items)"
            }
        default: break
        }
        relayout()
    }

    private var lineHeight: (size: Double, items: Double) {
        func height(_ font: NSFont?) -> Double { ceil(((font?.ascender ?? 0) - (font?.descender ?? 0)) + (font?.leading ?? 0)) }
        return (height(sizeLine.font), height(itemsLine.font))
    }

    private func width(_ field: NSTextField) -> Double {
        ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font as Any]).width)
    }

    /// The size the cell takes now.
    var naturalSize: NSSize {
        switch entry {
        case .idle, .error:
            return NSSize(width: calculate.naturalWidth, height: calculate.naturalHeight)
        case .calculating:
            guard delay.value else { return NSSize(width: 0, height: 0) }
            return NSSize(width: 12 + Self.gap + ClearButton.size, height: ClearButton.size)
        case .ready:
            let heights = lineHeight
            if style == .panel {
                let text = max(width(sizeLine), width(itemsLine))
                return NSSize(width: text + Self.gap + Self.refreshSize, height: heights.size + 1 + heights.items)
            }
            return NSSize(width: width(sizeLine) + Self.gap + Self.refreshSize, height: heights.size)
        }
    }

    private func relayout() {
        needsLayout = true
        applyColors()
    }

    private func applyColors() {
        let theme = AppearanceModel.shared.theme
        sizeLine.textColor = NSColor(style == .panel ? theme.palette.textPrimary : theme.palette.textSecondary)
        itemsLine.textColor = NSColor(theme.palette.textSecondary)
    }

    override func layout() {
        super.layout()
        let hideAll = [calculate, sizeLine, itemsLine, refresh, spinner, stop] as [NSView]
        for view in hideAll { view.isHidden = true }
        switch entry {
        case .idle, .error:
            calculate.isHidden = false
            calculate.frame = NSRect(x: 0, y: (bounds.height - calculate.naturalHeight) / 2, width: bounds.width, height: calculate.naturalHeight)
        case .calculating:
            guard delay.value else { return }
            spinner.isHidden = false
            stop.isHidden = false
            spinner.frame = NSRect(x: 0, y: (bounds.height - 12) / 2, width: 12, height: 12)
            stop.frame = NSRect(
                x: 12 + Self.gap, y: (bounds.height - ClearButton.size) / 2, width: ClearButton.size, height: ClearButton.size)
        case .ready:
            sizeLine.isHidden = false
            refresh.isHidden = false
            refresh.frame = NSRect(
                x: bounds.width - Self.refreshSize, y: (bounds.height - Self.refreshSize) / 2, width: Self.refreshSize,
                height: Self.refreshSize)
            let textWidth = max(0, bounds.width - Self.refreshSize - Self.gap)
            let heights = lineHeight
            if style == .panel {
                itemsLine.isHidden = false
                sizeLine.frame = NSRect(x: 0, y: 0, width: textWidth, height: heights.size)
                itemsLine.frame = NSRect(x: 0, y: heights.size + 1, width: textWidth, height: heights.items)
            } else {
                sizeLine.frame = NSRect(x: 0, y: (bounds.height - heights.size) / 2, width: textWidth, height: heights.size)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if case .calculating = entry, !delay.value { return nil }
        return super.hitTest(point)
    }
}
