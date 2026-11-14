import AppKit
import FTFileSystem
import FTFoundation

// The explorer windows' lives: opening them (at startup, from another window, with none open), what they remember of
// themselves, the question before closing the last one while an operation runs, and Merge All Windows. Quitting is the
// QuitCoordinator's. The windows themselves are made by the host, so all of this runs on stand-ins in the tests.
//
// An explorer window is one window with its tabs. Natively it is a group of tabbed NSWindows, one per tab
// (`ExplorerTabGroup`).

/// What the controller is told of a window.
@MainActor
public struct ExplorerWindowEvents {
    /// The window has drawn its first folder, and may be shown.
    public var readyToShow: () -> Void = {}
    /// It got the focus.
    public var focus: () -> Void = {}
    /// It is about to close: false holds it open (`close`, preventable).
    public var shouldClose: () -> Bool = { true }
    /// It has closed (`closed`).
    public var closed: () -> Void = {}
    /// It moved, was resized, zoomed or unzoomed, or left full screen.
    public var boundsChanged: () -> Void = {}
    /// It was minimized, came back, was shown or hidden.
    public var visibilityChanged: () -> Void = {}

    public init() {}
}

/// The parts of a window the controller uses (`ExplorerWindowLike`).
@MainActor
public protocol ExplorerWindowLike: AnyObject {
    /// Its number while the app runs.
    var windowID: Int { get }
    var events: ExplorerWindowEvents { get set }
    var isDestroyed: Bool { get }
    /// Closes it as its close button does: `events.shouldClose` may hold it open.
    func close()
    func show()
    func showInactive()
    func focus()
    var isVisible: Bool { get }
    var isMinimized: Bool { get }
    func restore()
    func maximize()
    var isMaximized: Bool { get }
    var isFullScreen: Bool { get }
    /// The place and size it goes back to out of full screen or zoomed.
    var normalBounds: WindowBounds { get }
    /// The window a question about it hangs from.
    var sheetParent: NSWindow? { get }
    /// Items opened with File Trail from another app are waiting for it.
    func openRequestsWaiting()
    /// What it says when Merge All Windows asks for its tabs.
    var mergeAnswer: WindowTabsAnswer { get }
}

@MainActor
public final class ExplorerWindowController<W: ExplorerWindowLike> {
    /// What the controller needs of the app (`ExplorerWindowHost`).
    @MainActor
    public struct Host {
        public var store: AppStateStore
        /// Makes a window for the record, not shown yet, opening as `launch` says.
        public var createWindow: (StoredExplorerWindow, ExplorerLaunchContext) -> W
        /// A new id for a window, kept between launches (`window-<uuid>`).
        public var newWindowID: () -> String = { "window-\(UUID().uuidString.lowercased())" }
        /// The usable area of the screen a window at `bounds` is on.
        public var workArea: (WindowBounds) -> WindowBounds
        /// Something the menu shows changed: which windows are open, which is in front, whether they are on screen.
        public var windowsChanged: () -> Void = {}
        public var scheduler: any FolderWatchScheduler

        public init(
            store: AppStateStore, createWindow: @escaping (StoredExplorerWindow, ExplorerLaunchContext) -> W,
            workArea: @escaping (WindowBounds) -> WindowBounds,
            scheduler: any FolderWatchScheduler = DispatchFolderWatchScheduler()
        ) {
            self.store = store
            self.createWindow = createWindow
            self.workArea = workArea
            self.scheduler = scheduler
        }
    }

    /// How long the place and size of a window that moves wait before they are recorded: a drag is one record.
    public static var boundsSaveDelayMilliseconds: Double { 160 }
    /// How long startup waits for a window's first folder before showing the windows anyway.
    public static var startupShowTimeoutMilliseconds: Double { 5_000 }

    public var host: Host
    /// Quitting, and the question before stopping an operation, which closing the last window asks too.
    public let quit: QuitCoordinator

