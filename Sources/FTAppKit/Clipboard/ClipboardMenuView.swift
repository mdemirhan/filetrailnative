// Port of the menu of apps/desktop/src/renderer/components/ClipboardButton.tsx and its rules in styles.css (7504-7690):
// the clipboard's list under its button, in a system popover (D-022), with the count, the hint, the items under their
// folders, and Clear Clipboard
import AppKit
import FTFileSystem
import FTFoundation

/// The content of `.toolbar-menu.clipboard-menu`: the header, the breakdown, the list of ten 24 pt rows (virtualized, the
/// top folder heading pinned over it, a scrollbar of its own while it scrolls), and Clear Clipboard. The system's popover
/// draws what is behind it. The keyboard never goes into it: the keys come to it through the window while it is open.
final class ClipboardMenuView: NSView {
    private(set) var model: ClipboardMenuModel
    private(set) var summary: FTFoundation.ClipboardSummary
    var pasteHint: String

    var onReveal: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onClear: () -> Void = {}
    var iconStore: FileIconStore?

    private let title = ClipboardMenuText(identifier: "clipboardPopover.title")
    private let hint = ClipboardMenuText(identifier: "clipboardPopover.hint")
    private let breakdown = ClipboardMenuText(identifier: "clipboardPopover.breakdown")
    private let list = ClipboardMenuList()
    private let pinned = ClipboardMenuHeadingRow(pinned: true)
    private let clear = ClipboardMenuClearRow()
    private var rowViews: [Int: NSView] = [:]

    private static var padding: Double { DesignTokens.menu.padding }
    private static var border: Double { DesignTokens.menu.borderWidth }

