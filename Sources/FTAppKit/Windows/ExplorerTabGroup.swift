// Port of the tab row of apps/desktop/src/renderer/hooks/useExplorerTabs.ts, on native window tabs: one explorer
// window of the original, whose tabs are the windows of one NSWindowTabGroup
import AppKit
import FTFoundation

/// One explorer window of the original. Each of its tabs is a window of its own, all in one native tab group; what
/// the original keeps per window (panels, widths, Reopen Closed Tab) they share through `session`.
@MainActor
final class ExplorerTabGroup: ExplorerWindowLike {
    let windowID: Int
    /// The id it is kept under between launches.
    let recordID: String
    var events = ExplorerWindowEvents()
    let session: TabGroupSession
    /// In the order of the tab bar.
    private(set) var tabs: [MainWindowController] = []
    private(set) var isDestroyed = false
    /// Shown once: from then on its tabs are in a native tab group, and the tab bar says which one is in front.
    private(set) var isMaterialized = false
    /// Its tabs are being put into the tab bar, or closed together.
    private(set) var isArranging = false
    private var closingAll = false
    private var pendingZoom = false
    /// Tabs on their way to a window of their own: each leaves once the window has opened.
    private var moving: Set<ObjectIdentifier> = []
    private var mergeUnderWay = false
    /// Where the window goes back to out of full screen or zoomed.
    private var normalFrame: NSRect
    private var lastSelected: MainWindowController?
    private weak var host: ExplorerWindows?
    private var observations: [NSKeyValueObservation] = []

    init(windowID: Int, recordID: String, session: TabGroupSession, frame: NSRect, host: ExplorerWindows) {
        self.windowID = windowID
        self.recordID = recordID
        self.session = session
        self.normalFrame = frame
        self.host = host
        session.onPanelsChanged = { [weak self] panels in
            guard let self else { return }
            for tab in tabs { tab.showPanels(panels) }
            saveSession()
            reportMenuStates()
        }
    }

    /// The tabs it opens with, the one at `active` in front.
    func start(with initial: [MainWindowController], active: Int) {
        tabs = initial
        lastSelected = initial.indices.contains(active) ? initial[active] : initial.first
        for tab in initial {
            tab.group = self
            tab.showPanels(session.panels)
        }
        refreshTitles()
    }

    /// The tabs of a window the system made of tabs dragged out of others; it is on screen already.
    func start(adopting adopted: [MainWindowController]) {
        isMaterialized = true
        start(with: adopted, active: 0)
        if let frame = selected?.window?.frame { normalFrame = frame }
        observeNativeGroup()
        saveSession()
    }

    /// The tab in front.
    var selected: MainWindowController? {
        if isMaterialized, let native = tabs.first?.window?.tabGroup?.selectedWindow,
            let tab = tabs.first(where: { $0.window === native })
        {
            return tab
        }
        return lastSelected.flatMap { tab in tabs.contains { $0 === tab } ? tab : nil } ?? tabs.first
    }

    /// A sheet, a dialog or an alert owns the window: the tabs don't change under it.
    var isBlocked: Bool {
        NSApp.modalWindow != nil || tabs.contains { $0.window?.attachedSheet != nil }
    }

    // MARK: ExplorerWindowLike

    var isVisible: Bool { selected?.window?.isVisible ?? false }
    var isMinimized: Bool { selected?.window?.isMiniaturized ?? false }
    var isMaximized: Bool { isMaterialized ? selected?.window?.isZoomed ?? false : pendingZoom }
    var isFullScreen: Bool { selected?.window?.styleMask.contains(.fullScreen) ?? false }
    var sheetParent: NSWindow? { selected?.window }

    var normalBounds: WindowBounds {
        guard let window = selected?.window, isMaterialized, !isMaximized, !isFullScreen else {
            return ScreenGeometry.bounds(of: normalFrame)
        }
        return ScreenGeometry.bounds(of: window.frame)
    }

