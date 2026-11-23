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

    /// The window a saved view's sheet goes over; nil, with a beep, while a sheet, a dialog or a name being edited
    /// holds the tab, as nothing else opens over those.
    private var canPresentSavedViewSheet: NSWindow? {
        guard let window, group?.isBlocked != true, dialogs.isEmpty else {
            NSSound.beep()
            return nil
        }
        return window
    }

    /// Save Tab View… (`editing` nil) or Edit… in the Views window: Tab View Options over this tab, filled in from it,
    /// and from the tab view being edited. Save keeps it in the list: in its place when edited, at the end when new, or
    /// in place of the one whose name it takes.
    func presentTabViewOptions(editing: TabView? = nil) {
        guard let window = canPresentSavedViewSheet else { return }
        AppMenuPresenter.shared.close()
        let label = tabDescription.label
        let tab = tabViewState
        let columnWidth = workspace.paneColumnWidth
        let draft = TabViewDraft(tab: tab, columnWidth: columnWidth, editing: editing, name: label)
        let sheet = TabViewOptionsSheet(
            draft: draft, saved: tabViews, density: preferences.density, subtitle: label,
            startsOn: showsTwoPanes && activePaneIndex == 1 ? .right : .left,
            load: { view in TabViewDraft(tab: tab, columnWidth: columnWidth, editing: view) })
        let scrim = DialogScrim(panel: sheet, placement: .sheet)
        scrim.setAccessibilityIdentifier("tabViewOptions.scrim")
        sheet.onCancel = { [weak scrim] in scrim?.dismiss() }
        sheet.onManage = { [weak self, weak scrim] in
            scrim?.dismiss()
            self?.manageViews(.tabViews)
        }
        sheet.chooseFolder = { [weak self, weak window] done in
            let start = self?.shownFolderPath
            Task { @MainActor in done(await Self.pickDirectory(start, window)) }
        }
        sheet.onSave = { [weak self, weak scrim] draft in
            guard let self else { return }
            // A new one past the limit keeps the sheet up, so another name can be chosen to save over.
            guard !self.refusesNew(draft.name, editing: draft.editingID, in: self.tabViews, kind: .tabViews, scrim)
            else { return }
            scrim?.dismiss()
            self.saveTabView(draft)
        }
        scrim.present(in: window)
    }

    /// Saves what the sheet settled.
    private func saveTabView(_ draft: TabViewDraft) {
        let name = SavedViewNames.clean(draft.name)
        guard !name.isEmpty else { return }
        let kept = tabViews
        let taken = SavedViewNames.index(named: name, in: kept)
        guard draft.editingID != nil || taken != nil || kept.count < SavedViewNames.limit else { return }
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
        guard let window = canPresentSavedViewSheet else { return }
        AppMenuPresenter.shared.close()
        let folderTreeOpen = preferences.folderTreeOpen
        let propertiesOpen = preferences.propertiesOpen
        let sheet = WindowViewOptionsSheet(
            draft: draft, saved: saved, tabViews: tabViews,
            load: { [weak window] view in
                WindowViewDraft(
                    editing: view, sizeNow: draft.sizeNow, folderTreeOpen: folderTreeOpen,
                    propertiesOpen: propertiesOpen, largestSize: WindowView.room(on: window))
            })
        let scrim = DialogScrim(panel: sheet, placement: .sheet)
        scrim.setAccessibilityIdentifier("windowViewOptions.scrim")
        sheet.onCancel = { [weak scrim] in scrim?.dismiss() }
        sheet.onManage = { [weak self, weak scrim] in
            scrim?.dismiss()
            self?.manageViews(.windowViews)
        }
        sheet.onSave = { [weak self, weak scrim] draft in
            guard let self else { return }
            guard
                !self.refusesNew(
                    draft.name, editing: draft.editingID, in: self.preferences.windowViews, kind: .windowViews, scrim)
            else { return }
            scrim?.dismiss()
            self.saveWindowView(draft)
        }
        scrim.present(in: window)
    }

    /// Edit… of a window view in the Views window: its sheet over this window.
    func editWindowView(_ view: WindowView) {
        guard let window else { return }
        let draft = WindowViewDraft(
            editing: view, sizeNow: WindowView.Size(width: Int(window.frame.width), height: Int(window.frame.height)),
            folderTreeOpen: preferences.folderTreeOpen, propertiesOpen: preferences.propertiesOpen,
            largestSize: WindowView.room(on: window))
        presentWindowViewOptions(draft, saved: preferences.windowViews, tabViews: tabViews)
    }

    private func saveWindowView(_ draft: WindowViewDraft) {
        let name = SavedViewNames.clean(draft.name)
        guard !name.isEmpty else { return }
        let kept = preferences.windowViews
        let taken = SavedViewNames.index(named: name, in: kept)
        guard draft.editingID != nil || taken != nil || kept.count < SavedViewNames.limit else { return }
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

    /// Whether a sheet's Save would add a new one, named `typed`, to `kept` already at the limit: then a notice over
    /// the sheet says so, with Manage… to the Views window (the sheet closing) and OK back to the sheet, where another
    /// name can be chosen to save over.
    private func refusesNew<View: NamedSavedView>(
        _ typed: String, editing: String?, in kept: [View], kind: ViewsWindowPane, _ sheet: DialogScrim?
    ) -> Bool {
        let name = SavedViewNames.clean(typed)
        guard editing == nil, !name.isEmpty, SavedViewNames.index(named: name, in: kept) == nil,
            kept.count >= SavedViewNames.limit, let window
        else { return false }
        let words = kind == .tabViews ? "tab views" : "window views"
        let manage = kind == .tabViews ? "Manage Tab Views\u{2026}" : "Manage Window Views\u{2026}"
        let count = kept.count
        // Stacked, so Manage Tab Views… shows whole on the narrow alert.
        Task { @MainActor [weak self, weak sheet] in
            let goes = await InWindowAlerts.ask(
                title: SavedViewNames.limitTitle(kind: words),
                message: SavedViewNames.saveLimitMessage(kind: words, name: name, count: count),
                buttons: [
                    AlertButtonSpec(manage, .plain, answer: true), AlertButtonSpec("OK", .default, answer: false),
                ],
                escape: false, stacked: true, in: window)
            guard goes else { return }
            sheet?.dismiss()
            self?.manageViews(kind)
        }
        return true
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
            PaneState(
                folder: closed.start.path, settings: activePane.tabViewState.settings,
                viewerDefaults: activePane.viewerDefaults)
        }
        return TabState(
            panes: panes.map(\.tabViewState), active: activePaneIndex, split: workspace.paneSplit,
            includeHidden: includeHidden, closedPane: closed)
    }

    /// `keeps` applied: the second pane opened or closed as ⌘\ does, the divider, hidden files, then each pane given
    /// settings takes them and goes to its folder where the tab view keeps one, and its viewer opens where it keeps
    /// one.
    func apply(_ keeps: TabViewKeeps) {
        let applied = TabViews.applying(keeps, to: tabViewState, columnWidth: workspace.paneColumnWidth)
        if case .closed(let index)? = applied.secondPane, panes.indices.contains(index),
            panes[index].viewer?.isDirty == true
        {
            // A pane with a file's edits not saved closes only once they are saved or dropped; Cancel applies
            // nothing.
            afterLeavingViewer(of: panes[index]) { $0.apply(keeps) }
            return
        }
        switch applied.secondPane {
        case .opened?: openSecondPane()
        case .closed(let index)?:
            // The pane kept is the one Two Panes leaves: the other is made the active one first when it is that one.
            if index == activePaneIndex, panes.indices.contains(1 - index) { focusPane(panes[1 - index]) }
            closeOtherPane()
        case nil: break
        }
        if keeps.forgetsSecondPane == true { forgetClosedSecondPane() }
        if keeps.divider != nil, showsTwoPanes { workspace.setPaneSplit(applied.tab.split) }
        if applied.tab.includeHidden != includeHidden { perform(.toggleHiddenFiles) }
        let given = keeps.paneKeeps(active: activePaneIndex)
        tabViewApplyNumber += 1
        // Viewers that give way: a pane's that gets a view of a folder, and the other pane's of one that gets the
        // viewer. Each asks about its edits; what waits on one goes on only once it has closed.
        var closing: [Int: Task<Bool, Never>] = [:]
        for index in applied.viewersClosed where panes.indices.contains(index) {
            let pane = panes[index]
            closing[index] = Task { [weak self] in await self?.closeViewer(in: pane) ?? false }
        }
        var viewers: [(index: Int, setting: PaneViewer)] = []
        for (index, paneKeeps) in given where panes.indices.contains(index) {
            let pane = panes[index]
            pane.takeViewerDefaults(paneKeeps)
            // The viewer opens over the pane's list, which takes the rest as any pane does.
            if let viewer = applied.viewers[index] { viewers.append((index, viewer)) }
            let before = pane.shownOrder
            pane.takeTabViewSettings(paneKeeps.view, sizes: paneKeeps.sizes)
            if let results = paneKeeps.searchResults { pane.takeSearchResultsView(results) }
            if let folder = paneKeeps.folder, DiskPath(folder) != DiskPath(pane.folderPath) || pane.folderLetGo {
                // The view and columns now carried show as the folder arrives: arriving in a folder with no view of
                // its own shows nothing new by itself.
                pane.refreshColumns()
                pane.content.setMode(pane.shownViewMode)
                pane.go(to: folder, cause: .command)
            } else {
                pane.showTabViewSettings(orderBefore: before)
            }
        }
        // A viewer goes in once its own pane, and the list beside it it follows, have taken their folders and
        // settings: it shows what a list selects there, and its pane going to its folder would close it. Each
        // navigation is under way by now.
        for (index, setting) in viewers {
            if applied.viewersInPlace.contains(index) {
                showViewerInPlaceWhenSettled(setting, in: panes[index])
            } else {
                showViewerWhenListSettles(
                    setting, in: panes[index], beside: panes[index == 0 ? 1 : 0],
                    after: closing[index == 0 ? 1 : 0])
            }
        }
        group?.tabChanged(self)
    }

    /// `setting` shown in `pane` once `list` has settled in its folder and its own viewer, if it had one, has closed
    /// (`closing` true). Nothing happens if either pane has gone from the tab, or another tab view was applied
    /// meanwhile.
    private func showViewerWhenListSettles(
        _ setting: PaneViewer, in pane: BrowserPane, beside list: BrowserPane, after closing: Task<Bool, Never>?
    ) {
        let number = tabViewApplyNumber
        let stillApplies = { [weak self, weak pane, weak list] () -> (BrowserPane, BrowserPane)? in
            guard let self, let pane, let list, number == tabViewApplyNumber,
                panes.contains(where: { $0 === pane }), panes.contains(where: { $0 === list })
            else { return nil }
            return (pane, list)
        }
        let show = { [weak self, weak pane, weak list] in
            pane?.whenNavigationSettles {
                list?.whenNavigationSettles {
                    guard let (pane, list) = stillApplies() else { return }
                    self?.showTabViewViewer(setting, in: pane, beside: list)
                }
            }
        }
        guard let closing else {
            show()
            return
        }
        Task {
            guard await closing.value, stillApplies() != nil else { return }
            show()
        }
    }

    /// `setting` shown over `pane`'s own list once it has settled in its folder. Nothing happens if the pane has gone
    /// from the tab, or another tab view was applied meanwhile.
    private func showViewerInPlaceWhenSettled(_ setting: PaneViewer, in pane: BrowserPane) {
        let number = tabViewApplyNumber
        pane.whenNavigationSettles { [weak self, weak pane] in
            guard let self, let pane, number == tabViewApplyNumber, panes.contains(where: { $0 === pane }) else {
                return
            }
            showTabViewViewerInPlace(setting, in: pane)
        }
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
