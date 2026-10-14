// Port of the BrowserWindow host of apps/desktop/src/main/main.ts (createExplorerWindow, the window IPC) on native
// window tabs: what the app shell needs of the explorer windows
import AppKit
import FTFileSystem
import FTFoundation

/// Screen places as `app-state.json` keeps them: from the top left of the main screen, y growing down.
@MainActor
enum ScreenGeometry {
    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func bounds(of frame: NSRect) -> WindowBounds {
        WindowBounds(
            x: Double(frame.minX), y: Double(primaryHeight - frame.maxY), width: Double(frame.width),
            height: Double(frame.height))
    }

    static func frame(of bounds: WindowBounds) -> NSRect {
        NSRect(
            x: bounds.x, y: Double(primaryHeight) - bounds.y - bounds.height, width: bounds.width,
            height: bounds.height)
    }

    /// Where a stored window goes; one with no place is centered on the main screen.
    static func frame(for stored: StoredWindowState) -> NSRect {
        if let x = stored.x, let y = stored.y {
            return frame(of: WindowBounds(x: x, y: y, width: stored.width, height: stored.height))
        }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSRect(
            x: (screen.midX - stored.width / 2).rounded(), y: (screen.midY - stored.height / 2).rounded(),
            width: stored.width, height: stored.height)
    }

    /// The usable area of the screen a window at `bounds` is on.
    static func workArea(for bounds: WindowBounds) -> WindowBounds {
        let frame = frame(of: bounds)
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
        return self.bounds(of: screen?.visibleFrame ?? frame)
    }

    static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A notice a window shows (a toast in the original).
enum WindowNotice: Equatable {
    /// "A window can have up to 100 tabs".
    case tabLimit

    var title: String {
        switch self {
        case .tabLimit: "A window can have up to \(AppPreferenceLimits.openTabsLimit) tabs"
        }
    }
}

/// The explorer windows of the app, on native window tabs: each explorer window of the original is a tab group, each
/// tab a window. It plugs `ExplorerWindowController` into AppKit and is the app shell's `ExplorerWindowHost`.
@MainActor
final class ExplorerWindows: ExplorerWindowHost, ExplorerWindowListing {
    let store: AppStateStore
    private(set) var controller: ExplorerWindowController<ExplorerTabGroup>!
    /// What Copy or Cut put on the clipboard, which every window pastes (P5-08 fills it).
    let clipboard = SharedClipboard()
    private let tabRequests = WindowTabsRequests()
    private var groups: [ExplorerTabGroup] = []
    private var nextGroupNumber = 1_000_000
    private var reconcileScheduled = false

    /// The one folder watch of the app: each window watches its front tab's folder.
    var folderWatches: FolderWatches?
    /// Something the menu shows changed: which windows are open, which is in front, whether they are on screen.
    var onWindowsChanged: () -> Void = {}
    /// What a tab says the menu should show.
    var onMenuState: (_ windowID: Int, ApplicationMenuState) -> Void = { _, _ in }
    /// Mounts a disk image opened from another app (P2's disk image opener).
    var mountDiskImage: (String) async -> DiskImageOpenResponse = { _ in DiskImageOpenResponse(status: .failed) }
    /// Shows a notice in a window (P5-09's notifications); by default the app beeps.
    var showNotice: (WindowNotice, NSWindow?) -> Void = { _, _ in NSSound.beep() }
    var log: (String) -> Void = { _ in }

    /// Where a tab with nowhere else to go opens.
    var home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Which disk a path is on (`getVolumeRootPath`): `/Volumes/<name>`, or `/`.
    var volumeRoot: (String) -> String = { ExplorerTabs.volumeRootPath($0) }
    private var observers: [any NSObjectProtocol] = []

