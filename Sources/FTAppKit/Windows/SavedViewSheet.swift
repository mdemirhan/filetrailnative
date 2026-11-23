// What Tab View Options and Window View Options share: a sheet laid out as Folder View Options is
import AppKit
import FTFoundation

/// A sheet of rows laid out as Folder View Options lays out its own: a header with a symbol, a title and what it is
/// for; the name, typed or chosen among the saved views' to save over one; groups titled as Settings titles them, each
/// a card of rows with a hairline between each two; each row a checkbox titled with its setting (or a name) and its
/// control in a column that starts at the same place in every row; a line saying what is kept; and the buttons.
///
/// Every control is made once, with the sheet. A change shows itself in the controls it touches, in place (each
/// sheet's `refresh`): a row that doesn't apply is hidden or dimmed, never taken away, so a field keeps what is typed in
/// it and the keyboard stays where it is. The sheet lays out again only when its height changed. A sheet taller than
/// the room under the toolbar scrolls, its buttons staying at its foot, so the window never cuts it. Tab goes along
/// each row, then down.
@MainActor
class SavedViewSheet: DialogPanelView {
    class var width: Double { FolderViewPopover.width + 40 }
    static let margin = 20.0
    /// A sheet with a sidebar: its width, and the gap between it and the rows beside it.
    static let sidebarWidth = 176.0
    static let sidebarGap = 20.0
    /// Room left under the sheet, above the window's bottom edge.
    static let bottomInset = 24.0
    var contentWidth: Double { Self.width - 2 * Self.margin }
    /// How wide a card of rows is: the sheet's content, or the room beside the sidebar.
    var rowsWidth: Double { contentWidth }
    /// Where every row's control starts, from the row's left edge: Folder View Options' column, or one with room for
    /// longer titles.
    var controlColumn: Double { FolderViewPopover.controlColumn }
    /// What the sheet's controls are identified by: `tabViewOptions`, `windowViewOptions`.
    let identifierPrefix: String
    /// "tab view", "window view": what the sheet saves, as its words say it.
    let kind: String

    let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = SheetDocumentView()
    private var footerView: NSView?
    /// A hairline over the buttons while the rows scroll under them.
    private let footerLine = NSBox()
    /// The rows' height and the footer's, as last measured.
    private var rowsHeight = 0.0
    private var footerHeight = 0.0

    let nameBox: SheetNameBox
    /// Under the name while another saved view has it: Save replaces that one.
    let nameNote = NSTextField(wrappingLabelWithString: "")
    /// What the saved view keeps, a part for each, under the rows.
    let summary = NSTextField(wrappingLabelWithString: "")
    let saveButton = ClosureButton(title: "Save", action: {})
    let cancelButton = ClosureButton(title: "Cancel", action: {})

    /// Cancel, Escape, ⌘.
    var onCancel: () -> Void = {}
    /// All Tab Views… or All Window Views….
    var onManage: () -> Void = {}

    /// `names`: the saved views' names, offered in the name's list; `placeholder`: the name's prompt.
    init(identifierPrefix: String, kind: String, names: [String], name: String, placeholder: String) {
        self.identifierPrefix = identifierPrefix
        self.kind = kind
        nameBox = SheetNameBox(names: names)
        super.init(cornerRadius: GlassSurface.sheetRadius)
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityIdentifier(identifierPrefix)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: 4, right: Self.margin)
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        addSubview(scroll)
        footerLine.boxType = .separator
        addSubview(footerLine)

        nameBox.stringValue = name
        nameBox.placeholderString = placeholder
        nameBox.setAccessibilityIdentifier("\(identifierPrefix).name")
        nameBox.setAccessibilityLabel("Name")
        nameBox.toolTip = "Type a name, or choose a \(kind) to save over it"
        nameBox.changed = { [weak self] text in self?.nameTyped(text) }
        nameBox.picked = { [weak self] index in self?.namePicked(index) }
        for note in [nameNote, summary] {
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = contentWidth
        }
        nameNote.setAccessibilityIdentifier("\(identifierPrefix).nameNote")
        saveButton.run = { [weak self] _ in self?.save() }
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("\(identifierPrefix).save")
        cancelButton.run = { [weak self] _ in self?.onCancel() }
        cancelButton.bezelStyle = .push
        cancelButton.setAccessibilityIdentifier("\(identifierPrefix).cancel")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var initialResponder: NSView? { nameBox }

