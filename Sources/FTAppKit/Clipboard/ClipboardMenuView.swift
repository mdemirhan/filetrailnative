// The clipboard's list under its button, in a system popover, with the count, the hint, the items under their folders
// (cut ones and copied ones apart when it holds both), Clear Clipboard, and Put Back after a Copy or Cut replaced a
// clipboard built with Add
import AppKit
import FTFileSystem
import FTFoundation

/// The content of the clipboard menu: the header, the breakdown, the list of ten 24 pt rows (virtualized, the top
/// folder heading pinned over it, a scrollbar of its own while it scrolls), Clear Clipboard and, when there is one to
/// put back, Put Back. On a clipboard holding both, the list is in two parts, Cut then Copied, as ⌘V runs. Each row
/// has its mark, which switches it between the two, and a menu of its own. The system's popover draws what is behind
/// it. The keyboard never goes into it: the keys come to it through the window while it is open.
final class ClipboardMenuView: NSView {
    private(set) var model: ClipboardMenuModel
    private(set) var summary: FTFoundation.ClipboardSummary
    var pasteHint: String

    var onReveal: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onClear: () -> Void = {}
    var onPutBack: () -> Void = {}
    /// The item is to be copied or moved as the mode says from now on.
    var onSetMode: (String, ClipboardMode) -> Void = { _, _ in }
    /// The item keeps its own name, and the other of its name is pasted under another (Use This One Instead).
    var onKeepName: (String) -> Void = { _ in }
    var iconStore: FileIconStore?

    private let title = ClipboardMenuText(identifier: "clipboardPopover.title")
    private let hint = ClipboardMenuText(identifier: "clipboardPopover.hint")
    private let breakdown = ClipboardMenuText(identifier: "clipboardPopover.breakdown")
    private let list = ClipboardMenuList()
    private let pinned = ClipboardMenuHeadingRow(pinned: true)
    private let clear = ClipboardMenuClearRow()
    private let putBack = ClipboardMenuClearRow(identifier: "clipboardPopover.putBack")
    private var rowViews: [Int: NSView] = [:]

    private static var padding: Double { DesignTokens.menu.padding }
    private static var border: Double { DesignTokens.menu.borderWidth }

