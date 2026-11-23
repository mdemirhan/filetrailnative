// The Views window's Tab Views and Window Views panes: the saved views in the menu's order
import AppKit
import FTFoundation

/// A pane of the Views window listing the tab views or the window views in the menu's order: the key each has now (the
/// first five can be given keys), its name, and what it keeps. Drag a row to reorder; double-click a name to rename
/// it. Several rows can be selected: Duplicate, Remove and a drag act on all of them; Apply (a tab view, to the window
/// that opened the Views window) or Open (a window view) and Edit… on one alone. Remove All… removes every row. Tab
/// Views also chooses the tab view new tabs open with.
@MainActor
final class SavedViewsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Kind {
        case tab, window

        var word: String { self == .tab ? "tab view" : "window view" }
        var words: String { self == .tab ? "tab views" : "window views" }
    }

    struct Row: Equatable {
        var id: String
        var name: String
        var key: String
        var keeps: String
    }

    let kind: Kind
    private weak var host: ViewsWindowController?
    private let table = SavedViewsTable()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(title: "", target: nil, action: nil)
    private let edit = NSButton(title: "Edit\u{2026}", target: nil, action: nil)
    private let duplicate = NSButton(title: "Duplicate", target: nil, action: nil)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAll = NSButton(title: "Remove All\u{2026}", target: nil, action: nil)
    private let newTabs = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var rows: [Row] = []
    private static let dragType = NSPasteboard.PasteboardType("com.filetrail.saved-view-row")

    init(kind: Kind, host: ViewsWindowController) {
        self.kind = kind
        self.host = host
        super.init(frame: .zero)
        setAccessibilityIdentifier(kind == .tab ? "tabViews" : "windowViews")
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Where the views are

    private var explorer: MainWindowController? { host?.explorer }
    private var preferences: AppPreferences { explorer?.preferences ?? AppPreferences.defaults() }

    private func update(_ change: (inout EditedPreferences) -> Void) {
        explorer?.updatePreferences(change)
        host?.savedViewsChanged()
    }

    private var ids: [String] {
        kind == .tab ? preferences.tabViews.map(\.id) : preferences.windowViews.map(\.id)
    }

    // MARK: Building

    private func build() {
        for (identifier, title, width) in [
            ("key", "Key", 70.0), ("name", "Name", 180.0), ("keeps", "What It Keeps", 300.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.resizingMask = identifier == "keeps" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.style = .inset
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([Self.dragType])
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.setAccessibilityIdentifier("\(kind == .tab ? "tabViews" : "windowViews").table")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        empty.stringValue =
            kind == .tab
            ? "No tab views yet. Save one from Layout \u{203A} Save Tab View\u{2026}"
            : "No window views yet. Save one from Layout \u{203A} Save Window View\u{2026}"
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.preferredMaxLayoutWidth = 320

        apply.title = kind == .tab ? "Apply" : "Open"
        let prefix = kind == .tab ? "tabViews" : "windowViews"
        for (button, action, name) in [
            (apply, #selector(applySelected), "apply"), (edit, #selector(editSelected), "edit"),
            (duplicate, #selector(duplicateSelected), "duplicate"), (remove, #selector(removeSelected), "remove"),
            (removeAll, #selector(askToRemoveAll), "removeAll"),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
            button.setAccessibilityIdentifier("\(prefix).\(name)")
        }
        let keysNote = NSTextField(
            labelWithString: "Drag to reorder. The first five can be given keys in Settings \u{203A} Shortcuts.")
        keysNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keysNote.textColor = .secondaryLabelColor
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.setViews([remove, removeAll, duplicate], in: .leading)
        bar.setViews([edit, apply], in: .trailing)
        let foot = NSStackView()
        foot.orientation = .horizontal
        foot.spacing = 8
        if kind == .tab {
            let label = NSTextField(labelWithString: "New tabs open with")
            newTabs.target = self
            newTabs.action = #selector(newTabViewChosen)
            newTabs.setAccessibilityIdentifier("tabViews.newTabs")
            newTabs.setAccessibilityLabel("New tabs open with")
            foot.setViews([label, newTabs], in: .leading)
        }
        foot.setViews([keysNote], in: .trailing)
        for view in [scroll, empty, bar, foot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -10),
            foot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            foot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            foot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    func takeKeyboard() { window?.makeFirstResponder(table) }

    // MARK: Rows

    /// The rows again from the preferences, keeping the selection where its views still are.
    func reload() {
        let selectedIDs = selectedRows.map(\.id)
        let preferences = preferences
        let bindings = ShortcutCommands.resolve(preferences.shortcutOverrides).bindings
        let slots = kind == .tab ? TabViews.slotCommands : WindowViews.slotCommands
        func key(_ index: Int) -> String {
            guard slots.indices.contains(index) else { return "" }
            return Shortcuts.menuShortcut(bindings[slots[index]] ?? []).map(ShortcutLabels.format) ?? ""
        }
        switch kind {
        case .tab:
            rows = preferences.tabViews.enumerated().map { index, view in
                let parts = SavedViewText.parts(view.keeps)
                let newTab = preferences.newTabViewID == view.id ? ["New tabs"] : []
                return Row(
                    id: view.id, name: view.name, key: key(index),
                    keeps: (newTab + parts).joined(separator: " \u{00B7} "))
            }
            newTabs.removeAllItems()
            newTabs.addItem(withTitle: "None")
            for view in preferences.tabViews { newTabs.addItem(withTitle: MenuName.shortened(view.name)) }
            let chosen = preferences.newTabViewID.flatMap { SavedViewNames.index(id: $0, in: preferences.tabViews) }
            newTabs.selectItem(at: chosen.map { $0 + 1 } ?? 0)
        case .window:
            rows = preferences.windowViews.enumerated().map { index, view in
                Row(
                    id: view.id, name: view.name, key: key(index),
                    keeps: SavedViewText.parts(view, tabViews: preferences.tabViews).joined(separator: " \u{00B7} "))
            }
        }
        table.reloadData()
        select(selectedIDs)
        empty.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        syncButtons()
    }

    /// The selected rows, in the list's order.
    private var selectedRows: [Row] {
        table.selectedRowIndexes.filter(rows.indices.contains).map { rows[$0] }
    }

    /// The selected row when it is the only one: what Apply or Open and Edit… act on.
    private var selectedRow: Row? {
        let selected = selectedRows
        return selected.count == 1 ? selected[0] : nil
    }

    /// The rows of the views with these ids selected, and no other.
    private func select(_ ids: [String]) {
        let indexes = IndexSet(rows.indices.filter { ids.contains(rows[$0].id) })
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func syncButtons() {
        let one = selectedRow != nil && explorer != nil
        let any = !selectedRows.isEmpty && explorer != nil
        for button in [apply, edit] { button.isEnabled = one }
        for button in [duplicate, remove] { button.isEnabled = any }
        removeAll.isEnabled = !rows.isEmpty && explorer != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        switch column {
        case "key":
            field.stringValue = rows[row].key
            field.textColor = .secondaryLabelColor
        case "name":
            field.stringValue = rows[row].name
            field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            // Editable only once double-clicked: a click selects the row, as anywhere in a list.
            field.isEditable = false
            field.delegate = self
            field.tag = row
            field.setAccessibilityIdentifier("\(kind == .tab ? "tabViews" : "windowViews").name")
        default:
            field.stringValue = rows[row].keeps
            field.textColor = .secondaryLabelColor
            field.toolTip = rows[row].keeps
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncButtons() }

    // MARK: Renaming

    /// A double-click on a row: its name is edited in place.
    @objc private func doubleClicked() {
        let row = table.clickedRow
        let name = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard rows.indices.contains(row), table.clickedColumn == name else { return }
        startRenaming(row: row)
    }

    func startRenaming(row: Int) {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard column >= 0, let field = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField
        else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        field.isEditable = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// A name typed in a row: kept when no other has it, or else said why and put back.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rows.indices.contains(field.tag) else { return }
        field.isEditable = false
        rename(rows[field.tag].id, to: field.stringValue)
    }

    func rename(_ id: String, to typed: String) {
        let name = SavedViewNames.clean(typed)
        let preferences = preferences
        let refusal =
            kind == .tab
            ? SavedViewNames.renameRefusal(name, id: id, in: preferences.tabViews, kind: kind.word)
            : SavedViewNames.renameRefusal(name, id: id, in: preferences.windowViews, kind: kind.word)
        guard !name.isEmpty, refusal == nil else {
            if let refusal, let window { say(refusal, in: window) } else { NSSound.beep() }
            reload()
            return
        }
        update { preferences in
            switch kind {
            case .tab:
                if let at = SavedViewNames.index(id: id, in: preferences.tabViews) {
                    preferences.tabViews[at].name = name
                }
            case .window:
                if let at = SavedViewNames.index(id: id, in: preferences.windowViews) {
                    preferences.windowViews[at].name = name
                }
            }
        }
    }

    private func say(_ text: String, _ detail: String = "", in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Reordering

    /// One item for each row dragged: the selected rows when the drag starts on one of them, else the row alone.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let dragged = (info.draggingPasteboard.pasteboardItems ?? []).compactMap {
            $0.string(forType: Self.dragType).flatMap { Int($0) }
        }
        guard !dragged.isEmpty else { return false }
        move(rows: IndexSet(dragged), to: row)
        return true
    }

    /// The row at `from` put before the row at `to` (the end at `rows.count`).
    func move(from: Int, to: Int) { move(rows: [from], to: to) }

    /// The rows at `moved` put, in their order, before the row at `to` (the end at `rows.count`), and left selected:
    /// the keys go by the new order.
    func move(rows moved: IndexSet, to: Int) {
        guard !moved.isEmpty, moved.allSatisfy(rows.indices.contains), to >= 0, to <= rows.count else { return }
        let ids = moved.map { rows[$0].id }
        let order = rows.map(\.id)
        guard SavedViewNames.moving(order, rows: moved, to: to).views != order else { return }
        update { preferences in
            switch kind {
            case .tab: preferences.tabViews = SavedViewNames.moving(preferences.tabViews, rows: moved, to: to).views
            case .window:
                preferences.windowViews = SavedViewNames.moving(preferences.windowViews, rows: moved, to: to).views
            }
        }
        select(ids)
        syncButtons()
    }

    // MARK: Actions

    @objc func applySelected() {
        guard let row = selectedRow, let explorer else { return }
        switch kind {
        case .tab:
            explorer.window?.makeKeyAndOrderFront(nil)
            explorer.applyTabView(id: row.id)
        case .window:
            explorer.group?.openWindowView(id: row.id)
        }
    }

    @objc func editSelected() {
        guard let row = selectedRow, let explorer else { return }
        explorer.window?.makeKeyAndOrderFront(nil)
        switch kind {
        case .tab:
            guard let view = preferences.tabViews.first(where: { $0.id == row.id }) else { return }
            explorer.presentTabViewOptions(editing: view)
        case .window:
            guard let view = preferences.windowViews.first(where: { $0.id == row.id }) else { return }
            explorer.editWindowView(view)
        }
    }

    /// Duplicate: a copy after each selected row, its name the first "… copy" no other has; the copies are left
    /// selected. When they don't fit under the limit, a notice says so and nothing is added.
    @objc func duplicateSelected() {
        let selected = selectedRows.map(\.id)
        guard !selected.isEmpty else { return }
        guard ids.count + selected.count <= SavedViewNames.limit else {
            if let window {
                say(
                    SavedViewNames.limitTitle(kind: kind.words),
                    SavedViewNames.duplicateLimitMessage(kind: kind.words, count: ids.count, copies: selected.count),
                    in: window)
            }
            return
        }
        var copies: [String] = []
        update { preferences in
            switch kind {
            case .tab:
                let result = SavedViewNames.duplicating(selected, in: preferences.tabViews) {
                    SavedViewNames.newID("tab-view")
                }
                preferences.tabViews = result.views
                copies = result.copies
            case .window:
                let result = SavedViewNames.duplicating(selected, in: preferences.windowViews) {
                    SavedViewNames.newID("window-view")
                }
                preferences.windowViews = result.views
                copies = result.copies
            }
        }
        select(copies)
        syncButtons()
    }

    /// Remove takes the selected rows without asking, as Duplicate is there first and nothing else is lost; tab views
    /// that window views use ask first, naming them, as their tabs will open as new tabs.
    @objc func removeSelected() {
        let selected = selectedRows
        guard !selected.isEmpty else { return }
        let gone = selected.map(\.id)
        let windowViews = preferences.windowViews
        let used = kind == .tab ? selected.filter { !WindowViews.using($0.id, in: windowViews).isEmpty } : []
        let users = windowViews.filter { view in used.contains { !WindowViews.using($0.id, in: [view]).isEmpty } }
        guard !users.isEmpty, let window else {
            forget(gone)
            return
        }
        func quoted(_ names: [String]) -> String {
            ListFormatter.localizedString(byJoining: names.map { "\u{201C}\($0)\u{201D}" })
        }
        let alert = NSAlert()
        if selected.count == 1 {
            alert.messageText = "Remove \u{201C}\(selected[0].name)\u{201D}?"
            alert.informativeText = "It is used by \(quoted(users.map(\.name))). Their tabs will open as new tabs."
        } else {
            alert.messageText = "Remove \(FormatLocale.count(selected.count)) \(kind.words)?"
            alert.informativeText =
                "\(quoted(used.map(\.name))) \(used.count == 1 ? "is" : "are") used by \(quoted(users.map(\.name))). "
                + "Their tabs will open as new tabs."
        }
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.forget(gone)
            }
        }
    }

    @objc func askToRemoveAll() {
        guard !rows.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText =
            rows.count == 1 ? "Remove the \(kind.word)?" : "Remove all \(FormatLocale.count(rows.count)) \(kind.words)?"
        alert.informativeText =
            kind == .tab
            ? "Window views that use them will open their tabs as new tabs. This can\u{2019}t be undone."
            : "This can\u{2019}t be undone."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let all = ids
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.forget(all)
            }
        }
    }

    /// The views with these ids gone; a tab view gone leaves the window views that used it plain tabs, and new tabs
    /// as before when it was the one they opened with.
    func forget(_ gone: [String]) {
        update { preferences in
            switch kind {
            case .tab:
                preferences.tabViews.removeAll { gone.contains($0.id) }
                for id in gone {
                    preferences.windowViews = WindowViews.forgetting(id, in: preferences.windowViews)
                }
                if let id = preferences.newTabViewID, gone.contains(id) { preferences.newTabViewID = nil }
            case .window:
                preferences.windowViews.removeAll { gone.contains($0.id) }
            }
        }
    }

    @objc private func newTabViewChosen() {
        let index = newTabs.indexOfSelectedItem
        let views = preferences.tabViews
        update { $0.newTabViewID = index > 0 && views.indices.contains(index - 1) ? views[index - 1].id : nil }
    }

    #if DEBUG
        var tableView: NSTableView { table }
        var applyButton: NSButton { apply }
        var newTabsPopUp: NSPopUpButton { newTabs }
        func chooseNewTabView(at index: Int) {
            newTabs.selectItem(at: index)
            newTabViewChosen()
        }
    #endif
}

/// The list of saved views: ⌫ removes the selected ones, Esc closes the window.
final class SavedViewsTable: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete()
        case 53: window?.performClose(nil)
        default: super.keyDown(with: event)
        }
    }
}