    // MARK: What each sheet says

    /// Whether Save can save now.
    var canSave: Bool { false }
    /// The name another saved view has: Save replaces that one. Nil when the name is free or the one being edited.
    var takenName: String? { nil }
    /// The name as typed, kept in the draft.
    func nameTyped(_ name: String) {}
    /// A saved view chosen from the name's list, by its place in it.
    func namePicked(_ index: Int) {}
    /// Saves what the sheet shows.
    func save() {}

    // MARK: The keyboard

    /// Escape and ⌘. cancel; Return saves; Space presses the focused button, checks the focused checkbox or opens
    /// the focused pop-up, as in the app's alerts (the window keeps Space for itself otherwise). Return and Escape are
    /// the name list's own while it is open.
    override func handleKey(_ event: NSEvent) -> Bool {
        guard !nameBox.isListOpen else { return false }
        if KeyCode.isCancel(event) {
            // Escape while text is being composed cancels the composition, not the sheet.
            if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            onCancel()
            return true
        }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, event.charactersIgnoringModifiers == " ", let button = window?.firstResponder as? NSButton,
            button.isDescendant(of: self)
        {
            if button.isEnabled { button.performClick(nil) }
            return true
        }
        guard KeyCode.isReturn(event), plain else { return false }
        guard canSave else {
            NSSound.beep()
            return true
        }
        save()
        return true
    }

    /// Tab goes round the sheet's controls, but not while the name list is open: it is the list's.
    override func cycleFocus(backward: Bool) {
        guard !nameBox.isListOpen else { return }
        super.cycleFocus(backward: backward)
    }

