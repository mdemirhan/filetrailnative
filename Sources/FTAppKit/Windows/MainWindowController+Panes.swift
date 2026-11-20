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

    /// View ▸ Duplicate Pane (⌥⌘\): the second pane opens as a copy of the active one, never where a pane was last
    /// closed. With two panes already, the other one is put in its place as that copy, on its side and at its width.
    func duplicatePane() {
        let activeOnTheRight = showsTwoPanes && activePaneIndex == 1
        if showsTwoPanes { closeOtherPane() }
        openSecondPane(reopening: false)
        if activeOnTheRight { swapPanes() }
    }

    /// Opens the second pane, to the right, on `path`; without one, where it was last closed in this tab (unless
    /// `reopening` is false), or else as a copy of the active pane. The active pane stays active. With two panes
    /// already, the other one opens `path`.
    @discardableResult
    func openSecondPane(at path: String? = nil, reopening: Bool = true) -> BrowserPane {
        if let other = otherPane {
            if let path { other.go(to: URL(fileURLWithPath: path)) }
            return other
        }
        let source = activePane
        var start: StartupTab
        var history: (paths: [String], index: Int)?
        var view: TabViewState?
        if path == nil, reopening, let closed = closedSecondPane {
            start = closed.start
            history = (closed.history.paths, closed.history.index)
            view = closed.view
        } else if let path, path != source.shownFolderPath {
            start = startupTab(of: source, path: path)
        } else {
            // A pane opened on the active pane's own folder is a copy of it, as Duplicate Tab copies a tab: its view,
            // order and sizes, its folder's filter mode, and its Back and Forward. What is typed (a filter, a search)
            // and what is selected are left behind.
            start = startupTab(of: source, path: source.shownFolderPath)
            start.filterMode = source.content.folderFilterMode
            history = (source.navigationHistory.paths, source.navigationHistory.index)
        }
        // Hidden Files is the tab's: a pane opened again where it was takes it as the tab has it now.
        start.includeHidden = includeHidden
        let keyboard = paneWithKeyboard
        let pane = addSecondPane(start: start, history: history)
        if let view { pane.carry(view) }
        pane.ensureLoaded()
        panesChanged()
        keepKeyboard(in: keyboard)
        return pane
    }

    /// The list that had the keyboard before the panes changed has it still: a view moved in the window lets go of it.
    private func keepKeyboard(in pane: BrowserPane?) {
        guard let pane, panes.contains(where: { $0 === pane }), paneWithKeyboard !== pane else { return }
        focusPane(pane)
    }

    /// The second pane, made and put in place unread.
    private func addSecondPane(start: StartupTab, history: (paths: [String], index: Int)?) -> BrowserPane {
        let pane = BrowserPane(tab: start, history: history, folderSizes: folderSizes, startsTheWindow: false)
        pane.tab = self
        pane.watchID = Self.makeWatchID()
        panes.append(pane)
        install(pane)
        workspace.showSecondPane(pane.content.view, status: pane.content.contentShell.pathBarRow)
        fitWindowToPanes()
        return pane
    }

    /// A tab brought back with two panes (a relaunch, Reopen Closed Tab, Duplicate Tab, a tab moved to another
    /// window): its second pane as it was kept, read with the tab's first. It shows hidden files as the first does, the
    /// tab having one Hidden Files (`PreferencesSanitizer.openTabs` reads a file saved while each pane had its own).
    func restoreSecondPane(
        _ saved: OpenPanePreference, history: (paths: [String], index: Int)?, view: TabViewState? = nil, active: Bool,
        split: Double?
    ) {
        guard !showsTwoPanes else { return }
        let start = StartupTab(
            path: saved.path ?? "", rootPath: treeRootPath, favoritePath: nil, viewMode: saved.viewMode,
            searchViewMode: saved.searchViewMode, sortBy: saved.sortBy, sortDirection: saved.sortDirection,
            includeHidden: includeHidden, foldersFirst: saved.foldersFirst, favoritesExpanded: favoritesExpanded,
            locationsExpanded: locationsExpanded, viewSizes: saved.viewSizes, filterMode: saved.filterMode,
            groupBy: saved.groupBy ?? .none, searchGroupBy: saved.searchGroupBy ?? .none)
        let pane = addSecondPane(start: start, history: history)
        if let view { pane.carry(view) }
        if let split { workspace.setPaneSplit(split) }
        if loaded { pane.ensureLoaded() }
        if active {
            activePaneIndex = 1
            activePaneChanged(saving: false)
        }
        panesChanged()
    }

    /// Closes the pane that isn't active; the active one takes the whole width. Where the closed one was is kept, for
    /// ⌘\ to open it there again as it was: its history, filter mode, selection, filters and scroll.
    func closeOtherPane() {
        guard let gone = otherPane else { return }
        let keep = activePane
        let keyboard = paneWithKeyboard
        var start = startupTab(of: gone, path: gone.shownFolderPath)
        start.filterMode = gone.content.folderFilterMode
        closedSecondPane = (start, gone.navigationHistory, gone.closedView)
        closedPaneWatchID = gone.watchID
        // Folder Customization open on the pane that goes has nothing left to change.
        if folderViewPopover?.pane === gone { closeFolderViewPopover() }
        gone.searchStore?.session.close()
        gone.searchStore?.disconnect()
        // A folder the closed pane was still being decided on was only passed through.
        gone.visitTracker.dispose()
        // The cells let go of their views first, so the kept pane's view moves into the left cell without being taken out
        // again.
        workspace.showSecondPane(nil, status: nil)
        workspace.mainCell.content = keep.content.view
        workspace.statusCell.content = keep.content.contentShell.pathBarRow
        panes = [keep]
        activePaneIndex = 0
        window?.minSize = minimumWindowSize
        // The active pane is the one it was: nothing that follows it is told of a change, so the sidebar's row (a
        // favorite it was opened from) and Show Info's item stay as they are.
        updateTitle()
        panesChanged()
        // The list that had the keyboard keeps it; the pane that went gives it to the one that stays.
        if keyboard != nil { keepKeyboard(in: keep) }
    }

    /// File ▸ Close Pane (⌘W): while the tab shows two panes, the active one closes and the other takes the whole
    /// width, active, with the keyboard if the closed one had it; ⌘\ opens the closed one again, on the right. With one
    /// pane the tab closes, and the window on its last tab.
    func closePane() {
        guard showsTwoPanes else {
            group?.closeTab(self)
            return
        }
        // A rename being typed or a dialog open holds the tab, as it holds Close Tab.
        guard group?.isBlocked != true, let other = otherPane,
            let index = panes.firstIndex(where: { $0 === other })
        else { return }
        // The other pane becomes the active one, and what follows the active pane follows it; the one that was active is
        // then the other pane, closed as ⌘\ closes it.
        activePaneIndex = index
        activePaneChanged(saving: false)
        closeOtherPane()
    }

    /// The panes changed: the window's watches, title and saved state follow, the Info Row goes to the active pane, and
    /// the tab's magnifier to the searches still there.
    private func panesChanged() {
        window?.minSize = minimumWindowSize
        workspace.activePane = activePaneIndex
        showInfoRow(animated: false)
        updateSearchTabAccessory()
        group?.tabChanged(self)
        notify(.panels)
    }

    /// The Info Row shows in the active pane only, as it describes that pane's selection: the other pane has none.
    func showInfoRow(animated: Bool) {
        let open = panels.detailRowOpen
        for pane in panes { pane.content.setInfoRowOpen(open && pane === activePane, animated: animated) }
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
            locationsExpanded: locationsExpanded, viewSizes: pane.viewSizes, groupBy: pane.groupBy,
            searchGroupBy: pane.searchGroupBy)
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

    // MARK: Across the panes

    /// Copy or Move to Other Pane: the selection goes into the other pane's folder through the paste's flow, so what is
    /// there already is reviewed first, and Undo takes it back. The active pane stays active.
    func sendSelectionToOtherPane(copying: Bool) {
        sendToOtherPane(selectedPaths, copying: copying)
    }

    /// `paths` of the active pane go into the other pane's folder (the right-click menu's Copy and Move).
    func sendToOtherPane(_ sources: [String], copying: Bool) {
        guard let other = otherPane, let destination = otherPaneDestination(other), let actions = writeActions else {
            return
        }
        let searching = searchRootPath != nil
        // Both panes on one folder: nothing to copy or move. The menu items are dimmed then, and the key of a dimmed
        // item still comes here (`keyOfDimmedItem`), where a copy would make a second "name copy" of each item.
        guard !sources.isEmpty, searching || !samePath(destination, activePane.shownFolderPath) else { return }
        let action: WriteOperationAction = copying ? .copyTo : .moveTo
        if actions.refuseWhileBusy(.operation(action)) { return }
        Task {
            if let message = await TabDragDrop.destinationRefusal(destination, services.directoryService) {
                actions.dialogs.showRefusal(.operation(action), message: message, in: window)
                return
            }
            let outcome = await actions.copyLike(
                mode: copying ? .copy : .cut, sources: sources, destination: destination, action: action,
                initiator: .otherPane)
            actions.reviewIfAsked(outcome, action: action)
        }
    }

    /// The folder Copy and Move to Other Pane put items into: the one `other` shows. None while it shows no folder,
    /// search results, or the Trash or a folder in it, where nothing is pasted either.
    func otherPaneDestination(_ other: BrowserPane) -> String? {
        let path = other.shownFolderPath
        guard other.searchRootPath == nil, !path.isEmpty, !Paths.isInsideTrash(path, homePath: trashHomePath) else {
            return nil
        }
        return path
    }

    /// Swap Panes: the panes change places, each keeping its folder, history and view; the active one stays active,
    /// on the other side, whichever had the keyboard.
    func swapPanes() {
        guard showsTwoPanes else { return }
        let active = activePane
        // The views move without leaving the window: the keyboard stays where it is, in the tree, a field or either
        // pane's list, and no pane is made active by it.
        workspace.swapPanes()
        panes.reverse()
        activePaneIndex = panes.firstIndex { $0 === active } ?? 0
        panesChanged()
        // A path being typed keeps its suggestions, over the bar where it is now.
        window?.contentView?.layoutSubtreeIfNeeded()
        for pane in panes { pane.content.contentShell.pathBarRow.editor.editorMoved() }
    }

    /// Make Panes Equal Width, and a double-click on the divider.
    func equalizePanes() {
        guard showsTwoPanes, workspace.paneSplit != PaneSplit.even else { return }
        workspace.setPaneSplit(PaneSplit.even)
        group?.tabChanged(self)
    }

    /// Disks went while the tab is on screen, and it stays: each pane on one opens Home, and a pane elsewhere stays
    /// where it is. A tree rooted on one of them starts again at Home when the active pane doesn't take it there.
    func leaveUnmountedDisks(homePath: String, isGone: (String) -> Bool) {
        guard !homePath.isEmpty else { return }
        let active = activePane
        let activeLeaves = isGone(active.shownFolderPath)
        for pane in panes where isGone(pane.shownFolderPath) { pane.go(to: URL(fileURLWithPath: homePath)) }
        if !activeLeaves, isGone(treeRootPath) {
            sidebarController.model.initializeTree(homePath)
            sidebarController.activePaneChanged(to: active.shownFolderPath)
        }
    }

    // MARK: The active pane

    /// A change of `pane`'s own: its folder, history, view, search or selection. The other pane's is told apart, so
    /// that what follows the active pane keeps what it shows: Show Info's item stays, the active item isn't read again,
    /// and the toolbar keeps the active pane's Back and Forward, view and search.
    func paneChanged(_ change: ExplorerWindowChange, in pane: BrowserPane) {
        notify(pane === activePane ? change : .otherPane(change))
    }

    /// Makes `pane` the active one: the toolbar, the tree, the Info panel and the commands follow it.
    func activate(_ pane: BrowserPane) {
        guard let index = panes.firstIndex(where: { $0 === pane }), index != activePaneIndex else { return }
        activePaneIndex = index
        activePaneChanged()
    }

    /// What follows the active pane: the search field, the Info panel and Info Row, the tree's selection, the title and
    /// everything that reads the tab. Hidden Files is the tab's, so the tree shows what it showed. `saving`: the tab is
    /// saved with its new active pane; off when what comes next saves it anyway.
    func activePaneChanged(saving: Bool = true) {
        let pane = activePane
        workspace.activePane = activePaneIndex
        pane.search.connect(searchField)
        infoController?.follow(row: pane.content.contentShell.infoRow)
        showInfoRow(animated: false)
        sidebarController.activePaneChanged(to: pane.shownFolderPath)
        updateTitle()
        for change: ExplorerWindowChange in [.folder, .history, .view, .search, .selection, .focusedPane] {
            notify(change)
        }
        if saving { group?.tabChanged(self) }
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
                    searchRootPath: session.rootPath, searchRunning: session.isRunning,
                    homePath: trashHomePath, startupDiskName: disk
                ).label
            }
            return ExplorerTabs.folderDisplayName(pane.shownFolderPath, homePath: trashHomePath, startupDiskName: disk)
        }
        return names.joined(separator: " | ")
    }
}
