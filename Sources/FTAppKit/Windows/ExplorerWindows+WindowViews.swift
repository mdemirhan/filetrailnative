// Layout ▸ Window Views: a window of tab views, opened by name, and saved from a window
import AppKit
import FTFileSystem
import FTFoundation

extension ExplorerWindows {
    /// The window views kept, in the menu's order.
    var windowViews: [WindowView] { store.preferences().windowViews }

    /// Opens the window view `id` in a new window, or in place of `tab`'s window (the menu's item with ⌥). Its tabs
    /// start as new tabs from the pane `tab` (or the window in front) shows, and each takes its tab view as it is
    /// first shown. A window held by a sheet, a dialog or a name being edited isn't replaced: nothing opens, with a
    /// beep.
    func openWindowView(id: String, inPlaceOf tab: MainWindowController? = nil) {
        let kept = windowViews
        guard let index = SavedViewNames.index(id: id, in: kept) else { return }
        if let tab, tab.group?.isBlocked ?? true {
            beep()
            return
        }
        let view = kept[index]
        let source = tab ?? (front as? MainWindowController)
        let preferences = store.preferences()
        var session = source?.preferences.windowSession ?? preferences.windowSession
        let base = source?.activePaneTab ?? Self.homeTab(home, preferences)
        session.openTabs = Array(repeating: base, count: view.tabs.count)
        session.activeTabIndex = view.frontTab
        session.lastVisitedPath = base.path
        session.lastVisitedFavoritePath = nil
        if let tree = view.folderTreeOpen { session.folderTreeOpen = tree }
        if let info = view.propertiesOpen { session.propertiesOpen = info }
        let size = view.size.map {
            StoredWindowState(width: Double($0.width), height: Double($0.height), maximized: false)
        }
        let tabViews = view.resolvedTabs(in: preferences.tabViews)
        var opened: ExplorerTabGroup?
        let shown: () -> Void = {
            guard let opened else { return }
            for (tab, tabView) in zip(opened.tabs, tabViews) {
                guard let tabView else { continue }
                tab.applyTabViewWhenReady(tabView)
            }
        }
        let held: () -> Void = { [weak self] in self?.beep() }
        opened = controller.openSavedWindow(
            session: session, size: size, replacing: tab?.group?.windowID, shown: shown, held: held)
    }

    /// Window View 1 to 5: the window view at `slot` in the list, in a window of its own or in place of `tab`'s.
    /// Nothing for a slot with none.
    func openWindowView(slot: Int, inPlaceOf tab: MainWindowController? = nil) {
        let kept = windowViews
        guard kept.indices.contains(slot) else { return }
        openWindowView(id: kept[slot].id, inPlaceOf: tab)
    }

    /// A tab on Home, for a window view opened with no window to start from.
    private static func homeTab(_ home: String, _ preferences: AppPreferences) -> OpenTabPreference {
        OpenTabPreference(
            path: home, treeRootPath: home, favoritePath: nil, viewMode: preferences.viewMode,
            searchViewMode: preferences.searchViewMode, sortBy: preferences.sortBy,
            sortDirection: preferences.sortDirection, includeHidden: preferences.includeHidden,
            foldersFirst: preferences.foldersFirst, favoritesExpanded: preferences.favoritesExpanded,
            locationsExpanded: preferences.locationsExpanded)
    }

    // MARK: Saving

    /// Save Window View…: Window View Options over `tab`'s window, filled in from it: as many tabs as it has, each
    /// with the tab view last applied to it, the tab in front, its size, folder tree and Info panel.
    func saveWindowView(from tab: MainWindowController) {
        guard let group = tab.group, let window = tab.window, !group.isBlocked else { return }
        let tabViews = store.preferences().tabViews
        let draft = WindowViewDraft(
            tabs: group.tabs.map { tab in
                tab.lastTabViewID.flatMap { SavedViewNames.index(id: $0, in: tabViews) }.map { tabViews[$0].id }
            },
            front: group.tabs.firstIndex { $0 === group.selected } ?? 0,
            size: WindowView.Size(width: Int(window.frame.width), height: Int(window.frame.height)),
            folderTreeOpen: tab.preferences.folderTreeOpen, propertiesOpen: tab.preferences.propertiesOpen,
            largestSize: WindowViewOptionsSheet.screenRoom(of: window))
        tab.presentWindowViewOptions(draft, saved: windowViews, tabViews: tabViews)
    }
}

extension ExplorerWindows {
    /// Manage Folder Views…, Manage Tab Views… or Manage Window Views…, from the menu: the Views window on that pane,
    /// acting on the window in front.
    func manageViews(_ pane: ViewsWindowPane) {
        if let tab = front as? MainWindowController {
            tab.manageViews(pane)
        } else {
            ViewsWindowController.show(pane, folderViews: ExplorerServices.current.folderViews, explorer: nil)
        }
    }
}