    /// Along each row, left to right, then down: a row's controls are centered on one line, though not all of a
    /// height. A hidden row has nothing in it; a segmented control counts as a control. A sidebar's list comes right
    /// after the Name, before the rows of the part it shows, as its arrow keys choose the part.
    override func focusOrder() -> [NSView] {
        var found = Self.focusable(in: self)
        var sidebars: [NSView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let segmented = view as? NSSegmentedControl, segmented.isEnabled { found.append(segmented) }
            if let sidebar = view as? SheetSidebar {
                sidebars.append(sidebar.list)
                return
            }
            for child in view.subviews { visit(child) }
        }
        visit(self)
        layoutSubtreeIfNeeded()
        let placed = found.map { ($0, $0.convert($0.bounds, to: self)) }.sorted { $0.1.midY < $1.1.midY }
        // Rows: controls whose middles are within a few points of the row's first one.
        var rows: [[(NSView, NSRect)]] = []
        for item in placed {
            if let first = rows.last?.first, abs(item.1.midY - first.1.midY) <= 8 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        var order = rows.flatMap { row in row.sorted { $0.1.minX < $1.1.minX }.map(\.0) }
        let afterName = order.firstIndex(of: nameBox).map { $0 + 1 } ?? 0
        order.insert(contentsOf: sidebars, at: afterName)
        return order
    }

    /// A control Tab lands on is scrolled into view.
    override func moveKeyboard(to view: NSView) {
        super.moveKeyboard(to: view)
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -8))
    }

    // MARK: Size and layout

    /// The buttons along the sheet's foot, outside what scrolls: All… and `leading` at the left, Cancel and Save at
    /// the right. Set once.
    func setFooter(manageTitle: String, leading: [NSView] = []) {
        let manage = ClosureButton(title: manageTitle) { [weak self] in self?.onManage() }
        manage.bezelStyle = .push
        manage.setAccessibilityIdentifier("\(identifierPrefix).manage")
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.setViews(leading + [manage], in: .leading)
        row.setViews([cancelButton, saveButton], in: .trailing)
        footerView = row
        addSubview(row)
        footerHeight = ceil(row.fittingSize.height) + 2 * Self.margin
        contentChanged()
    }

    override func panelSize(in size: NSSize) -> NSSize {
        let whole = measureRows() + footerHeight
        // The sheet starts under the toolbar: what is left of the window below that is its room.
        let room = size.height - DialogLayout.sheetTop - Self.bottomInset
        return NSSize(width: Self.width, height: max(min(160, whole), min(room, whole)))
    }

    override func layout() {
        super.layout()
        if let footerView {
            footerView.frame = NSRect(
                x: Self.margin, y: bounds.height - footerHeight + Self.margin, width: contentWidth,
                height: footerHeight - 2 * Self.margin)
        }
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(0, bounds.height - footerHeight))
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: rowsHeight)
        stack.frame = document.bounds
        footerLine.frame = NSRect(x: 0, y: scroll.frame.maxY, width: Self.width, height: 1)
        footerLine.isHidden = rowsHeight <= scroll.frame.height + 0.5
    }

    /// The rows' height now, kept for `layout`.
    @discardableResult
    private func measureRows() -> Double {
        rowsHeight = ceil(stack.fittingSize.height)
        return rowsHeight
    }

    /// Rows were shown, hidden or changed: the sheet, and the scrim around it, lay out again when its height changed.
    /// Otherwise nothing is laid out again.
    func contentChanged() {
        let before = rowsHeight
        guard measureRows() != before else { return }
        needsLayout = true
        superview?.needsLayout = true
    }

    // MARK: The name

    /// The Name row, then the line saying a name is taken.
    func addName() {
        add(row(label("Name"), nameBox, stretch: true), after: 4)
        add(nameNote, after: 8)
    }

    /// The name's line and Save as the name is now: Replace while another saved view has it.
    func refreshName(_ name: String) {
        nameBox.show(name)
        let note = takenName.map { "A \(kind) called \u{201C}\($0)\u{201D} exists. Saving replaces it." }
        Self.set(nameNote, note ?? "")
        Self.set(nameNote, hidden: note == nil)
        let title = note == nil ? "Save" : "Replace"
        if saveButton.title != title { saveButton.title = title }
        if saveButton.isEnabled != canSave { saveButton.isEnabled = canSave }
    }

    /// Asks whether a saved view chosen by name fills the sheet in (`true`), to change that one, or the sheet keeps
    /// what it has, to save in place of it. Escape keeps it.
    func askToLoad(_ name: String) async -> Bool {
        guard let window else { return false }
        return await InWindowAlerts.ask(
            title: "Load the settings of \u{201C}\(name)\u{201D}?",
            message:
                "Load them to change that \(kind) here, or keep what this sheet has and save it in its place.",
            buttons: [
                AlertButtonSpec("Keep These", .plain, answer: false),
                AlertButtonSpec("Load Settings", .default, answer: true),
            ], escape: false, in: window)
    }

    // MARK: Pieces

    func add(_ view: NSView, fullWidth: Bool = true, after spacing: Double? = nil) {
        stack.addArrangedSubview(view)
        if fullWidth { view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true }
        if let spacing { stack.setCustomSpacing(spacing, after: view) }
    }

    /// The sheet's symbol, its title and, under it, `subtitle`, which the sheet may change.
    func header(symbol: String, title: String, subtitle: NSTextField) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [titleField, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    /// The summary of what is kept, under a hairline.
    func addSummary() {
        add(separator())
        add(summary, after: 8)
    }

    func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    /// A note in the controls' column; `fullWidth`, one across the sheet.
    func note(_ text: String, fullWidth: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = fullWidth ? rowsWidth : rowsWidth - controlColumn
        return field
    }

    func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func pair(_ views: NSView...) -> NSStackView {
        let pair = NSStackView(views: views)
        pair.orientation = .horizontal
        pair.spacing = 8
        return pair
    }

    /// A pop-up identified as `id` and read out as `label`. Its items can change later (`show`).
    func popUp(
        _ titles: [String] = [], label: String, width: Double = FolderViewPopover.popUpWidth, id: String,
        _ action: @escaping (Int) -> Void
    ) -> ClosurePopUp {
        let popup = ClosurePopUp(titles: titles, action: action)
        popup.setAccessibilityIdentifier("\(identifierPrefix).\(id)")
        popup.setAccessibilityLabel(label)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    /// A field for a whole number, identified as `id` and read out as `label`: what is typed is told as it is typed
    /// (`changed`, with each whole number) and once the field is left (`ended`).
    func numberField(
        label: String, id: String, width: Double, changed: @escaping (Int) -> Void, ended: @escaping () -> Void
    ) -> SheetField {
        let field = SheetField()
        field.changed = { text in
            if let number = Int(text.trimmingCharacters(in: .whitespaces)) { changed(number) }
        }
        field.ended = ended
        field.alignment = .right
        field.setAccessibilityIdentifier("\(identifierPrefix).\(id)")
        field.setAccessibilityLabel(label)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// Rows with a hairline between each two shown, as Folder View Options groups them.
    func card(_ rows: [NSView]) -> SheetCard {
        SheetCard(rows: rows, width: rowsWidth)
    }

    /// The header with the Name at its end, and under it the line saying a name is taken: for a sheet with a sidebar.
    func addHeaderWithName(symbol: String, title: String, subtitle: NSTextField) {
        let header = header(symbol: symbol, title: title, subtitle: subtitle)
        let name = label("Name")
        nameBox.translatesAutoresizingMaskIntoConstraints = false
        nameBox.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.setViews([header], in: .leading)
        row.setViews([name, nameBox], in: .trailing)
        add(row, after: 4)
        add(nameNote, after: 10)
    }

    /// The sidebar and the page beside it, its height that of the tallest page, so the sheet keeps one height
    /// whichever part is shown.
    func sidebarBody(_ sidebar: SheetSidebar, pages: [NSView]) -> SheetBody {
        SheetBody(sidebar: sidebar, pages: pages, pageWidth: rowsWidth, gap: Self.sidebarGap)
    }

    /// A page of a sheet with a sidebar: what it is for, then its parts, top down.
    func page(_ note: String, _ parts: [(view: NSView, after: Double)]) -> NSStackView {
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 6
        let line = self.note(note, fullWidth: true)
        page.addArrangedSubview(line)
        page.setCustomSpacing(10, after: line)
        for part in parts {
            page.addArrangedSubview(part.view)
            page.setCustomSpacing(part.after, after: part.view)
        }
        return page
    }

    /// A setting's row: a checkbox titled with its name and its control in the controls' column.
    func keepRow(_ title: String, _ control: NSView, _ toggled: @escaping (Bool) -> Void) -> KeepRow {
        let box = ClosureButton(checkboxWithTitle: title) { box in toggled(box.state == .on) }
        box.setAccessibilityIdentifier("\(identifierPrefix).keep.\(title)")
        return KeepRow(view: row(box, control), box: box, control: control)
    }

    /// A row of a label (lined up with the checkboxes' titles when `indented`) and its control.
    func plainRow(
        _ title: String, _ control: NSView?, indented: Bool = false, height: Double = FolderViewPopover.rowHeight
    ) -> NSView {
        let text = label(title)
        return row(indented ? self.indented(text) : text, control, height: height)
    }

    /// A view lined up with the checkboxes' titles.
    func indented(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return stack
    }

    func row(
        _ leading: NSView, _ control: NSView?, atEnd: Bool = false, stretch: Bool = false,
        height: Double = FolderViewPopover.rowHeight
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        for view in [leading] + (control.map { [$0] } ?? []) {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
            view.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
            view.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6).isActive = true
            view.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -6).isActive = true
        }
        leading.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        if let control {
            if atEnd {
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
                control.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12).isActive =
                    true
            } else {
                control.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: controlColumn)
                    .isActive = true
                leading.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8).isActive =
                    true
                if stretch { control.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true }
            }
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        return row
    }

    // MARK: Showing values, only where they changed

    /// Every control in `view` on or off.
    static func enable(_ view: NSView, _ on: Bool) {
        if let control = view as? NSControl, control.isEnabled != on { control.isEnabled = on }
        for child in view.subviews { enable(child, on) }
    }

    /// `popup` with `titles` as its items and the one at `selected` chosen. The items are made again only when their
    /// titles changed, and `made` then dresses them (their symbols).
    static func show(
        _ popup: NSPopUpButton, titles: [String], selected: Int, made: (NSPopUpButton) -> Void = { _ in }
    ) {
        if popup.itemTitles != titles {
            popup.removeAllItems()
            for title in titles {
                // Added one by one: two items of the same title are both kept.
                popup.menu?.addItem(withTitle: title, action: nil, keyEquivalent: "")
            }
            made(popup)
        }
        if popup.indexOfSelectedItem != selected, popup.numberOfItems > selected { popup.selectItem(at: selected) }
    }

    static func set(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    static func set(_ view: NSView, hidden: Bool) {
        if view.isHidden != hidden { view.isHidden = hidden }
    }
}

