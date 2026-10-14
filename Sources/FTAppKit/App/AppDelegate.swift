// Port of apps/desktop/src/main/main.ts (launch, Dock, open-file, quit) and the Dock parts of explorerWindowController.ts
import AppKit
import FTFileSystem
import FTFoundation

/// The app shell. Launch order, as the original's: the logger, the state store, the window host, the native appearance,
/// the services, the menu and the Dock menu, the startup windows, then the disk images that came before them.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
        openFiles = OpenFileEntryPoint { [weak self] path in self?.openDiskImageFromOtherApp(path) }
    }

    // MARK: Services

    public private(set) var logger: AppLogger?
    public private(set) var store: AppStateStore?
    /// One directory service for the app, and the one folder watch the windows share (P2-01).
    public let directoryService = DirectoryService()
    public private(set) var folderWatches: FolderWatches?

    /// The theme and accent every window draws with, followed live (B-DLG-232, 233).
    public let appearance = AppearanceModel.shared
    /// Help, About and Acknowledgements.
    public private(set) var pageWindows: PageWindows!
    /// What a window changes of the preferences goes through here: it is stored, and told to the appearance, to every
    /// explorer window and to the menu. P5-01's toolbar and P6-04's Settings change the look through it.
    public private(set) var preferenceChannel: WindowPreferenceChannel?

    /// Quit and close while busy. P3-05's write coordinator fills `quit.hooks.activeOperation` and `shutDown`.
    public let quit = QuitCoordinator()

    /// The explorer windows, made once the state store is open.
    private(set) var explorerWindows: ExplorerWindows!
    var host: any ExplorerWindowHost { explorerWindows }

    private var openFiles: OpenFileEntryPoint!
    private var diskImages: DiskImageOpener?
    private var mainMenu: MainMenu?
    private var dockMenu: NSMenu?
    private var isSecondInstance = false
    private var readyToTerminate = false

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Launch

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppClock.start()
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !handOverToRunningInstance(arguments) else { return }

        startLogger(arguments)
        let preferences = store?.preferences() ?? AppPreferences.defaults(theme: .auto)
        appearance.apply(theme: preferences.theme, accent: preferences.accent)
        appearance.startFollowingSystem()
        startServices()
        buildMenus()
        #if DEBUG
            registerAutomationPreferences()
        #endif

        let flagValues = Set(
            ["--snapshot", "--automation", "--out", "--elements", "--user-data-dir"].compactMap {
                Self.value(after: $0, in: arguments)
            })
        let launchArguments = arguments.filter { !flagValues.contains($0) }
        let requested = LaunchContext.resolveStartupFolderPath(
            argv: launchArguments,
            cwd: LaunchContext.resolveWorkingDirectory(
                envPWD: ProcessInfo.processInfo.environment["PWD"], cwd: FileManager.default.currentDirectoryPath),
            argvOffset: 0, homePath: home.path, appPath: Bundle.main.bundlePath)

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
        // Disk images File Trail was launched to open go to the window in front.
        openFiles.startupWindowsOpened()
        NSApp.activate()
        guard let controller = explorerWindows.front as? MainWindowController else { return }

        #if DEBUG
            if let automation {
                Task { await automation.run() }
                return
            }
        #endif

        if arguments.contains("--bench-launch") {
            Benchmark.launch(controller)
        } else if arguments.contains("--bench-scroll") {
            Task { await Benchmark.scroll(in: controller) }
        } else if arguments.contains("--bench") {
            Task { await Benchmark.run(in: controller, root: start) }
        }
        if let snapshot = Self.value(after: "--snapshot", in: arguments) {
            Task { await Benchmark.snapshot(controller, to: URL(fileURLWithPath: snapshot)) }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// One File Trail runs at a time: LaunchServices keeps it so for the bundle, and a copy started by hand hands over to
    /// the one running. The second launch ignores its arguments and only brings a window forward.
    private func handOverToRunningInstance(_ arguments: [String]) -> Bool {
        let driven = arguments.contains {
            ["--automation", "--bench", "--bench-launch", "--bench-scroll"].contains($0)
        }
        guard !driven, ProcessInfo.processInfo.environment["FILETRAIL_ALLOW_MULTIPLE"] != "1",
            let bundleID = Bundle.main.bundleIdentifier,
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0 != NSRunningApplication.current })
        else { return false }
        running.activate()
        isSecondInstance = true
        NSApp.terminate(nil)
        return true
    }

    private func startLogger(_ arguments: [String]) {
        // A run driven by a script (automation, benchmarks) starts from nothing, not from the windows of the last.
        let driven = arguments.contains {
            ["--automation", "--bench", "--bench-launch", "--bench-scroll", "--snapshot"].contains($0)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "filetrail-driven-\(ProcessInfo.processInfo.processIdentifier)")
        let userData =
            Self.value(after: "--user-data-dir", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? (driven ? scratch : AppStatePaths.userDataDirectory())
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

    /// Native parts of the window (title bar, scroll bars, pickers) follow the app's theme rather than the macOS
    /// appearance: Light or Dark pins them, Auto follows the system.
    public func applyAppearance(_ theme: ThemePreference) {
        appearance.apply(theme: theme)
    }

    private func startServices() {
        let store = store ?? AppStateStore(filePath: AppStatePaths.appState(in: AppStatePaths.userDataDirectory()).path)
        let windows = ExplorerWindows(store: store, quit: quit)
        explorerWindows = windows
        let pages = PageWindows(preferences: { [weak self] in self?.store?.preferences() ?? .defaults() })
        pages.openSettingsOnShortcuts = { [weak self] in self?.host.windows.front?.perform(.openSettings) }
        pageWindows = pages
        preferenceChannel = WindowPreferenceChannel(
            store: store,
            explorerWindowID: { [weak windows] senderID in
                senderID.flatMap { windows?.tab(windowID: $0)?.group?.recordID }
            },
            onPreferencesChanged: { [weak self] preferences, change in self?.preferencesChanged(preferences, change) })
        let folderWatches = FolderWatches(
            .app(cache: directoryService.cache) { [weak windows] windowID, change in
                windows?.folderChanged(windowID: windowID, change)
            })
        self.folderWatches = folderWatches
        windows.folderWatches = folderWatches
        windows.log = { [weak logger] message in logger?.info(.text("[filetrail] \(message)")) }
        let diskImages = DiskImageOpener(
            onMounted: {}, logError: { [weak logger] message in logger?.error(.text(message)) })
        self.diskImages = diskImages
        windows.mountDiskImage = { await diskImages.open($0) }

        quit.hooks.activeOperation = { nil }
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
            self?.folderWatches?.stopAll()
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
            openHelp: { [weak self] topic in self?.pageWindows.openHelp(topic: topic) },
            openWindowFor: { [weak self] command in
                // A window opened with none open runs the place chosen once it has opened.
                self?.host.openDefaultWindow(initialCommand: command == .newWindow ? nil : command)
            },
            openNewWindowFromFront: { [weak self] in self?.host.openNewWindowFromFront() })
        menu.shortcuts = { [weak self] in
            self?.store.map { ShortcutCommands.resolve($0.preferences().shortcutOverrides).bindings }
                ?? ShortcutCommands.defaultBindings
        }
        menu.textEditorName = { [weak self] in self?.store?.preferences().defaultTextEditor.appName }
        menu.build()
        menu.observeFocus()
        mainMenu = menu
        explorerWindows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
        explorerWindows.onMenuState = { [weak menu] windowID, state in
            menu?.sync.setWindowState(windowID: windowID, state)
        }

        dockMenu = ShellActions.makeDockMenu(target: self, action: #selector(dockNewWindow(_:)))
    }

    /// A preference changed in a window (`app:updatePreferences`): the appearance follows a new theme or accent, every
    /// explorer window and Help are told, and the menu is built again with new keys or a new text editor (B-DLG-233).
    private func preferencesChanged(_ preferences: AppPreferences, _ change: PreferencesChange) {
        appearance.preferencesChanged(preferences, change)
        explorerWindows.preferencesChanged(preferences, change)
        pageWindows.preferencesChanged(preferences, change)
        if change.patch["shortcutOverrides"] != nil || change.patch["defaultTextEditor"] != nil {
            mainMenu?.build()
        }
    }

    #if DEBUG
        /// What a scenario's `prefs` step does with the look: through the appearance, as Settings does. The zoom is read
        /// and ignored (D-005).
        private func registerAutomationPreferences() {
            AutomationPrefs.register("theme") { [appearance] value, _ in
                guard let theme = value.string.flatMap(ThemePreference.init(rawValue:)) else {
                    return .failed("theme \(value)")
                }
                appearance.apply(theme: theme)
                return .applied
            }
            AutomationPrefs.register("accent") { [appearance] value, _ in
                guard let accent = value.string.flatMap(AppPreferenceLimits.normalizeAccentColor) else {
                    return .failed("accent \(value)")
                }
                appearance.apply(accent: accent)
                return .applied
            }
            AutomationPrefs.register("zoomPercent") { value, _ in
                value.number == nil ? .failed("zoomPercent \(value)") : .applied
            }
        }
    #endif

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
        Task { @MainActor in
            switch await quit.quit() {
            case .keptWorking: NSApp.reply(toApplicationShouldTerminate: false)
            case .exited, .alreadyShuttingDown, .questionBroughtForward: break
            }
        }
        return .terminateLater
    }

    // MARK: Files from Finder

    /// A disk image opened with File Trail from Finder (Open With) or another app opens in a tab, as one opened in File
    /// Trail does. macOS sends it before the windows are open when it launches File Trail to open it: it waits for them.
    /// Other files, folders included, aren't File Trail's to open (as in the original).
    public func application(_ application: NSApplication, open urls: [URL]) {
        let claimed = openFiles.open(urls.filter(\.isFileURL).map(\.path))
        for path in claimed { logger?.info("[filetrail] open file", .context(["path": .string(path)])) }
    }

    /// The window in front takes a disk image. With no window open it is mounted here and its disk opens in a window of
    /// its own; an error is shown on its own, with no window to show it in.
    private func openDiskImageFromOtherApp(_ path: String) {
        guard let diskImages else { return }
        Task { @MainActor in
            await ShellActions.openDiskImage(
                path, shutdownInProgress: quit.shutdownInProgress, host: host,
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

    // MARK: Windows the automation opens

    /// New Window on `url`, from the tab in front; the new window's tab.
    @discardableResult
    func openWindow(at url: URL) -> MainWindowController? {
        explorerWindows.openWindow(at: url)
    }
}
