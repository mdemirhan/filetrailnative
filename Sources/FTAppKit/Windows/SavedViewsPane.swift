// The Views window's Tab Views and Window Views panes: the saved views in the menu's order
import AppKit
import FTFoundation

/// A pane of the Views window listing the tab views or the window views in the menu's order: the key each has now (the
/// first five can be given keys), its name, and what it keeps. Drag a row to reorder; double-click a name to rename
/// it. Apply (a tab view, to the window that opened the Views window) or Open (a window view), Edit…, Duplicate,
/// Remove and Remove All… act on the selected row. Tab Views also chooses the tab view new tabs open with.
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
            ? "No tab views yet. Save one from Saved Views \u{203A} Save Tab View\u{2026}"
            : "No window views yet. Save one from Saved Views \u{203A} Save Window View\u{2026}"
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.preferredMaxLayoutWidth = 320

        apply.title = kind == .tab ? "Apply" : "Open"
        for (button, action) in [
            (apply, #selector(applySelected)), (edit, #selector(editSelected)),
            (duplicate, #selector(duplicateSelected)), (remove, #selector(removeSelected)),
            (removeAll, #selector(askToRemoveAll)),
        ] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
        }
        let keysNote = NSTextField(
            labelWithString: "Drag to reorder. The first five can be given keys in Settings \u{203A} Shortcuts.")
        keysNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        keysNote.textColor = .secondaryLabelColor
        var barViews: [NSView] = [remove, removeAll, duplicate, NSView(), edit, apply]
        var footer: [NSView] = [keysNote]
        if kind == .tab {
            let label = NSTextField(labelWithString: "New tabs open with")
            newTabs.target = self
            newTabs.action = #selector(newTabViewChosen)
            newTabs.setAccessibilityIdentifier("tabViews.newTabs")
            footer = [label, newTabs, NSView(), keysNote]
        }
        let bar = NSStackView(views: barViews)
        bar.orientation = .horizontal
        bar.spacing = 8
        let foot = NSStackView(views: footer)
        foot.orientation = .horizontal
        foot.spacing = 8
        barViews = []
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

    /// The rows again from the preferences, keeping the selection where its view still is.
    func reload() {
        let selectedID = selectedRow.map(\.id)
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
        if let selectedID, let row = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        empty.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        syncButtons()
    }

    private var selectedRow: Row? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func syncButtons() {
        let on = selectedRow != nil
        for button in [apply, edit, duplicate, remove] { button.isEnabled = on && explorer != nil }
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
            field.isEditable = true
            field.delegate = self
            field.tag = row
        default:
            field.stringValue = rows[row].keeps
            field.textColor = .secondaryLabelColor
            field.toolTip = rows[row].keeps
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncButtons() }

    // MARK: Renaming

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), table.clickedColumn >= 0 else { return }
        table.editColumn(
            table.column(withIdentifier: NSUserInterfaceItemIdentifier("name")), row: row, with: nil, select: true)
    }

    /// A name typed in a row: kept when no other has it, or else said why and put back.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rows.indices.contains(field.tag) else { return }
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

    private func say(_ text: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Reordering

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
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
            let from = Int(text)
        else { return false }
        move(from: from, to: row)
        return true
    }

    /// The row at `from` put before the row at `to` (the end at `rows.count`): the keys go by the new order.
    func move(from: Int, to: Int) {
        guard rows.indices.contains(from), to >= 0, to <= rows.count, to != from, to != from + 1 else { return }
        // Where it lands once taken out of its place.
        let landed = to > from ? to - 1 : to
        update { preferences in
            switch kind {
            case .tab: preferences.tabViews = SettingsValues.move(preferences.tabViews, from: from, to: landed)
            case .window:
                preferences.windowViews = SettingsValues.move(preferences.windowViews, from: from, to: landed)
            }
        }
        table.selectRowIndexes([landed], byExtendingSelection: false)
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

    @objc func duplicateSelected() {
        guard let row = selectedRow else { return }
        update { preferences in
            switch kind {
            case .tab:
                guard let at = SavedViewNames.index(id: row.id, in: preferences.tabViews),
                    preferences.tabViews.count < SavedViewNames.limit
                else { return }
                var copy = preferences.tabViews[at]
                copy.id = SavedViewNames.newID("tab-view")
                copy.name = SavedViewNames.copyName(of: copy.name, in: preferences.tabViews)
                preferences.tabViews.insert(copy, at: at + 1)
            case .window:
                guard let at = SavedViewNames.index(id: row.id, in: preferences.windowViews),
                    preferences.windowViews.count < SavedViewNames.limit
                else { return }
                var copy = preferences.windowViews[at]
                copy.id = SavedViewNames.newID("window-view")
                copy.name = SavedViewNames.copyName(of: copy.name, in: preferences.windowViews)
                preferences.windowViews.insert(copy, at: at + 1)
            }
        }
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            table.selectRowIndexes([index + 1], byExtendingSelection: false)
        }
    }

    /// Remove doesn't ask, as Duplicate is there first and nothing else is lost; a tab view that window views use asks
    /// first, naming them, as their tabs will open as new tabs.
    @objc func removeSelected() {
        guard let row = selectedRow else { return }
        let users = kind == .tab ? WindowViews.using(row.id, in: preferences.windowViews) : []
        guard !users.isEmpty, let window else {
            forget([row.id])
            return
        }
        let names = users.map { "\u{201C}\($0.name)\u{201D}" }
        let alert = NSAlert()
        alert.messageText = "Remove \u{201C}\(row.name)\u{201D}?"
        alert.informativeText =
            "It is used by \(ListFormatter.localizedString(byJoining: names)). Their tabs will open as new tabs."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.forget([row.id])
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

/// The list of saved views: ⌫ removes the selected one, Esc closes the window.
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
