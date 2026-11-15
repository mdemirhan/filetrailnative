import AppKit
import FTFoundation

/// The command palette (⇧⌘P): a panel dropped below the toolbar, as Go To is, with a field, every command that matches
/// what is typed and a line of keys at its foot. What is listed, and in what order, is `CommandPalette`'s.
@MainActor
final class CommandPaletteBox: DialogPanelView, NSTextFieldDelegate {
    private(set) var entries: [CommandPaletteEntry]
    private let recent: [String]
    /// The key that opened it, which closes it again.
    private let ownKey: String?
    let shell = GoToFieldShell(
        label: "Command name", placeholder: CommandPalette.placeholder, identifier: "commandPalette")
    let scroll = NSScrollView()
    private let listContent = PaletteListView()
    let footer = DialogFooterLine(thickness: DialogLayout.GoTo.footerBorder)
    let hintLabel = PlainLabel(labelWithString: "↑↓ to choose    ↩ to run    esc to close")
    let countLabel = PlainLabel(labelWithString: "")
    /// What the selected command does, in a line: Help's line for it.
    let helpLabel = PlainLabel(labelWithString: "")
    let emptyLabel = PlainLabel(wrappingLabelWithString: "")
    private(set) var sections: [CommandPaletteSection] = []
    private(set) var rowViews: [CommandPaletteRowView] = []
    private var headingViews: [PlainLabel] = []
    /// The row selected, among every row of every section.
    private(set) var selectedIndex = 0

    /// A command chosen, by Return or a click, that can run: the box is to close and the command run.
    var onRun: (CommandPaletteEntry) -> Void = { _ in }
    /// Escape, ⌘., the palette's key again, or a press on the scrim.
    var onClose: () -> Void = {}

    private static let hintFont = ThemeFonts.sans(DesignTokens.typeScale.small)
    private static let helpFont = ThemeFonts.sans(DesignTokens.typeScale.callout)
    private static let headingFont = ThemeFonts.sans(DesignTokens.typeScale.small, .semibold)
    private static let emptyFont = ThemeFonts.sans(DesignTokens.typeScale.callout)

    init(entries: [CommandPaletteEntry], recent: [String], ownKey: String?) {
        self.entries = entries
        self.recent = recent
        self.ownKey = ownKey
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("Command Palette")
        setAccessibilityIdentifier("commandPalette")
        addSubview(shell)
        shell.field.delegate = self
        shell.clearButton.target = self
        shell.clearButton.action = #selector(clearPressed(_:))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = listContent
        scroll.setAccessibilityIdentifier("commandPalette.list")
        addSubview(scroll)
        emptyLabel.font = Self.emptyFont
        emptyLabel.alignment = .center
        emptyLabel.setAccessibilityIdentifier("commandPalette.empty")
        addSubview(emptyLabel)
        footer.setAccessibilityIdentifier("commandPalette.footer")
        addSubview(footer)
        for label in [hintLabel, countLabel] {
            label.font = Self.hintFont
            footer.addSubview(label)
        }
        countLabel.alignment = .right
        helpLabel.font = Self.helpFont
        helpLabel.lineBreakMode = .byTruncatingTail
        helpLabel.setAccessibilityIdentifier("commandPalette.help")
        footer.addSubview(helpLabel)
        countLabel.setAccessibilityIdentifier("commandPalette.count")
        applyTheme(theme)
        showRows()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var field: GoToField { shell.field }

    /// Every row shown, in order.
    var rows: [CommandPaletteRow] { sections.flatMap(\.rows) }

    /// The row selected, if any is shown.
    var selectedRow: CommandPaletteRow? {
        let rows = rows
        return rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        textChanged(field.stringValue)
    }

    /// What is typed changed: the rows follow, the best one selected.
    func textChanged(_ value: String) {
        if field.stringValue != value { field.stringValue = value }
        showRows()
        listContent.scroll(.zero)
    }

    @objc private func clearPressed(_ sender: Any?) {
        textChanged("")
        window?.makeFirstResponder(field)
    }

    // MARK: Keys

    override var initialResponder: NSView? { field }

    override var keepsPaneFocus: Bool { true }

    override func handleKey(_ event: NSEvent) -> Bool {
        if KeyCode.isCancel(event) || isOwnKey(event) {
            onClose()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        case (KeyCode.down, []): moveSelection(1)
        case (KeyCode.up, []): moveSelection(-1)
        case (Self.pageDown, []): moveSelection(visibleRowCount)
        case (Self.pageUp, []): moveSelection(-visibleRowCount)
        case (Self.letterN, [.control]): moveSelection(1)
        case (Self.letterP, [.control]): moveSelection(-1)
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []): runSelected()
        default: return false
        }
        return true
    }

