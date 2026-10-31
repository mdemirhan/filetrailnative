// Port of apps/desktop/src/main/explorerWindowController.ts
import AppKit
import FTFileSystem
import FTFoundation

// The explorer windows' lives: opening them (at startup, from another window, with none open), what they remember of
// themselves, the question before closing the last one while an operation runs, and Merge All Windows. Quitting is the
// QuitCoordinator's. The windows themselves are made by the host, so all of this runs on stand-ins in the tests.
//
// An explorer window here is the original's: one window with its tabs. Natively it is a group of tabbed NSWindows,
// one per tab (`ExplorerTabGroup`).

/// What the controller is told of a window, as Electron's window events tell it.
@MainActor
public struct ExplorerWindowEvents {
    /// The window has drawn its first folder (`ready-to-show`).
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

/// What the controller is told a window can be told (the original's `webContents.send`).
public enum ExplorerWindowMessage: Equatable, Sendable {
    /// Items opened with File Trail from another app are waiting for it (`filetrail:openRequestsWaiting`).
    case openRequestsWaiting
}

/// The parts of a window the controller uses (`ExplorerWindowLike`).
@MainActor
public protocol ExplorerWindowLike: AnyObject {
    /// Its number while the app runs (the original's web contents id).
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
    func tell(_ message: ExplorerWindowMessage)
}

/// What the controller keeps in the app state store (`ExplorerWindowStore`).
public protocol ExplorerWindowStore: AnyObject {
    func preferences() -> AppPreferences
    func explorerWindows() -> [StoredExplorerWindow]
    func windowPreferences(_ windowID: String) -> AppPreferences
    func lastClosedWindow() -> StoredExplorerWindow?
    func createWindowSession(overrides: [String: JSONNode]) -> WindowSession
    func addExplorerWindow(id: String, bounds: StoredWindowState, session: WindowSession?)
    func removeExplorerWindow(_ windowID: String)
    func setExplorerWindowOrder(_ windowIDs: [String])
    func rememberClosedWindow(_ windowID: String)
    func setExplorerWindowBounds(_ windowID: String, _ value: StoredWindowState)
    func flush()
}

extension AppStateStore: ExplorerWindowStore {}

@MainActor
public final class ExplorerWindowController<W: ExplorerWindowLike> {
    /// What the controller needs of the app (`ExplorerWindowHost`).
    @MainActor
    public struct Host {
        public var store: any ExplorerWindowStore
        /// Makes a window for the record, not shown yet, opening as `launch` says.
        public var createWindow: (StoredExplorerWindow, ExplorerLaunchContext) -> W
        /// A new id for a window, kept between launches (`window-<uuid>`).
        public var newWindowID: () -> String = { "window-\(UUID().uuidString.lowercased())" }
        /// The usable area of the screen a window at `bounds` is on.
        public var workArea: (WindowBounds) -> WindowBounds
        /// Asks each window for its tabs as they are now; nil for one that doesn't answer.
        public var requestTabs: @MainActor ([W]) async -> [WindowTabsAnswer?]
        /// Something the menu shows changed: which windows are open, which is in front, whether they are on screen.
        public var windowsChanged: () -> Void = {}
        public var log: (String) -> Void = { _ in }
        public var scheduler: any FolderWatchScheduler

        public init(
            store: any ExplorerWindowStore, createWindow: @escaping (StoredExplorerWindow, ExplorerLaunchContext) -> W,
            workArea: @escaping (WindowBounds) -> WindowBounds,
            requestTabs: @escaping @MainActor ([W]) async -> [WindowTabsAnswer?],
            scheduler: any FolderWatchScheduler = DispatchFolderWatchScheduler()
        ) {
            self.store = store
            self.createWindow = createWindow
            self.workArea = workArea
            self.requestTabs = requestTabs
            self.scheduler = scheduler
        }
    }