    init(summary: FTFoundation.ClipboardSummary, pasteHint: String) {
        self.summary = summary
        self.pasteHint = pasteHint
        model = ClipboardMenuModel(items: summary.items)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Clipboard")
        setAccessibilityIdentifier("clipboardPopover")
        for view in [title, hint, breakdown, list, pinned, clear] as [NSView] { addSubview(view) }
        list.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        pinned.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        clear.onHover = { [weak self] in self?.setActive(self?.model.clearIndex ?? -1) }
        clear.onClick = { [weak self] in self?.onClear() }
        model.opened()
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Contents

    /// The clipboard changed while the menu is open: the active row keeps its place.
    func update(_ summary: FTFoundation.ClipboardSummary) {
        self.summary = summary
        model.setItems(summary.items)
        let height = model.contentHeight - model.listHeight
        model.scrollTop = max(0, min(model.scrollTop, height))
        apply()
    }

    private func apply() {
        let theme = AppearanceModel.shared.theme
        let palette = theme.palette
        title.set(summary.countLabel, font: ChromeColors.font(size: DesignTokens.typeScale.body, weight: 600))
        title.textColor = NSColor(palette.contextMenuText)
        hint.set(pasteHint, font: ChromeColors.font(size: DesignTokens.typeScale.small))
        hint.textColor = NSColor(palette.contextMenuShortcut)
        breakdown.isHidden = summary.breakdown == nil
        breakdown.set(summary.breakdown ?? "", font: ChromeColors.font(size: DesignTokens.typeScale.small))
        breakdown.textColor = NSColor(palette.contextMenuShortcut)
        clear.isActive = model.activeIndex == model.clearIndex
        clear.applyTheme(theme)
        needsLayout = true
        layoutSubtreeIfNeeded()
        drawRows()
    }

    /// The menu's size: as wide as its contents, 260 to 420 (and 16 less than the window), the list at most ten rows.
    func fittingSize(viewportWidth: Double) -> NSSize {
        let layout = ClipboardLayout.Menu.self
        var content = layout.headerPaddingHorizontal * 2 + title.textWidth + layout.headerGap + hint.textWidth
        if !breakdown.isHidden { content = max(content, layout.headerPaddingHorizontal * 2 + breakdown.textWidth) }
        let font = ChromeColors.font(size: DesignTokens.typeScale.body)
        for item in summary.items {
            let name = ceil((item.name as NSString).size(withAttributes: [.font: font]).width)
            content = max(
                content,
                layout.itemPaddingLeading + layout.itemIconSize + layout.itemIconGap + name + layout.removeSize
                    + layout.itemPaddingTrailing + (model.scrolls ? layout.scrollbarWidth : 0))
        }
        content = max(content, clear.naturalWidth)
        let maxWidth = min(layout.maxWidth, viewportWidth - layout.viewportInset)
        let width = max(layout.minWidth, min(maxWidth, content + 2 * Self.padding + 2 * Self.border))
        return NSSize(width: width, height: totalHeight)
    }

    private var headerHeight: Double {
        let layout = ClipboardLayout.Menu.self
        var height = 2 * layout.headerPaddingVertical + title.lineHeight
        if !breakdown.isHidden { height += breakdown.lineHeight + layout.breakdownPaddingBottom }
        return height
    }

    private var separatorHeight: Double {
        DesignTokens.menu.separatorHeight + 2 * DesignTokens.menu.separatorMarginVertical
    }

    private var totalHeight: Double {
        2 * Self.padding + 2 * Self.border + headerHeight + 2 * separatorHeight + model.listHeight
            + DesignTokens.menu.rowHeight
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let layout = ClipboardLayout.Menu.self
        let inset = Self.padding + Self.border
        let width = bounds.width - 2 * inset
        var y = inset + layout.headerPaddingVertical
        let line = title.lineHeight
        // `align-items: baseline`: the smaller hint sits on the title's baseline.
        let hintY = y + title.ascent - hint.ascent
        let hintWidth = min(hint.textWidth, width - 2 * layout.headerPaddingHorizontal)
        hint.frame = NSRect(
            x: inset + width - layout.headerPaddingHorizontal - hintWidth, y: hintY, width: hintWidth,
            height: hint.lineHeight)
        let titleWidth = max(
            0, min(title.textWidth, hint.frame.minX - layout.headerGap - inset - layout.headerPaddingHorizontal))
        title.frame = NSRect(
            x: inset + layout.headerPaddingHorizontal, y: y, width: titleWidth, height: title.lineHeight)
        y += line + layout.headerPaddingVertical
        if !breakdown.isHidden {
            // The box is the whole row's, its padding inside (`padding: 0 10px 4px`), as the original's element is.
            breakdown.leadingInset = layout.headerPaddingHorizontal
            breakdown.frame = NSRect(
                x: inset, y: y, width: width, height: breakdown.lineHeight + layout.breakdownPaddingBottom)
            y += breakdown.lineHeight + layout.breakdownPaddingBottom
        }
        y += separatorHeight
        list.frame = NSRect(x: inset, y: y, width: width, height: model.listHeight)
        list.scrolls = model.scrolls
        let pinnedWidth = width - (model.scrolls ? layout.scrollbarWidth : 0)
        pinned.frame = NSRect(x: inset, y: y, width: pinnedWidth, height: layout.rowHeight)
        y += model.listHeight + separatorHeight
        clear.frame = NSRect(x: inset, y: y, width: width, height: DesignTokens.menu.rowHeight)
        drawRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = ChromeColors.palette(for: self)
        let inset = Self.padding + Self.border
        let margin = DesignTokens.menu.separatorMarginHorizontal
        NSColor(palette.contextMenuSeparator).setFill()
        for y in [list.frame.minY - separatorHeight, list.frame.maxY] {
            NSRect(
                x: inset + margin, y: y + DesignTokens.menu.separatorMarginVertical,
                width: bounds.width - 2 * inset - 2 * margin, height: DesignTokens.menu.separatorHeight
            ).fill()
        }
    }

    /// The rows in view and four on each side; the others aren't drawn.
    private func drawRows() {
        let drawn = model.drawnRows
        let height = ClipboardLayout.Menu.rowHeight
        // The popover's glass shows through the pinned heading: the rows stop under it rather than passing behind.
        let hiddenTop = model.pinnedHeading == nil ? 0 : height
        list.hiddenTop = hiddenTop
        let width = list.bounds.width - (model.scrolls ? ClipboardLayout.Menu.scrollbarWidth : 0)
        for (index, view) in rowViews where !drawn.contains(index) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: index)
        }
        for index in drawn {
            let row = model.rows[index]
            // A view kept for a place in the list may have shown another row (an item removed shifts the rest): it is
            // set again for the row there now, its buttons acting on that row's item, as the original's keyed rows do.
            var view = rowViews[index]
            if let kept = view, !Self.fits(kept, row) {
                kept.removeFromSuperview()
                view = nil
            }
            let shown = view ?? makeRow(row)
            if view == nil {
                list.content.addSubview(shown)
                rowViews[index] = shown
            }
            bind(shown, to: row)
            shown.frame = NSRect(
                x: 0, y: Double(index) * height - model.scrollTop - hiddenTop, width: width, height: height)
        }
        if let heading = model.pinnedHeading {
            pinned.isHidden = false
            pinned.set(heading.label, path: heading.parentPath)
        } else {
            pinned.isHidden = true
        }
        list.scrollTop = model.scrollTop
        list.contentHeight = model.contentHeight
        list.needsDisplay = true
        clear.isActive = model.activeIndex == model.clearIndex
    }

    private func makeRow(_ row: ClipboardMenuRow) -> NSView {
        switch row {
        case .heading: ClipboardMenuHeadingRow(pinned: false)
        case .item: ClipboardMenuItemRow()
        }
    }

    private static func fits(_ view: NSView, _ row: ClipboardMenuRow) -> Bool {
        switch row {
        case .heading: view is ClipboardMenuHeadingRow
        case .item: view is ClipboardMenuItemRow
        }
    }

    /// Shows `row` in `view`: a heading's folder, or an item with its hover, click and × for that item.
    private func bind(_ view: NSView, to row: ClipboardMenuRow) {
        switch row {
        case .heading(let label, let parentPath):
            (view as? ClipboardMenuHeadingRow)?.set(label, path: parentPath)
        case .item(let item, let itemIndex):
            guard let view = view as? ClipboardMenuItemRow else { return }
            view.onHover = { [weak self] in self?.setActive(itemIndex) }
            view.onReveal = { [weak self] in self?.onReveal(item.path) }
            view.onRemove = { [weak self] in self?.onRemove(item.path) }
            view.configure(item, active: itemIndex == model.activeIndex, iconStore: iconStore)
        }
    }

    // MARK: Pointer and keys

    /// The pointer makes a row active; it never scrolls the list.
    private func setActive(_ index: Int) {
        guard model.activeIndex != index else { return }
        model.activeIndex = index
        drawRows()
    }

    private func scroll(by delta: Double) {
        let limit = max(0, model.contentHeight - model.listHeight)
        let next = max(0, min(limit, model.scrollTop + delta))
        guard next != model.scrollTop else { return }
        model.scrollTop = next
        drawRows()
    }

    /// A key while the menu is open.
    func key(_ event: NSEvent) -> ClipboardMenuKeyResult {
        let flags = event.modifierFlags
        let key: ClipboardMenuKey =
            switch Int(event.keyCode) {
            case 53: .escape
            case 48: .tab
            case 125: .down
            case 126: .up
            case 115: .home
            case 119: .end
            case 36, 76: .enter
            case 49: .space
            case 51: .backspace
            case 117: .delete
            default: .other
            }
        let result = model.key(
            key, command: flags.contains(.command), control: flags.contains(.control), option: flags.contains(.option))
        drawRows()
        return result
    }

    #if DEBUG
        var modelForTests: ClipboardMenuModel { model }
    #endif
}

