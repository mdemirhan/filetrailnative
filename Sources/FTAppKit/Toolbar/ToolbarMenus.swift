import AppKit
import FTFileSystem
import FTFoundation

extension ExplorerToolbar {
    static let historyHoldSeconds = 0.35

    func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    func toggleMenu(from button: ToolbarButton, make: () -> Void) {
        if AppMenuPresenter.shared.isOpen(from: button) {
            AppMenuPresenter.shared.close()
            return
        }
        make()
    }

    /// Opens `menu` for `button`, at `origin` or under the button.
    private func present(_ menu: AppMenu, from button: ToolbarButton, at origin: NSPoint? = nil) {
        button.menuOpen = true
        let close = { [weak self, weak button] () -> Void in
            button?.menuOpen = false
            // The system's menu took the release of the hold that opened it.
            self?.openedByHold = false
        }
        if let origin, let window = button.window {
            AppMenuPresenter.shared.show(menu, in: window, at: origin, owner: button, onClose: close)
        } else {
            AppMenuPresenter.shared.drop(menu, from: button, onClose: close)
        }
    }

    private var sortButton: ToolbarButton? { button(.sort) }

    static let sortMenuWidth = 200.0

    /// The window was resized: the Sort menu closes when its button goes to the » menu.
    func windowResized() {
        if item(.sort)?.isVisible == false { closeSortMenu() }
        scheduleSearchWidth()
    }

    /// The items change: the Sort menu's button may move or go.
    func closeSortMenu() {
        if let sortButton, AppMenuPresenter.shared.isOpen(from: sortButton) { AppMenuPresenter.shared.close() }
    }

    /// Where the window's menus are placed from: over the title bar the toolbar is drawn in.
    private func menuHost(of view: NSView) -> NSView? { view.window.flatMap(AppMenuPresenter.overlayHost(of:)) }

