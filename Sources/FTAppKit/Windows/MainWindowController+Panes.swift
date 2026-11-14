// Two panes in a tab: opening and closing the second, which one is active, and Tab between them
import AppKit
import FTFoundation

extension MainWindowController {
    /// The tab shows two panes side by side.
    var showsTwoPanes: Bool { panes.count > 1 }

    /// The pane that isn't active, while the tab shows two.
    var otherPane: BrowserPane? {
        showsTwoPanes ? panes[activePaneIndex == 0 ? 1 : 0] : nil
    }

    /// The smallest the window can be: wider while it shows two panes, so each keeps its room.
    var minimumWindowSize: NSSize {
        guard showsTwoPanes else { return Self.minimumSize }
        return NSSize(width: Self.minimumSize.width + workspace.extraContentWidth, height: Self.minimumSize.height)
    }

    // MARK: The second pane

    /// View ▸ Two Panes (⌘\): opens the second pane, or closes the one that isn't active.
    func toggleTwoPanes() {
        if showsTwoPanes {
            closeOtherPane()
        } else {
            openSecondPane()
        }
    }

    /// Opens the second pane, to the right, on `path`; without one, where it was last closed in this tab, or else on the
    /// active pane's folder. The active pane stays active. With two panes already, the other one opens `path`.
    @discardableResult
    func openSecondPane(at path: String? = nil) -> BrowserPane {
        if let other = otherPane {
            if let path { other.go(to: URL(fileURLWithPath: path)) }
            return other
        }
        let source = activePane
        let start: StartupTab
        var history: (paths: [String], index: Int)?
        if path == nil, let closed = closedSecondPane {
            start = closed.start
            history = (closed.history.paths, closed.history.index)
        } else {
            start = startupTab(of: source, path: path ?? source.shownFolderPath)
        }
        let pane = BrowserPane(tab: start, history: history, folderSizes: folderSizes, startsTheWindow: false)
        pane.tab = self
        pane.watchID = Self.makeWatchID()
        panes.append(pane)
        install(pane)
        workspace.showSecondPane(pane.content.view, status: pane.content.contentShell.pathBarRow)
        fitWindowToPanes()
        pane.ensureLoaded()
        panesChanged()
        return pane
    }

    /// Closes the pane that isn't active; the active one takes the whole width. Where the closed one was is kept, for
    /// ⌘\ to open it there again.
    func closeOtherPane() {
        guard let gone = otherPane else { return }
        let keep = activePane
        let hadKeyboard = paneWithKeyboard === gone
        closedSecondPane = (startupTab(of: gone, path: gone.shownFolderPath), gone.navigationHistory)
        closedPaneWatchID = gone.watchID
        gone.searchStore?.session.close()
        // The cells let go of their views first, so the kept pane's view moves into the left cell without being taken out
        // again.
        workspace.showSecondPane(nil, status: nil)
        workspace.mainCell.content = keep.content.view
        workspace.statusCell.content = keep.content.contentShell.pathBarRow
        panes = [keep]
        activePaneIndex = 0
        window?.minSize = minimumWindowSize
        if hadKeyboard { keep.content.focusList() }
        activePaneChanged()
        panesChanged()
    }

    /// The panes changed: the window's watches, title and saved state follow.
    private func panesChanged() {
        window?.minSize = minimumWindowSize
        workspace.activePane = activePaneIndex
        group?.refreshTitles()
        group?.tabChanged(self)
        notify(.panels)
    }

    /// The window is widened, as far as its screen allows, to the width two panes need.
    private func fitWindowToPanes() {
        guard let window else { return }
        let minimum = minimumWindowSize
        window.minSize = minimum
        let frame = window.frame
        guard frame.width < minimum.width, !window.styleMask.contains(.fullScreen) else { return }
        var widened = frame
        widened.size.width = minimum.width
        if let screen = window.screen?.visibleFrame {
            if widened.maxX > screen.maxX { widened.origin.x = max(screen.minX, screen.maxX - widened.width) }
            widened.size.width = min(widened.width, screen.width)
        }
        window.setFrame(widened, display: true)
    }

    /// A pane's place as a new pane starts from it: its view, order and hidden files, on `path`.
    private func startupTab(of pane: BrowserPane, path: String) -> StartupTab {
        StartupTab(
            path: path, rootPath: treeRootPath, favoritePath: nil, viewMode: pane.viewMode,
            searchViewMode: pane.searchViewMode, sortBy: pane.sortBy, sortDirection: pane.sortDirection,
            includeHidden: pane.includeHidden, foldersFirst: pane.foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded)
    }