    private static let pageUp: UInt16 = 116
    private static let pageDown: UInt16 = 121
    private static let letterN: UInt16 = 45
    private static let letterP: UInt16 = 35

    private func isOwnKey(_ event: NSEvent) -> Bool {
        guard let ownKey, let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)) else {
            return false
        }
        return pressed == ownKey
    }

    private var visibleRowCount: Int {
        max(1, Int(scroll.contentSize.height / rowHeight))
    }

    func moveSelection(_ step: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selectedIndex = min(count - 1, max(0, selectedIndex + step))
        markSelection()
        scrollSelectionIntoView()
    }

    /// Runs the row selected; one that can't run now beeps.
    func runSelected() {
        guard let row = selectedRow else {
            NSSound.beep()
            return
        }
        run(row.entry)
    }

    private func run(_ entry: CommandPaletteEntry) {
        guard entry.enabled else {
            NSSound.beep()
            return
        }
        onRun(entry)
    }

    // MARK: Mouse

    func rowClicked(_ index: Int) {
        guard rowViews.indices.contains(index) else { return }
        selectedIndex = index
        markSelection()
        run(rowViews[index].row.entry)
    }

    func pointerMoved(over index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        markSelection()
    }

    // MARK: Showing

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        shell.applyTheme(theme)
        footer.applyTheme(theme)
        let secondary = NSColor(theme.palette.textSecondary)
        for label in [hintLabel, countLabel, emptyLabel] + headingViews { label.textColor = secondary }
        helpLabel.textColor = NSColor(theme.palette.textPrimary)
        for row in rowViews { row.applyTheme(theme) }
    }

    /// The sections for what is typed, drawn again.
    private func showRows() {
        sections = CommandPalette.sections(entries, query: field.stringValue, recent: recent)
        for view in rowViews { view.removeFromSuperview() }
        for view in headingViews { view.removeFromSuperview() }
        rowViews = []
        headingViews = []
        var index = 0
        for section in sections {
            if let title = section.title {
                let heading = PlainLabel(labelWithString: title)
                heading.font = Self.headingFont
                heading.textColor = NSColor(theme.palette.textSecondary)
                heading.setAccessibilityIdentifier("commandPalette.heading")
                listContent.addSubview(heading)
                headingViews.append(heading)
            }
            for row in section.rows {
                let view = CommandPaletteRowView(index: index, row: row, theme: theme)
                view.box = self
                listContent.addSubview(view)
                rowViews.append(view)
                index += 1
            }
        }
        // The first row that can run: Return does something.
        selectedIndex = rowViews.firstIndex { $0.row.entry.enabled } ?? 0
        let typed = !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        shell.clearButton.isHidden = field.stringValue.isEmpty
        emptyLabel.stringValue = "No command matches \u{201C}\(field.stringValue)\u{201D}."
        emptyLabel.isHidden = !rowViews.isEmpty
        scroll.isHidden = rowViews.isEmpty
        let count = rowViews.count
        countLabel.stringValue = typed ? "\(count) \(count == 1 ? "command" : "commands")" : "\(entries.count) commands"
        markSelection()
        shell.needsLayout = true
        needsLayout = true
        superview?.needsLayout = true
    }

    private func markSelection() {
        for view in rowViews { view.isSelected = view.index == selectedIndex }
        let entry = selectedRow?.entry
        helpLabel.stringValue = entry.map { $0.help.isEmpty ? $0.title : $0.help } ?? ""
    }

    private func scrollSelectionIntoView() {
        guard rowViews.indices.contains(selectedIndex) else { return }
        var rect = rowViews[selectedIndex].frame
        // The first row of a section brings its heading along.
        if let heading = headingViews.first(where: { abs($0.frame.maxY - rect.minY) < 1 }) {
            rect = rect.union(heading.frame)
        }
        listContent.scrollToVisible(rect)
    }

    // MARK: Layout

    private var rowHeight: CGFloat { CGFloat(DesignTokens.controlHeights.large) }

    /// The list's height with every row and heading.
    private var listHeight: CGFloat {
        CGFloat(rowViews.count) * rowHeight
            + CGFloat(headingViews.count) * CGFloat(DialogLayout.CommandPalette.headingHeight)
    }

    private var footerHeight: CGFloat {
        let layout = DialogLayout.CommandPalette.self
        return CGFloat(DialogLayout.GoTo.footerBorder + layout.footerTop + layout.helpBottom + layout.footerBottom)
            + GoToRowView.lineHeight(Self.helpFont) + GoToRowView.lineHeight(Self.hintFont)
    }

    /// The field, the room around the list, and the foot.
    private var fixedHeight: CGFloat {
        let goTo = DialogLayout.GoTo.self
        return CGFloat(goTo.paddingTop) + CGFloat(DesignTokens.controlHeights.large)
            + CGFloat(goTo.sectionTop + goTo.sectionBottom) + footerHeight
    }

    private func emptyHeight(width: CGFloat) -> CGFloat {
        let inner = width - 2 * CGFloat(DialogLayout.GoTo.sectionHorizontal + DialogLayout.GoTo.emptyHorizontal)
        return ceil(emptyLabel.sizeThatFits(NSSize(width: max(1, inner), height: .greatestFiniteMagnitude)).height)
    }

    override func panelSize(in size: NSSize) -> NSSize {
        let goTo = DialogLayout.GoTo.self
        let layout = DialogLayout.CommandPalette.self
        let width = min(CGFloat(layout.width), max(0, size.width - CGFloat(goTo.viewportInset)))
        let maxHeight = max(0, size.height - CGFloat(goTo.heightInset))
        let list: CGFloat =
            rowViews.isEmpty
            ? CGFloat(layout.emptyTop + layout.emptyBottom) + emptyHeight(width: width)
            : min(listHeight, CGFloat(layout.visibleRows) * rowHeight)
        return NSSize(width: width, height: min(fixedHeight + list, maxHeight))
    }

    override func layout() {
        super.layout()
        let goTo = DialogLayout.GoTo.self
        let layout = DialogLayout.CommandPalette.self
        let width = bounds.width
        var y = CGFloat(goTo.paddingTop)
        let section = CGFloat(goTo.inputSectionHorizontal)
        let fieldHeight = CGFloat(DesignTokens.controlHeights.large)
        shell.frame = NSRect(x: section, y: y, width: max(0, width - 2 * section), height: fieldHeight)
        y += fieldHeight + CGFloat(goTo.sectionTop)
        footer.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        let inset = GoToRowView.cellInset
        let helpY = CGFloat(goTo.footerBorder + layout.footerTop)
        let helpHeight = GoToRowView.lineHeight(Self.helpFont)
        let textWidth = max(0, width - 2 * CGFloat(layout.footerHorizontal))
        helpLabel.frame = NSRect(
            x: CGFloat(layout.footerHorizontal) - inset, y: helpY, width: textWidth + 2 * inset, height: helpHeight)
        let lineY = helpY + helpHeight + CGFloat(layout.helpBottom)
        let textHeight = GoToRowView.lineHeight(Self.hintFont)
        hintLabel.frame = NSRect(
            x: CGFloat(layout.footerHorizontal) - inset, y: lineY, width: textWidth * 0.7 + 2 * inset,
            height: textHeight)
        countLabel.frame = NSRect(
            x: CGFloat(layout.footerHorizontal) + textWidth * 0.7 - inset, y: lineY, width: textWidth * 0.3 + 2 * inset,
            height: textHeight)
        let sectionX = CGFloat(goTo.sectionHorizontal)
        let listBottom = bounds.height - footerHeight - CGFloat(goTo.sectionBottom)
        if rowViews.isEmpty {
            let emptyInset = sectionX + CGFloat(goTo.emptyHorizontal)
            emptyLabel.frame = NSRect(
                x: emptyInset, y: y + CGFloat(layout.emptyTop), width: max(0, width - 2 * emptyInset),
                height: emptyHeight(width: width))
            return
        }
        scroll.frame = NSRect(x: sectionX, y: y, width: max(0, width - 2 * sectionX), height: max(0, listBottom - y))
        let contentWidth = scroll.contentSize.width
        listContent.frame = NSRect(x: 0, y: 0, width: contentWidth, height: listHeight)
        var rowY: CGFloat = 0
        var headings = headingViews.makeIterator()
        var rowIndex = 0
        let headingHeight = CGFloat(layout.headingHeight)
        let headingTextHeight = GoToRowView.lineHeight(Self.headingFont)
        for section in sections {
            if section.title != nil, let heading = headings.next() {
                let padding = CGFloat(goTo.rowPaddingHorizontal)
                heading.frame = NSRect(
                    x: padding - inset, y: rowY + headingHeight - headingTextHeight - 4,
                    width: max(0, contentWidth - 2 * padding) + 2 * inset, height: headingTextHeight)
                rowY += headingHeight
            }
            for _ in section.rows {
                rowViews[rowIndex].frame = NSRect(x: 0, y: rowY, width: contentWidth, height: rowHeight)
                rowY += rowHeight
                rowIndex += 1
            }
        }
    }
}

