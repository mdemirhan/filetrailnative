// The tab's side of a folder's view: the Folder View commands, the List's columns and the popovers
import AppKit
import FTFoundation

extension MainWindowController {
    /// The folders' views changed (in this window or another): each pane shows the view its folder uses now.
    func folderViewsChanged() {
        for pane in panes { pane.refreshFolderView() }
        folderViewPopover?.refresh()
    }

    /// The List's columns shown in the active pane's folder, which View ▸ Columns checks.
    var shownColumns: Set<OptionalDetailColumnKey> {
        let columns = activePane.shownPreferences(preferences).detailColumns
        return Set(OptionalDetailColumnKey.allCases.filter { columns[$0] })
    }

    /// View ▸ Folder View's commands, for the active pane.
    func performFolderViewCommand(_ command: AppCommand) {
        let pane = activePane
        switch command {
        case .rememberFolderView:
            pane.rememberFolderView()
        case .updateFolderView:
            pane.updateFolderView()
        case .revertFolderView:
            pane.revertFolderView()
        case .folderViewOptions:
            showFolderViewPopover(for: pane, from: nil)
        case .resetFolderView:
            pane.resetFolderView()
        case .manageFolderViews:
            FolderViewsWindowController.show(services.folderViews) { [weak self] path in
                guard let self else { return }
                self.window?.makeKeyAndOrderFront(nil)
                self.go(to: URL(fileURLWithPath: path))
            }
        default:
            break
        }
        notify(.view)
    }

    // MARK: Columns