    /// The explorer windows, front to back.
    public let windows = ExplorerWindowOrder<W>()
    // Records each window's size and position in the store, by window id.
    private var boundsRecorders: [String: () -> Void] = [:]
    // Windows that close without asking first: the person agreed to stop the running operation, or their tabs were
    // merged into another window.
    private var closingWithoutAsking: Set<ObjectIdentifier> = []
    // Windows closed by Merge All Windows: not remembered as the window closed last.
    private var merged: Set<ObjectIdentifier> = []
    // Windows whose close went ahead, on their way out until "closed": two windows closed in the same moment (Close
    // All) aren't open for each other.
    private var closing: Set<ObjectIdentifier> = []
    // Windows closed with Stop and Close: their operation is stopped, not handed to a window opened while the
    // question was on screen.
    private var stoppedOnClose: Set<Int> = []
    // The window the close question is on, from the moment closing asks until it has its answer.
    public private(set) var stopQuestionParent: W?
    // Files opened with File Trail from another app, waiting for the window to open them, by window.
    private var openRequests: [Int: [OpenRequest]] = [:]

    public init(host: Host, quit: QuitCoordinator) {
        self.host = host
        self.quit = quit
    }

    private var shuttingDown: Bool { quit.shutdownInProgress }

    /// The window in front, if one is open and not closing.
    public func frontWindow() -> W? {
        openWindows().first?.window
    }

    /// The id of the explorer window `windowID` is; nil for other windows.
    public func recordID(of windowID: Int?) -> String? {
        windows.byWindowID(windowID)?.id
    }

    // MARK: Opening

    /// `openStartupWindows`: every window that was open when the app quit, front one in front, when the last folders
    /// and tabs are reopened; otherwise one window. The folder the app was launched with goes to the window in front.
    public func openStartupWindows(folder startupFolderPath: String?) {
        let store = host.store
        let stored = store.explorerWindows()
        var records = store.preferences().restoreSessionOnStartup ? stored : Array(stored.prefix(1))
        // Windows not brought back now aren't brought back later either.
        for dropped in stored.dropFirst(records.count) {
            store.removeExplorerWindow(dropped.id)
        }
        // No window was open at quit: one, as a window opened with none open starts.
        if records.isEmpty {
            let record = recordFromLastClosed()
            store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
            records.append(record)
        }
        let startup = StartupShow()
        let showAll = { [startup] in
            guard !startup.shown else { return }
            startup.shown = true
            // Shown back to front, so they stack as they were.
            for (index, entry) in startup.opened.enumerated().reversed() {
                guard let window = entry.window.value, !window.isDestroyed else { continue }
                if entry.maximized { window.maximize() }
                if index == 0 { window.show() } else { window.showInactive() }
            }
            startup.opened = []
        }
        for (index, record) in records.enumerated() {
            let window = open(
                record,
                launch: ExplorerLaunchContext(startupFolderPath: index == 0 ? startupFolderPath : nil), place: .back)
            startup.pending.insert(window.windowID)
            startup.opened.append((Weak(window), record.bounds.maximized))
            let windowID = window.windowID
            window.events.readyToShow = { [startup] in
                startup.pending.remove(windowID)
                if startup.pending.isEmpty { showAll() }
            }
        }
        // A window whose first folder never comes isn't waited for.
        _ = host.scheduler.schedule(afterMilliseconds: Self.startupShowTimeoutMilliseconds) { showAll() }
    }

    // The windows the app opens with, until they are shown together. Held weakly: each window's `readyToShow` holds
    // this, so a window closed before it was shown would otherwise keep itself.
    private final class StartupShow {
        var pending = Set<Int>()
        var opened: [(window: Weak<W>, maximized: Bool)] = []
        var shown = false
    }

    /// `openDefaultWindow`: a window opened with none open (the Dock icon, New Window, the second launch). It starts
    /// where the window closed last was; `initialCommand` is run once it has opened.
    public func openDefaultWindow(initialCommand: AppCommand? = nil) {
        // Not while quitting: the window would close again moments later.
        guard !shuttingDown else { return }
        let record = recordFromLastClosed()
        host.store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        open(
            record,
            launch: ExplorerLaunchContext(
                restoreTabs: !record.session.openTabs.isEmpty, initialCommand: initialCommand),
            place: .front)
    }