    func show() {
        if !materialize(makeKey: true) { selected?.window?.makeKeyAndOrderFront(nil) }
    }

    func showInactive() {
        if !materialize(makeKey: false) { selected?.window?.orderFront(nil) }
    }

    func focus() {
        if !materialize(makeKey: true) { selected?.window?.makeKeyAndOrderFront(nil) }
    }

    func restore() {
        selected?.window?.deminiaturize(nil)
    }

    func maximize() {
        guard isMaterialized, let window = selected?.window else {
            pendingZoom = true
            return
        }
        if !window.isZoomed { window.zoom(nil) }
    }

    func close() {
        guard !isDestroyed, events.shouldClose() else { return }
        closingAll = true
        isArranging = true
        for tab in tabs { tab.window?.close() }
        finishClosing()
    }

    func tell(_ message: ExplorerWindowMessage) {
        switch message {
        case .openRequestsWaiting: host?.openRequestsWaiting(in: self)
        }
    }

    /// Puts the tabs into one native tab group and shows it, the first time. False when it was shown already.
    private func materialize(makeKey: Bool) -> Bool {
        guard !isMaterialized, !isDestroyed, let active = selected, let activeWindow = active.window else {
            return false
        }
        isMaterialized = true
        isArranging = true
        defer { isArranging = false }
        for tab in tabs { tab.window?.setFrame(normalFrame, display: false) }
        if makeKey { activeWindow.makeKeyAndOrderFront(nil) } else { activeWindow.orderFront(nil) }
        let index = tabs.firstIndex { $0 === active } ?? 0
        var anchor = activeWindow
        for tab in tabs[..<index].reversed() {
            guard let window = tab.window else { continue }
            anchor.addTabbedWindow(window, ordered: .below)
            anchor = window
        }
        anchor = activeWindow
        for tab in tabs[(index + 1)...] {
            guard let window = tab.window else { continue }
            anchor.addTabbedWindow(window, ordered: .above)
            anchor = window
        }
        if tabs.count > 1 { activeWindow.tabGroup?.selectedWindow = activeWindow }
        if pendingZoom {
            pendingZoom = false
            if !activeWindow.isZoomed { activeWindow.zoom(nil) }
        }
        observeNativeGroup()
        refreshTitles()
        return true
    }

    // MARK: Closing

    /// The window's close button, Close Window, and ⌘W on its last tab: closed as the original's close button closes
    /// it, so the question before stopping a copy is asked and its place is recorded.
    func closeAsCloseButton() {
        host?.controller.closeWindow(of: windowID)
    }

    /// `closeTab` (⌘W): the tab on screen hands over to the tab on its right, or its left when it was last. The last
    /// tab closes the window.
    func closeTab(_ tab: MainWindowController) {
        guard !isBlocked, tabs.contains(where: { $0 === tab }) else { return }
        guard tabs.count > 1 else {
            closeAsCloseButton()
            return
        }
        prepareToClose(tab, remember: true)
        tab.window?.close()
    }

    /// A tab closed from the tab bar.
    func shouldCloseTab(_ tab: MainWindowController) -> Bool {
        if closingAll || isDestroyed { return true }
        guard tabs.count > 1 else {
            closeAsCloseButton()
            return false
        }
        prepareToClose(tab, remember: true)
        return true
    }

    private func prepareToClose(_ tab: MainWindowController, remember: Bool) {
        if remember { session.rememberClosedTab(tab.snapshot) }
        if selected === tab,
            let next = ExplorerTabs.tabAfterClose(tabs.map(ObjectIdentifier.init), closing: ObjectIdentifier(tab)),
            let nextTab = tabs.first(where: { ObjectIdentifier($0) == next })
        {
            select(nextTab)
        }
    }

