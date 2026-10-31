// Port of the toolbar's menus of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx with HistoryButton.tsx,
// ThemeMenuButton.tsx and the entries of ToolbarOverflowButton.tsx
import AppKit
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

    /// The Sort menu's place: 8 below the button, its left edge kept 12 inside the window.
    private func sortMenuOrigin(_ anchor: ToolbarButton) -> NSPoint? {
        guard let rect = frameInContent(anchor), let host = menuHost(of: anchor) else { return nil }
        let width = Self.sortMenuWidth
        return NSPoint(x: max(12, min(rect.minX, host.bounds.width - width - 12)), y: rect.maxY + 8)
    }

    static let sortMenuWidth = 200.0

    /// The window was resized: the Sort menu closes when its button goes to the » menu (`sortMenuResetKey`).
    func windowResized() {
        if item(.sort)?.isVisible == false { closeSortMenu() }
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries =
            back
            ? HistoryMenu.backEntries(
                historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home)
            : HistoryMenu.forwardEntries(
                historyPaths: context.historyPaths, historyIndex: context.historyIndex, homePath: home)
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
        guard let context, let origin = sortMenuOrigin(anchor) else { return }
        let view = context.viewState
        var items = SortByPreference.menuOrder.map { value in
            AppMenuItem(
                title: Self.sortLabel(value), checked: view.sortBy == value,
                action: { [weak self] in
                    if value != view.sortBy { self?.context?.perform(Self.sortCommand(value)) }
                })
        }
        items.append(.separator)
        for direction in [SortDirectionPreference.asc, .desc] {
            items.append(
                AppMenuItem(
                    title: direction == .asc ? "Ascending" : "Descending", checked: view.sortDirection == direction,
                    action: { [weak self] in
                        if direction != view.sortDirection { self?.context?.perform(Self.sortCommand(view.sortBy)) }
                    }))
        }
        let menu = AppMenu(
            items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item", minWidth: Self.sortMenuWidth)
        present(menu, from: anchor, at: origin)
    }

    static func sortCommand(_ value: SortByPreference) -> RendererCommand {
        switch value {
        case .name: .sortByName
        case .kind: .sortByKind
        case .modified: .sortByModified
        case .size: .sortBySize
        }
    }

    func viewOptionsMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let view = context.viewState
        let panels = context.panels
        let shortcuts = shortcuts
        func key(_ shortcut: ShortcutCommandID) -> MenuKeyEquivalent? {
            shortcuts.written(shortcut).flatMap(MenuKeyEquivalent.parse)
        }
        func toggle(_ title: String, _ shortcut: ShortcutCommandID, _ on: Bool, _ command: RendererCommand)
            -> AppMenuItem
        {
            AppMenuItem(
                title: title, key: key(shortcut), checked: on,
                action: { [weak self] in self?.context?.perform(command) })
        }
        let items: [AppMenuItem] = [
            toggle("Folders First", .toggleFoldersFirst, view.foldersFirst, .toggleFoldersFirst),
            toggle("Hidden Files", .toggleHiddenFiles, view.includeHidden, .toggleHiddenFiles),
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

    func themeMenu(anchor: ToolbarButton) {
        guard let context else { return }
        let theme = context.preferences.theme
        let items = AppPreferenceLimits.themeOptions.map { option in
            AppMenuItem(
                title: option.label, checked: theme == option.value,
                action: { [weak self] in self?.context?.updatePreferences(["theme": .string(option.value.rawValue)]) })
        }
        present(AppMenu(items: items, identifier: "toolbarMenu", rowIdentifier: "toolbarMenu.item"), from: anchor)
    }

    // MARK: The » menu

    /// What the system's » menu says for an item with no room, worded as in the menu bar (`getOverflowEntries`). The
    /// items that are several choices (the view, the sort, the theme) are a submenu: the system's menu holds one entry
    /// per item.
    func overflowEntry(_ id: ToolbarItemID) -> NSMenuItem? {
        guard let context else { return nil }
        let view = context.viewState
        let panels = context.panels
        func run(_ command: RendererCommand) -> () -> Void { { [weak self] in self?.context?.perform(command) } }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            menu.items = items
            entry.submenu = menu
            return entry
        }
        switch id {
        case .topSeparator, .search:
            return nil
        case .title:
            return overflowItem(Self.title(of: context), enabled: false) {}
        case .clipboard:
            return overflowItem(ToolbarItems.definition(id).label) { [weak self] in
                guard let self, let button = self.clipboardButton, let tab = self.context as? MainWindowController
                else { return }
                tab.clipboardUI.toggle(from: button)
            }
        case .back:
            return overflowItem("Back", enabled: context.canGoBack, run: run(.goBack))
        case .forward:
            return overflowItem("Forward", enabled: context.canGoForward, run: run(.goForward))
        case .up:
            return overflowItem(
                "Enclosing Folder", enabled: ExplorerTabs.parentDirectoryPath(context.shownFolderPath) != nil
            ) { [weak self] in self?.context?.goToParentFolder() }
        case .view:
            return submenu(
                ToolbarItems.definition(id).label,
                ExplorerViewMode.menuOrder.map { mode in
                    // The view on screen: search results show in one of their own (`shownViewMode`).
                    let shown = context.searchRootPath != nil ? view.searchViewMode : view.viewMode
                    return overflowItem("as \(mode.menuName)", checked: shown == mode, run: run(Self.viewCommand(mode)))
                })
        case .sort:
            return submenu(
                ToolbarItems.definition(id).label,
                SortByPreference.menuOrder.map { value in
                    overflowItem("Sort by \(Self.sortLabel(value))", checked: view.sortBy == value) { [weak self] in
                        if value != view.sortBy { self?.context?.perform(Self.sortCommand(value)) }
                    }
                })
        case .viewOptions:
            return submenu(
                ToolbarItems.definition(id).label,
                [
                    overflowItem("Folders First", checked: view.foldersFirst, run: run(.toggleFoldersFirst)),
                    overflowItem("Hidden Files", checked: view.includeHidden, run: run(.toggleHiddenFiles)),
                    overflowItem("Info Panel", checked: panels.propertiesOpen, run: run(.toggleInfoPanel)),
                    overflowItem("Info Row", checked: panels.detailRowOpen, run: run(.toggleInfoRow)),
                    overflowItem("Customize Toolbar…", run: run(.customizeToolbar)),
                ])
        case .foldersFirst:
            return overflowItem("Folders First", checked: view.foldersFirst, run: run(.toggleFoldersFirst))
        case .hidden:
            return overflowItem("Hidden Files", checked: view.includeHidden, run: run(.toggleHiddenFiles))
        case .folderTree:
            return overflowItem("Folder Tree", checked: panels.folderTreeOpen, run: run(.toggleFolderTree))
        case .infoPanel:
            return overflowItem("Info Panel", checked: panels.propertiesOpen, run: run(.toggleInfoPanel))
        case .infoRow:
            return overflowItem("Info Row", checked: panels.detailRowOpen, run: run(.toggleInfoRow))
        case .theme:
            let theme = context.preferences.theme
            return submenu(
                ToolbarItems.definition(id).label,
                AppPreferenceLimits.themeOptions.map { option in
                    overflowItem(option.label, checked: theme == option.value) { [weak self] in
                        self?.context?.updatePreferences(["theme": .string(option.value.rawValue)])
                    }
                })
        default:
            guard let command = ToolbarItems.definition(id).commandType else { return nil }
            return overflowItem(
                Tooltips.toolbarItemLabel(itemID: id, state: tooltipState), enabled: context.canPerform(command),
                run: run(command))
        }
    }
}