    /// `openNewWindowFromFront`: New Window from the Dock menu, or while another window (Settings) has the keyboard: a
    /// window on the folder of the front window's tab. It is opened here rather than by that window, which can't
    /// while a sheet is open in it.
    public func openNewWindowFromFront() {
        guard !shuttingDown else { return }
        guard let front = openWindows().first else {
            openDefaultWindow()
            return
        }
        let preferences = host.store.windowPreferences(front.id)
        let tabs = preferences.openTabs
        guard !tabs.isEmpty else {
            openDefaultWindow()
            return
        }
        openWindowFrom(front.windowID, tabs: [tabs[min(preferences.activeTabIndex, tabs.count - 1)]], activeTabIndex: 0)
    }

    /// `openWindowFrom`: a window opened from another one (New Window, Open in New Window, Move Tab to New Window). It
    /// has the tabs it is given, and the other window's panels and size, a step down and to the right of it.
    @discardableResult
    public func openWindowFrom(_ senderID: Int?, tabs: [OpenTabPreference], activeTabIndex: Int) -> Bool {
        guard !tabs.isEmpty, !shuttingDown else { return false }
        let store = host.store
        let source = windows.byWindowID(senderID) ?? windows.front
        let sourcePreferences = source.map { store.windowPreferences($0.id) } ?? store.preferences()
        let activeIndex = min(max(0, activeTabIndex), tabs.count - 1)
        let activeTab = tabs[activeIndex]
        var session = sourcePreferences.windowSession
        session.openTabs = tabs
        session.activeTabIndex = activeIndex
        session.lastVisitedPath = activeTab.path
        session.lastVisitedFavoritePath = activeTab.favoritePath
        session.treeRootPath = activeTab.treeRootPath
        let record = createRecord(newWindowBounds(source?.window)) { $0 = session }
        store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        open(record, launch: ExplorerLaunchContext(restoreTabs: true), place: .front)
        return true
    }

    /// `mergeInto`, Merge All Windows: the tabs of every other window, front to back, which close. The window asking
    /// adds the tabs after its own `tabCount`. One stays open, its tabs where they are, when something is open in it
    /// that closing would lose, or when its tabs don't fit in the window asking. Nothing is merged into a window on its
    /// way out, or while the app quits.
    public func mergeInto(_ senderID: Int?, tabCount: Int) -> [OpenTabPreference] {
        guard let target = windows.byWindowID(senderID), !shuttingDown, isStayingOpen(target.window) else { return [] }
        let others = openWindows().filter { $0 !== target }
        let answers = others.map(\.window.mergeAnswer)
        var room = AppPreferenceLimits.openTabsLimit - tabCount
        var tabs: [OpenTabPreference] = []
        for (entry, answer) in zip(others, answers) {
            guard !answer.busy, !answer.tabs.isEmpty, answer.tabs.count <= room else { continue }
            room -= answer.tabs.count
            tabs += answer.tabs
            closingWithoutAsking.insert(ObjectIdentifier(entry.window))
            merged.insert(ObjectIdentifier(entry.window))
            entry.window.close()
        }
        return tabs
    }

    /// `openFromOtherApp`: an item opened with File Trail from another app (Finder's Open With, `open -a`): the window in
    /// front opens it. False when no window is open to take it.
    public func openFromOtherApp(_ request: OpenRequest) -> Bool {
        if shuttingDown { return true }
        guard let entry = openWindows().first else { return false }
        addOpenRequest(request, to: entry)
        if entry.window.isMinimized { entry.window.restore() }
        if entry.window.isVisible { entry.window.focus() }
        return true
    }

    /// `openWindowOnFolder`: a window on one folder (a disk image's disk, or a folder or item opened from another app, with
    /// no window open), where the window closed last was and with its panels, but none of its tabs. `selectPath`, an item
    /// in the folder, is selected once it has opened.
    public func openWindowOnFolder(_ path: String, selecting selectPath: String? = nil) {
        guard !shuttingDown else { return }
        let lastClosed = host.store.lastClosedWindow()
        let record = createRecord(lastClosed?.bounds ?? .default) {
            if let lastClosed { $0 = lastClosed.session }
            $0.openTabs = []
            $0.activeTabIndex = 0
        }
        host.store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        let window = open(record, launch: ExplorerLaunchContext(startupFolderPath: path), place: .front)
        if let selectPath, let entry = windows.byWindowID(window.windowID) {
            addOpenRequest(OpenRequest(path: selectPath, kind: .select), to: entry)
        }
    }