    /// WINDOW_BOUNDS_SAVE_DELAY_MS: how long the place and size of a window that moves wait before they are recorded.
    public static var boundsSaveDelayMilliseconds: Double { Double(WindowBoundsRecorder.saveDelayMilliseconds) }
    /// STARTUP_SHOW_TIMEOUT_MS: how long startup waits for a window's first folder before showing the windows anyway.
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
    // The window the close question is on, while it is asked.
    public private(set) var stopQuestionParent: W?
    // Set from the moment closing asks until it has its answer.
    private var closeQuestionPending = false
    // True while Merge All Windows waits for the windows' tabs: one runs at a time, or the two would close each
    // other's windows.
    private var merging = false
    // True until the windows the app opens with have been shown.
    private var startupShowPending = false
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
        startupShowPending = true
        let showAll = { [weak self, startup] in
            guard !startup.shown else { return }
            startup.shown = true
            self?.startupShowPending = false
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
    public func openDefaultWindow(initialCommand: RendererCommand? = nil) {
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
        let record = createRecord(newWindowBounds(source?.window), session: Self.node(session))
        store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        open(record, launch: ExplorerLaunchContext(restoreTabs: true), place: .front)
        return true
    }

    /// `mergeInto`, Merge All Windows: the tabs of every other window, front to back, which close. The window asking
    /// adds the tabs after its own `tabCount`. One stays open, its tabs where they are, when it doesn't answer, when
    /// something is open in it that closing would lose, or when its tabs don't fit in the window asking. One merge
    /// runs at a time; and when the window asking closes, or the app starts quitting, while the windows are asked,
    /// nothing is merged.
    public func mergeInto(_ senderID: Int?, tabCount: Int) async -> [OpenTabPreference] {
        guard let target = windows.byWindowID(senderID), !shuttingDown, !merging, isStayingOpen(target.window) else {
            return []
        }
        merging = true
        defer { merging = false }
        let others = openWindows().filter { $0 !== target }
        let answers = await host.requestTabs(others.map(\.window))
        var room = AppPreferenceLimits.openTabsLimit - tabCount
        var tabs: [OpenTabPreference] = []
        for (index, entry) in others.enumerated() {
            if !isStayingOpen(target.window) || shuttingDown { break }
            guard answers.indices.contains(index), let answer = answers[index], !answer.busy, !answer.tabs.isEmpty,
                answer.tabs.count <= room, isStayingOpen(entry.window)
            else { continue }
            room -= answer.tabs.count
            tabs += answer.tabs
            closingWithoutAsking.insert(ObjectIdentifier(entry.window))
            merged.insert(ObjectIdentifier(entry.window))
            entry.window.close()
        }
        return tabs
    }

    /// `launchContextFor`: what the window opened with.
    public func launchContext(for windowID: Int?) -> ExplorerLaunchContext {
        windows.byWindowID(windowID)?.launch ?? ExplorerLaunchContext()
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
        var session = lastClosed.map { Self.node($0.session) } ?? [:]
        session["openTabs"] = .array([])
        session["activeTabIndex"] = .number(0)
        let record = createRecord(lastClosed?.bounds ?? .default, session: session)
        host.store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        let window = open(record, launch: ExplorerLaunchContext(startupFolderPath: path), place: .front)
        if let selectPath, let entry = windows.byWindowID(window.windowID) {
            addOpenRequest(OpenRequest(path: selectPath, kind: .select), to: entry)
        }
    }

    private func addOpenRequest(_ request: OpenRequest, to entry: ExplorerWindowEntry<W>) {
        openRequests[entry.windowID, default: []].append(request)
        entry.window.tell(.openRequestsWaiting)
    }

    /// `takeOpenRequests`: the items waiting for this window to open them; each is handed out once.
    public func takeOpenRequests(_ windowID: Int?) -> [OpenRequest] {
        guard let entry = windows.byWindowID(windowID) else { return [] }
        return openRequests.removeValue(forKey: entry.windowID) ?? []
    }

    /// `successorOf`: the window a running operation goes to when the one that started it closes: the one in front.
    /// None for a window closed with Stop and Close: its operation is stopped.
    public func successor(of windowID: Int) -> W? {
        if stoppedOnClose.contains(windowID) { return nil }
        return openWindows().first { $0.windowID != windowID }?.window
    }

    /// `closeWindowOf`: ⌘W on a window's last tab: closed as its close button closes it, so the question before
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

    // MARK: Windows the system made

    /// A window the system made of a tab dragged out of another (the original has no such thing): it becomes an
    /// explorer window of its own, with the panels and the size of the one it came from.
    public func adopt(_ window: W, id: String, from sourceID: Int?, overrides session: [String: JSONNode]) {
        let source = windows.byWindowID(sourceID)
        var overrides = source.map { Self.node(host.store.windowPreferences($0.id).windowSession) } ?? [:]
        overrides.merge(session) { _, new in new }
        let record = StoredExplorerWindow(
            id: id, bounds: Self.stored(window), session: host.store.createWindowSession(overrides: overrides))
        host.store.addExplorerWindow(id: record.id, bounds: record.bounds, session: record.session)
        attach(window, record: record, launch: ExplorerLaunchContext(restoreTabs: true), place: .front)
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
        return createRecord(lastClosed?.bounds ?? .default, session: lastClosed.map { Self.node($0.session) } ?? [:])
    }

    private func createRecord(_ bounds: StoredWindowState, session: [String: JSONNode]) -> StoredExplorerWindow {
        StoredExplorerWindow(
            id: host.newWindowID(), bounds: bounds, session: host.store.createWindowSession(overrides: session))
    }

    static func node(_ session: WindowSession) -> [String: JSONNode] {
        (try? JSONNode.of(session))?.object ?? [:]
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
        attach(window, record: record, launch: launch, place: place)
        return window
    }

    private func attach(
        _ window: W, record: StoredExplorerWindow, launch: ExplorerLaunchContext, place: ExplorerWindowOrder<W>.Place
    ) {
        let store = host.store
        let id = record.id
        let entry = ExplorerWindowEntry(id: id, window: window, windowID: window.windowID, launch: launch)
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
        if quit.isAskingToStop || closeQuestionPending {
            if !bringStopQuestionForward() { quit.hooks.bringStopQuestionForward() }
            return true
        }
        if openWindows().contains(where: { $0.window !== window }) { return false }
        guard let kind = quit.hooks.activeOperation(), QuitWhileBusy.question(kind, trigger: .close) != nil else {
            return false
        }
        let windowID = window.windowID
        closeQuestionPending = true
        stopQuestionParent = window
        Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            let stop = await quit.askToStopOperation(.close, parent: window?.sheetParent)
            closeQuestionPending = false
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
