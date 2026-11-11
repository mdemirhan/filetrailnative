import AppKit
import FTFoundation

/// A full-width row of a card that may draw the line under itself.
@MainActor
protocol SettingsListBlock: SettingsBlock {
    var drawsSeparator: Bool { get set }
}

/// A button of the bar under a list. Add, Remove, Move Up and Move Down are segments of the system's segmented
/// control, one control for each pair; the others are the system's small push buttons.
@MainActor
final class SettingsListBarButton {
    enum Kind: Equatable {
        case add, remove, moveUp, moveDown
        case text(String)
    }

    let kind: Kind
    let tooltip: String?
    /// What it does, with the selected row's name in it ("Remove Desktop").
    var label: String { didSet { changed() } }
    var isEnabled = true { didSet { changed() } }
    var onPress: () -> Void = {}
    /// Tells the bar that shows it.
    fileprivate var changed: () -> Void = {}

    init(_ kind: Kind, label: String, tooltip: String? = nil) {
        self.kind = kind
        self.label = label
        self.tooltip = tooltip
    }

    /// Clicks it, as a click on it does.
    func press() {
        guard isEnabled else { return }
        onPress()
    }

    /// The segment's symbol.
    fileprivate var image: NSImage? {
        let symbol: String
        switch kind {
        case .add: symbol = "plus"
        case .remove: symbol = "minus"
        case .moveUp: symbol = "chevron.up"
        case .moveDown: symbol = "chevron.down"
        case .text: return nil
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }
}

/// The bar under a list: segmented controls and push buttons, left to right, a spacer taking the room left.
final class SettingsListBar: ThemedView {
    enum Part {
        /// Buttons side by side as the segments of one control.
        case segments([SettingsListBarButton])
        case button(SettingsListBarButton)
        case spacer
    }

    private(set) var parts: [Part] = []
    private var controls: [NSControl?] = []