    private func addOpenRequest(_ request: OpenRequest, to entry: ExplorerWindowEntry<W>) {
        openRequests[entry.windowID, default: []].append(request)
        entry.window.openRequestsWaiting()
    }

    /// `takeOpenRequests`: the items waiting for this window to open them; each is handed out once.
    public func takeOpenRequests(_ windowID: Int?) -> [OpenRequest] {
        guard let entry = windows.byWindowID(windowID) else { return [] }
        return openRequests.removeValue(forKey: entry.windowID) ?? []
    }

    /// The window a running operation goes to when the one that started it closes: the one in front.
    /// None for a window closed with Stop and Close: its operation is stopped.
    public func successor(of windowID: Int) -> W? {
        if stoppedOnClose.contains(windowID) { return nil }
        return openWindows().first { $0.windowID != windowID }?.window
    }

    /// ⌘W on a window's last tab: closed as its close button closes it, so the question before
    /// stopping a copy is asked and its place is recorded.
    @discardableResult
    public func closeWindow(of windowID: Int?) -> Bool {
        guard let entry = windows.byWindowID(windowID), !entry.window.isDestroyed else { return false }
        entry.window.close()
        return true
    }

    /// `bringToFront`: a second launch, or a click on the Dock icon with no explorer window on screen.
    public func bringToFront() {
        guard let window = openWindows().first?.window ?? windows.front?.window else {
            openDefaultWindow()
            return
        }
        if window.isMinimized { window.restore() }
        window.focus()
    }

    /// `recordAllBounds`: records every window's place and size in the store.
    public func recordAllBounds() {
        for record in boundsRecorders.values { record() }
    }

    /// The window the open question is on comes forward. False when no explorer window has it.
    @discardableResult
    public func bringStopQuestionForward() -> Bool {
        guard let parent = stopQuestionParent, !parent.isDestroyed else { return false }
        if parent.isMinimized { parent.restore() }
        parent.focus()
        return true
    }

    // MARK: Workspaces

    /// What a workspace saved from the window `windowID` keeps: its id, its size (its place too, which the workspace
    /// drops) and its session as the store has it. Nil for a window not open.
    public func workspaceSnapshot(of windowID: Int?) -> (id: String, bounds: StoredWindowState, session: WindowSession)?
    {
        guard let entry = windows.byWindowID(windowID), isStayingOpen(entry.window) else { return nil }
        return (entry.id, Self.stored(entry.window), host.store.windowPreferences(entry.id).windowSession)
    }

    /// The window `windowID` is known by the workspace `workspaceID` from now on (it was saved as it), or by none.
    public func setWorkspace(_ workspaceID: String?, of windowID: Int?) {
        guard let entry = windows.byWindowID(windowID) else { return }
        host.store.setExplorerWindowWorkspace(entry.id, workspaceID)
    }

    /// `openWorkspace`: a window with the workspace's tabs, panels and size, placed as New Window places one, known by
    /// the workspace while it is open. It opens anew even while a window opened from it is open, as that window may
    /// have changed since. With `replacing`, it opens in that window's place and size, and the window closes once it is shown, as a merged one
    /// does: not remembered as the window closed last, its running operation going on in the new one. `shown` runs once
    /// the new window is on screen. The window that shows it; nil when nothing opened.
    @discardableResult
    public func openWorkspace(
        _ workspace: Workspace, replacing replacingID: Int? = nil, shown: @escaping () -> Void = {}
    )
        -> W?
    {
        guard !shuttingDown else { return nil }
        let replaced = replacingID.flatMap { windows.byWindowID($0) }
        if replacingID != nil {
            guard let replaced, isStayingOpen(replaced.window) else { return nil }
        }
        let bounds = replaced.map { Self.stored($0.window) } ?? workspaceBounds(workspace.bounds)
        var record = createRecord(bounds) { $0 = workspace.session }
        record.workspaceID = workspace.id
        host.store.addExplorerWindow(
            id: record.id, bounds: record.bounds, session: record.session, workspaceID: workspace.id)
        let window = open(record, launch: ExplorerLaunchContext(restoreTabs: true), place: .front)
        let show = window.events.readyToShow
        window.events.readyToShow = { [weak self, weak replacedWindow = replaced?.window] in
            show()
            if let self, let replacedWindow, !replacedWindow.isDestroyed {
                closingWithoutAsking.insert(ObjectIdentifier(replacedWindow))
                merged.insert(ObjectIdentifier(replacedWindow))
                replacedWindow.close()
            }
            shown()
        }
        return window
    }