    /// Connects a pane's list, path bar, menus and drags to the tab.
    func install(_ pane: BrowserPane) {
        wireContent(pane)
        wirePathBar(pane)
        contextMenus.install(on: pane)
        installDrags(on: pane)
        infoController?.watchDetails(of: pane.content)
        pane.content.clipboardMarksChanged(clipboardUI.marks, flash: false)
        pane.refreshColumns()
    }

    // MARK: The active pane

    /// Makes `pane` the active one: the toolbar, the tree, the Info panel and the commands follow it.
    func activate(_ pane: BrowserPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activePaneIndex else { return }
        activePaneIndex = index
        activePaneChanged()
    }

    /// What follows the active pane: the search field, the Info panel and Info Row, the tree's selection, the title
    /// and everything that reads the tab.
    func activePaneChanged() {
        let pane = activePane
        workspace.activePane = activePaneIndex
        pane.search.connect(searchField)
        infoController?.follow(row: pane.content.contentShell.infoRow)
        sidebarController.activePaneChanged(to: pane.shownFolderPath)
        updateTitle()
        if group?.selected === self { group?.frontSearch = pane.searchStore }
        for change: ExplorerWindowChange in [.folder, .history, .view, .search, .selection, .focusedPane] {
            notify(change)
        }
        group?.tabChanged(self)
    }

    /// The pane whose list, or path bar, has the keyboard.
    var paneWithKeyboard: BrowserPane? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return panes.first { pane in
            responder.isDescendant(of: pane.content.view)
                || responder.isDescendant(of: pane.content.contentShell.pathBarRow)
        }
    }

    /// The keyboard went into a pane that isn't active: it becomes the active one.
    func followKeyboardToPane() {
        guard showsTwoPanes, let pane = paneWithKeyboard, pane !== activePane else { return }
        activate(pane)
    }

    /// The keyboard goes to `pane`'s list, which becomes the active one.
    func focusPane(_ pane: BrowserPane) {
        activate(pane)
        pane.content.focusList()
    }

    // MARK: Tab

    /// Tab in a pane's list: on to the next of the tree, the left pane and the right pane, in that order; Shift-Tab
    /// back. A hidden tree is left out. With one pane Tab goes to the tree and back, and with the tree hidden it stays.
    func tabKeyPressed(from pane: BrowserPane) {
        let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let treeOpen = panels.folderTreeOpen
        guard showsTwoPanes, let index = panes.firstIndex(where: { $0 === pane }) else {
            if treeOpen { perform(.focusTreePane) } else { pane.content.focusList() }
            return
        }
        let other = panes[index == 0 ? 1 : 0]
        // Forward from the left pane and back from the right one meet the other pane; the rest meet the tree.
        let towardOther = backward ? index == 1 : index == 0
        if towardOther || !treeOpen {
            focusPane(other)
        } else {
            perform(.focusTreePane)
        }
    }

    /// Tab in the tree: to the left pane, or Shift-Tab to the right one; with one pane, to its list.
    func tabKeyPressedInTree() {
        guard showsTwoPanes else {
            perform(.focusContentPane)
            return
        }
        let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        focusPane(backward ? panes[panes.count - 1] : panes[0])
    }

    /// Window ▸ Switch to Other Pane: the keyboard goes to the other pane's list.
    func switchToOtherPane() {
        guard let other = otherPane else { return }
        focusPane(other)
    }

    // MARK: The tab's label

    /// The tab bar's label while the tab shows two panes: both folders, left first. Nil with one pane.
    var twoPaneLabel: String? {
        guard showsTwoPanes else { return nil }
        let disk = services.startupDisk.name
        let names = panes.map { pane -> String in
            if let session = pane.searchStore?.session, session.resultsVisible {
                return ExplorerTabs.describe(
                    currentPath: pane.shownFolderPath, searchVisible: true, searchQuery: session.committedQuery,
                    searchRootPath: session.rootPath, searchRunning: session.isRunning, startupDiskName: disk
                ).label
            }
            return ExplorerTabs.folderDisplayName(pane.shownFolderPath, startupDiskName: disk)
        }
        return names.joined(separator: " | ")
    }
}
