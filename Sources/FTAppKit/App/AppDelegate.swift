import AppKit
import FTFileSystem
import FTFoundation

/// The app shell: it starts the app's services and windows, and answers the system about the app's lifetime and the
/// items other apps open with it.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
        openFiles = OpenFileEntryPoint(
            describe: { LaunchContext.describeOpenedPath($0) },
            open: { [weak self] request in self?.openFromOtherApp(request) })
    }

    // MARK: Services

    public private(set) var logger: AppLogger?
    public private(set) var store: AppStateStore?
    /// One directory service for the app, and the one folder watch the windows share.
    public let directoryService = DirectoryService()
    public private(set) var folderWatches: FolderWatches?

    /// The theme and accent every window draws with; a change reaches every window at once.
    public let appearance = AppearanceModel.shared
    /// Settings, Help, About and Acknowledgements.
    public private(set) var pageWindows: PageWindows!
    /// What a window changes of the preferences goes through here: it is stored, and told to the appearance, to every
    /// explorer window and to the menu. The toolbar and Settings change the look through it.
    public private(set) var preferenceChannel: WindowPreferenceChannel?

    /// Quit and close while busy. The write coordinator fills `quit.hooks.activeOperation` and `shutDown`.
    public let quit = QuitCoordinator()
    /// The file operations: the crash journal's recovery, the write coordinator, each window's side.
    private(set) var writeOperations: AppWriteOperations?
    private var userDataDirectory: URL?

    /// The explorer windows, made once the state store is open.
    private(set) var explorerWindows: ExplorerWindows!
    var host: any ExplorerWindowHost { explorerWindows }

    private var openFiles: OpenFileEntryPoint!
    private var diskImages: DiskImageOpener?
    private var mainMenu: MainMenu?
    private var dockMenu: NSMenu?
    private var isSecondInstance = false
    private var secondInstanceObserver: (any NSObjectProtocol)?
    private var readyToTerminate = false
    private var windowVisibility: WindowVisibilityMonitor?

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Launch

    /// The dates' minute timer rests while no window can be seen, and they are read again on the way back.
    private func followWindowVisibility() {
        let clock = RelativeClock.shared
        clock.isWindowVisible = { WindowVisibilityMonitor.anExplorerWindowCanBeSeen() }
        windowVisibility = WindowVisibilityMonitor(
            isVisible: { WindowVisibilityMonitor.anExplorerWindowCanBeSeen() },
            changed: { clock.windowStateDidChange() })
    }

    /// Launch order: a copy started by hand hands over to the one running; otherwise the logger and the state store,
    /// the appearance, the services (the window host among them), the menu and the Dock menu, the startup windows,
    /// then the items that came before them.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppClock.start()
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !handOverToRunningInstance(arguments) else { return }

        startLogger(arguments)
        let preferences = store?.preferences() ?? AppPreferences.defaults(theme: .auto)
        appearance.apply(theme: preferences.theme, accent: preferences.accent)
        appearance.startFollowingSystem()
        startServices()
        followWindowVisibility()
        buildMenus()
        let flagValues = Set(
            ["--snapshot", "--automation", "--out", "--elements", "--user-data-dir"].compactMap {
                Self.value(after: $0, in: arguments)
            })
        let launchArguments = arguments.filter { !flagValues.contains($0) }
        let requested = LaunchContext.resolveStartupFolderPath(
            argv: launchArguments,
            cwd: LaunchContext.resolveWorkingDirectory(
                envPWD: ProcessInfo.processInfo.environment["PWD"], cwd: FileManager.default.currentDirectoryPath),
            homePath: home.path, appPath: Bundle.main.bundlePath)

        #if DEBUG
            let automation = AutomationRunner.options(from: arguments).map { options in
                AutomationRunner(options: options) { [weak self] in
                    self?.explorerWindows.front as? MainWindowController
                }
            }
            _ = automation?.load()
            let start = automation?.startFolder ?? requested.map { URL(fileURLWithPath: $0) } ?? home
        #else
            let start = requested.map { URL(fileURLWithPath: $0) } ?? home
        #endif

        // The windows open as they were at quit; the folder File Trail was launched with goes to the one in front.
        explorerWindows.openStartupWindows(folder: requested == nil && start == home ? nil : start.path)
        writeOperations?.showStartupNotices()
        // Items File Trail was launched to open go to the window in front.
        openFiles.startupWindowsOpened()
        if let bundleID = Bundle.main.bundleIdentifier {
            secondInstanceObserver = SecondInstance.listen(bundleID: bundleID) { [weak self] in
                guard let self else { return }
                SecondInstance.arrived(shutdownInProgress: self.quit.shutdownInProgress, host: self.host)
            }
        }
        NSApp.activate()
        guard let controller = explorerWindows.front as? MainWindowController else { return }

        #if DEBUG
            if let automation {
                Task { await automation.run() }
                return
            }
        #endif

        if let snapshot = Self.value(after: "--snapshot", in: arguments) {
            Task { await WindowSnapshot.write(controller, to: URL(fileURLWithPath: snapshot)) }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// One File Trail runs at a time: LaunchServices keeps it so for the bundle, and a copy started by hand hands over to
    /// the one running. The second launch ignores its arguments and only brings a window forward, restoring or opening
    /// one if it has to (`SecondInstance`).
    private func handOverToRunningInstance(_ arguments: [String]) -> Bool {
        guard !Self.isDrivenRun(arguments), ProcessInfo.processInfo.environment["FILETRAIL_ALLOW_MULTIPLE"] != "1",
            let bundleID = Bundle.main.bundleIdentifier,
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0 != NSRunningApplication.current })
        else { return false }
        running.activate()
        SecondInstance.announce(bundleID: bundleID)
        isSecondInstance = true
        NSApp.terminate(nil)
        return true
    }

    /// A folder no earlier run used: a process number comes round again, and the state left under it would bring back
    /// that run's windows.
    static func drivenUserDataDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("filetrail-driven-\(UUID().uuidString)")
    }

    /// A run driven by a script (automation, a snapshot): it starts from nothing, not from the windows of
    /// the last, and runs beside a File Trail already open instead of handing over to it.
    static let drivenRunFlags: Set<String> = [
        "--automation", "--snapshot",
    ]

    static func isDrivenRun(_ arguments: [String]) -> Bool {
        arguments.contains { drivenRunFlags.contains($0) }
    }

    private func startLogger(_ arguments: [String]) {
        let driven = Self.isDrivenRun(arguments)
        let scratch = Self.drivenUserDataDirectory()
        let userData =
            Self.value(after: "--user-data-dir", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? (driven ? scratch : AppStatePaths.userDataDirectory())
        userDataDirectory = userData
        let logger = AppLogger(filePath: AppStatePaths.appLog(in: userData).path)
        self.logger = logger
        logger.info(
            "[filetrail] app start",
            .context([
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "userDataPath": .string(userData.path),
                "debugEnabled": .bool(logger.isDebugEnabled),
            ]))
        store = AppStateStore(filePath: AppStatePaths.appState(in: userData).path)
        quit.hooks.log = { [weak logger] message in logger?.info(.text("[filetrail] \(message)")) }
    }

    private func startServices() {
        let store = store ?? AppStateStore(filePath: AppStatePaths.appState(in: AppStatePaths.userDataDirectory()).path)
        let windows = ExplorerWindows(store: store, quit: quit)
        explorerWindows = windows
        // Read off the main thread: the windows say "Macintosh HD" until it returns, then the name it read.
        StartupDisk.shared.start()
        let pages = PageWindows(preferences: { [weak self] in self?.store?.preferences() ?? .defaults() })
        pageWindows = pages
        let channel = WindowPreferenceChannel(
            store: store,
            explorerWindowID: { [weak windows] senderID in
                senderID.flatMap { windows?.tab(windowID: $0)?.group?.recordID }
            },
            onPreferencesChanged: { [weak self] preferences, change in self?.preferencesChanged(preferences, change) })
        preferenceChannel = channel
        // Settings reads and writes the app's preferences, not a window's: it asks the channel for no window.
        pages.loadPreferences = { [weak channel] in channel?.preferences(for: nil) ?? store.preferences() }
        pages.updatePreferences = { [weak channel] change in channel?.update(from: nil) { $0.apply(change) } }
        let folderWatches = FolderWatches(
            .app(cache: directoryService.cache) { [weak windows] windowID, change in
                windows?.folderChanged(windowID: windowID, change)
            })
        self.folderWatches = folderWatches
        windows.folderWatches = folderWatches
        let iconStore = FileIconStore()
        // The icons nearly every folder shows are drawn while the first window opens.
        iconStore.preloadGenericIcons()
        ExplorerServices.installed = ExplorerServices(
            directoryService: directoryService, iconStore: iconStore, clipboard: windows.clipboard,
            preferences: preferenceChannel)
        let diskImages = DiskImageOpener(
            onMounted: {}, logError: { [weak logger] message in logger?.error(.text(message)) })
        self.diskImages = diskImages
        windows.mountDiskImage = { await diskImages.open($0) }

        // The journal's recovery runs before any window can write.
        let writes = AppWriteOperations(
            userData: userDataDirectory ?? AppStatePaths.userDataDirectory(), directoryService: directoryService,
            windows: windows, trash: .live(homePath: FileManager.default.homeDirectoryForCurrentUser.path),
            emptyTrash: {
                let result = await TrashState.empty()
                return (result.ok, result.error)
            },
            log: { [weak logger] message in logger?.info(.text(message)) })
        writeOperations = writes
        windows.onExplorerWindowClosed = { [weak writes] group in writes?.explorerWindowClosed(group) }
        windows.onTabFocused = { [weak writes] tab in writes?.tabCameToFront(tab) }
        quit.hooks.activeOperation = { [weak writes] in writes?.busyKind }
        quit.hooks.anyWindowOpen = { NSApp.windows.contains { $0.isVisible || $0.isMiniaturized } }
        quit.hooks.frontWindow = { [weak self] in self?.host.windows.front?.window }
        quit.hooks.recordAllBounds = { [weak windows] in windows?.controller.recordAllBounds() }
        quit.hooks.bringStopQuestionForward = { [weak self, weak windows] in
            // The question hangs from an explorer window, or from the window in front when quitting.
            if windows?.controller.bringStopQuestionForward() == true { return }
            guard let parent = self?.quit.stopQuestionParent else { return }
            if parent.isMiniaturized { parent.deminiaturize(nil) }
            parent.makeKeyAndOrderFront(nil)
        }
        quit.hooks.flushStore = { [weak self] in self?.store?.flush() }
        quit.hooks.shutDown = { [weak self] in
            // The running operation stops (not Empty Trash), waited for up to 15 s; the folder sizes stop measuring.
            await self?.writeOperations?.shutDown()
            self?.folderWatches?.stopAll()
            // No fd goes on searching after the app.
            SearchRuntime.shared.close()
            self?.logger?.info("[filetrail] app stop", .context(["phase": .string("before-quit")]))
            self?.logger?.flush()
        }
        quit.hooks.showStopQuestion = { question, parent in await StopQuestionAlert.show(question, parent: parent) }
        quit.hooks.exit = { [weak self] in
            self?.readyToTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func buildMenus() {
        let menu = MainMenu(windows: host.windows)
        menu.connect(
            openAbout: { [weak self] in self?.pageWindows.openAbout() },
            openSettings: { [weak self] in self?.pageWindows.openSettings() },
            openHelp: { [weak self] topic in self?.pageWindows.openHelp(topic: topic) },
            openWindowFor: { [weak self] command in
                // A window opened with none open runs the place chosen once it has opened.
                self?.host.openDefaultWindow(initialCommand: command)
            },
            openNewWindowFromFront: { [weak self] in self?.host.openNewWindowFromFront() },
            openWorkspace: { [weak self] id, window in
                self?.explorerWindows.openWorkspace(id: id, inPlaceOf: window as? MainWindowController)
            },
            manageWorkspaces: { [weak self] in self?.pageWindows.openSettings(tab: .browsing) })
        menu.shortcuts = { [weak self] in
            self?.store.map { ShortcutCommands.resolve($0.preferences().shortcutOverrides).bindings }
                ?? ShortcutCommands.defaultBindings
        }
        menu.textEditorName = { [weak self] in self?.store?.preferences().defaultTextEditor.appName }
        menu.workspaces = { [weak self] in
            (self?.store?.preferences().workspaces ?? []).map { WorkspaceMenuEntry(id: $0.id, name: $0.name) }
        }
        menu.build()
        menu.observeFocus()
        mainMenu = menu
        explorerWindows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
        explorerWindows.onMenuState = { [weak menu] windowID, state in
            menu?.sync.setWindowState(windowID: windowID, state)
        }

        dockMenu = ShellActions.makeDockMenu(target: self, action: #selector(dockNewWindow(_:)))
    }

    /// A preference changed, in a window or in Settings: the appearance follows a new theme or accent, every
    /// explorer window and Help are told, and the menu is built again with new keys or a new text editor.
    private func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        appearance.preferencesChanged(preferences, change)
        explorerWindows.preferencesChanged(preferences, change)
        pageWindows.preferencesChanged(preferences, change)
        if change.keys.contains(.shortcutOverrides) || change.keys.contains(.defaultTextEditor)
            || change.keys.contains(.workspaces)
        {
            mainMenu?.build()
        }
    }

    // MARK: The app's lifetime

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon. With no explorer window open one opens, even while Settings is open; with every window
    /// minimized the one in front comes back.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger?.info(
            "[filetrail] app activate",
            .context([
                "explorerWindowCount": .number(Double(host.windows.count)), "hasVisibleWindows": .bool(flag),
            ]))
        ShellActions.activate(hasVisibleWindows: flag, shutdownInProgress: quit.shutdownInProgress, host: host)
        return false
    }

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu
    }

    @objc private func dockNewWindow(_ sender: Any?) {
        host.openNewWindowFromFront()
    }

    /// Quitting always goes through the quit coordinator, which ends in `NSApp.reply`. A second ⌘Q while it waits for
    /// an operation to stop must not cut that wait short.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isSecondInstance || readyToTerminate { return .terminateNow }
        let wasOwed = terminateReplies.asked()
        Task { @MainActor in
            let outcome = await quit.quit()
            if let answer = terminateReplies.answer(outcome, wasOwed: wasOwed) {
                NSApp.reply(toApplicationShouldTerminate: answer)
            }
        }
        return .terminateLater
    }

    private var terminateReplies = TerminateReplies()

    // MARK: Files from Finder

    /// An item opened with File Trail from Finder (Open With), a drop on the Dock icon or `open -a "File Trail" <path>`: a
    /// disk image opens as one opened in File Trail does, a folder opens in a new tab, and any other item is selected in
    /// its folder in a new tab. macOS sends it before the windows are open when it launches File Trail to open it: it
    /// waits for them.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let taken = openFiles.open(urls.filter(\.isFileURL).map(\.path))
        Task { [weak self] in
            for request in await taken.value {
                self?.logger?.info(
                    "[filetrail] open file",
                    .context(["path": .string(request.path), "kind": .string(request.kind.rawValue)]))
            }
        }
    }

    /// The window in front takes the item. With no window open, see `ShellActions.openFromOtherApp`; an error is shown on
    /// its own, with no window to show it in.
    private func openFromOtherApp(_ request: OpenRequest) {
        guard let diskImages else { return }
        Task { @MainActor in
            await ShellActions.openFromOtherApp(
                request, shutdownInProgress: quit.shutdownInProgress, host: host,
                mount: { await diskImages.open($0) },
                showFailure: { title, message in
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = title
                    alert.informativeText = message
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                })
        }
    }
}

/// Whether a quit asked of AppKit ("terminate later") still waits for its answer. Each is answered once: a second ⌘Q
/// that comes while the first waits for an operation to stop leaves the answer to the first, and one that only brings
/// forward a question asked for another reason (the last window closing) is answered at once, or AppKit would wait for
/// good.
struct TerminateReplies {
    private(set) var owed = false

    /// A quit was asked of AppKit: whether one was waiting for its answer already.
    mutating func asked() -> Bool {
        defer { owed = true }
        return owed
    }

    /// What to answer AppKit once the quit ended with `outcome`, or nil for nothing (the app exits, or the quit before
    /// answers). `wasOwed` is what `asked` said.
    mutating func answer(_ outcome: QuitCoordinator.Outcome, wasOwed: Bool) -> Bool? {
        switch outcome {
        case .keptWorking:
            owed = false
            return false
        case .questionBroughtForward:
            guard !wasOwed else { return nil }
            owed = false
            return false
        case .exited, .alreadyShuttingDown:
            return nil
        }
    }
}