/// A text of the menu, laid out by hand.
final class ClipboardMenuText: NSTextField {
    // No inset: a frame as wide as the measured text shows all of it, from the frame's edge.
    override class var cellClass: AnyClass? {
        get { ThemedTextCell.self }
        set {}
    }

    init(identifier: String) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ text: String, font: NSFont) {
        stringValue = text
        self.font = font
    }

    var textWidth: Double {
        guard let font else { return 0 }
        return ceil((stringValue as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Space before the text inside the frame.
    var leadingInset: Double = 0 {
        didSet { (cell as? ThemedTextCell)?.leadingInset = leadingInset }
    }

    /// The whole points above the baseline, as the page lays the line out (12 at 13 pt, 10 at 11 pt).
    var ascent: Double {
        guard let font else { return 0 }
        return Double(font.ascender.rounded(.down))
    }

    /// `line-height: normal` as the page has it: 15 at 13 pt, 13 at 11 pt.
    var lineHeight: Double {
        guard let font else { return 0 }
        return Double((font.ascender - font.descender + font.leading).rounded())
    }
}

/// The list's window onto its rows, and its scrollbar (always there while the list scrolls).
final class ClipboardMenuList: NSView {
    /// The rows, placed from the top down as the menu's own views are.
    private final class Content: NSView {
        override var isFlipped: Bool { true }
    }

    let content: NSView = Content()
    var onScroll: (Double) -> Void = { _ in }
    var scrolls = false
    var scrollTop = 0.0
    var contentHeight = 0.0
    /// How much of its top the rows leave to the pinned heading.
    var hiddenTop = 0.0 {
        didSet { needsLayout = hiddenTop != oldValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(content)
        setAccessibilityIdentifier("clipboardPopover.list")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: 0, y: hiddenTop, width: bounds.width, height: max(0, bounds.height - hiddenTop))
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll(-Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard scrolls, contentHeight > bounds.height else { return }
        let layout = ClipboardLayout.Menu.self
        let palette = ChromeColors.palette(for: self)
        let track = NSRect(
            x: bounds.width - layout.scrollbarWidth, y: 0, width: layout.scrollbarWidth, height: bounds.height)
        let thumbHeight = max(layout.scrollbarWidth * 2, bounds.height * bounds.height / contentHeight)
        let travel = bounds.height - thumbHeight
        let offset = travel * scrollTop / max(1, contentHeight - bounds.height)
        let thumb = NSRect(x: track.minX, y: offset, width: track.width, height: thumbHeight)
            .insetBy(dx: layout.scrollbarThumbInset, dy: layout.scrollbarThumbInset)
        NSColor(palette.contextMenuText.withAlpha(palette.contextMenuText.alpha * layout.scrollbarThumbAlpha)).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: thumb.width / 2, yRadius: thumb.width / 2).fill()
    }
}

/// A folder heading of the list (`.toolbar-menu-heading.clipboard-menu-heading`), or the one pinned over its top.
final class ClipboardMenuHeadingRow: NSView {
    private let label = ClipboardMenuText(identifier: "clipboardPopover.heading.label")
    private let isPinned: Bool
    var onScroll: (Double) -> Void = { _ in }

    init(pinned: Bool) {
        isPinned = pinned
        super.init(frame: .zero)
        addSubview(label)
        setAccessibilityIdentifier(pinned ? "clipboardPopover.pinnedHeading" : "clipboardPopover.heading")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func set(_ text: String, path: String) {
        let palette = ChromeColors.palette(for: self)
        label.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600))
        label.textColor = NSColor(palette.contextMenuShortcut)
        toolTip = path
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = ClipboardLayout.Menu.headingPaddingHorizontal
        label.frame = NSRect(
            x: inset, y: (bounds.height - label.lineHeight) / 2, width: max(0, bounds.width - 2 * inset),
            height: label.lineHeight)
    }

    /// The pinned heading takes the pointer itself, and hands the wheel to the list.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isPinned && !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        onScroll(-Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 10))
    }
}