    // A workspace's size, a step down and to the right of the window in front as New Window places one; centered
    // with no window open.
    private func workspaceBounds(_ size: StoredWindowState) -> StoredWindowState {
        guard let front = openWindows().first?.window, !front.isDestroyed else {
            return StoredWindowState(width: size.width, height: size.height, maximized: size.maximized)
        }
        let normal = front.normalBounds
        let from = WindowBounds(x: normal.x, y: normal.y, width: size.width, height: size.height)
        let placed = ExplorerWindowPlacement.placeNewWindow(from: from, workArea: host.workArea(normal))
        return StoredWindowState(
            x: placed.x, y: placed.y, width: placed.width, height: placed.height, maximized: size.maximized)
    }

    // MARK: Windows the system made

    /// A window the system made of a tab dragged out of another: it becomes an explorer window of its own, with the
    /// panels and the size of the one it came from.
    public func adopt(_ window: W, id: String, from sourceID: Int?) {
        let source = windows.byWindowID(sourceID).map { host.store.windowPreferences($0.id).windowSession }
        let record = StoredExplorerWindow(
            id: id, bounds: Self.stored(window),
            session: host.store.createWindowSession { if let source { $0 = source } })
        host.store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        attach(window, record: record, place: .front)
    }

    /// A window whose tabs the system moved into another (a tab dragged onto another window's tab bar) closes as a
    /// merged one: not remembered as the window closed last.
    public func absorb(_ window: W) {
        closingWithoutAsking.insert(ObjectIdentifier(window))
        merged.insert(ObjectIdentifier(window))
    }

    // MARK: Internals

    // A window that starts as the window closed last ended: its place and size, panels and column widths, and the
    // tab that was in front. Before any window has closed, the app's latest values at the default size.
    private func recordFromLastClosed() -> StoredExplorerWindow {
        let lastClosed = host.store.lastClosedWindow()
        return createRecord(lastClosed?.bounds ?? .default) { if let lastClosed { $0 = lastClosed.session } }
    }

    // The session starts as the app's latest values; what `change` makes of it is checked as when the file is read.
    private func createRecord(_ bounds: StoredWindowState, _ change: (inout WindowSession) -> Void)
        -> StoredExplorerWindow
    {
        StoredExplorerWindow(id: host.newWindowID(), bounds: bounds, session: host.store.createWindowSession(change))
    }

    private static func stored(_ window: W) -> StoredWindowState {
        // Where it goes back to out of full screen or zoomed, not the size of the screen. A full-screen window comes
        // back out of full screen, at that place.
        let bounds = window.normalBounds
        return StoredWindowState(
            x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height,
            maximized: window.isMaximized && !window.isFullScreen)
    }

    private func newWindowBounds(_ source: W?) -> StoredWindowState {
        guard let source, !source.isDestroyed else { return .default }
        // The size it has out of full screen or zoomed, as it would be put back to.
        let from = source.normalBounds
        let bounds = ExplorerWindowPlacement.placeNewWindow(from: from, workArea: host.workArea(from))
        return StoredWindowState(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height, maximized: false)
    }

    @discardableResult
    private func open(
        _ record: StoredExplorerWindow, launch: ExplorerLaunchContext, place: ExplorerWindowOrder<W>.Place
    )
        -> W
    {
        let window = host.createWindow(record, launch)
        attach(window, record: record, place: place)
        return window
    }