    init(store: AppStateStore, quit: QuitCoordinator) {
        self.store = store
        // The app's own tab commands open tabs; macOS doesn't make windows into tabs by itself.
        NSWindow.allowsAutomaticWindowTabbing = false
        var host = ExplorerWindowController<ExplorerTabGroup>.Host(
            store: store,
            createWindow: { [unowned self] record, launch in makeGroup(record, launch: launch) },
            workArea: { ScreenGeometry.workArea(for: $0) },
            requestTabs: { [unowned self] groups in await requestTabs(groups) })
        host.windowsChanged = { [unowned self] in onWindowsChanged() }
        host.log = { [unowned self] in log($0) }
        controller = ExplorerWindowController(host: host, quit: quit)
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated {
                    guard let path = volume?.standardizedFileURL.path else { return }
                    self?.disksUnmounted([path])
                }
            })
    }

    // MARK: Tabs that follow the disk

    /// Disks just unmounted, by the folders they were mounted at: every window lets go of them (B-VIEW-173).
    func disksUnmounted(_ mountPaths: Set<String>) {
        guard !mountPaths.isEmpty else { return }
        for group in groups where !group.isDestroyed {
            group.disksUnmounted(mountPaths, homePath: home, volumeRoot: volumeRoot)
        }
    }

    /// A file operation's progress, from whichever window ran it, as the original's `onWriteOperationProgress` reaches
    /// every window: once one that renamed or moved folders has ended, every window's tabs follow them (B-VIEW-172).
    /// The write coordinator sends every progress event here. Until it exists (P3-05; FTOperations runs no file
    /// operation yet) nothing in the app renames or moves an item, so nothing calls this.
    func writeOperationProgress(_ event: WriteOperationProgress) {
        itemsMoved(ExplorerTabs.followedMoves(event))
    }

    /// Folders renamed or moved: every window's tabs follow them.
    private func itemsMoved(_ moves: [PathMove]) {
        guard !moves.isEmpty else { return }
        for group in groups where !group.isDestroyed {
            group.followMovedItems(moves)
        }
    }

    // MARK: ExplorerWindowHost

    var windows: any ExplorerWindowListing { self }

    func openStartupWindows(folder: String?) {
        controller.openStartupWindows(folder: folder)
    }

    func openDefaultWindow(initialCommand: RendererCommand?) {
        controller.openDefaultWindow(initialCommand: initialCommand)
    }

    func openNewWindowFromFront() {
        controller.openNewWindowFromFront()
    }

    func bringToFront() {
        controller.bringToFront()
    }

    func openFromOtherApp(_ path: String) -> Bool {
        controller.openFromOtherApp(path)
    }

    func openWindowOnFolder(_ path: String) {
        controller.openWindowOnFolder(path)
    }

    // MARK: ExplorerWindowListing

    /// The tab in front of the explorer window in front.
    var front: (any ExplorerWindowHandle)? { controller.frontWindow()?.selected }
    var count: Int { controller.windows.count }

    func handle(for window: NSWindow) -> (any ExplorerWindowHandle)? {
        var current: NSWindow? = window
        while let candidate = current {
            if let tab = (candidate as? ExplorerTabWindow)?.explorerTab, tab.group != nil { return tab }
            current = candidate.sheetParent
        }
        return nil
    }

    func handle(windowID: Int) -> (any ExplorerWindowHandle)? {
        tab(windowID: windowID)
    }

    /// Every open tab, window by window.
    var allTabs: [MainWindowController] { groups.flatMap(\.tabs) }

    func tab(windowID: Int) -> MainWindowController? {
        allTabs.first { $0.windowID == windowID }
    }

    // MARK: Preferences

    /// A preference changed in any window: every explorer window that follows preferences is told.
    func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        for tab in allTabs {
            tab.preferencesChanged(change)
        }
    }

    // MARK: Running operations

    /// The explorer window a tab is in: an operation belongs to the window that started it.
    func explorerWindowID(ofTab windowID: Int) -> Int? {
        tab(windowID: windowID)?.group?.windowID
    }

    /// `successorOf`: the tab in front of the window a running operation goes to when its own window closes; nil for a
    /// window closed with Stop and Close, or with no other window open. P3-05's write coordinator asks it.
    func successor(ofExplorerWindow windowID: Int) -> MainWindowController? {
        controller.successor(of: windowID)?.selected
    }

    // MARK: Opening

    /// New Window on `folder`, from the tab in front (the automation's `newWindow`); the new window's tab.
    @discardableResult
    func openWindow(at folder: URL) -> MainWindowController? {
        if let tab = front as? MainWindowController, let group = tab.group {
            group.openNewWindow(from: tab, path: folder.path)
        } else {
            controller.openWindowOnFolder(folder.path)
        }
        return front as? MainWindowController
    }

    private func makeGroup(_ record: StoredExplorerWindow, launch: ExplorerLaunchContext) -> ExplorerTabGroup {
        let preferences = store.windowPreferences(record.id)
        let resolved = StartupTabs.resolve(
            preferences, homePath: home, startupFolderPath: launch.startupFolderPath, restoreTabs: launch.restoreTabs)
        // A waiting tab whose folder is gone is dropped; the one in front opens the nearest folder above it.
        var tabs: [StartupTab] = []
        var active = 0
        for (index, startup) in resolved.tabs.enumerated() {
            if index == resolved.activeIndex {
                var shown = startup
                shown.path = ExplorerTabs.pathAndAncestors(startup.path).first(where: ScreenGeometry.isFolder) ?? home
                active = tabs.count
                tabs.append(shown)
            } else if ScreenGeometry.isFolder(startup.path) {
                tabs.append(startup)
            }
        }
        let frame = ScreenGeometry.frame(for: record.bounds)
        nextGroupNumber += 1
        let group = ExplorerTabGroup(
            windowID: nextGroupNumber, recordID: record.id, session: TabGroupSession(preferences.windowSession),
            frame: frame, host: self)
        let controllers = tabs.enumerated().map { index, startup in
            MainWindowController(tab: startup, frame: frame, loadNow: index == active)
        }
        let shown = controllers[active]
        shown.onReady = { [weak group, weak shown] in
            group?.events.readyToShow()
            if let command = launch.initialCommand { shown?.perform(command) }
        }
        group.start(with: controllers, active: active)
        groups.append(group)
        return group
    }

    private func requestTabs(_ asked: [ExplorerTabGroup]) async -> [WindowTabsAnswer?] {
        var answers: [WindowTabsAnswer?] = []
        for group in asked {
            let answer = await tabRequests.ask(windowID: group.windowID) { [weak self, weak group] requestID in
                guard let group, !group.isDestroyed else { throw CancellationError() }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.tabRequests.answer(from: group.windowID, requestID: requestID, group.mergeAnswer)
                    }
                }
            }
            answers.append(answer)
        }
        return answers
    }

    /// Disk images opened from another app wait for the window in front: it mounts each and opens its disk in a new
    /// window, or a new tab as Settings says (`openDiskImage`).
    func openRequestsWaiting(in group: ExplorerTabGroup) {
        for path in controller.takeOpenRequests(group.windowID) {
            Task {
                let response = await mountDiskImage(path)
                guard let tab = group.selected else { return }
                if response.status == .opened, let volumePath = response.volumePath {
                    if store.preferences().diskImageOpensIn == .tab {
                        group.openTab(path: volumePath, from: tab)
                    } else {
                        group.openNewWindow(from: tab, path: volumePath)
                    }
                } else if response.status == .failed, let window = tab.window {
                    let notice = DiskImageNames.describeFailure(path: path, reason: response.reason)
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = notice.title
                    alert.informativeText = notice.message
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    func tellTabLimit(in window: NSWindow?) {
        guard store.preferences().notificationsEnabled else { return }
        showNotice(.tabLimit, window)
    }

    // MARK: What the windows tell it

    func groupClosed(_ group: ExplorerTabGroup) {
        groups.removeAll { $0 === group }
    }

    /// A tab closed: its folder is no longer watched, and the menu forgets what it said.
    func tabGone(_ tab: MainWindowController) {
        folderWatches?.watch(windowID: tab.windowID, path: nil)
    }

    /// The tab got the keyboard: a change its folder's watch could not see is looked for.
    func tabFocused(_ tab: MainWindowController) {
        folderWatches?.checkForMissedChanges(windowID: tab.windowID)
        tabNavigated(tab)
    }

    /// Only the folder of a window's front tab is watched; a tab in the background reads its folder again when it
    /// comes back.
    func tabNavigated(_ tab: MainWindowController) {
        if let group = tab.group, let watches = folderWatches {
            for other in group.tabs {
                let watched = other === group.selected && other.loaded
                watches.watch(windowID: other.windowID, path: watched ? other.folder.path : nil)
            }
        }
        reportMenuState(tab)
    }

    func reportMenuState(_ tab: MainWindowController) {
        onMenuState(tab.windowID, tab.menuState)
    }

    /// A folder a window watches changed.
    func folderChanged(windowID: Int, _ change: FolderChange) {
        tab(windowID: windowID)?.reload()
    }

    // MARK: Tabs the system moved

    /// Tabs dragged between windows by the system's tab bar: once the move is over, each native tab group is one
    /// explorer window again.
    func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.reconcileScheduled = false
                self.reconcile()
            }
        }
    }

    private func reconcile() {
        let live = groups.filter { $0.isMaterialized && !$0.isDestroyed && !$0.isArranging }
        guard live.count == groups.filter({ !$0.isDestroyed }).count else {
            // A window is opening or closing its tabs: once it is done.
            return
        }
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        var seen = Set<ObjectIdentifier>()
        var sets: [[MainWindowController]] = []
        for group in live {
            for tab in group.tabs where !seen.contains(ObjectIdentifier(tab)) {
                guard let window = tab.window else { continue }
                let peers = (window.tabbedWindows ?? [window]).compactMap { ($0 as? ExplorerTabWindow)?.explorerTab }
                    .filter { $0.group.map { liveIDs.contains(ObjectIdentifier($0)) } ?? false }
                for peer in peers { seen.insert(ObjectIdentifier(peer)) }
                if !peers.isEmpty { sets.append(peers) }
            }
        }
        if sets.count == live.count,
            zip(sets, live).allSatisfy({ $0.map(ObjectIdentifier.init) == $1.tabs.map(ObjectIdentifier.init) })
        {
            return
        }
        // The largest set keeps a window's identity; a set no window can claim becomes a window of its own.
        var claimed = Set<ObjectIdentifier>()
        for set in sets.sorted(by: { $0.count > $1.count }) {
            let owners = live.filter { group in !claimed.contains(ObjectIdentifier(group)) }
                .map { group in (group, set.filter { $0.group === group }.count) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            if let owner = owners.first?.0 {
                claimed.insert(ObjectIdentifier(owner))
                owner.replaceTabs(set)
            } else {
                adopt(set)
            }
        }
        for group in live where !claimed.contains(ObjectIdentifier(group)) {
            controller.absorb(group)
            group.finishAbsorbed()
        }
    }

    private func adopt(_ tabs: [MainWindowController]) {
        guard let first = tabs.first, let source = first.group else { return }
        nextGroupNumber += 1
        let id = controller.host.newWindowID()
        // The panels of the window it came from, and none of its closed tabs.
        let group = ExplorerTabGroup(
            windowID: nextGroupNumber, recordID: id,
            session: TabGroupSession(store.windowPreferences(source.recordID).windowSession),
            frame: first.window?.frame ?? .zero, host: self)
        group.session.update { $0 = source.session.panels }
        groups.append(group)
        controller.adopt(group, id: id, from: source.windowID, overrides: [:])
        group.start(adopting: tabs)
    }
}
