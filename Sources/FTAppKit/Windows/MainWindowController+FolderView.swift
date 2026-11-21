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
        // Each acts only where its menu item is on, as its rule in `CommandAvailability` has it: a dimmed item's
        // key still comes here. Search results are no folder, and a pane with no folder has none to customize.
        switch command {
        case .manageFolderViews:
            break
        default:
            // Update, Revert and Reset look for something unsaved, or a view of the folder's own, themselves.
            guard pane.searchRootPath == nil, !pane.shownFolderPath.isEmpty else { return }
            // What they act on is the folder's view, not a tab view laid over it.
            pane.endTabViewOverride()
        }
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
            manageViews(.folderViews)
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
        if pane.changedByHand(.columns), pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { keeps in
                guard var columns = keeps.columns else { return }
                toggle(&columns.visibility, &columns.order)
                keeps.columns = columns
            }
        } else {
            pane.changeSharedSettings { preferences in
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
        if pane.changedByHand(.columns), pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { $0.columns?.order = order }
        } else {
            pane.changeSharedSettings { $0.detailColumnOrder = order }
        }
    }

    /// Moves a column of search results one place left or right among those shown, in their own order; Name stays
    /// first, and Folder moves as any other.
    func moveSearchColumn(_ key: OptionalSearchColumnKey, by offset: Int) {
        let shown = preferences.searchColumns
        guard let order = ColumnOrder.moving(key, by: offset, in: preferences.searchColumnOrder, isShown: { shown[$0] })
        else { return }
        updatePreferences { $0.searchColumnOrder = order }
    }

    /// A column title dragged to another place among those shown (`before`: the column it now comes before; nil for
    /// last). Search results have columns and an order of their own: a drag there moves theirs, never a folder's.
    func dropColumn(_ column: DetailColumn, before: DetailColumn?, in pane: BrowserPane) {
        if pane.showsSearchResults {
            guard let key = OptionalSearchColumnKey(rawValue: column.rawValue) else { return }
            let order = ColumnOrder.placing(
                key, before: before.flatMap { OptionalSearchColumnKey(rawValue: $0.rawValue) },
                in: preferences.searchColumnOrder)
            guard order != preferences.searchColumnOrder else { return }
            updatePreferences { $0.searchColumnOrder = order }
            return
        }
        guard let key = OptionalDetailColumnKey(rawValue: column.rawValue) else { return }
        let shown = pane.shownPreferences(preferences)
        let order = ColumnOrder.placing(
            key, before: before.flatMap { OptionalDetailColumnKey(rawValue: $0.rawValue) }, in: shown.detailColumnOrder)
        guard order != shown.detailColumnOrder else { return }
        if pane.changedByHand(.columns), pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView { $0.columns?.order = order }
        } else {
            pane.changeSharedSettings { $0.detailColumnOrder = order }
        }
    }

    /// Reset Columns: the columns and widths as they first were.
    func resetColumns(in pane: BrowserPane) {
        if pane.changedByHand(.columns), pane.folderViewKeeps(.columns) {
            pane.changeShownFolderView {
                $0.columns = FolderViewColumns(
                    visibility: .defaults, order: AppPreferenceLimits.defaultDetailColumnOrder, widths: .defaults)
            }
        } else {
            pane.setViewSize { $0.detailColumnWidths = .defaults }
            pane.changeSharedSettings {
                $0.detailColumns = .defaults
                $0.detailColumnOrder = AppPreferenceLimits.defaultDetailColumnOrder
                $0.detailColumnWidths = .defaults
            }
            pane.refreshColumns()
        }
    }

    /// Keep Columns for “…”: the folder's own view keeps the columns on screen, or keeps them no more.
    func keepColumns(_ keep: Bool, in pane: BrowserPane) {
        pane.keepOwnColumns(keep)
    }

    /// The List header's right-click menu: Keep Columns for the folder, the columns to show, moving the one clicked,
    /// Size All Columns to Fit and Reset Columns. Search results have the same of their own columns, and no Keep.
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
            if let column, let key = OptionalSearchColumnKey(rawValue: column.rawValue) {
                let title = DetailsColumns.title(column)
                let (order, shown) = (preferences.searchColumnOrder, preferences.searchColumns)
                let left = ActionMenuItem("Move “\(title)” Left") { [weak self] in self?.moveSearchColumn(key, by: -1) }
                left.isEnabled = ColumnOrder.moving(key, by: -1, in: order, isShown: { shown[$0] }) != nil
                let right = ActionMenuItem("Move “\(title)” Right") { [weak self] in
                    self?.moveSearchColumn(key, by: 1)
                }
                right.isEnabled = ColumnOrder.moving(key, by: 1, in: order, isShown: { shown[$0] }) != nil
                menu.addItem(left)
                menu.addItem(right)
            }
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
        // Checked where the columns are, or at Save will be, this folder's own: a view from above that keeps
        // columns leaves it unchecked, and choosing it there gives the folder its own.
        let ownKeeps = pane.keepsOwnColumns
        let keep = ActionMenuItem("Keep Columns for “\(name)”", checked: ownKeeps) { [weak self, weak pane] in
            guard let pane else { return }
            self?.keepColumns(!ownKeeps, in: pane)
        }
        keep.isEnabled = !pane.shownFolderPath.isEmpty
        menu.addItem(keep)
        let whereTo: String
        if let view, view.shown.keeps(.columns) {
            whereTo =
                view.use.own || view.becomesOwn
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
        // The column clicked groups the list, as View ▸ Group By does; checked while it does, when choosing it again
        // groups by None.
        if let column, let field = GroupByPreference.of(column) {
            let grouped = pane.shownGroupBy == field
            menu.addItem(
                ActionMenuItem("Group by “\(DetailsColumns.title(column))”", checked: grouped) { [weak self] in
                    self?.perform(grouped ? .groupByNone : field.command)
                })
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

    /// Folder View Options, over the status bar's symbol (from a click on it, a menu or ⌘J).
    func showFolderViewPopover(for pane: BrowserPane, from anchor: NSView?) {
        // Only for a folder on screen: search results are no folder, and a pane that let go of its folder has none.
        // The symbol isn't there then, and whatever else asks (a menu, a key, a click that was on its way) is refused
        // here, so nothing is changed or saved for a folder that isn't shown.
        guard let window, !pane.showsSearchResults, pane.searchRootPath == nil, !pane.shownFolderPath.isEmpty else {
            return
        }
        // The options show and save the folder's view: a tab view laid over it lets go first.
        pane.endTabViewOverride()
        if let shown = folderViewPopover {
            let same = shown.pane === pane
            closeFolderViewPopover()
            // A second click on the symbol closes it.
            if same, anchor != nil { return }
        }
        let popover = FolderViewPopover(
            pane: pane, tab: self,
            dismiss: { [weak self] in self?.closeFolderViewPopover() })
        folderViewPopover = popover
        let symbol = pane.content.contentShell.pathBarRow.folderViewButton
        popover.show(
            from: anchor ?? (symbol.isHidden ? pane.content.contentShell.pathBarRow.status : symbol), in: window)
    }
}

extension MainWindowController {
    /// Folder View Options closes: asked to, or its pane is no longer there to customize.
    func closeFolderViewPopover() {
        folderViewPopover?.close()
        folderViewPopover = nil
    }
}

/// Moving one of the List's columns, a folder's or search results', in the order of all of them (hidden ones keep
/// their place).
enum ColumnOrder {
    /// `key` one place left or right among the columns shown; nil when it can't go further.
    static func moving(
        _ key: OptionalDetailColumnKey, by offset: Int, in order: [OptionalDetailColumnKey],
        visible: DetailColumnVisibility
    ) -> [OptionalDetailColumnKey]? {
        moving(key, by: offset, in: order, isShown: { visible[$0] })
    }

    /// The same for any list's columns, a folder's or search results'.
    static func moving<Key: Equatable>(_ key: Key, by offset: Int, in order: [Key], isShown: (Key) -> Bool) -> [Key]? {
        let shown = order.filter(isShown)
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
    static func placing<Key: Equatable>(_ key: Key, before: Key?, in order: [Key]) -> [Key] {
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