/// The palette's list, top down.
@MainActor
final class PaletteListView: NSView {
    override var isFlipped: Bool { true }
}

/// One command of the palette: its symbol, its name with the letters typed in bold, where it is in the menus, a check
/// for what is on, and its keys as a menu shows them. The selected one is filled with the accent, as a menu row; one
/// that can't run now is dimmed.
@MainActor
final class CommandPaletteRowView: NSView, ThemeApplying {
    let index: Int
    let row: CommandPaletteRow
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let placeLabel = PlainLabel(labelWithString: "")
    let checkLabel = PlainLabel(labelWithString: "")
    let keysLabel = PlainLabel(labelWithString: "")
    weak var box: CommandPaletteBox?
    var isSelected = false { didSet { if isSelected != oldValue { applyColors() } } }
    private var theme: Theme
    private var trackingArea: NSTrackingArea?
    private static let titleFont = ThemeFonts.sans(DesignTokens.typeScale.body)
    private static let matchFont = ThemeFonts.sans(DesignTokens.typeScale.body, .bold)
    private static let detailFont = ThemeFonts.sans(DesignTokens.typeScale.callout)

    init(index: Int, row: CommandPaletteRow, theme: Theme) {
        self.index = index
        self.row = row
        self.theme = theme
        super.init(frame: .zero)
        let entry = row.entry
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.title)
        setAccessibilityEnabled(entry.enabled)
        setAccessibilityIdentifier("commandPalette.row")
        for label in [titleLabel, placeLabel, checkLabel, keysLabel] {
            label.isBordered = false
            label.drawsBackground = false
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            addSubview(label)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("commandPalette.row.title")
        placeLabel.font = Self.detailFont
        placeLabel.lineBreakMode = .byTruncatingTail
        placeLabel.stringValue = entry.place.map { $0.replacingOccurrences(of: " > ", with: " \u{203A} ") } ?? ""
        placeLabel.setAccessibilityIdentifier("commandPalette.row.place")
        checkLabel.font = Self.detailFont
        checkLabel.alignment = .center
        checkLabel.stringValue = entry.checked ? "\u{2713}" : ""
        checkLabel.setAccessibilityIdentifier("commandPalette.row.check")
        keysLabel.font = Self.detailFont
        keysLabel.alignment = .right
        keysLabel.stringValue = entry.keys.map { $0 == "esc" ? "Esc" : $0 }.joined()
        keysLabel.setAccessibilityIdentifier("commandPalette.row.keys")
        iconView.imageScaling = .scaleProportionallyDown
        if let icon = entry.icon {
            iconView.image = SymbolGlyph.image(icon.symbolName, pointSize: DesignTokens.typeScale.body)
        }
        addSubview(iconView)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        applyColors()
    }