    func tabWillClose(_ tab: MainWindowController) {
        guard !closingAll, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        tab.group = nil
        host?.tabGone(tab)
        keepAliveUntilClosed([tab])
        if tabs.isEmpty {
            // Closed by the system without asking (Close All).
            if !isDestroyed { finishClosing() }
        } else {
            tabsChanged()
        }
    }

    private func finishClosing() {
        isDestroyed = true
        for tab in tabs {
            tab.group = nil
            host?.tabGone(tab)
        }
        keepAliveUntilClosed(tabs)
        tabs = []
        observations = []
        isArranging = false
        events.closed()
        host?.groupClosed(self)
    }

    // A tab is let go of from inside its own window's close: it stays until that is over.
    private func keepAliveUntilClosed(_ closed: [MainWindowController]) {
        guard !closed.isEmpty else { return }
        DispatchQueue.main.async { withExtendedLifetime(closed) {} }
    }

    /// Its tabs went to other windows (dragged onto their tab bars): it closes as a merged window.
    func finishAbsorbed() {
        guard !isDestroyed else { return }
        tabs = []
        finishClosing()
    }

    // MARK: Opening tabs

    /// `hasRoomForTab`: a window holds no more tabs than it can save, and Merge All Windows can hand over; a notice
    /// says why no tab opened.
    private func hasRoomForTab() -> Bool {
        if tabs.count < AppPreferenceLimits.openTabsLimit { return true }
        host?.tellTabLimit(in: selected?.window)
        return false
    }

    private var tabFrame: NSRect { selected?.window?.frame ?? normalFrame }

    /// `openNewTab` (⌘T): a tab on the folder on screen, with a history of its own and the view of the tab it came
    /// from, right after it.
    func openNewTab(from tab: MainWindowController) {
        guard !isBlocked, hasRoomForTab() else { return }
        insert(MainWindowController(tab: tab.startupTab, frame: tabFrame), after: tab, select: true)
    }

    /// `openPathInNewTab`: `path` in a new tab after `tab`, with that tab's view and tree.
    func openTab(path: String, from tab: MainWindowController) {
        guard !isBlocked, !path.isEmpty, hasRoomForTab() else { return }
        var startup = tab.startupTab
        startup.path = path
        startup.favoritePath = nil
        insert(MainWindowController(tab: startup, frame: tabFrame), after: tab, select: true)
    }

    /// `reopenClosedTab` (⇧⌘T): the tab closed last, after the tab on screen, at its folder.
    func reopenClosedTab(from tab: MainWindowController) {
        guard !session.closedTabs.isEmpty, !isBlocked, hasRoomForTab(), let snapshot = session.takeClosedTab() else {
            return
        }
        let startup = StartupTab(
            path: snapshot.currentPath, rootPath: snapshot.treeRootPath,
            favoritePath: snapshot.selectedTreeItemID?.hasPrefix("favorite:") == true ? snapshot.currentPath : nil,
            viewMode: snapshot.viewMode, searchViewMode: snapshot.searchViewMode, sortBy: snapshot.sortBy,
            sortDirection: snapshot.sortDirection, includeHidden: snapshot.includeHidden,
            foldersFirst: snapshot.foldersFirst, favoritesExpanded: snapshot.favoritesExpanded,
            locationsExpanded: snapshot.locationsExpanded)
        let reopened = MainWindowController(
            tab: startup, history: (snapshot.historyPaths, snapshot.historyIndex), frame: tabFrame)
        insert(reopened, after: tab, select: true)
    }

    /// Merge All Windows: the other windows' tabs join this window's, after them, waiting unread until they are
    /// shown. No more are kept than a window may hold; one whose folder is gone is left out.
    func addTabs(_ added: [OpenTabPreference]) {
        let room = max(0, AppPreferenceLimits.openTabsLimit - tabs.count)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for preference in added.prefix(room) {
            let startup = StartupTabs.startupTab(preference, homePath: home)
            guard ScreenGeometry.isFolder(startup.path), let last = tabs.last else { continue }
            insert(MainWindowController(tab: startup, frame: tabFrame, loadNow: false), after: last, select: false)
        }
    }