    init(summary: FTFoundation.ClipboardSummary, pasteHint: String, putBackCount: Int? = nil) {
        self.summary = summary
        self.pasteHint = pasteHint
        model = ClipboardMenuModel(items: summary.items, putBackCount: putBackCount)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Clipboard")
        setAccessibilityIdentifier("clipboardPopover")
        for view in [title, hint, breakdown, list, pinned, clear, putBack] as [NSView] { addSubview(view) }
        list.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        pinned.onScroll = { [weak self] delta in self?.scroll(by: delta) }
        clear.onHover = { [weak self] in self?.setActive(self?.model.clearIndex ?? -1) }
        clear.onClick = { [weak self] in self?.onClear() }
        putBack.onHover = { [weak self] in self?.setActive(self?.model.putBackIndex ?? -1) }
        putBack.onClick = { [weak self] in self?.onPutBack() }
        model.opened()
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Contents

    /// The clipboard changed while the menu is open: the active row keeps its place.
    func update(_ summary: FTFoundation.ClipboardSummary, putBackCount: Int? = nil) {
        self.summary = summary
        model.setItems(summary.items, putBackCount: putBackCount)
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
        let details = [summary.intentLabel, summary.breakdown].compactMap { $0 }
        breakdown.isHidden = details.isEmpty
        breakdown.set(
            details.joined(separator: " \u{B7} "), font: ChromeColors.font(size: DesignTokens.typeScale.small))
        breakdown.textColor = NSColor(palette.contextMenuShortcut)
        clear.isActive = model.activeIndex == model.clearIndex
        clear.applyTheme(theme)
        putBack.isHidden = model.putBackCount == nil
        putBack.title = ClipboardTexts.putBackTitle(model.putBackCount ?? 0)
        putBack.isActive = model.activeIndex == model.putBackIndex
        putBack.applyTheme(theme)
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
                layout.itemPaddingLeading + layout.itemIconSize + layout.itemIconGap + name
                    + ClipboardMenuItemRow.noteWidth(item) + 2 * layout.removeSize + layout.itemPaddingTrailing
                    + (model.scrolls ? layout.scrollbarWidth : 0))
        }
        content = max(content, clear.naturalWidth)
        if !putBack.isHidden { content = max(content, putBack.naturalWidth) }
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
            + DesignTokens.menu.rowHeight * (model.putBackCount == nil ? 1 : 2)
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let layout = ClipboardLayout.Menu.self
        let inset = Self.padding + Self.border
        let width = bounds.width - 2 * inset
        var y = inset + layout.headerPaddingVertical
        let line = title.lineHeight
        // The smaller hint sits on the title's baseline.
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
            // The box is the whole row's, its padding inside: 10 at each side and 4 below.
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
        y += DesignTokens.menu.rowHeight
        putBack.frame = NSRect(x: inset, y: y, width: width, height: DesignTokens.menu.rowHeight)
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
        let hiddenTop = model.pinnedRow == nil ? 0 : height
        list.hiddenTop = hiddenTop
        let width = list.bounds.width - (model.scrolls ? ClipboardLayout.Menu.scrollbarWidth : 0)
        for (index, view) in rowViews where !drawn.contains(index) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: index)
        }
        for index in drawn {
            let row = model.rows[index]
            // A view kept for a place in the list may have shown another row (an item removed shifts the rest): it is
            // set again for the row there now, its buttons acting on that row's item.
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
        switch model.pinnedRow {
        case .heading(let label, let parentPath)?:
            pinned.isHidden = false
            pinned.set(label, path: parentPath, mode: model.pinnedMode)
        case .section(let mode, let count)?:
            pinned.isHidden = false
            pinned.setSection(mode, count: count)
        case .item?, nil:
            pinned.isHidden = true
        }
        list.scrollTop = model.scrollTop
        list.contentHeight = model.contentHeight
        list.needsDisplay = true
        clear.isActive = model.activeIndex == model.clearIndex
        putBack.isActive = model.activeIndex == model.putBackIndex
    }

    private func makeRow(_ row: ClipboardMenuRow) -> NSView {
        switch row {
        case .heading, .section: ClipboardMenuHeadingRow(pinned: false)
        case .item: ClipboardMenuItemRow()
        }
    }

    private static func fits(_ view: NSView, _ row: ClipboardMenuRow) -> Bool {
        switch row {
        case .heading, .section: view is ClipboardMenuHeadingRow
        case .item: view is ClipboardMenuItemRow
        }
    }

    /// Shows `row` in `view`: a heading's folder, or an item with its hover, click and × for that item.
    private func bind(_ view: NSView, to row: ClipboardMenuRow) {
        switch row {
        case .heading(let label, let parentPath):
            (view as? ClipboardMenuHeadingRow)?.set(label, path: parentPath, mode: nil)
        case .section(let mode, let count):
            (view as? ClipboardMenuHeadingRow)?.setSection(mode, count: count)
        case .item(let item, let itemIndex):
            guard let view = view as? ClipboardMenuItemRow else { return }
            view.onHover = { [weak self] in self?.setActive(itemIndex) }
            view.onReveal = { [weak self] in self?.onReveal(item.path) }
            view.onRemove = { [weak self] in self?.onRemove(item.path) }
            view.onSwitchMode = { [weak self] in self?.onSetMode(item.path, item.mode == .cut ? .copy : .cut) }
            view.menuItems = { [weak self] in self?.rowMenu(item) ?? [] }
            view.configure(item, active: itemIndex == model.activeIndex, iconStore: iconStore)
        }
    }

    /// The menu of an item's row: show it, have it copied or moved instead, keep its own name when another has it,
    /// take it off.
    private func rowMenu(_ item: ClipboardItem) -> [NSMenuItem] {
        let path = item.path
        var items: [NSMenuItem] = [
            ActionMenuItem(ClipboardTexts.showInFolderTitle) { [weak self] in self?.onReveal(path) },
            .separator(),
            ActionMenuItem(ClipboardTexts.switchModeTitle(from: item.mode)) { [weak self] in
                self?.onSetMode(path, item.mode == .cut ? .copy : .cut)
            },
        ]
        if item.pastedUnderAnotherName {
            items.append(
                ActionMenuItem(ClipboardTexts.useThisOneInsteadTitle) { [weak self] in self?.onKeepName(path) })
        }
        items.append(.separator())
        items.append(ActionMenuItem(ClipboardTexts.removeFromClipboardTitle) { [weak self] in self?.onRemove(path) })
        return items
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

    /// The whole points above the baseline: the font's ascent rounded down (12 at 13 pt, 10 at 11 pt).
    var ascent: Double {
        guard let font else { return 0 }
        return Double(font.ascender.rounded(.down))
    }

    /// The font's natural line (ascent, descent and leading), rounded: 15 at 13 pt, 13 at 11 pt.
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
        didSet {
            if hiddenTop != oldValue { needsLayout = true }
        }
    }
    /// Scroll Bars' "Click in the scroll bar to" in System Settings: to the spot clicked, or a page that way.
    var jumpsToClickedSpot = UserDefaults.standard.bool(forKey: "AppleScrollerPagingBehavior")
    /// Where in the thumb the pointer holds it, while it is dragged.
    private var thumbGrab: Double? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // The rows stop at the pinned heading rather than running on behind it.
        content.clipsToBounds = true
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

    // MARK: Scrollbar

    private var showsBar: Bool { scrolls && contentHeight > bounds.height }

    private var track: NSRect {
        let width = ClipboardLayout.Menu.scrollbarWidth
        return NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    private var scrollRange: Double { max(1, contentHeight - bounds.height) }

    private var thumbHeight: Double {
        max(ClipboardLayout.Menu.scrollbarWidth * 2, bounds.height * bounds.height / contentHeight)
    }

    private var thumb: NSRect {
        let offset = (bounds.height - thumbHeight) * scrollTop / scrollRange
        return NSRect(x: track.minX, y: offset, width: track.width, height: thumbHeight)
    }

    private func location(of event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    /// Scrolls so that the thumb's top is `thumbTop` down the track.
    private func moveThumb(to thumbTop: Double) {
        let travel = max(1, bounds.height - thumbHeight)
        onScroll(thumbTop / travel * scrollRange - scrollTop)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !isHidden, showsBar, track.contains(convert(point, from: superview)) { return self }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        if thumb.contains(point) {
            thumbGrab = point.y - thumb.minY
        } else if jumpsToClickedSpot {
            thumbGrab = thumbHeight / 2
            moveThumb(to: point.y - thumbHeight / 2)
        } else {
            let page = bounds.height - hiddenTop
            onScroll(point.y < thumb.minY ? -page : page)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let thumbGrab else { return }
        moveThumb(to: location(of: event).y - thumbGrab)
    }

    override func mouseUp(with event: NSEvent) { thumbGrab = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard showsBar else { return }
        let layout = ClipboardLayout.Menu.self
        let palette = ChromeColors.palette(for: self)
        let shown = thumb.insetBy(dx: layout.scrollbarThumbInset, dy: layout.scrollbarThumbInset)
        let alpha = thumbGrab == nil ? layout.scrollbarThumbAlpha : layout.scrollbarThumbActiveAlpha
        NSColor(palette.contextMenuText.withAlpha(palette.contextMenuText.alpha * alpha)).setFill()
        NSBezierPath(roundedRect: shown, xRadius: shown.width / 2, yRadius: shown.width / 2).fill()
    }
}

/// A folder heading of the list, or the one pinned over its top; on a clipboard holding both, also the title of a
/// part ("Cut · 4", what ⌘V does with them on the right), and the pinned folder shows the mark of its part.
final class ClipboardMenuHeadingRow: NSView {
    private let glyph = SymbolIconView(CommandIcon.cut.symbolName)
    private let label = ClipboardMenuText(identifier: "clipboardPopover.heading.label")
    private let detail = ClipboardMenuText(identifier: "clipboardPopover.heading.detail")
    private let isPinned: Bool
    private var showsGlyph = false
    var onScroll: (Double) -> Void = { _ in }

    init(pinned: Bool) {
        isPinned = pinned
        super.init(frame: .zero)
        addSubview(glyph)
        addSubview(label)
        addSubview(detail)
        setAccessibilityIdentifier(pinned ? "clipboardPopover.pinnedHeading" : "clipboardPopover.heading")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A folder, with the mark of the part it is in when the clipboard holds both (only pinned).
    func set(_ text: String, path: String, mode: ClipboardMode?) {
        let palette = ChromeColors.palette(for: self)
        label.set(text, font: ChromeColors.font(size: DesignTokens.typeScale.small, weight: 600))
        label.textColor = NSColor(palette.contextMenuShortcut)
        detail.isHidden = true
        showGlyph(mode, color: NSColor(palette.contextMenuShortcut))
        toolTip = path
        setAccessibilityIdentifier(isPinned ? "clipboardPopover.pinnedHeading" : "clipboardPopover.heading")
        needsLayout = true
    }

    /// The title of a part: what ⌘V does with the items under it.
    func setSection(_ mode: ClipboardMode, count: Int) {
        let palette = ChromeColors.palette(for: self)
        label.set(
            ClipboardTexts.sectionTitle(mode, count: count),
            font: ChromeColors.font(size: DesignTokens.typeScale.small, weight: 700))
        label.textColor = NSColor(palette.contextMenuText)
        detail.isHidden = false
        detail.set(ClipboardTexts.sectionDetail(mode), font: ChromeColors.font(size: DesignTokens.typeScale.small))
        detail.textColor = NSColor(palette.contextMenuShortcut)
        showGlyph(mode, color: NSColor(palette.contextMenuText))
        toolTip = nil
        setAccessibilityIdentifier(isPinned ? "clipboardPopover.pinnedSection" : "clipboardPopover.section")
        needsLayout = true
    }

    private func showGlyph(_ mode: ClipboardMode?, color: NSColor) {
        showsGlyph = mode != nil
        glyph.isHidden = mode == nil
        glyph.symbolName = (mode == .cut ? CommandIcon.cut : .copy).symbolName
        glyph.color = color
    }

    override func layout() {
        super.layout()
        let inset = ClipboardLayout.Menu.headingPaddingHorizontal
        let size = ClipboardLayout.Mark.iconSize
        glyph.frame = NSRect(x: inset, y: (bounds.height - size) / 2, width: size, height: size)
        let labelX = showsGlyph ? inset + size + ClipboardLayout.Menu.itemIconGap : inset
        let detailWidth = detail.isHidden ? 0 : min(detail.textWidth, max(0, bounds.width / 2))
        detail.frame = NSRect(
            x: bounds.width - inset - detailWidth, y: (bounds.height - detail.lineHeight) / 2, width: detailWidth,
            height: detail.lineHeight)
        let labelEnd = detail.isHidden ? bounds.width - inset : detail.frame.minX - ClipboardLayout.Menu.headerGap
        label.frame = NSRect(
            x: labelX, y: (bounds.height - label.lineHeight) / 2, width: max(0, labelEnd - labelX),
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

/// An item of the list: its icon and name (a click shows it in its folder), "renamed on paste" when another item has
/// its name, its mark (scissors or copy, which switches it between the two), the × that takes it off the clipboard
/// (shown on the active row), and a menu of its own on a right-click.
final class ClipboardMenuItemRow: NSView {
    private let icon = NSImageView()
    private let name = ClipboardMenuText(identifier: "clipboardPopover.item.name")
    private let note = ClipboardMenuText(identifier: "clipboardPopover.item.note")
    private let mark = ClipboardMenuRemoveButton(
        symbol: CommandIcon.cut.symbolName, identifier: "clipboardPopover.item.mark")
    private let remove = ClipboardMenuRemoveButton()
    private var isActive = false
    private var tracking: NSTrackingArea?
    private var iconRequest: LoadHandle?
    var onHover: () -> Void = {}
    var onReveal: () -> Void = {}
    var onRemove: () -> Void = {}
    var onSwitchMode: () -> Void = {}
    /// The items of the row's menu, built when it opens.
    var menuItems: () -> [NSMenuItem] = { [] }

    /// The width "renamed on paste" takes beside a name, with its gap; none for an item that keeps its name.
    static func noteWidth(_ item: ClipboardItem) -> Double {
        guard item.pastedUnderAnotherName else { return 0 }
        let font = ChromeColors.font(size: DesignTokens.typeScale.small)
        return ClipboardLayout.Menu.itemIconGap
            + ceil((ClipboardTexts.renamedOnPasteNote as NSString).size(withAttributes: [.font: font]).width)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(name)
        addSubview(note)
        addSubview(mark)
        addSubview(remove)
        remove.onClick = { [weak self] in self?.onRemove() }
        mark.onClick = { [weak self] in self?.onSwitchMode() }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityIdentifier("clipboardPopover.item")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func configure(_ item: ClipboardItem, active: Bool, iconStore: FileIconStore?) {
        let theme = AppearanceModel.shared.theme
        isActive = active
        let text = active ? theme.accent.onSolid : theme.palette.contextMenuText
        // A cut item looks taken out already, as its row in the folder does.
        let cutAlpha = item.mode == .cut && !active ? ClipboardLayout.Mark.cutLabelAlpha : 1
        name.set(item.name, font: ChromeColors.font(size: DesignTokens.typeScale.body))
        name.textColor = NSColor(text.withAlpha(text.alpha * cutAlpha))
        name.toolTip = item.path
        note.isHidden = !item.pastedUnderAnotherName
        note.set(ClipboardTexts.renamedOnPasteNote, font: ChromeColors.font(size: DesignTokens.typeScale.small))
        note.textColor = NSColor(active ? theme.accent.onSolid : theme.palette.contextMenuShortcut)
        toolTip = item.path
        setAccessibilityLabel(ClipboardTexts.itemAccessibilityLabel(item))
        mark.symbolName = (item.mode == .cut ? CommandIcon.cut : .copy).symbolName
        mark.color = NSColor(
            text.withAlpha(text.alpha * (item.mode == .cut && !active ? ClipboardLayout.Mark.cutIconAlpha : 1)))
        mark.hoverFill = NSColor(
            (active ? theme.accent.onSolid : theme.palette.contextMenuText).withAlpha(
                ClipboardLayout.Menu.removeHoverAlpha))
        mark.toolTip = ClipboardTexts.switchModeTitle(from: item.mode)
        mark.setAccessibilityLabel(ClipboardTexts.switchModeTitle(from: item.mode))
        remove.isHidden = !active
        remove.color = NSColor(text)
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
                guard let self, self.toolTip.map({ samePath($0, path) }) == true else { return }
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
        let markX = removeX - layout.removeSize
        mark.frame = NSRect(
            x: markX, y: (bounds.height - layout.removeSize) / 2, width: layout.removeSize, height: layout.removeSize)
        let nameX = icon.frame.maxX + layout.itemIconGap
        let noteWidth = note.isHidden ? 0 : note.textWidth
        let noteSpace = note.isHidden ? 0 : layout.itemIconGap + noteWidth
        let nameWidth = max(0, min(name.textWidth, markX - nameX - noteSpace))
        name.frame = NSRect(
            x: nameX, y: (bounds.height - name.lineHeight) / 2, width: nameWidth, height: name.lineHeight)
        note.frame = NSRect(
            x: name.frame.maxX + layout.itemIconGap, y: (bounds.height - note.lineHeight) / 2,
            width: max(0, min(noteWidth, markX - name.frame.maxX - layout.itemIconGap)), height: note.lineHeight)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onHover()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in menuItems() { menu.addItem(item) }
        return menu.items.isEmpty ? nil : menu
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

/// The × that removes an item, or the mark that switches it between copied and cut.
final class ClipboardMenuRemoveButton: NSView {
    private let glyph: SymbolIconView
    var onClick: () -> Void = {}
    var symbolName: String {
        get { glyph.symbolName }
        set { glyph.symbolName = newValue }
    }
    var color: NSColor = .labelColor {
        didSet { glyph.color = color }
    }
    var hoverFill: NSColor = .clear
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    init(symbol: String = "xmark", identifier: String = "clipboardPopover.item.remove") {
        glyph = SymbolIconView(symbol)
        super.init(frame: .zero)
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(identifier)
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

/// The Clear Clipboard row, and the Put Back row under it.
final class ClipboardMenuClearRow: NSView {
    private let label: ClipboardMenuText
    var title = "Clear Clipboard" {
        didSet { setAccessibilityLabel(title) }
    }
    var isActive = false {
        didSet {
            needsDisplay = true
            applyTheme(AppearanceModel.shared.theme)
        }
    }
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    private var tracking: NSTrackingArea?

    init(identifier: String = "clipboardPopover.clear") {
        label = ClipboardMenuText(identifier: "\(identifier).label")
        super.init(frame: .zero)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        label.set(title, font: ChromeColors.font(size: DesignTokens.typeScale.body))
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

/// The icons of what is on the clipboard.
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