    /// The anchor's frame in the window's content, from the top left.
    private func frameInContent(_ view: NSView) -> NSRect? {
        guard let host = menuHost(of: view) else { return nil }
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped
            ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Back's or Forward's menu: the folders that way, nearest first, under the button's left edge.
    func showHistoryMenu(back: Bool, from button: ToolbarButton) {
        guard let context, button.isEnabled else { return }
        let home = DiskPath.home.string
        let disk = context.services.startupDisk.name
        let entries =
            back
            ? HistoryMenu.backEntries(
                historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home,
                startupDiskName: disk)
            : HistoryMenu.forwardEntries(
                historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home,
                startupDiskName: disk)
        guard !entries.isEmpty, let rect = frameInContent(button), let host = menuHost(of: button) else { return }
        let items = entries.map { entry in
            AppMenuItem(
                title: entry.label, detail: entry.detail, tooltip: entry.path,
                action: { [weak self] in self?.context?.goToHistoryIndex(entry.index) })
        }
        let menu = AppMenu(
            items: items, identifier: "historyMenu", rowIdentifier: "historyMenu.item",
            maxWidth: min(420, host.bounds.width - 16), nameMaxWidth: DesignTokens.menu.historyNameMaxWidth)
        // The keyboard starts on the nearest folder.
        menu.markedIndex = 0
        present(menu, from: button, at: NSPoint(x: rect.minX, y: rect.maxY + MenuPlacement.dropGap))
    }

    func sortMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let view = context.viewState
        let canRun = context.commandAvailability()
        let (current, sortDirection) = view.sortCommand
        var items = Self.sortRows.map { row in
            AppMenuItem(
                title: row.title, checked: row.command == current, enabled: canRun(row.command),
                action: { [weak self] in
                    if row.command != current { self?.context?.perform(row.command) }
                })
        }
        items.append(.separator)
        for direction in [SortDirectionPreference.asc, .desc] {
            items.append(
                AppMenuItem(
                    title: direction == .asc ? "Ascending" : "Descending", checked: sortDirection == direction,
                    action: { [weak self] in
                        if direction != sortDirection { self?.context?.perform(current) }
                    }))
        }
        // One last item for the groups, named for the grouping in use, so the menu stays short.
        let grouped = context.searchRootPath != nil ? view.searchGroupBy : view.groupBy
        items.append(.separator)
        items.append(AppMenuItem(title: "Group By: \(grouped.title)", submenu: groupByRows()))
        let menu = AppMenu(
            items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item", minWidth: Self.sortMenuWidth)
        present(menu, from: anchor)
    }

    /// View ▸ Group By's items, as the menu bar has them now: those of a folder, or of search results while they show.
    func groupByRows() -> [AppMenuItem] {
        guard let context else { return [] }
        let canRun = context.commandAvailability()
        let view = context.viewState
        let searching = context.searchRootPath != nil
        let grouped = searching ? view.searchGroupBy : view.groupBy
        func row(_ title: String, _ command: AppCommand, checked: Bool? = nil) -> AppMenuItem {
            AppMenuItem(
                title: title,
                key: ShortcutCommandID(rawValue: command.rawValue).flatMap { shortcuts.written($0) }
                    .flatMap(MenuKeyEquivalent.parse),
                checked: checked, enabled: canRun(command),
                action: { [weak self] in self?.context?.perform(command) })
        }
        let fields = searching ? GroupByPreference.searchMenuOrder : GroupByPreference.menuOrder
        let reversed = (context as? MainWindowController)?.activePane.activeGroupReversed == true
        return [row("None", .groupByNone, checked: grouped == .none), .separator]
            + fields.map { row($0.title, $0.command, checked: grouped == $0) }
            + [.separator, row("Reverse Group Order", .reverseGroupOrder, checked: reversed)]
    }

    /// The View Mode Menu's menu: the four views, then the counts of the Previews segment's menu, checked while the pane
    /// shows Previews at one of them.
    func viewModeMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let view = context.viewState
        let shortcuts = shortcuts
        func key(_ command: AppCommand) -> MenuKeyEquivalent? {
            ShortcutCommandID(rawValue: command.rawValue).flatMap(shortcuts.written).flatMap(MenuKeyEquivalent.parse)
        }
        // The view on screen: search results show in one of their own.
        let shown = context.searchRootPath != nil ? view.searchViewMode : view.viewMode
        let previewCount = shown == .previews ? (context as? MainWindowController)?.content.previewCount : nil
        var items = ExplorerViewMode.menuOrder.map { mode in
            let command = Self.viewCommand(mode)
            return AppMenuItem(
                title: mode.menuName, key: key(command), checked: shown == mode,
                action: { [weak self] in self?.context?.perform(command) })
        }
        items += [.separator, .heading("Show Previews")]
        for count in PreviewGrid.counts {
            guard let command = Self.showPreviewsCommand(count) else { continue }
            items.append(
                AppMenuItem(
                    title: "\(count) at a Time", key: key(command), checked: previewCount == count,
                    action: { [weak self] in self?.context?.perform(command) }))
        }
        present(AppMenu(items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"), from: anchor)
    }

    /// The fields the Sort menus list, as View ▸ Sort By does: Folder after Name, dimmed while a folder shows.
    static var sortRows: [(title: String, command: AppCommand)] {
        SearchResultsSortByPreference.menuOrder.map { ($0.title, $0.command) }
    }

    static func sortCommand(_ value: SortByPreference) -> AppCommand { value.command }

    /// The Group button's menu: View ▸ Group By's items.
    func groupByMenu(anchor: ToolbarButton) {
        let menu = AppMenu(
            items: groupByRows(), identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item",
            minWidth: Self.sortMenuWidth)
        present(menu, from: anchor)
    }

    func viewOptionsMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let view = context.viewState
        let panels = context.panels
        let shortcuts = shortcuts
        func key(_ shortcut: ShortcutCommandID) -> MenuKeyEquivalent? {
            shortcuts.written(shortcut).flatMap(MenuKeyEquivalent.parse)
        }
        let canRun = context.commandAvailability()
        // An item that can't run now is dimmed, as the menu bar's: Folders First over search results.
        func toggle(_ title: String, _ shortcut: ShortcutCommandID, _ on: Bool, _ command: AppCommand)
            -> AppMenuItem
        {
            AppMenuItem(
                title: title, key: key(shortcut), checked: on, enabled: canRun(command),
                action: { [weak self] in self?.context?.perform(command) })
        }
        let items: [AppMenuItem] = [
            toggle("Folders First", .toggleFoldersFirst, view.foldersFirst, .toggleFoldersFirst),
            toggle("Hidden Files", .toggleHiddenFiles, view.includeHidden, .toggleHiddenFiles),
            // View ▸ Folder View, as the list's right-click menu has it.
            AppMenuItem(title: "Folder View", submenu: folderViewRows()),
            .separator,
            toggle("Info Panel", .toggleInfoPanel, panels.propertiesOpen, .toggleInfoPanel),
            toggle("Info Row", .toggleInfoRow, panels.detailRowOpen, .toggleInfoRow),
            .separator,
            AppMenuItem(
                title: "Customize Toolbar…", key: key(.customizeToolbar),
                action: { [weak self] in self?.context?.perform(.customizeToolbar) }),
        ]
        present(AppMenu(items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"), from: anchor)
    }

    /// View ▸ Folder View's items, as the menu bar has them now.
    func folderViewRows() -> [AppMenuItem] {
        guard let context else { return [] }
        let canRun = context.commandAvailability()
        let remembered = (context as? MainWindowController)?.activePane.shownFolderView?.isOwnSaved == true
        func row(_ title: String, _ command: AppCommand, checked: Bool? = nil) -> AppMenuItem {
            AppMenuItem(
                title: title,
                key: ShortcutCommandID(rawValue: command.rawValue).flatMap { shortcuts.written($0) }
                    .flatMap(MenuKeyEquivalent.parse),
                checked: checked, enabled: canRun(command),
                action: { [weak self] in self?.context?.perform(command) })
        }
        return [
            row("Remember View for This Folder", .rememberFolderView, checked: remembered),
            row("Update Folder View", .updateFolderView), row("Revert to Saved View", .revertFolderView), .separator,
            row("Folder View Options…", .folderViewOptions), .separator, row("Reset Folder View", .resetFolderView),
            row("Manage Folder Views…", .manageFolderViews),
        ]
    }

    func themeMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let theme = context.preferences.theme
        let items = AppPreferenceLimits.themeOptions.map { option in
            AppMenuItem(
                title: option.label, checked: theme == option.value,
                action: { [weak self] in self?.context?.updatePreferences { $0.theme = option.value } })
        }
        present(AppMenu(items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"), from: anchor)
    }

    // MARK: The » menu

    /// What the system's » menu says for an item with no room, worded as in the menu bar. The
    /// items that are several choices (the view, the sort, the theme) are a submenu: the system's menu holds one entry
    /// per item. `canPerform`: which commands can run, when the caller has read it already.
    func overflowEntry(_ id: ToolbarItemID, _ canPerform: ((AppCommand) -> Bool)? = nil) -> NSMenuItem? {
        guard let context else { return nil }
        let view = context.viewState
        let panels = context.panels
        func run(_ command: AppCommand) -> () -> Void { { [weak self] in self?.context?.perform(command) } }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            menu.items = items
            entry.submenu = menu
            return entry
        }
        switch id {
        case .topSeparator, .search, .compactSearch:
            return nil
        case .title:
            return overflowItem(Self.title(of: context, inMenu: true), enabled: false) {}
        case .clipboard:
            return overflowItem(ToolbarItems.definition(id).label) { [weak self] in
                guard let self, let button = self.clipboardButton, let tab = self.context as? MainWindowController
                else { return }
                tab.clipboardUI.toggle(from: button)
            }
        case .undoHistory:
            return overflowItem(ToolbarItems.definition(id).label) { [weak self] in
                guard let self, let button = self.undoHistoryButton, let tab = self.context as? MainWindowController
                else { return }
                tab.undoHistoryUI.toggle(from: button)
            }
        case .undo, .redo:
            let command: AppCommand = id == .undo ? .undo : .redo
            return overflowItem(
                Tooltips.toolbarItemLabel(itemID: id, state: tooltipState),
                enabled: (canPerform ?? context.commandAvailability())(command)
                    && hasUndo(id == .undo ? .undo : .redo)
            ) { [weak self] in self?.performFileUndo(command) }
        case .back:
            return overflowItem("Back", enabled: context.canGoBack, run: run(.goBack))
        case .forward:
            return overflowItem("Forward", enabled: context.canGoForward, run: run(.goForward))
        case .up:
            return overflowItem(
                "Enclosing Folder", enabled: ExplorerTabs.parentDirectoryPath(context.shownFolderPath) != nil
            ) { [weak self] in self?.context?.goToParentFolder() }
        case .view, .viewMenu:
            return submenu(
                ToolbarItems.definition(.view).label,
                ExplorerViewMode.menuOrder.map { mode in
                    // The view on screen: search results show in one of their own (`shownViewMode`).
                    let shown = context.searchRootPath != nil ? view.searchViewMode : view.viewMode
                    return overflowItem("as \(mode.menuName)", checked: shown == mode, run: run(Self.viewCommand(mode)))
                })
        case .sort:
            let current = view.sortCommand.command
            let can = canPerform ?? context.commandAvailability()
            return submenu(
                ToolbarItems.definition(id).label,
                Self.sortRows.map { row in
                    overflowItem("Sort by \(row.title)", checked: row.command == current, enabled: can(row.command)) {
                        [weak self] in
                        if row.command != current { self?.context?.perform(row.command) }
                    }
                })
        case .groupBy:
            let searching = context.searchRootPath != nil
            let grouped = searching ? view.searchGroupBy : view.groupBy
            let can = canPerform ?? context.commandAvailability()
            let fields =
                [GroupByPreference.none] + (searching ? GroupByPreference.searchMenuOrder : GroupByPreference.menuOrder)
            return submenu(
                ToolbarItems.definition(id).label,
                fields.map { field in
                    overflowItem(
                        "Group by \(field.title)", checked: grouped == field, enabled: can(field.command),
                        run: run(field.command))
                } + [
                    .separator(),
                    overflowItem(
                        "Reverse Group Order",
                        checked: (context as? MainWindowController)?.activePane.activeGroupReversed == true,
                        enabled: can(.reverseGroupOrder), run: run(.reverseGroupOrder)),
                ])
        case .viewOptions:
            let can = canPerform ?? context.commandAvailability()
            return submenu(
                ToolbarItems.definition(id).label,
                [
                    overflowItem(
                        "Folders First", checked: view.foldersFirst, enabled: can(.toggleFoldersFirst),
                        run: run(.toggleFoldersFirst)),
                    overflowItem("Hidden Files", checked: view.includeHidden, run: run(.toggleHiddenFiles)),
                    overflowItem("Info Panel", checked: panels.propertiesOpen, run: run(.toggleInfoPanel)),
                    overflowItem("Info Row", checked: panels.detailRowOpen, run: run(.toggleInfoRow)),
                    overflowItem("Customize Toolbar…", run: run(.customizeToolbar)),
                ])
        case .foldersFirst:
            let can = canPerform ?? context.commandAvailability()
            return overflowItem(
                "Folders First", checked: view.foldersFirst, enabled: can(.toggleFoldersFirst),
                run: run(.toggleFoldersFirst))
        case .hidden:
            return overflowItem("Hidden Files", checked: view.includeHidden, run: run(.toggleHiddenFiles))
        case .folderTree:
            return overflowItem("Folder Tree", checked: panels.folderTreeOpen, run: run(.toggleFolderTree))
        case .infoPanel:
            return overflowItem("Info Panel", checked: panels.propertiesOpen, run: run(.toggleInfoPanel))
        case .twoPanes:
            let shown = (context as? MainWindowController)?.showsTwoPanes == true
            return overflowItem("Two Panes", checked: shown, run: run(.toggleTwoPanes))
        case .infoRow:
            return overflowItem("Info Row", checked: panels.detailRowOpen, run: run(.toggleInfoRow))
        case .theme:
            let theme = context.preferences.theme
            return submenu(
                ToolbarItems.definition(id).label,
                AppPreferenceLimits.themeOptions.map { option in
                    overflowItem(option.label, checked: theme == option.value) { [weak self] in
                        self?.context?.updatePreferences { $0.theme = option.value }
                    }
                })
        default:
            guard let command = ToolbarItems.definition(id).commandType else { return nil }
            return overflowItem(
                Tooltips.toolbarItemLabel(itemID: id, state: tooltipState),
                enabled: (canPerform ?? context.commandAvailability())(command),
                run: run(command))
        }
    }
}