/// A sheet's parts in a source list, under headings, one chosen at a time: its rows show beside it.
@MainActor
final class SheetSidebar: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case heading(String)
        case item(id: String, title: String, symbol: String)
    }

    private let table = NSTableView()
    /// The list the keyboard goes to.
    var list: NSView { table }
    private(set) var rows: [Row] = []
    /// The item chosen, by its id.
    private(set) var selectedID: String?
    var chosen: (String) -> Void = { _ in }

    init(identifier: String) {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("part"))
        table.addTableColumn(column)
        table.headerView = nil
        // Plain, with the selection drawn by its rows: a source list's vibrant selection doesn't belong on a sheet's
        // glass.
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.floatsGroupRows = false
        table.focusRingType = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier(identifier)
        table.setAccessibilityLabel("Parts")
        documentView = table
        hasVerticalScroller = false
        drawsBackground = false
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `rows`, with the item `id` chosen (the first item when none is `id`). The list is made again only when the
    /// rows changed.
    func show(_ rows: [Row], selected id: String) {
        if rows != self.rows {
            self.rows = rows
            table.reloadData()
        }
        let index =
            rows.firstIndex { if case .item(let item, _, _) = $0 { item == id } else { false } }
            ?? rows.firstIndex { if case .item = $0 { true } else { false } }
        selectedID = index.flatMap { if case .item(let item, _, _) = rows[$0] { item } else { nil } }
        if let index, table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// The chosen part is drawn by the row itself, a tint the title stays readable on, in the sheet's glass as in a
    /// window.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SheetSidebarRow() }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .heading = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text
        switch rows[row] {
        case .heading(let title):
            text.stringValue = title
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        case .item(let id, let title, let symbol):
            text.stringValue = title
            let icon = NSImageView(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .controlAccentColor
            cell.addSubview(icon)
            cell.imageView = icon
            cell.setAccessibilityIdentifier("\(table.accessibilityIdentifier()).\(id)")
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row), case .item(let id, _, _) = rows[row], id != selectedID else { return }
        selectedID = id
        chosen(id)
    }
}

