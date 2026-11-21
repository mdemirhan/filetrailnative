// Layout ▸ Tab Views: a tab view applied to this tab, and the one new tabs open with
import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// The tab views kept, in the menu's order.
    var tabViews: [TabView] { preferences.tabViews }

    /// Applies the tab view `id` to this tab, as Tab Views 1 to 5 and the menu's items do. A tab held by a sheet, a
    /// dialog or a name being edited isn't changed: nothing happens, with a beep. A folder of the tab view that is
    /// gone opens the nearest folder above it, and a notice says so.
    func applyTabView(id: String) {
        guard let index = SavedViewNames.index(id: id, in: tabViews) else { return }
        guard group?.isBlocked != true else {
            NSSound.beep()
            return
        }
        apply(tabViews[index])
    }

    /// Applies `view` to this tab: its folders that are gone open the nearest folder above, with a notice.
    func apply(_ view: TabView) {
        let replaced = withGoneFoldersReplaced(view.keeps)
        apply(replaced.keeps)
        lastTabViewID = view.id
        if replaced.count > 0, preferences.notificationsEnabled {
            showNotice(title: WindowNotice.tabViewFoldersGone(panes: replaced.count).title, message: "")
        }
    }

    /// Tab View 1 to 5: the tab view at `slot` in the list; nothing for a slot with none.
    func applyTabView(slot: Int) {
        let kept = tabViews
        guard kept.indices.contains(slot) else { return }
        applyTabView(id: kept[slot].id)
    }

    /// A new tab or a new window's tab, once its first folder is read: the tab view new tabs open with, if one is set
    /// by then.
    func applyNewTabView() {
        applyTabViewWhenReady { [weak self] in self?.preferences.newTabViewID }
    }

    /// `view`, applied once the tab's first folder is read (at once when it has been): each tab of a window view, as
    /// it is first shown.
    func applyTabViewWhenReady(_ view: TabView) {
        panes.first?.whenFirstReadFinished { [weak self] _ in self?.apply(view) }
    }

    /// The tab view `id` names, applied once the tab's first folder is read (at once when it has been): a new tab's.
    func applyTabViewWhenReady(_ id: @escaping @MainActor () -> String?) {
        panes.first?.whenFirstReadFinished { [weak self] _ in
            guard let self, let id = id() else { return }
            applyTabView(id: id)
        }
    }

    // MARK: Tab View Options

    /// Save Tab View… (`editing` nil) or Edit… in the Views window: Tab View Options over this tab, filled in from it,
    /// and from the tab view being edited. Save keeps it in the list: in its place when edited, at the end when new, or
    /// in place of the one whose name it takes.
    func presentTabViewOptions(editing: TabView? = nil) {
        guard let window, group?.isBlocked != true,
            !dialogs.contains(where: { $0.panel is TabViewOptionsSheet || $0.panel is WindowViewOptionsSheet })
        else { return }
        AppMenuPresenter.shared.close()
        let label = tabDescription.label
        let draft = TabViewDraft(
            tab: tabViewState, columnWidth: workspace.paneColumnWidth, editing: editing, name: label)
        let sheet = TabViewOptionsSheet(
            draft: draft, saved: tabViews, density: preferences.density, subtitle: label,
            startsOn: showsTwoPanes && activePaneIndex == 1 ? .right : .left)
        let scrim = DialogScrim(panel: sheet, placement: .sheet)
        scrim.setAccessibilityIdentifier("tabViewOptions.scrim")
        sheet.onCancel = { [weak scrim] in scrim?.dismiss() }
        sheet.onManage = { [weak self, weak scrim] in
            scrim?.dismiss()
            self?.manageViews(.tabViews)
        }
        sheet.chooseFolder = { [weak self, weak window] done in
            let start = self?.shownFolderPath
            Task { @MainActor in
                let choice = await SystemPickers.pickDirectory(defaultPath: start, window: window)
                done(choice.canceled ? nil : choice.path)
            }
        }
        sheet.onSave = { [weak self, weak scrim] draft in
            scrim?.dismiss()
            self?.saveTabView(draft)
        }
        scrim.present(in: window)
    }

    /// Saves what the sheet settled.
    private func saveTabView(_ draft: TabViewDraft) {
        let name = SavedViewNames.clean(draft.name)
        guard !name.isEmpty else { return }
        let kept = tabViews
        let taken = SavedViewNames.index(named: name, in: kept)
        if draft.editingID == nil, taken == nil, kept.count >= SavedViewNames.limit {
            showNotice(title: SavedViewNames.limitTitle(kind: "tab views"), message: SavedViewNames.limitMessage)
            return
        }
        let id = draft.editingID ?? taken.map { kept[$0].id } ?? SavedViewNames.newID("tab-view")
        let view = TabView(id: id, name: name, keeps: draft.keeps)
        updatePreferences { preferences in
            var list = preferences.tabViews
            // A name another tab view has replaces that one; editing keeps its place in the list.
            if let taken, list[taken].id != id {
                let removed = list[taken].id
                list.remove(at: taken)
                preferences.windowViews = WindowViews.forgetting(removed, in: preferences.windowViews)
                if preferences.newTabViewID == removed { preferences.newTabViewID = nil }
            }
            if let at = SavedViewNames.index(id: id, in: list) {
                list[at] = view
            } else {
                list.append(view)
            }
            preferences.tabViews = list
        }
        lastTabViewID = id
    }

    // MARK: Window View Options

    /// Save Window View… (a new one, from this window) or Edit… in the Views window: Window View Options over this
    /// window.
    func presentWindowViewOptions(_ draft: WindowViewDraft, saved: [WindowView], tabViews: [TabView]) {
        guard let window, group?.isBlocked != true,
            !dialogs.contains(where: { $0.panel is TabViewOptionsSheet || $0.panel is WindowViewOptionsSheet })
        else { return }
        AppMenuPresenter.shared.close()
        let sheet = WindowViewOptionsSheet(draft: draft, saved: saved, tabViews: tabViews)
        let scrim = DialogScrim(panel: sheet, placement: .sheet)
        scrim.setAccessibilityIdentifier("windowViewOptions.scrim")
        sheet.onCancel = { [weak scrim] in scrim?.dismiss() }
        sheet.onManage = { [weak self, weak scrim] in
            scrim?.dismiss()
            self?.manageViews(.windowViews)
        }
        sheet.onSave = { [weak self, weak scrim] draft in
            scrim?.dismiss()
            self?.saveWindowView(draft)
        }
        scrim.present(in: window)
    }

    /// Edit… of a window view in the Views window: its sheet over this window.
    func editWindowView(_ view: WindowView) {
        guard let window else { return }
        let draft = WindowViewDraft(
            editing: view, sizeNow: WindowView.Size(width: Int(window.frame.width), height: Int(window.frame.height)),
            folderTreeOpen: preferences.folderTreeOpen, propertiesOpen: preferences.propertiesOpen,
            largestSize: WindowViewOptionsSheet.screenRoom(of: window))
        presentWindowViewOptions(draft, saved: preferences.windowViews, tabViews: tabViews)
    }

    private func saveWindowView(_ draft: WindowViewDraft) {
        let name = SavedViewNames.clean(draft.name)
        guard !name.isEmpty else { return }
        let kept = preferences.windowViews
        let taken = SavedViewNames.index(named: name, in: kept)
        if draft.editingID == nil, taken == nil, kept.count >= SavedViewNames.limit {
            showNotice(title: SavedViewNames.limitTitle(kind: "window views"), message: SavedViewNames.limitMessage)
            return
        }
        let id = draft.editingID ?? taken.map { kept[$0].id } ?? SavedViewNames.newID("window-view")
        let view = draft.windowView(id: id)
        updatePreferences { preferences in
            var list = preferences.windowViews
            if let taken, list[taken].id != id { list.remove(at: taken) }
            if let at = SavedViewNames.index(id: id, in: list) {
                list[at] = view
            } else {
                list.append(view)
            }
            preferences.windowViews = list
        }
    }

    /// Manage Folder Views…, Manage Tab Views… or Manage Window Views…: the Views window on that pane, acting on this
    /// window.
    func manageViews(_ pane: ViewsWindowPane) {
        ViewsWindowController.show(pane, folderViews: services.folderViews, explorer: self)
    }

    /// The tab as a tab view sees it: its panes, the active one, the divider, hidden files and the pane ⌘\ would bring
    /// back.
    var tabViewState: TabState {
        let closed = closedSecondPane.map { closed in
            PaneState(folder: closed.start.path, settings: activePane.tabViewState.settings)
        }
        return TabState(
            panes: panes.map(\.tabViewState), active: activePaneIndex, split: workspace.paneSplit,
            includeHidden: includeHidden, closedPane: closed)
    }

    /// `keeps` applied: the second pane opened or closed as ⌘\ does, the divider, hidden files, then each pane given
    /// settings takes them, goes to its folder where the tab view keeps one, and holds the override the tab view
    /// leaves.
    func apply(_ keeps: TabViewKeeps) {
        let applied = TabViews.applying(keeps, to: tabViewState, columnWidth: workspace.paneColumnWidth)
        switch applied.secondPane {
        case .opened?: openSecondPane()
        case .closed?: closeOtherPane()
        case nil: break
        }
        if keeps.divider != nil, showsTwoPanes { workspace.setPaneSplit(applied.tab.split) }
        if applied.tab.includeHidden != includeHidden { perform(.toggleHiddenFiles) }
        let given = keeps.paneKeeps(active: activePaneIndex)
        for index in applied.viewersClosed where panes.indices.contains(index) {
            let pane = panes[index]
            Task { [weak self] in await self?.closeViewer(in: pane) }
        }
        for (index, paneKeeps) in given where panes.indices.contains(index) {
            let pane = panes[index]
            if let viewer = paneKeeps.viewer {
                // A viewer is applied once the other pane has taken its folder and settings: it shows what that
                // list selects there.
                let list = panes[index == 0 ? 1 : 0]
                DispatchQueue.main.async { [weak self, weak pane, weak list] in
                    guard let self, let pane, let list else { return }
                    list.whenFirstReadFinished { [weak self] _ in
                        self?.showTabViewViewer(viewer, in: pane, beside: list)
                    }
                }
                continue
            }
            let before = pane.shownOrder
            pane.tabViewOverride = nil
            pane.arrivingTabViewOverride = nil
            pane.takeTabViewSettings(paneKeeps.view)
            let override = paneKeeps.choice == .folderFirst ? nil : paneKeeps
            if let folder = paneKeeps.folder, DiskPath(folder) != DiskPath(pane.folderPath) || pane.folderLetGo {
                // The override waits for the folder to arrive, and holds there by the path its listing gives.
                pane.arrivingTabViewOverride = override.map {
                    TabViewOverride(folder: folder, choice: $0.choice, kept: Set($0.view.kept))
                }
                // The view and columns now carried show as the folder arrives: arriving in a folder with no view of
                // its own shows nothing new by itself.
                pane.refreshColumns()
                pane.content.setMode(pane.shownViewMode)
                pane.go(to: folder)
            } else {
                pane.tabViewOverride = override.map {
                    TabViewOverride(folder: pane.folderPath, choice: $0.choice, kept: Set($0.view.kept))
                }
                pane.showTabViewSettings(orderBefore: before)
            }
        }
        group?.tabChanged(self)
    }

    /// The tab view with each folder that is gone shown as the nearest folder above it that is there (Home when none
    /// is), and how many were. A folder whose disk doesn't answer in time is kept: its pane finds its way when shown.
    private func withGoneFoldersReplaced(_ keeps: TabViewKeeps) -> (keeps: TabViewKeeps, count: Int) {
        let folders = keeps.folders
        guard !folders.isEmpty else { return (keeps, 0) }
        let kept = ScreenGeometry.keepsWaitingTabs(folders)
        let gone = Set(zip(folders, kept).filter { !$0.1 }.map { DiskPath($0.0) })
        let home = NSHomeDirectory()
        let result = TabViews.replacingGoneFolders(keeps, gone: gone) { path in
            ExplorerTabs.pathAndAncestors(path).dropFirst().first { ScreenGeometry.isFolder($0) } ?? home
        }
        return (result.keeps, result.replaced)
    }
}
