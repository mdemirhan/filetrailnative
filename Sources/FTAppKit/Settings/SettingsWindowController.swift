// Port of apps/desktop/src/renderer/SettingsWindowApp.tsx and openSettingsWindow in apps/desktop/src/main/main.ts
import AppKit
import FTFoundation

/// The Settings window (720 by 540, at least 680 by 420, not full-screenable): a sidebar of sections and the section on
/// screen. Every edit is saved as it is made and reaches the explorer windows; edits made elsewhere are shown here. Esc
/// closes it, once an open pop-up, the recorder or the search field has had it.
@MainActor
public final class SettingsWindowController: PageWindowController, SettingsPageHost {
    public static let title = "Settings"

    let settingsView: SettingsView
    /// Nil until the preferences are loaded (they failed to load).
    private(set) var loadedStore: SettingsStore?
    private(set) lazy var popovers = SettingsPopovers()
    var services: SettingsServices
    var openColorPicker: ColorPicker = AccentSelector.openColorPanel
    /// Told the tab on screen, so the app can open Settings on it next time.
    public var onTabChange: (SettingsTab) -> Void = { _ in }
    /// While this window writes, the change it is told back is its own.
    private var isWriting = false
    private var monitor: Any?
    private var checkedAppPaths: [String]?
    private var focusObservation: NSKeyValueObservation?

    /// `load` reads the preferences (and throws when it can't); `write` saves a patch, false when it was refused.
    init(
        tab: SettingsTab, load: () throws -> AppPreferences, homePath: String,
        write: @escaping (PreferencesPatch) -> Bool, services: SettingsServices = SettingsServices(),
        model: AppearanceModel = .shared
    ) {
        settingsView = SettingsView(tab: tab, theme: model.theme)
        self.services = services
        super.init(
            spec: PageWindowSpec(
                title: Self.title, size: SettingsMetrics.windowSize, minSize: SettingsMetrics.windowMinSize,
                trafficLights: SettingsMetrics.trafficLights),
            model: model)
        (window as? PageWindow)?.closesOnEscape = true
        window?.contentView = settingsView
        window?.initialFirstResponder = settingsView
        // A section's controls are built when it is chosen, and its lists and rows change: Tab goes through what shows.
        window?.autorecalculatesKeyViewLoop = true
        focusObservation = window?.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                // A number field's keyboard is its editor's.
                let editor = window.firstResponder as? NSTextView
                guard let view = editor?.delegate as? NSView ?? window.firstResponder as? NSView else { return }
                self?.settingsView.reveal(view, for: NSApp.currentEvent?.type)
            }
        }
        window?.setContentSize(SettingsMetrics.windowSize)
        settingsView.onTabChange = { [weak self] tab in
            self?.popovers.close(returnFocus: false)
            self?.onTabChange(tab)
        }
        settingsView.onScroll = { [weak self] in self?.popovers.update() }
        do {
            let preferences = try load()
            let store = SettingsStore(
                preferences: preferences, homePath: homePath,
                write: { [weak self] patch in self?.write(patch, write) ?? false }, schedule: services.schedule)
            store.onChange = { [weak self] in self?.storeChanged() }
            loadedStore = store
            settingsView.makePage = { [weak self] tab in
                guard let self else { return SettingsPageView(tab: tab, host: EmptyPageHost(), theme: model.theme) }
                return SettingsPageView(tab: tab, host: self, theme: self.model.theme)
            }
            settingsView.showPage()
        } catch {
            // Nothing but the sidebar shows.
            settingsView.showNotice(SettingsText.loadFailed)
        }
        themeChanged(model.theme)
        checkMissingApps()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var store: SettingsStore { loadedStore ?? EmptyPageHost.placeholder }
    var pageWindow: NSWindow? { window }

    public var activeTab: SettingsTab { settingsView.activeTab }

    /// A tab asked for while the window is open is switched to.
    public func show(tab: SettingsTab) {
        settingsView.select(tab: tab)
    }

    public override func present() {
        super.present()
        guard monitor == nil else { return }
        // The pop-ups take their keys and presses before the window does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let taken = MainActor.assumeIsolated {
                guard let self, event.window === self.window || event.window === self.popovers.window else {
                    return false
                }
                return self.handle(event)
            }
            return taken ? nil : event
        }
    }

    /// An event on its way to the window: true when an open pop-up took it.
    func handle(_ event: NSEvent) -> Bool {
        popovers.handle(event)
    }

    // MARK: Saving

    private func write(_ patch: PreferencesPatch, _ write: (PreferencesPatch) -> Bool) -> Bool {
        isWriting = true
        defer { isWriting = false }
        return write(patch)
    }

    /// A change of the app's preferences: one made in another window is shown here; this window's own is not.
    public func preferencesChanged(_ change: PreferencesChange) {
        guard !isWriting else { return }
        loadedStore?.remote(change.patch)
    }

    /// Writes what is waiting now (the window closes).
    public func flushPending() {
        loadedStore?.sync.flushPending()
    }

    private func storeChanged() {
        settingsView.page?.refresh()
        settingsView.page?.applyTheme(model.theme, throughSubviews: true)
        settingsView.needsLayout = true
        checkMissingApps()
    }

    func showNotice(_ text: String) {
        settingsView.showNotice(text)
    }

    func pageLayoutChanged() {
        settingsView.needsLayout = true
    }

    // MARK: Pinned apps

    /// Pinned apps that aren't where they were are flagged; checked when the list changes and when the window comes
    /// forward.
    private func checkMissingApps(force: Bool = false) {
        guard let store = loadedStore else { return }
        let paths = store.preferences.openWithApplications.map(\.appPath)
        guard force || paths != checkedAppPaths else { return }
        checkedAppPaths = paths
        guard !paths.isEmpty else {
            store.setMissingApps([])
            return
        }
        let check = services.missingApps
        Task { @MainActor [weak self] in
            let missing = await check(paths)
            guard let self, self.checkedAppPaths == paths else { return }
            self.loadedStore?.setMissingApps(missing)
        }
    }

    // MARK: Window

    public override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        checkMissingApps(force: true)
    }

    public func windowDidResignMain(_ notification: Notification) {
        // A panel closes when the window goes to the back. Not when it only stops being key: a click in the popover does
        // that too.
        popovers.close(returnFocus: false)
    }

    public override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)
        popovers.update()
    }

    public override func windowWillClose(_ notification: Notification) {
        flushPending()
        popovers.close(returnFocus: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.windowWillClose(notification)
    }
}

/// A host for a page built after its window went away; it saves nothing.
@MainActor
private final class EmptyPageHost: SettingsPageHost {
    static let placeholder = SettingsStore(
        preferences: .defaults(), homePath: "", write: { _ in true }, schedule: { _, _ in {} })
    var store: SettingsStore { Self.placeholder }
    lazy var popovers = SettingsPopovers()
    var services = SettingsServices()
    var pageWindow: NSWindow? { nil }
    func showNotice(_ text: String) {}
    func pageLayoutChanged() {}
    var openColorPicker: ColorPicker { { _, _ in } }
}