/// A row of a sheet's sidebar: chosen, a rounded tint of the accent color under its title.
final class SheetSidebarRow: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A sidebar and, beside it, the page of the part chosen: every page is made once, and the others are hidden. As tall
/// as the tallest page, so choosing another part doesn't change the sheet's height.
@MainActor
final class SheetBody: NSView {
    let sidebar: SheetSidebar
    let pages: [NSView]
    private var height: NSLayoutConstraint!

    init(sidebar: SheetSidebar, pages: [NSView], pageWidth: Double, gap: Double) {
        self.sidebar = sidebar
        self.pages = pages
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SavedViewSheet.sidebarWidth),
        ])
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: gap),
                page.topAnchor.constraint(equalTo: topAnchor),
                page.widthAnchor.constraint(equalToConstant: pageWidth),
            ])
        }
        height = heightAnchor.constraint(equalToConstant: 100)
        height.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the page at `index`, and holds the body to the tallest page as they are now.
    func show(page index: Int) {
        for (place, page) in pages.enumerated() where page.isHidden != (place != index) {
            page.isHidden = place != index
        }
        let tallest = ceil(pages.map(\.fittingSize.height).max() ?? 100)
        if height.constant != tallest { height.constant = tallest }
    }
}

/// A setting's row: its checkbox and its control, both kept.
@MainActor
final class KeepRow {
    let view: NSView
    let box: ClosureButton
    let control: NSView