    override init(frame: NSRect = .zero, theme: Theme = AppearanceModel.shared.theme) {
        super.init(frame: frame, theme: theme)
        edges = [.top: { $0.palette.settingsSeparator }]
        setAccessibilityIdentifier("settings.listBar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Every button of the bar.
    var buttons: [SettingsListBarButton] {
        parts.flatMap { part -> [SettingsListBarButton] in
            switch part {
            case .segments(let buttons): buttons
            case .button(let button): [button]
            case .spacer: []
            }
        }
    }

    func set(_ parts: [Part]) {
        for control in controls { control?.removeFromSuperview() }
        self.parts = parts
        controls = parts.map { part -> NSControl? in
            switch part {
            case .segments(let buttons):
                let control = NSSegmentedControl()
                control.segmentStyle = .smallSquare
                control.trackingMode = .momentary
                control.controlSize = .small
                control.segmentCount = buttons.count
                for (index, button) in buttons.enumerated() {
                    control.setImage(button.image, forSegment: index)
                    control.setImageScaling(.scaleProportionallyDown, forSegment: index)
                    control.setToolTip(button.tooltip, forSegment: index)
                    control.setWidth(SettingsMetrics.listBarSegmentWidth, forSegment: index)
                }
                control.target = self
                control.action = #selector(segmentPressed(_:))
                control.refusesFirstResponder = true
                control.setAccessibilityIdentifier("settings.listBar.segments")
                return control
            case .button(let button):
                let control = NSButton(title: button.title, target: self, action: #selector(buttonPressed(_:)))
                control.bezelStyle = .push
                control.controlSize = .small
                control.font = ThemeFonts.sans(DesignTokens.typeScale.small)
                control.refusesFirstResponder = true
                control.toolTip = button.tooltip
                control.setAccessibilityIdentifier("settings.listBar.button")
                return control
            case .spacer:
                return nil
            }
        }
        for control in controls { if let control { addSubview(control) } }
        for button in buttons { button.changed = { [weak self] in self?.sync() } }
        sync()
        needsLayout = true
    }

    /// The controls show their buttons' state.
    private func sync() {
        for (part, control) in zip(parts, controls) {
            switch part {
            case .segments(let buttons):
                guard let control = control as? NSSegmentedControl else { continue }
                for (index, button) in buttons.enumerated() { control.setEnabled(button.isEnabled, forSegment: index) }
            case .button(let button):
                control?.isEnabled = button.isEnabled
                control?.setAccessibilityLabel(button.label)
            case .spacer:
                break
            }
        }
    }

    @objc private func segmentPressed(_ sender: NSSegmentedControl) {
        guard let index = controls.firstIndex(where: { $0 === sender }),
            case .segments(let buttons) = parts[index], buttons.indices.contains(sender.selectedSegment)
        else { return }
        buttons[sender.selectedSegment].press()
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let index = controls.firstIndex(where: { $0 === sender }), case .button(let button) = parts[index] else {
            return
        }
        button.press()
    }

    override func layout() {
        super.layout()
        // Centred under the bar's top line.
        let line = SettingsMetrics.separatorWidth
        let fixed = controls.reduce(CGFloat(0)) { $0 + ($1.map { ceil($0.fittingSize.width) } ?? 0) }
        let gaps = CGFloat(max(0, controls.compactMap { $0 }.count - 1)) * SettingsMetrics.listBarGap
        let spacers = CGFloat(max(1, parts.filter { if case .spacer = $0 { true } else { false } }.count))
        let spare = max(0, bounds.width - 2 * SettingsMetrics.listBarPadding - fixed - gaps) / spacers
        var x = SettingsMetrics.listBarPadding
        for control in controls {
            guard let control else {
                x += spare
                continue
            }
            let size = control.fittingSize
            control.frame = NSRect(
                x: x, y: (line + (bounds.height - line - size.height) / 2).rounded(), width: ceil(size.width),
                height: size.height)
            x += ceil(size.width) + SettingsMetrics.listBarGap
        }
    }
}

extension SettingsListBarButton {
    fileprivate var title: String {
        if case .text(let text) = kind { return text }
        return ""
    }
}

/// One row of a Settings list: what leads it (an icon, a checkbox), its name, the path under it, a note at the end,
/// and the handle it is dragged by. The table's row under it draws the selection.
final class SettingsListRow: ThemedView {
    struct Spec {
        var name: String
        /// What the row stands for (a column's key): the selection follows it when the rows are reordered.
        var key: String?
        var path: String?
        /// Nothing is at `path` any more: the row says so.
        var missing = false
        /// The note at the row's end ("Always first").
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
    private let handle = NSImageView()
    var isSelected = false { didSet { if isSelected != oldValue { applyColors() } } }
    var listFocused = false { didSet { if listFocused != oldValue { applyColors() } } }
    var drawsTopLine = false { didSet { needsDisplay = true } }

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
        if spec.draggable {
            handle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
            handle.symbolConfiguration = .init(pointSize: SettingsMetrics.dragHandleSize, weight: .regular)
            addSubview(handle)
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
        let primary =
            showsAccent
            ? theme.accent.onSelection : spec.disabled ? palette.settingsLabelSecondary : palette.textPrimary
        let secondary = showsAccent ? theme.accent.onSelection : palette.settingsLabelSecondary
        nameText.textColor = NSColor(primary)
        noteText.textColor = NSColor(palette.settingsLabelSecondary)
        handle.contentTintColor = NSColor(showsAccent ? theme.accent.onSelection : palette.textTertiary)
        if let path = spec.path {
            let attributed = NSMutableAttributedString()
            let font = ThemeFonts.sans(DesignTokens.typeScale.small)
            if spec.missing {
                attributed.append(
                    NSAttributedString(
                        string: SettingsText.missingApp,
                        attributes: [
                            .font: font,
                            .foregroundColor: NSColor(showsAccent ? theme.accent.onSelection : palette.dangerText),
                        ]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributed.append(
                NSAttributedString(
                    string: path,
                    attributes: [.font: font, .foregroundColor: NSColor(secondary)]))
            attributed.addAttribute(
                .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
            pathText.attributedStringValue = attributed
        }
        (spec.leading as? FavoriteIconButton)?.onSelection = showsAccent
        needsDisplay = true
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
        if spec.draggable {
            let size = handle.intrinsicContentSize
            handle.frame = NSRect(
                x: end - size.width, y: ((bounds.height - size.height) / 2).rounded(), width: size.width,
                height: size.height)
            end -= size.width + SettingsMetrics.listRowGap
        }
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
        guard drawsTopLine else { return }
        NSColor(theme.palette.settingsSeparator).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: SettingsMetrics.separatorWidth).fill()
    }
}

/// The system's table under a Settings list: its keys go to the list first.
final class SettingsListTable: NSTableView {
    weak var list: SettingsListView?

    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if list?.handleKey(event) != true { super.keyDown(with: event) }
    }

    /// A click on a row, its name or its path gives the table the keyboard, as a click on any list does.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        list?.tookKeyboard()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        DispatchQueue.main.async { [weak self] in self?.list?.focusMoved() }
        return true
    }
}

/// A table row that draws a Settings list's selection: the accent while the list has the keyboard, gray otherwise.
final class SettingsListRowShell: NSTableRowView {
    weak var list: SettingsListView?

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard let list else { return }
        let theme = list.theme
        NSColor(list.hasFocus ? theme.accent.selectionBg : theme.palette.bgActiveInactive).setFill()
        bounds.fill()
    }
}

/// A list as macOS draws one in Settings: the system's table, whose rows are selected, dragged into a new order, or
/// removed, and a bar of buttons under it. The table takes the keyboard; the selected row is its focus.
final class SettingsListView: ThemedView, SettingsListBlock, NSTableViewDataSource, NSTableViewDelegate {
    enum Keys {
        /// Favorites, First in Open With: Return changes, ⌫ and Delete remove.
        case items
        /// Columns: Space checks the row.
        case columns
    }

    private static let dragType = NSPasteboard.PasteboardType("com.filetrail.native.settings-list-row")

    let label: String
    let keys: Keys
    let table = SettingsListTable()
    /// A row before the others that can't be selected or moved (the columns' Name).
    let fixedRow: SettingsListRow?
    private(set) var rows: [SettingsListRow] = []
    private(set) var selectedIndex: Int?
    /// The selected row's key, when rows have keys.
    private var selectedKey: String?
    let bar = SettingsListBar()
    var drawsSeparator = true { didSet { needsDisplay = true } }
    /// The selection is being set here, not by the table.
    private var settingSelection = false

    var onMove: (Int, Int) -> Void = { _, _ in }
    var onChange: (Int) -> Void = { _ in }
    var onRemove: (Int) -> Void = { _ in }
    var onToggle: (Int) -> Void = { _ in }
    /// The bar's buttons follow the selection.
    var onSelectionChange: () -> Void = {}

    init(label: String, keys: Keys, fixedRow: SettingsListRow.Spec? = nil, theme: Theme) {
        self.label = label
        self.keys = keys
        self.fixedRow = fixedRow.map { SettingsListRow($0, theme: theme) }
        super.init(theme: theme)
        if let row = self.fixedRow {
            row.setAccessibilityEnabled(false)
            row.drawsTopLine = false
        }
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsEmptySelection = true
        table.list = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel(label)
        table.setAccessibilityIdentifier("settings.list.table")
        addSubview(table)
        addSubview(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("settings.list")
        table.reloadData()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The table's rows before the list's own: the fixed row.
    private var offset: Int { fixedRow == nil ? 0 : 1 }

    var barButtons: [SettingsListBarButton] { bar.buttons }

    /// The table or a control in one of its rows (a favorite's icon button) has the keyboard.
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// A control in a row took or left the keyboard: the selection's look follows.
    func focusMoved() { syncRows() }

    /// The table took the keyboard: its selected row has it, or its first when none is (the roving tab stop).
    func tookKeyboard() {
        if selectedIndex == nil, !rows.isEmpty { select(0) } else { syncRows() }
    }

    func setBar(_ parts: [SettingsListBar.Part]) {
        bar.set(parts)
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
        let tableHadKeyboard = window?.firstResponder === table
        rows = specs.map { SettingsListRow($0, theme: theme) }
        if let selectedKey, let index = rows.firstIndex(where: { $0.spec.key == selectedKey }) {
            selectedIndex = index
        } else if let selectedIndex, selectedIndex >= rows.count {
            self.selectedIndex = rows.isEmpty ? nil : rows.count - 1
        }
        selectedKey = selectedIndex.flatMap { rows[$0].spec.key }
        reload()
        if let controlRow, let window {
            let control = rows.indices.contains(controlRow) ? rows[controlRow].spec.leading : nil
            window.makeFirstResponder(control?.acceptsFirstResponder == true ? control : table)
        } else if tableHadKeyboard, window?.firstResponder !== table {
            window?.makeFirstResponder(table)
        }
        syncRows()
        onSelectionChange()
    }

    /// The table shows the rows, every one of them made at once (the page, not the table, scrolls), and the selection.
    private func reload() {
        settingSelection = true
        table.reloadData()
        makeRows()
        showSelection()
        settingSelection = false
    }

    /// Every row's view in the table, on screen or not.
    private func makeRows() {
        for row in 0..<table.numberOfRows { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
    }

    private func showSelection() {
        let rows = selectedIndex.map { IndexSet(integer: $0 + offset) } ?? IndexSet()
        if table.selectedRowIndexes != rows { table.selectRowIndexes(rows, byExtendingSelection: false) }
    }

    func select(_ index: Int?) {
        selectedIndex = index.flatMap { rows.indices.contains($0) ? $0 : nil }
        selectedKey = selectedIndex.flatMap { rows[$0].spec.key }
        settingSelection = true
        showSelection()
        settingSelection = false
        syncRows()
        onSelectionChange()
    }

    private func syncRows() {
        let focused = hasFocus
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selectedIndex
            row.listFocused = focused
            row.drawsTopLine = index > 0 || fixedRow != nil
        }
        table.enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

    // MARK: Layout

    func arrange(width: CGFloat) -> CGFloat {
        let height = ([fixedRow].compactMap { $0 } + rows).reduce(0) { $0 + $1.spec.height }
        table.tableColumns.first?.width = width
        table.frame = NSRect(x: 0, y: 0, width: width, height: height)
        makeRows()
        bar.frame = NSRect(x: 0, y: height, width: width, height: SettingsMetrics.listBarHeight)
        return height + SettingsMetrics.listBarHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if drawsSeparator {
            NSColor(theme.palette.settingsSeparator).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    // MARK: Table

    private func row(_ tableRow: Int) -> SettingsListRow? {
        if tableRow < offset { return fixedRow }
        let index = tableRow - offset
        return rows.indices.contains(index) ? rows[index] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { offset + rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        self.row(row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let shell = SettingsListRowShell()
        shell.list = self
        return shell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        self.row(row)?.spec.height ?? SettingsMetrics.listRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row >= offset }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !settingSelection else { return }
        let row = table.selectedRow
        selectedIndex = row >= offset ? row - offset : nil
        selectedKey = selectedIndex.flatMap { rows[$0].spec.key }
        syncRows()
        onSelectionChange()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let index = table.clickedRow - offset
        if keys == .items, rows.indices.contains(index) { onChange(index) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// The list's own keys: the arrows select, ⌥ or ⌘ with them moves the row; Return changes it, ⌫ removes it, Space
    /// checks it. True when the key was one of them.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let index = selectedIndex ?? (rows.isEmpty ? nil : 0) else { return false }
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
            return false
        }
        return true
    }

    /// Moves a row to `target` and selects it there; no change past the ends.
    func move(_ index: Int, to target: Int) {
        guard index != target, rows.indices.contains(target), rows.indices.contains(index) else { return }
        selectedIndex = target
        selectedKey = rows[index].spec.key
        onMove(index, target)
        settingSelection = true
        showSelection()
        settingSelection = false
        syncRows()
        onSelectionChange()
    }

    private func scrollRowToVisible(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].scrollToVisible(rows[index].bounds)
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let index = row - offset
        guard rows.indices.contains(index), rows[index].spec.draggable else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(index), forType: Self.dragType)
        return item
    }

    private func draggedIndex(_ info: any NSDraggingInfo) -> Int? {
        guard (info.draggingSource as? NSTableView) === table,
            let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
            let index = Int(text), rows.indices.contains(index)
        else { return nil }
        return index
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard draggedIndex(info) != nil else { return [] }
        // Between rows, never above the fixed one.
        tableView.setDropRow(max(row, offset), dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let from = draggedIndex(info),
            let target = Self.dropTarget(from: from, aboveTableRow: row, offset: offset, count: rows.count)
        else { return false }
        drop(from, on: target)
        return true
    }

    /// Where row `from` goes when it is dropped in the gap above table row `row` (the table's rows start with
    /// `offset` fixed ones; `row` past the last is the gap at the end); nil when it stays where it is.
    static func dropTarget(from: Int, aboveTableRow row: Int, offset: Int, count: Int) -> Int? {
        // The gap is before list row `row - offset` while the dragged row is still in its place.
        var target = max(0, row - offset)
        if from < target { target -= 1 }
        target = min(target, count - 1)
        return target == from ? nil : target
    }

    /// A drag of row `from` dropped on row `to`, as the drag ends (tests and the automation).
    func drop(_ from: Int, on to: Int) {
        move(from, to: to)
    }
}
