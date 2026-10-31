// Port of SettingsList, ColumnList, DragHandle and SettingsListText of
// apps/desktop/src/renderer/components/SettingsView.tsx, drawn as styles.css:5742-5908 draws them
import AppKit
import FTFoundation

/// A full-width row of a card that may draw the line under itself.
@MainActor
protocol SettingsListBlock: SettingsBlock {
    var drawsSeparator: Bool { get set }
}

/// A button of the bar under a list: a 24 by 20 icon, or text 8 in from each side.
final class SettingsListBarButton: SettingsControlView {
    enum Content {
        case icon(String)
        case text(String)
    }

    let content: Content
    private static var font: NSFont { ThemeFonts.sans(DesignTokens.typeScale.small) }
    private let label = FlushTextField(labelWithString: "")

    init(_ content: Content, label accessibilityLabel: String, tooltip: String? = nil, theme: Theme) {
        self.content = content
        super.init(theme: theme)
        if case .text(let text) = content {
            label.stringValue = text
            label.font = Self.font
            addSubview(label)
        }
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("settings.listBar.button")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHovering: Bool { didSet { applyColors() } }

    var preferredWidth: CGFloat {
        switch content {
        case .icon: SettingsMetrics.listBarButtonSize.width
        case .text(let text): SettingsGlyph.textWidth(text, Self.font) + 2 * SettingsMetrics.listBarTextPadding
        }
    }

    private var ink: RGBA { isHovering && isEnabled ? theme.palette.textPrimary : theme.palette.textSecondary }

    private func applyColors() {
        label.textColor = NSColor(ink)
        needsDisplay = true
    }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyColors()
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: SettingsMetrics.listBarTextPadding,
            y: ((bounds.height - height) / 2).rounded(),
            width: bounds.width - 2 * SettingsMetrics.listBarTextPadding,
            height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering && isEnabled {
            let radius = CGFloat(DesignTokens.radii.xs)
            NSColor(theme.palette.bgHover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if case .icon(let path) = content {
            let size = SettingsMetrics.listBarIconSize
            let rect = NSRect(
                x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            SettingsGlyph.stroke(
                path, box: SettingsMetrics.listBarIconBox, in: rect, width: SettingsMetrics.listBarIconStroke,
                color: NSColor(ink))
        }
    }
}

/// One row of a Settings list: what leads it (an icon, a checkbox), its name, the path under it, a note at the end,
/// and the handle it is dragged by.
final class SettingsListRow: ThemedView {
    struct Spec {
        var name: String
        /// What the row stands for (a column's key): the selection follows it when the rows are reordered.
        var key: String?
        var path: String?
        /// Nothing is at `path` any more: the row says so.
        var missing = false
        /// `.settings-list-trailing-note` ("Always first").
        var trailingNote: String?
        var draggable = true
        var disabled = false
        var leading: NSView?
        var height = SettingsMetrics.listRowHeight
    }

    let spec: Spec
    let nameText = FlushTextField(labelWithString: "")
    let pathText = FlushTextField(labelWithString: "")
    let noteText = FlushTextField(labelWithString: "")
    var isSelected = false { didSet { applyColors() } }
    var listFocused = false { didSet { applyColors() } }
    var isDragging = false { didSet { alphaValue = isDragging ? SettingsMetrics.draggingOpacity : 1 } }
    /// The drop line: above (`before`) or under (`after`) the row.
    var dropSide: DropSide? { didSet { needsDisplay = true } }
    var drawsTopLine = false { didSet { needsDisplay = true } }

    enum DropSide { case before, after }

    init(_ spec: Spec, theme: Theme) {
        self.spec = spec
        super.init(theme: theme)
        nameText.stringValue = spec.name
        nameText.font = ThemeFonts.sans(DesignTokens.typeScale.body)
        nameText.lineBreakMode = .byTruncatingTail
        nameText.setAccessibilityIdentifier("settings.list.name")
        addSubview(nameText)
        if let leading = spec.leading { addSubview(leading) }
        if spec.path != nil {
            pathText.font = ThemeFonts.sans(DesignTokens.typeScale.small)
            pathText.lineBreakMode = .byTruncatingTail
            pathText.toolTip = spec.path
            pathText.setAccessibilityIdentifier("settings.list.path")
            addSubview(pathText)
        }
        if let note = spec.trailingNote {
            noteText.stringValue = note
            noteText.font = ThemeFonts.sans(DesignTokens.typeScale.small)
            addSubview(noteText)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(spec.name)
        setAccessibilityIdentifier("settings.list.row")
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyTheme(_ theme: Theme) {
        super.applyTheme(theme)
        applyColors()
    }

    /// Selected in a list that has the keyboard: the accent fill of every list's selection.
    var showsAccent: Bool { isSelected && listFocused }

    private func applyColors() {
        let palette = theme.palette
        let background = showsAccent ? theme.accent.selectionBg : palette.settingsPageBg
        let primary =
            showsAccent
            ? theme.accent.onSelection : spec.disabled ? palette.settingsLabelSecondary : palette.textPrimary
        let secondary = showsAccent ? theme.accent.onSelection : palette.settingsLabelSecondary
        nameText.textColor = NSColor(primary.flattened(over: background))
        noteText.textColor = NSColor(palette.settingsLabelSecondary.flattened(over: background))
        if let path = spec.path {
            let attributed = NSMutableAttributedString()
            let font = ThemeFonts.sans(DesignTokens.typeScale.small)
            if spec.missing {
                attributed.append(
                    NSAttributedString(
                        string: SettingsText.missingApp,
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor(
                                (showsAccent ? theme.accent.onSelection : palette.dangerText).flattened(
                                    over: background)),
                        ]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributed.append(
                NSAttributedString(
                    string: path,
                    attributes: [.font: font, .foregroundColor: NSColor(secondary.flattened(over: background))]))
            attributed.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            pathText.attributedStringValue = attributed
        }
        (spec.leading as? FavoriteIconButton)?.onSelection = showsAccent
        needsDisplay = true
    }

    /// The handle's place at the row's end.
    private var handleRect: NSRect {
        let size = SettingsMetrics.dragHandleSize
        return NSRect(
            x: bounds.width - SettingsMetrics.listRowPadding - size.width,
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let padding = SettingsMetrics.listRowPadding
        var x = padding
        if let leading = spec.leading {
            let size = leading.frame.size
            leading.frame = NSRect(
                x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + SettingsMetrics.listRowGap
        }
        var end = bounds.width - padding
        if spec.draggable { end -= SettingsMetrics.dragHandleSize.width + SettingsMetrics.listRowGap }
        if spec.trailingNote != nil {
            let width = noteText.intrinsicContentSize.width
            let height = noteText.intrinsicContentSize.height
            noteText.frame = NSRect(
                x: end - width, y: ((bounds.height - height) / 2).rounded(), width: width,
                height: height)
            end -= width + SettingsMetrics.listRowGap
        }
        let nameHeight = nameText.intrinsicContentSize.height
        let pathHeight = spec.path == nil ? 0 : pathText.intrinsicContentSize.height
        let top = ((bounds.height - nameHeight - pathHeight) / 2).rounded()
        let width = max(0, end - x)
        nameText.frame = NSRect(x: x, y: top, width: width, height: nameHeight)
        if spec.path != nil {
            pathText.frame = NSRect(
                x: x, y: top + nameHeight, width: width, height: pathHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        if isSelected {
            NSColor(listFocused ? theme.accent.selectionBg : palette.bgActiveInactive).setFill()
            bounds.fill()
        }
        if drawsTopLine {
            NSColor(palette.settingsSeparator).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: SettingsMetrics.separatorWidth).fill()
        }
        if let dropSide {
            NSColor(theme.accent.solid).setFill()
            let width = SettingsMetrics.dropLineWidth
            NSRect(x: 0, y: dropSide == .before ? 0 : bounds.height - width, width: bounds.width, height: width).fill()
        }
        if spec.draggable {
            SettingsGlyph.stroke(
                SettingsMetrics.dragHandlePath, box: SettingsMetrics.dragHandleSize.width, in: handleRect,
                width: SettingsMetrics.dragHandleStroke,
                color: NSColor(showsAccent ? theme.accent.onSelection : palette.textTertiary))
        }
    }
}

/// A list as macOS draws one in Settings (`SettingsList`, `ColumnList`): rows to select, drag into a new order, or
/// remove, and a bar of buttons under it. The list takes the keyboard; the selected row is its focus.
final class SettingsListView: ThemedView, SettingsListBlock {
    enum Keys {
        /// Favorites, Always in Open With: Return changes, ⌫ and Delete remove.
        case items
        /// Columns: Space checks the row.
        case columns
    }

    let label: String
    let keys: Keys
    /// A row before the others that can't be selected or moved (the columns' Name).
    private let fixedRow: SettingsListRow?
    private(set) var rows: [SettingsListRow] = []
    private(set) var selectedIndex: Int?
    /// The selected row's key, when rows have keys (ColumnList's selectedKey).
    private var selectedKey: String?
    private(set) var draggedIndex: Int?
    private(set) var dropIndex: Int?
    let bar = ThemedView()
    private(set) var barButtons: [SettingsListBarButton] = []
    private var barLayout: [BarPart] = []
    var drawsSeparator = true { didSet { needsDisplay = true } }

    var onMove: (Int, Int) -> Void = { _, _ in }
    var onChange: (Int) -> Void = { _ in }
    var onRemove: (Int) -> Void = { _ in }
    var onToggle: (Int) -> Void = { _ in }
    /// The bar's buttons follow the selection.
    var onSelectionChange: () -> Void = {}

    enum BarPart {
        case button(SettingsListBarButton)
        case divider
        case spacer
    }

    init(label: String, keys: Keys, fixedRow: SettingsListRow.Spec? = nil, theme: Theme) {
        self.label = label
        self.keys = keys
        self.fixedRow = fixedRow.map { SettingsListRow($0, theme: theme) }
        super.init(theme: theme)
        if let row = self.fixedRow {
            row.setAccessibilityRole(.row)
            row.setAccessibilityEnabled(false)
            addSubview(row)
        }
        bar.edges = [.top: { $0.palette.settingsSeparator }]
        bar.setAccessibilityIdentifier("settings.listBar")
        addSubview(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("settings.list")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// The list or a control in one of its rows (a favorite's icon button) has the keyboard: `:focus-within`.
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// A control in a row took or left the keyboard: the selection's look follows.
    func focusMoved() { syncRows() }

    /// The list takes the keyboard on its selected row, or on its first when none is (the roving tab stop): that row
    /// is selected.
    override func becomeFirstResponder() -> Bool {
        defer {
            if selectedIndex == nil, !rows.isEmpty { select(0) } else { syncRows() }
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.syncRows() } }
        return true
    }

    func setBar(_ parts: [BarPart]) {
        for button in barButtons { button.removeFromSuperview() }
        barLayout = parts
        barButtons = parts.compactMap {
            if case .button(let button) = $0 { return button }
            return nil
        }
        for button in barButtons { bar.addSubview(button) }
        needsLayout = true
    }

    /// The rows as they are now: a keyed selection follows its row; otherwise the selection stays where it was, on
    /// the last row when rows were removed under it.
    func setRows(_ specs: [SettingsListRow.Spec]) {
        // The rows are made anew, and the control that goes takes the keyboard with it: a favorite's icon button, given
        // it back as the grid closes, just before its new icon comes here.
        let window = window
        let controlRow = (window?.firstResponder as? NSView).flatMap { responder in
            rows.firstIndex { responder.isDescendant(of: $0) }
        }
        for row in rows { row.removeFromSuperview() }
        rows = specs.map { SettingsListRow($0, theme: theme) }
        for row in rows { addSubview(row, positioned: .below, relativeTo: bar) }
        if let selectedKey, let index = rows.firstIndex(where: { $0.spec.key == selectedKey }) {
            selectedIndex = index
        } else if let selectedIndex, selectedIndex >= rows.count {
            self.selectedIndex = rows.isEmpty ? nil : rows.count - 1
        }
        selectedKey = selectedIndex.flatMap { rows[$0].spec.key }
        if let controlRow, let window {
            let control = rows.indices.contains(controlRow) ? rows[controlRow].spec.leading : nil
            window.makeFirstResponder(control?.acceptsFirstResponder == true ? control : self)
        }
        syncRows()
        onSelectionChange()
    }

    func select(_ index: Int?) {
        selectedIndex = index.flatMap { rows.indices.contains($0) ? $0 : nil }
        selectedKey = selectedIndex.flatMap { rows[$0].spec.key }
        syncRows()
        onSelectionChange()
    }

    private func syncRows() {
        let focused = hasFocus
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selectedIndex
            row.listFocused = focused
            row.isDragging = index == draggedIndex
            row.dropSide =
                draggedIndex != nil && dropIndex == index && draggedIndex != index
                ? ((draggedIndex ?? 0) < index ? .after : .before) : nil
            row.drawsTopLine = index > 0 || fixedRow != nil
        }
    }

    // MARK: Layout

    func arrange(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        if let fixedRow {
            fixedRow.frame = NSRect(x: 0, y: y, width: width, height: fixedRow.spec.height)
            y += fixedRow.spec.height
        }
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.spec.height)
            y += row.spec.height
        }
        bar.frame = NSRect(x: 0, y: y, width: width, height: SettingsMetrics.listBarHeight)
        layoutBar(width: width)
        y += SettingsMetrics.listBarHeight
        return y
    }

    private func layoutBar(width: CGFloat) {
        let height = SettingsMetrics.listBarButtonSize.height
        // Centred under the bar's top line, which is inside its 28.
        let line = SettingsMetrics.separatorWidth
        let top = line + (SettingsMetrics.listBarHeight - line - height) / 2
        let fixed = barLayout.reduce(CGFloat(0)) { total, part in
            switch part {
            case .button(let button): total + button.preferredWidth
            case .divider: total + SettingsMetrics.separatorWidth + 2 * SettingsMetrics.listBarDividerMargin
            case .spacer: total
            }
        }
        let spacers = barLayout.filter {
            if case .spacer = $0 { return true }
            return false
        }.count
        let spare = max(0, width - 2 * SettingsMetrics.listBarPadding - fixed) / CGFloat(max(1, spacers))
        var x = SettingsMetrics.listBarPadding
        for part in barLayout {
            switch part {
            case .button(let button):
                button.frame = NSRect(x: x, y: top, width: button.preferredWidth, height: height)
                x += button.preferredWidth
            case .divider:
                x +=
                    SettingsMetrics.listBarDividerMargin + SettingsMetrics.separatorWidth
                    + SettingsMetrics.listBarDividerMargin
            case .spacer:
                x += spare
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The bar's divider.
        var x = SettingsMetrics.listBarPadding
        for part in barLayout {
            switch part {
            case .button(let button): x = button.frame.maxX
            case .divider:
                NSColor(theme.palette.settingsSeparator).setFill()
                let height = SettingsMetrics.listBarDividerHeight
                NSRect(
                    x: x + SettingsMetrics.listBarDividerMargin,
                    y: bar.frame.minY + ((SettingsMetrics.listBarHeight - height) / 2).rounded(),
                    width: SettingsMetrics.separatorWidth, height: height
                ).fill()
                x += 2 * SettingsMetrics.listBarDividerMargin + SettingsMetrics.separatorWidth
            case .spacer: break
            }
        }
        if drawsSeparator {
            NSColor(theme.palette.settingsSeparator).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let index = selectedIndex ?? (rows.isEmpty ? nil : 0) else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = event.keyCode
        if code == 125 || code == 126 {
            let target = index + (code == 126 ? -1 : 1)
            if flags.contains(.option) || flags.contains(.command) {
                move(index, to: target)
            } else if rows.indices.contains(target) {
                select(target)
                scrollRowToVisible(target)
            }
        } else if keys == .items, code == 36 || code == 76 {
            onChange(index)
        } else if keys == .items, code == 51 || code == 117 {
            onRemove(index)
        } else if keys == .columns, code == 49 {
            onToggle(index)
        } else {
            super.keyDown(with: event)
        }
    }

    /// Moves a row to `target` and selects it there; no change past the ends.
    func move(_ index: Int, to target: Int) {
        guard index != target, rows.indices.contains(target), rows.indices.contains(index) else { return }
        selectedIndex = target
        selectedKey = rows[index].spec.key
        onMove(index, target)
        syncRows()
        onSelectionChange()
    }

    private func scrollRowToVisible(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].scrollToVisible(rows[index].bounds)
    }

    // MARK: Pointer

    private func rowIndex(at point: NSPoint) -> Int? {
        rows.firstIndex { $0.frame.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        select(index)
        if event.clickCount == 2 {
            if keys == .items { onChange(index) }
            return
        }
        guard rows[index].spec.draggable else { return }
        trackDrag(from: index, start: point)
    }

    /// Follows a drag of a row: it is dimmed, the row under the pointer is marked on the side it would go to, and
    /// releasing moves it there.
    private func trackDrag(from index: Int, start: NSPoint) {
        var dragging = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if dragging, let target = dropIndex { move(index, to: target) }
                break
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) > SettingsMetrics.dragThreshold {
                dragging = true
                draggedIndex = index
            }
            if dragging {
                dropIndex = rowIndex(at: point) ?? dropIndex
                syncRows()
            }
        }
        draggedIndex = nil
        dropIndex = nil
        syncRows()
    }

    /// A drag of row `from` dropped on row `to`, as the drag ends (tests and the automation).
    func drop(_ from: Int, on to: Int) {
        move(from, to: to)
    }
}