    private func attach(_ window: W, record: StoredExplorerWindow, place: ExplorerWindowOrder<W>.Place) {
        let store = host.store
        let id = record.id
        let entry = ExplorerWindowEntry(id: id, window: window, windowID: window.windowID)
        windows.add(entry, place)
        saveWindowOrder()

        let recordBounds = { [weak window] in
            guard let window, !window.isDestroyed else { return }
            store.setExplorerWindowBounds(id, Self.stored(window))
        }
        boundsRecorders[id] = recordBounds
        let state = WindowState()

        var events = window.events
        if place == .front {
            events.readyToShow = { [weak window] in
                guard let window, !state.shown else { return }
                state.shown = true
                // A window opened with none open is zoomed when the window closed last was.
                if record.bounds.maximized { window.maximize() }
                window.show()
            }
        }
        // The window used last is the one in front: New Window takes its folder from it, and it is in front again at
        // the next launch.
        events.focus = { [weak self] in
            guard let self, windows.moveToFront(id) else { return }
            saveWindowOrder()
        }
        events.shouldClose = { [weak self, weak window] in
            guard let self, let window else { return true }
            recordBounds()
            if holdClose(window) { return false }
            closing.insert(ObjectIdentifier(window))
            return true
        }
        events.closed = { [weak self, weak window] in
            guard let self else { return }
            state.cancelBoundsSave?()
            state.cancelBoundsSave = nil
            windows.remove(id)
            boundsRecorders[id] = nil
            if let window {
                let key = ObjectIdentifier(window)
                closing.remove(key)
                closingWithoutAsking.remove(key)
                let wasMerged = merged.remove(key) != nil
                openRequests[window.windowID] = nil
                // Closed while the app runs: it doesn't come back at the next launch, but the next window opened with
                // none open starts as it ended. Quitting keeps the windows open then.
                if !shuttingDown {
                    if !wasMerged { store.rememberClosedWindow(id) }
                    store.removeExplorerWindow(id)
                }
            }
            host.windowsChanged()
        }
        events.boundsChanged = { [weak self] in
            guard let self else { return }
            state.cancelBoundsSave?()
            state.cancelBoundsSave = host.scheduler.schedule(afterMilliseconds: Self.boundsSaveDelayMilliseconds) {
                state.cancelBoundsSave = nil
                recordBounds()
            }
        }
        // The menu acts on the window in front only while it is on screen.
        events.visibilityChanged = { [weak self] in self?.host.windowsChanged() }
        window.events = events
        host.windowsChanged()
    }

    // What one window's events share: whether it has been shown, and the bounds record waiting to be made.
    private final class WindowState {
        var shown = false
        var cancelBoundsSave: (() -> Void)?
    }

    // Closing the last explorer window stops a running copy, so it asks first, as quitting does, and the window waits
    // for the answer. With other windows open the copy goes on in one of them.
    private func holdClose(_ window: W) -> Bool {
        if shuttingDown || closingWithoutAsking.contains(ObjectIdentifier(window)) { return false }
        // The question is answered first; it comes forward.
        if quit.isAskingToStop || stopQuestionParent != nil {
            if !bringStopQuestionForward() { quit.hooks.bringStopQuestionForward() }
            return true
        }
        if openWindows().contains(where: { $0.window !== window }) { return false }
        guard let kind = quit.hooks.activeOperation(), QuitWhileBusy.question(kind, trigger: .close) != nil else {
            return false
        }
        let windowID = window.windowID
        stopQuestionParent = window
        Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            let stop = await quit.askToStopOperation(.close, parent: window?.sheetParent)
            stopQuestionParent = nil
            guard stop, let window, !window.isDestroyed else { return }
            // Stopped, even when another window was opened while the question was up: the operation isn't handed
            // to it.
            stoppedOnClose.insert(windowID)
            closingWithoutAsking.insert(ObjectIdentifier(window))
            window.close()
        }
        return true
    }

    // Not closing, nor on its way out.
    private func isStayingOpen(_ window: W) -> Bool {
        !window.isDestroyed && !closing.contains(ObjectIdentifier(window))
    }

    // The windows open and staying open, front to back.
    private func openWindows() -> [ExplorerWindowEntry<W>] {
        windows.all.filter { isStayingOpen($0.window) }
    }

    // The list of open windows is what says which is in front; the store keeps its order.
    private func saveWindowOrder() {
        host.store.setExplorerWindowOrder(windows.all.map(\.id))
    }
}