    private func insert(_ tab: MainWindowController, after anchor: MainWindowController, select selectIt: Bool) {
        tab.group = self
        tab.showPanels(session.panels)
        let index = tabs.firstIndex { $0 === anchor }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        if isMaterialized, let anchorWindow = anchor.window, let window = tab.window {
            isArranging = true
            anchorWindow.addTabbedWindow(window, ordered: .above)
            isArranging = false
        }
        if selectIt { select(tab) }
        tabsChanged()
    }

    /// Brings `tab` to the front of the tab bar.
    func select(_ tab: MainWindowController) {
        lastSelected = tab
        if isMaterialized { tab.window?.makeKeyAndOrderFront(nil) }
        tab.ensureLoaded()
    }

    /// Show Next Tab and Show Previous Tab: step through the row, wrapping around.
    func selectAdjacentTab(from tab: MainWindowController, _ direction: ExplorerTabs.Direction) {
        guard !isBlocked else { return }
        let ids = tabs.map(ObjectIdentifier.init)
        guard let next = ExplorerTabs.adjacentTab(ids, active: ObjectIdentifier(tab), direction),
            let target = tabs.first(where: { ObjectIdentifier($0) == next })
        else { return }
        select(target)
    }

    // MARK: Windows

    /// New Window (⌘N) on the folder on screen, or Open in New Window on `path`, with this tab's view and tree root.
    func openNewWindow(from tab: MainWindowController, path: String?) {
        var preference = tab.openTab
        if let path {
            preference.path = path
            preference.favoritePath = nil
        }
        guard preference.path?.isEmpty == false else { return }
        host?.controller.openWindowFrom(windowID, tabs: [preference], activeTabIndex: 0)
    }

    /// `moveTabToNewWindow`: the tab leaves for a window of its own, its folder, tree and view along; its history
    /// and search don't. A tab already moving isn't moved again, and the last tab left stays.
    func moveTabToNewWindow(_ tab: MainWindowController) {
        let key = ObjectIdentifier(tab)
        guard !moving.contains(key), !isBlocked, tabs.count - moving.count >= 2, let host else { return }
        moving.insert(key)
        let opened = host.controller.openWindowFrom(windowID, tabs: [tab.openTab], activeTabIndex: 0)
        moving.remove(key)
        if opened, tabs.count > 1, tabs.contains(where: { $0 === tab }) {
            prepareToClose(tab, remember: false)
            tab.window?.close()
        }
    }

    /// Merge All Windows, once at a time, once the window has shown its first folder.
    func mergeAllWindows(into tab: MainWindowController) {
        guard !mergeUnderWay, !isBlocked, tab.loaded, let host else { return }
        mergeUnderWay = true
        Task {
            let merged = await host.controller.mergeInto(
                windowID, tabCount: min(tabs.count, AppPreferenceLimits.openTabsLimit))
            mergeUnderWay = false
            addTabs(merged)
        }
    }

    /// What it says when Merge All Windows asks for its tabs: busy while something is open in it, while its own
    /// merge runs, or with more tabs than can be handed over.
    var mergeAnswer: WindowTabsAnswer {
        WindowTabsAnswer(
            tabs: tabs.map(\.openTab),
            busy: isBlocked || mergeUnderWay || tabs.count > AppPreferenceLimits.openTabsLimit)
    }

    // MARK: What the tabs tell it

    func tabBecameKey(_ tab: MainWindowController) {
        let changed = lastSelected !== tab
        lastSelected = tab
        events.focus()
        host?.tabFocused(tab)
        if changed { saveSession() }
        host?.scheduleReconcile()
    }

    /// The tab went to another folder, or shows it another way.
    func tabChanged(_ tab: MainWindowController) {
        refreshTitles()
        saveSession()
        host?.tabNavigated(tab)
    }