/// An item of the list: its icon and name (a click shows it in its folder), and the × that takes it off the clipboard,
/// shown on the active row.
final class ClipboardMenuItemRow: NSView {
    private let icon = NSImageView()
    private let name = ClipboardMenuText(identifier: "clipboardPopover.item.name")
    private let remove = ClipboardMenuRemoveButton()
    private var isActive = false
    private var tracking: NSTrackingArea?
    private var iconRequest: LoadHandle?
    var onHover: () -> Void = {}
    var onReveal: () -> Void = {}
    var onRemove: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(name)
        addSubview(remove)
        remove.onClick = { [weak self] in self?.onRemove() }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityIdentifier("clipboardPopover.item")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(_ item: ClipboardItem, active: Bool, iconStore: FileIconStore?) {
        let theme = AppearanceModel.shared.theme
        isActive = active
        name.set(item.name, font: ChromeColors.font(size: DesignTokens.typeScale.body))
        name.textColor = NSColor(active ? theme.accent.onSolid : theme.palette.contextMenuText)
        name.toolTip = item.path
        toolTip = item.path
        setAccessibilityLabel(item.name)
        remove.isHidden = !active
        remove.color = NSColor(active ? theme.accent.onSolid : theme.palette.contextMenuText)
        remove.hoverFill = NSColor(theme.accent.onSolid.withAlpha(ClipboardLayout.Menu.removeHoverAlpha))
        remove.toolTip = "Remove from Clipboard"
        remove.setAccessibilityLabel("Remove \(item.name) from the clipboard")
        showIcon(item, iconStore: iconStore)
        needsLayout = true
        needsDisplay = true
    }