    /// Shows or hides a column of the List: in the folder's view where it keeps its columns (unsaved until Update),
    /// else for every folder that has none of its own.
    func toggleColumn(_ key: OptionalDetailColumnKey, in pane: BrowserPane) {
        // A column shown takes its place in the standard order among those shown; one hidden keeps its place.
        func toggle(_ visibility: inout DetailColumnVisibility, _ order: inout [OptionalDetailColumnKey]) {
            visibility[key].toggle()
            guard visibility[key] else { return }
            let shown = visibility
            order = ColumnOrder.showing(
                key, in: order, isShown: { shown[$0] }, standard: OptionalDetailColumnKey.menuOrder)
        }
        if pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { keeps in
                guard var columns = keeps.columns else { return }
                toggle(&columns.visibility, &columns.order)
                keeps.columns = columns
            }
        } else {
            updatePreferences { preferences in
                var visibility = preferences.detailColumns
                var order = preferences.detailColumnOrder
                toggle(&visibility, &order)
                preferences.detailColumns = visibility
                preferences.detailColumnOrder = order
            }
        }
        notify(.view)
    }

    /// Shows or hides a column of search results, as `toggleColumn` does a folder's.
    func toggleSearchColumn(_ key: OptionalSearchColumnKey) {
        updatePreferences {
            $0.searchColumns[key].toggle()
            guard $0.searchColumns[key] else { return }
            let shown = $0.searchColumns
            $0.searchColumnOrder = ColumnOrder.showing(
                key, in: $0.searchColumnOrder, isShown: { shown[$0] }, standard: OptionalSearchColumnKey.menuOrder)
        }
    }

    /// Moves a column one place left (`by` -1) or right (1) among those shown; Name stays first.
    func moveColumn(_ key: OptionalDetailColumnKey, by offset: Int, in pane: BrowserPane) {
        let shown = pane.shownPreferences(preferences)
        guard let order = ColumnOrder.moving(key, by: offset, in: shown.detailColumnOrder, visible: shown.detailColumns)
        else { return }
        if pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { $0.columns?.order = order }
        } else {
            updatePreferences { $0.detailColumnOrder = order }
        }
    }

    /// A column dragged to another place among those shown (`before`: the column it now comes before; nil for last).
    func dropColumn(_ key: OptionalDetailColumnKey, before: OptionalDetailColumnKey?, in pane: BrowserPane) {
        let shown = pane.shownPreferences(preferences)
        let order = ColumnOrder.placing(key, before: before, in: shown.detailColumnOrder)
        guard order != shown.detailColumnOrder else { return }
        if pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { $0.columns?.order = order }
        } else {
            updatePreferences { $0.detailColumnOrder = order }
        }
    }

    /// Reset Columns: the columns and widths as they first were.
    func resetColumns(in pane: BrowserPane) {
        if pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView {
                $0.columns = FolderViewColumns(
                    visibility: .defaults, order: AppPreferenceLimits.defaultDetailColumnOrder, widths: .defaults)
            }
        } else {
            pane.setViewSize { $0.detailColumnWidths = .defaults }
            updatePreferences {
                $0.detailColumns = .defaults
                $0.detailColumnOrder = AppPreferenceLimits.defaultDetailColumnOrder
                $0.detailColumnWidths = .defaults
            }
            pane.refreshColumns()
        }
    }

    /// Keep Columns for “…”: the folder's own view keeps the columns on screen, or keeps them no more.
    func keepColumns(_ keep: Bool, in pane: BrowserPane) {
        pane.setFolderViewKeeps(.columns, keep)
    }

    /// The List header's right-click menu: Keep Columns for the folder, the columns to show, moving the one clicked,
    /// Size All Columns to Fit and Reset Columns. Search results have their own columns, and no Keep.
    func headerMenu(for column: DetailColumn?, in pane: BrowserPane) -> NSMenu {
        activate(pane)
        let menu = NSMenu(title: "Columns")
        menu.autoenablesItems = false
        if pane.searchStore?.showsResults == true {
            for key in OptionalSearchColumnKey.menuOrder {
                let shown = preferences.searchColumns[key]
                menu.addItem(
                    ActionMenuItem(SearchColumnKey(rawValue: key.rawValue)?.label ?? key.rawValue, checked: shown) {
                        [weak self] in self?.toggleSearchColumn(key)
                    })
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Size All Columns to Fit") { [weak pane] in pane?.content.fitAllColumns() })
            menu.addItem(
                ActionMenuItem("Reset Columns") { [weak self, weak pane] in
                    pane?.setViewSize { $0.searchColumnWidths = .defaults }
                    self?.updatePreferences {
                        $0.searchColumns = .defaults
                        $0.searchColumnOrder = AppPreferenceLimits.defaultSearchColumnOrder
                        $0.searchColumnWidths = .defaults
                    }
                    pane?.refreshColumns()
                })
            return menu
        }
        let name = FolderViewText.name(pane.shownFolderPath)
        let view = pane.shownFolderView
        let ownKeeps = view?.use.own == true && view?.shown.keeps(.columns) == true
        let keep = ActionMenuItem("Keep Columns for “\(name)”", checked: ownKeeps) { [weak self, weak pane] in
            guard let pane else { return }
            self?.keepColumns(!ownKeeps, in: pane)
        }
        keep.isEnabled = !pane.shownFolderPath.isEmpty
        menu.addItem(keep)
        let whereTo: String
        if let view, view.shown.keeps(.columns) {
            whereTo =
                view.use.own
                ? "Changes go to this folder's view, until Save"
                : "Changes go to “\(FolderViewText.name(view.use.view.path))” view, until Save"
        } else {
            whereTo = "Changes apply to all folders"
        }
        let note = NSMenuItem(title: whereTo, action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(.separator())
        let shown = pane.shownPreferences(preferences)
        let nameItem = NSMenuItem(title: DetailColumnKey.name.label, action: nil, keyEquivalent: "")
        nameItem.state = .on
        nameItem.isEnabled = false
        menu.addItem(nameItem)
        for key in OptionalDetailColumnKey.menuOrder {
            let item = ActionMenuItem(
                DetailColumnKey(rawValue: key.rawValue)?.label ?? key.rawValue,
                checked: shown.detailColumns[key]
            ) { [weak self, weak pane] in
                guard let pane else { return }
                self?.toggleColumn(key, in: pane)
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let column, let key = OptionalDetailColumnKey(rawValue: column.rawValue) {
            let title = DetailsColumns.title(column)
            let left = ActionMenuItem("Move “\(title)” Left") { [weak self, weak pane] in
                guard let pane else { return }
                self?.moveColumn(key, by: -1, in: pane)
            }
            left.isEnabled =
                ColumnOrder.moving(key, by: -1, in: shown.detailColumnOrder, visible: shown.detailColumns) != nil
            let right = ActionMenuItem("Move “\(title)” Right") { [weak self, weak pane] in
                guard let pane else { return }
                self?.moveColumn(key, by: 1, in: pane)
            }
            right.isEnabled =
                ColumnOrder.moving(key, by: 1, in: shown.detailColumnOrder, visible: shown.detailColumns) != nil
            menu.addItem(left)
            menu.addItem(right)
        }
        menu.addItem(ActionMenuItem("Size All Columns to Fit") { [weak pane] in pane?.content.fitAllColumns() })
        menu.addItem(
            ActionMenuItem("Reset Columns") { [weak self, weak pane] in
                guard let pane else { return }
                self?.resetColumns(in: pane)
            })
        return menu
    }

    // MARK: The popovers

    /// Folder Customization, over the status bar's symbol (from a click on it, a menu or ⌘J).
    func showFolderViewPopover(for pane: BrowserPane, from anchor: NSView?) {
        guard let window else { return }
        if let shown = folderViewPopover {
            let same = shown.pane === pane
            shown.close()
            folderViewPopover = nil
            // A second click on the symbol closes it.
            if same, anchor != nil { return }
        }
        let popover = FolderViewPopover(
            pane: pane, tab: self,
            dismiss: { [weak self] in
                self?.folderViewPopover?.close()
                self?.folderViewPopover = nil
            })
        folderViewPopover = popover
        let symbol = pane.content.contentShell.pathBarRow.folderViewButton
        popover.show(
            from: anchor ?? (symbol.isHidden ? pane.content.contentShell.pathBarRow.status : symbol), in: window)
    }
}

/// Moving one of the List's columns in the order of all of them (hidden ones keep their place).
enum ColumnOrder {
    /// `key` one place left or right among the columns shown; nil when it can't go further.
    static func moving(
        _ key: OptionalDetailColumnKey, by offset: Int, in order: [OptionalDetailColumnKey],
        visible: DetailColumnVisibility
    ) -> [OptionalDetailColumnKey]? {
        let shown = order.filter { visible[$0] }
        guard let at = shown.firstIndex(of: key) else { return nil }
        let target = at + offset
        guard shown.indices.contains(target) else { return nil }
        let other = shown[target]
        var next = order
        guard let from = next.firstIndex(of: key), let to = next.firstIndex(of: other) else { return nil }
        next.swapAt(from, to)
        return next
    }

    /// `key`, just shown, put where the standard order has it among the columns shown: right after the nearest shown
    /// column that comes before it there, or first (after Name) when none does. Where the hidden columns are, and
    /// where the others were moved to, stays as it is.
    static func showing<Key: Equatable>(_ key: Key, in order: [Key], isShown: (Key) -> Bool, standard: [Key]) -> [Key] {
        var next = order.filter { $0 != key }
        guard let place = standard.firstIndex(of: key) else { return next + [key] }
        let before = standard[..<place].reversed().first { isShown($0) && next.contains($0) }
        if let before, let index = next.firstIndex(of: before) {
            next.insert(key, at: index + 1)
        } else {
            next.insert(key, at: 0)
        }
        return next
    }

    /// `key` put just before `before` (nil: at the end).
    static func placing(
        _ key: OptionalDetailColumnKey, before: OptionalDetailColumnKey?, in order: [OptionalDetailColumnKey]
    ) -> [OptionalDetailColumnKey] {
        var next = order.filter { $0 != key }
        if let before, let index = next.firstIndex(of: before) {
            next.insert(key, at: index)
        } else {
            next.append(key)
        }
        return next
    }
}

/// A menu item that runs a closure: the header's menu, built for each right-click.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, checked: Bool? = nil, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let checked { state = checked ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
