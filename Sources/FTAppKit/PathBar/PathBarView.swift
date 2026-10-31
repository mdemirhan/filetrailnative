// Port of the <nav class="pathbar"> of apps/desktop/src/renderer/components/ContentPane.tsx (:760-848) with the .pathbar rules
// of styles.css:2032-2185 and 4387-4422
import AppKit
import FTFoundation

/// A segment of the path bar (or the "…" that stands for hidden folders): 20 tall, padding 0 6, the label cut with an ellipsis.
final class PathSegmentView: NSView, TextStyleSource {
    let label = TextBoxField(labelWithString: "")
    var path = ""
    var isActive = false { didSet { applyColors() } }
    var isDisabled = false
    var onClick: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var isHovered = false { didSet { applyColors() } }

    var styleTextField: NSTextField? { label }

    static var font: NSFont { ChromeColors.font(size: DesignTokens.typeScale.small) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("pathBar.segment.label")
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("pathBar.segment")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(label text: String, path: String, tooltip: String, active: Bool) {
        label.stringValue = text
        self.path = path
        toolTip = tooltip
        isActive = active
        setAccessibilityLabel(text)
        isDisabled = path.isEmpty
        applyColors()
    }

    /// The width the segment wants, as the collapse rules measure it: its text, rounded up, and 6 each side.
    static func width(of text: String) -> Double {
        ceil(textExtent(text, font)) + 2 * InfoMetrics.segmentPaddingInline
    }

    /// The width it has in the bar: the text to a fraction and 6 each side.
    static func exactWidth(of text: String) -> Double {
        textExtent(text, font) + 2 * InfoMetrics.segmentPaddingInline
    }

    override func layout() {
        super.layout()
        applyColors()
        let height = lineBox(Self.font)
        label.frame = NSRect(
            x: InfoMetrics.segmentPaddingInline, y: (bounds.height - height) / 2,
            width: max(0, bounds.width - 2 * InfoMetrics.segmentPaddingInline), height: height)
    }

    func applyColors() {
        let theme = infoTheme
        if isHovered && !isDisabled {
            // `color-mix(in srgb, var(--ft-accent-solid) 42%, var(--text-primary))`.
            label.textColor = NSColor(mixColor(theme.accent.solid, 42, with: theme.palette.textPrimary))
        } else {
            label.textColor = NSColor(isActive ? theme.palette.textPrimary : theme.palette.textSecondary)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered, !isDisabled else { return }
        NSColor(infoTheme.palette.bgHover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control)
            .fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick, let event = NSApp.currentEvent else { return false }
        onClick(event)
        return true
    }
}

/// The `›` between segments: a 16 wide button that opens the folder menu, or plain text before the "…".
final class PathSeparatorView: NSView, TextStyleSource {
    let label = TextBoxField(labelWithString: "›")
    let isButton: Bool
    var onClick: (() -> Void)?
    private(set) var isActive = false { didSet { applyColors() } }
    private var isHovered = false { didSet { applyColors() } }

    var styleTextField: NSTextField? { label }

    init(isButton: Bool) {
        self.isButton = isButton
        super.init(frame: .zero)
        label.font = ChromeColors.font(size: DesignTokens.typeScale.callout)
        label.alignment = .center
        addSubview(label)
        if isButton {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityIdentifier("pathBar.separator")
        } else {
            setAccessibilityIdentifier("pathBar.separatorPlain")
        }
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setMenuOpen(_ open: Bool) { isActive = open }

    static var width: Double {
        let glyph = textExtent("›", ChromeColors.font(size: DesignTokens.typeScale.callout))
        return max(InfoMetrics.separatorMinWidth, glyph + 6)
    }

    override func layout() {
        super.layout()
        applyColors()
        let font = label.font ?? .systemFont(ofSize: 12)
        let height = lineBox(font)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    func applyColors() {
        let palette = infoTheme.palette
        let on = isButton && (isHovered || isActive)
        label.textColor = NSColor(on ? palette.textPrimary : palette.textSecondary)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isButton, isHovered || isActive else { return }
        NSColor(infoTheme.palette.bgHover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: DesignTokens.radii.control, yRadius: DesignTokens.radii.control)
            .fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isButton, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isButton else { return false }
        onClick?()
        return true
    }
}

/// The bar of segments: the path from the top of the disk, collapsing its middle behind "…" when the row is narrow.
final class PathBarView: NSView {
    var segments: [PathbarSegment] = [] {
        didSet {
            guard segments != oldValue else { return }
            needsLayout = true
            rebuild = true
        }
    }
    private(set) var expanded = false
    private var rebuild = true
    private var items: [PathBarItem] = []
    private var itemViews: [NSView] = []
    private var scrollOffset = 0.0
    private var scrollToEnd = false
    private let clip = InfoFlippedView()

    var onNavigate: (String) -> Void = { _ in }
    var onOpenInNewTab: (String) -> Void = { _ in }
    var onEdit: () -> Void = {}
    /// The separator was pressed: its parent folder, the folder the path goes through, and the button.
    var onSeparator: (_ parent: String, _ active: PathbarSegment, _ button: PathSeparatorView) -> Void = { _, _, _ in }
    var hasFolderMenus = true
    var onPress: () -> Void = {}
    var onExpandedChange: (Bool) -> Void = { _ in }
    private var clickTimer: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        setAccessibilityIdentifier("pathBar")
        setAccessibilityRole(.list)
        setAccessibilityLabel("Folder path")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        scrollToEnd = value
        scrollOffset = 0
        rebuild = true
        needsLayout = true
        onExpandedChange(value)
    }

    func cancelPendingClick() {
        clickTimer?.cancel()
        clickTimer = nil
    }

    private func measure(_ label: String, _ isActive: Bool, _ collapsed: Bool, _ uncapped: Bool) -> Double {
        let natural = PathSegmentView.width(of: label)
        if collapsed || uncapped { return natural }
        return min(natural, isActive ? InfoMetrics.activeSegmentMaxWidth : InfoMetrics.segmentMaxWidth)
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        let resolved = PathBarModel.resolve(
            segments, availableWidth: bounds.width, expanded: expanded, measure: { [self] in measure($0, $1, $2, $3) })
        if resolved != items || rebuild {
            items = resolved
            rebuild = false
            rebuildViews()
        }
        place()
    }

    private func rebuildViews() {
        for view in itemViews { view.removeFromSuperview() }
        itemViews = []
        for (index, item) in items.enumerated() {
            if index > 0 {
                var parentSegment: PathbarSegment?
                if case .segment(let segment, _, _) = item, hasFolderMenus { parentSegment = segment }
                let separator = PathSeparatorView(isButton: parentSegment != nil)
                if let segment = parentSegment {
                    let parent = PathBarModel.parentPath(segment.path)
                    let label = "Folders in \(PathBarModel.label(parent))"
                    separator.setAccessibilityLabel(label)
                    separator.toolTip = label
                    separator.onClick = { [weak self, weak separator] in
                        guard let self, let separator else { return }
                        self.onSeparator(parent, segment, separator)
                    }
                }
                clip.addSubview(separator)
                itemViews.append(separator)
            }
            let view = PathSegmentView()
            switch item {
            case .segment(let segment, let isActive, _):
                view.configure(
                    label: segment.label, path: segment.path,
                    tooltip: segment.path.isEmpty ? segment.label : segment.path,
                    active: isActive)
                view.onClick = { [weak self] event in self?.segmentClicked(segment, event) }
                view.onDoubleClick = { [weak self] in self?.segmentDoubleClicked() }
            case .collapsed(let hidden):
                let title = PathBarModel.showHiddenLabel(hidden)
                view.configure(label: "…", path: "", tooltip: title, active: false)
                view.isDisabled = false
                view.setAccessibilityLabel(title)
                view.onClick = { [weak self] _ in self?.setExpanded(true) }
            }
            clip.addSubview(view)
            itemViews.append(view)
        }
    }

    private func place() {
        let segmentTop = (bounds.height - InfoMetrics.segmentHeight) / 2
        let separatorTop = (bounds.height - InfoMetrics.separatorHeight) / 2
        var x = 0.0
        var views = itemViews[...]
        var contentWidth = 0.0
        // The widths: natural; cut proportionally when the bar is too narrow (the flex items shrink).
        var natural: [Double] = []
        for item in items {
            switch item {
            case .collapsed: natural.append(PathSegmentView.exactWidth(of: "…"))
            case .segment(let segment, let isActive, let maxWidth):
                let cap = isActive ? InfoMetrics.activeSegmentMaxWidth : InfoMetrics.segmentMaxWidth
                natural.append(maxWidth ?? min(PathSegmentView.exactWidth(of: segment.label), cap))
            }
        }
        let separators = Double(max(0, items.count - 1)) * (PathSeparatorView.width + 2 * InfoMetrics.itemGap)
        let total = natural.reduce(0, +) + separators + 0
        let overflow = total - bounds.width
        // Each item (its separator and its segment) shrinks in proportion to its size; the segment gives way.
        let basis = natural.enumerated().map {
            $0.element + ($0.offset > 0 ? PathSeparatorView.width + InfoMetrics.itemGap : 0)
        }
        let shrinkBase = basis.reduce(0, +)
        for index in items.indices {
            if index > 0, let separator = views.popFirst() {
                separator.frame = NSRect(
                    x: x, y: separatorTop, width: PathSeparatorView.width, height: InfoMetrics.separatorHeight)
                x += PathSeparatorView.width + InfoMetrics.itemGap
            }
            guard let view = views.popFirst() else { break }
            var width = natural[index]
            if overflow > 0, shrinkBase > 0 { width = max(0, width - overflow * basis[index] / shrinkBase) }
            view.frame = NSRect(x: x, y: segmentTop, width: width, height: InfoMetrics.segmentHeight)
            x += width + InfoMetrics.itemGap
        }
        contentWidth = max(0, x - InfoMetrics.itemGap)
        if expanded {
            let maxOffset = max(0, contentWidth - bounds.width)
            if scrollToEnd {
                scrollOffset = maxOffset
                scrollToEnd = false
            }
            scrollOffset = min(scrollOffset, maxOffset)
            for view in itemViews { view.frame.origin.x -= scrollOffset }
        }
    }

    // MARK: Pointer

    private func segmentClicked(_ segment: PathbarSegment, _ event: NSEvent) {
        guard !segment.path.isEmpty else { return }
        if event.modifierFlags.contains(.command) {
            onOpenInNewTab(segment.path)
            return
        }
        cancelPendingClick()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clickTimer = nil
                self.setExpanded(false)
                self.onNavigate(segment.path)
            }
        }
        clickTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.segmentClickDelay, execute: work)
    }

    private func segmentDoubleClicked() {
        cancelPendingClick()
        setExpanded(false)
        onEdit()
    }

    override func mouseDown(with event: NSEvent) {
        onPress()
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            setExpanded(false)
            onEdit()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard expanded else { return super.scrollWheel(with: event) }
        let delta =
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset = max(0, scrollOffset - delta)
        needsLayout = true
    }

    /// The pointer is in the bar or in a separator's folder menu, which belongs to it.
    func contains(windowPoint: NSPoint) -> Bool {
        bounds.contains(convert(windowPoint, from: nil))
    }
}