    private func showIcon(_ item: ClipboardItem, iconStore: FileIconStore?) {
        iconRequest?.cancel()
        iconRequest = nil
        guard let iconStore else {
            icon.image = NSWorkspace.shared.icon(forFile: item.path)
            return
        }
        let entry = ClipboardIcons.iconEntry(item.entry)
        let request = IconRequest(entry: entry)
        switch iconStore.lookup(request) {
        case .image(let image): icon.image = image
        case .none: icon.image = nil
        case .missing:
            icon.image = nil
            let path = item.path
            iconRequest = iconStore.load(request) { [weak self] image in
                guard let self, self.toolTip == path else { return }
                self.icon.image = image
            }
        }
    }

    override func layout() {
        super.layout()
        let layout = ClipboardLayout.Menu.self
        let size = layout.itemIconSize
        icon.frame = NSRect(x: layout.itemPaddingLeading, y: (bounds.height - size) / 2, width: size, height: size)
        let removeX = bounds.width - layout.itemPaddingTrailing - layout.removeSize
        remove.frame = NSRect(
            x: removeX, y: (bounds.height - layout.removeSize) / 2, width: layout.removeSize, height: layout.removeSize)
        let nameX = icon.frame.maxX + layout.itemIconGap
        name.frame = NSRect(
            x: nameX, y: (bounds.height - name.lineHeight) / 2, width: max(0, min(name.textWidth, removeX - nameX)),
            height: name.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let radius = DesignTokens.radii.control
        NSColor(AppearanceModel.shared.theme.accent.solidButton).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseEntered(with event: NSEvent) { onHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onReveal()
    }

    override func accessibilityPerformPress() -> Bool {
        onReveal()
        return true
    }

    isolated deinit {
        iconRequest?.cancel()
    }
}

/// The × of an item (`.clipboard-menu-item-remove`).
final class ClipboardMenuRemoveButton: NSView {
    private let glyph = ToolbarIconView(.close)
    var onClick: () -> Void = {}
    var color: NSColor = .labelColor {
        didSet { glyph.color = color }
    }
    var hoverFill: NSColor = .clear
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("clipboardPopover.item.remove")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = ClipboardLayout.Menu.removeIconSize
        glyph.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        hoverFill.setFill()
        let radius = DesignTokens.radii.xs
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// Clear Clipboard (`.toolbar-menu-item.clipboard-menu-clear`).
final class ClipboardMenuClearRow: NSView {
    private let label = ClipboardMenuText(identifier: "clipboardPopover.clear.label")
    var isActive = false {
        didSet {
            needsDisplay = true
            applyTheme(AppearanceModel.shared.theme)
        }
    }
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("Clear Clipboard")
        setAccessibilityIdentifier("clipboardPopover.clear")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        label.set("Clear Clipboard", font: ChromeColors.font(size: DesignTokens.typeScale.body))
        label.textColor = NSColor(isActive ? theme.accent.onSolid : theme.palette.contextMenuText)
    }

    var naturalWidth: Double {
        ClipboardLayout.Menu.clearPaddingLeading + label.textWidth + DesignTokens.menu.rowPaddingTrailing
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: ClipboardLayout.Menu.clearPaddingLeading, y: (bounds.height - label.lineHeight) / 2,
            width: max(0, bounds.width - ClipboardLayout.Menu.clearPaddingLeading), height: label.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let radius = DesignTokens.radii.control
        NSColor(AppearanceModel.shared.theme.accent.solidButton).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseEntered(with event: NSEvent) { onHover() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

/// The icons of what is on the clipboard (`ClipboardItemsIcon`).
enum ClipboardIcons {
    /// What the icon cache keys an item by.
    static func iconEntry(_ entry: ClipboardItemEntry) -> IconEntry {
        let kind: IconEntryKind =
            switch entry.kind {
            case .directory: .directory
            case .file: .file
            case .symlinkDirectory: .symlinkDirectory
            case .symlinkFile: .symlinkFile
            case .bundle: .bundle
            case .other: .other
            }
        return IconEntry(
            path: entry.path, name: entry.name, extension: entry.fileExtension, kind: kind,
            isExecutable: entry.isExecutable)
    }
}