    private func applyColors() {
        let palette = theme.palette
        let enabled = row.entry.enabled
        let onAccent = isSelected && enabled
        let text: RGBA = onAccent ? theme.accent.onSolid : enabled ? palette.textPrimary : palette.textTertiary
        let detail: RGBA =
            onAccent
            ? theme.accent.onSolid.withAlpha(DialogLayout.GoTo.selectedPathAlpha)
            : enabled ? palette.textSecondary : palette.textTertiary
        let title = row.entry.title
        let name = NSMutableAttributedString(
            string: title, attributes: [.font: Self.titleFont, .foregroundColor: NSColor(text)])
        let length = (title as NSString).length
        for mark in row.marks where mark.start < length {
            name.addAttribute(
                .font, value: Self.matchFont,
                range: NSRange(location: mark.start, length: min(mark.end, length) - mark.start))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        name.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: length))
        titleLabel.attributedStringValue = name
        for label in [placeLabel, keysLabel] { label.textColor = NSColor(detail) }
        checkLabel.textColor = NSColor(
            onAccent ? theme.accent.onSolid : enabled ? theme.accent.solid : palette.textTertiary)
        iconView.contentTintColor = NSColor(detail)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let goTo = DialogLayout.GoTo.self
        let layout = DialogLayout.CommandPalette.self
        let padding = CGFloat(goTo.rowPaddingHorizontal)
        let gap = CGFloat(layout.rowGap)
        let iconSize = CGFloat(layout.rowIconSize)
        let inset = GoToRowView.cellInset
        let inner = max(0, bounds.width - 2 * padding)
        func centered(_ height: CGFloat) -> CGFloat { ((bounds.height - height) / 2).rounded() }
        iconView.frame = NSRect(x: padding, y: centered(iconSize), width: iconSize, height: iconSize)
        // The keys at the right, the check before them, the title and its place in what is left.
        let detailHeight = GoToRowView.lineHeight(Self.detailFont)
        let keysWidth = keysLabel.stringValue.isEmpty ? 0 : ceil(keysLabel.attributedStringValue.size().width)
        let right = padding + inner
        keysLabel.frame = NSRect(
            x: right - keysWidth - inset, y: centered(detailHeight), width: keysWidth + 2 * inset,
            height: detailHeight)
        let checkWidth = CGFloat(layout.checkWidth)
        let checkX = right - keysWidth - (keysWidth > 0 ? gap : 0) - checkWidth
        checkLabel.frame = NSRect(
            x: checkX - inset, y: centered(detailHeight), width: checkWidth + 2 * inset, height: detailHeight)
        let titleX = padding + iconSize + gap
        let room = max(0, checkX - gap - titleX)
        let natural = ceil(titleLabel.attributedStringValue.size().width)
        let titleWidth = min(natural, (inner * CGFloat(layout.titleMaxFraction)).rounded(.down), room)
        let titleHeight = GoToRowView.lineHeight(Self.titleFont)
        titleLabel.frame = NSRect(
            x: titleX - inset, y: centered(titleHeight), width: titleWidth + 2 * inset, height: titleHeight)
        let placeX = titleX + titleWidth + gap
        placeLabel.frame = NSRect(
            x: placeX - inset, y: centered(detailHeight), width: max(0, checkX - gap - placeX) + 2 * inset,
            height: detailHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let radius = CGFloat(DesignTokens.radii.control)
        let fill = row.entry.enabled ? theme.accent.solidButton : theme.palette.textTertiary
        NSColor(fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        box?.pointerMoved(over: index)
    }

    // The field keeps the keyboard while the list is used with the mouse.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        box?.rowClicked(index)
    }
}