    init(view: NSView, box: ClosureButton, control: NSView) {
        self.view = view
        self.box = box
        self.control = control
    }

    /// Checked or not; `available` false dims the checkbox too (a divider with one pane). With `dims`, the control is
    /// dimmed while the setting isn't kept.
    func show(kept: Bool, available: Bool = true, dims: Bool = true) {
        let state: NSControl.StateValue = kept ? .on : .off
        if box.state != state { box.state = state }
        if box.isEnabled != available { box.isEnabled = available }
        SavedViewSheet.enable(control, available && (kept || !dims))
    }
}

/// A card's rows, each with a hairline above it but the first shown. A row hidden takes its hairline with it.
@MainActor
final class SheetCard: NSStackView {
    private var cardRows: [(line: NSBox, row: NSView)] = []

    init(rows: [NSView], width: Double) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        for row in rows {
            let line = NSBox()
            line.boxType = .separator
            addArrangedSubview(line)
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            cardRows.append((line, row))
        }
        updateLines()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows or hides `row`, and the hairlines as the rows shown now need them.
    func set(_ row: NSView, shown: Bool) {
        guard row.isHidden == shown else { return }
        row.isHidden = !shown
        updateLines()
    }

    private func updateLines() {
        var first = true
        for (line, row) in cardRows {
            let hidden = first || row.isHidden
            if line.isHidden != hidden { line.isHidden = hidden }
            if !row.isHidden { first = false }
        }
    }
}

/// A text field that tells what is typed as it is typed, and when it is left: by Tab, by a click elsewhere, by
/// Return. `show` changes what it shows only while it isn't being typed in.
@MainActor
final class SheetField: NSTextField {
    var changed: (String) -> Void = { _ in }
    var ended: () -> Void = {}

    /// Shows `text`, unless the field is being typed in: what is typed stays as typed.
    func show(_ text: String) {
        guard currentEditor() == nil, stringValue != text else { return }
        stringValue = text
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        changed(stringValue)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        ended()
    }
}

/// The name of a saved view: AppKit's combo box, typed in or one of the saved views' names chosen from its list. A
/// name counts as chosen (`picked`) once the list has closed on it, by a click or Return; moving through the list
/// only shows each name in the field.
@MainActor
final class SheetNameBox: NSComboBox, NSComboBoxDelegate {
    var changed: (String) -> Void = { _ in }
    var picked: (Int) -> Void = { _ in }
    /// The list is open: Return, Escape and Tab are its own.
    private(set) var isListOpen = false
    /// The item the list is on, while it is open.
    private var listItem: Int?

    init(names: [String]) {
        super.init(frame: .zero)
        addItems(withObjectValues: names)
        completes = false
        numberOfVisibleItems = min(12, max(1, names.count))
        isEnabled = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `name`, unless the field is being typed in.
    func show(_ name: String) {
        guard currentEditor() == nil, stringValue != name else { return }
        stringValue = name
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        changed(stringValue)
    }

    func comboBoxWillPopUp(_ notification: Notification) {
        isListOpen = true
        listItem = nil
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard isListOpen else { return }
        listItem = indexOfSelectedItem >= 0 ? indexOfSelectedItem : nil
    }

    func comboBoxWillDismiss(_ notification: Notification) {
        listClosed(by: NSApp.currentEvent)
    }

    /// The list closes, by `event`: on the item it is on, unless Escape closed it on nothing chosen. The field takes
    /// the item's name once the list has closed: told then, and only if it closed on it.
    func listClosed(by event: NSEvent?) {
        let cancelled = event.map { $0.type == .keyDown && KeyCode.isCancel($0) } ?? false
        let item = cancelled ? nil : listItem
        listItem = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isListOpen = false
            guard let item, item < numberOfItems, let name = itemObjectValue(at: item) as? String,
                stringValue == name
            else { return }
            changed(name)
            picked(item)
        }
    }
}

/// What the sheet's rows scroll in: top down, as the panel is.
final class SheetDocumentView: NSView {
    override var isFlipped: Bool { true }
}