    func tabBoundsChanged(_ tab: MainWindowController) {
        guard tab === selected, let window = tab.window, isMaterialized, !isArranging else { return }
        if !window.isZoomed, !window.styleMask.contains(.fullScreen) { normalFrame = window.frame }
        events.boundsChanged()
    }

    func tabVisibilityChanged(_ tab: MainWindowController) {
        guard tab === selected else { return }
        events.visibilityChanged()
    }

    /// The tab bar now holds `native`, in its order (tabs dragged in, out or along by the system).
    func replaceTabs(_ native: [MainWindowController]) {
        guard !isDestroyed, native.map(ObjectIdentifier.init) != tabs.map(ObjectIdentifier.init) else { return }
        tabs = native
        for tab in native where tab.group !== self {
            tab.group = self
            tab.showPanels(session.panels)
        }
        observeNativeGroup()
        tabsChanged()
    }

    private func tabsChanged() {
        refreshTitles()
        saveSession()
        reportMenuStates()
        if let selected { host?.tabNavigated(selected) }
    }

    private func reportMenuStates() {
        for tab in tabs { host?.reportMenuState(tab) }
    }

    private func observeNativeGroup() {
        observations = []
        guard isMaterialized, let native = selected?.window?.tabGroup else { return }
        observations = [
            native.observe(\.windows) { [weak self] _, _ in
                Task { @MainActor in self?.host?.scheduleReconcile() }
            },
            native.observe(\.selectedWindow) { [weak self] _, _ in
                Task { @MainActor in self?.nativeSelectionChanged() }
            },
        ]
    }

    private func nativeSelectionChanged() {
        guard !isDestroyed, !isArranging, let tab = selected, tab !== lastSelected else { return }
        lastSelected = tab
        tab.ensureLoaded()
        saveSession()
        host?.tabNavigated(tab)
    }

    /// `describeTab` and `disambiguateTabLabels`: the tab bar's labels and tooltips. The window title stays the
    /// folder's name, for the Window menu.
    func refreshTitles() {
        let descriptions = tabs.map(\.tabDescription)
        let labels = ExplorerTabs.disambiguate(
            zip(tabs, descriptions).map { TabLabel(label: $1.label, kind: $1.kind, path: $0.folder.path) })
        for (index, tab) in tabs.enumerated() {
            tab.window?.tab.title = labels[index].label
            tab.window?.tab.toolTip = descriptions[index].tooltip
        }
    }

    /// What the window keeps between launches: its tabs, the one in front and how it shows its folder, and its
    /// panels (the original's `usePreferencesSync`).
    func saveSession() {
        guard !isDestroyed, let host, let active = selected else { return }
        let front = active.openTab
        func node<T: Encodable>(_ value: T) -> JSONNode { (try? JSONNode.of(value)) ?? .null }
        var patch = session.panels.patch
        patch["openTabs"] = node(Array(tabs.prefix(AppPreferenceLimits.openTabsLimit).map(\.openTab)))
        patch["activeTabIndex"] = .number(
            Double(min(AppPreferenceLimits.openTabsLimit - 1, tabs.firstIndex { $0 === active } ?? 0)))
        patch["lastVisitedPath"] = node(front.path)
        patch["lastVisitedFavoritePath"] = node(front.favoritePath)
        patch["treeRootPath"] = node(front.treeRootPath)
        patch["viewMode"] = node(front.viewMode)
        patch["searchViewMode"] = node(front.searchViewMode)
        patch["sortBy"] = node(front.sortBy)
        patch["sortDirection"] = node(front.sortDirection)
        patch["includeHidden"] = .bool(front.includeHidden)
        patch["foldersFirst"] = .bool(front.foldersFirst)
        patch["favoritesExpanded"] = .bool(front.favoritesExpanded)
        patch["locationsExpanded"] = .bool(front.locationsExpanded)
        host.store.updateWindowPreferences(recordID, patch)
    }
}
