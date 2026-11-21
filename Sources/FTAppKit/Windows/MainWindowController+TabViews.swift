// Saved Views ▸ Tab Views: a tab view applied to this tab, and the one new tabs open with
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
        let view = tabViews[index]
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
        let ready = onReady
        onReady = { [weak self] in
            ready?()
            guard let self, let id = preferences.newTabViewID else { return }
            applyTabView(id: id)
        }
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
        for (index, paneKeeps) in given where panes.indices.contains(index) {
            let pane = panes[index]
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
