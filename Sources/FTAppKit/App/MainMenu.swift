// Port of buildApplicationMenu and the focus wiring of apps/desktop/src/main/main.ts
import AppKit
import FTFoundation

/// The menu bar of the app: builds it from the command table and the shortcuts chosen in Settings, keeps it in step
/// with the explorer window it acts on, and builds it again when Undo or Redo, the shortcuts or the text editor change.
@MainActor
public final class MainMenu {
    let router = MenuCommandRouter()
    private(set) var sync: ApplicationMenuSync!
    private(set) var built: BuiltApplicationMenu?
    private var index: MenuItemIndex?
    private var observers: [any NSObjectProtocol] = []

    /// The keys chosen in Settings → Shortcuts, and the text editor Settings → Files names. Read at every build.
    var shortcuts: () -> ShortcutBindings = { ShortcutCommands.defaultBindings }
    var textEditorName: () -> String? = { nil }

    init(windows: any ExplorerWindowListing) {
        sync = ApplicationMenuSync(
            .init(
                windows: windows, focusedWindow: { NSApp.keyWindow }, menu: { [weak self] in self?.index },
                build: { [weak self] in self?.build() }))
        router.explorerFor = { [weak sync] window in sync?.explorerFor(window) }
        router.isTextEditing = { [weak sync] target in sync?.state(of: target).textEditing ?? false }
        router.onCommandSent = { [weak sync] in sync?.sync() }
    }

    /// The window actions of the menu: About, Settings, Help and the windows the Go menu and New Window open with
    /// none open. P4-03's windows and P4-02's controller plug in here.
    func connect(
        openAbout: (() -> Void)? = nil, openSettings: (() -> Void)? = nil, openHelp: ((HelpTopicID?) -> Void)? = nil,
        openWindowFor: @escaping (RendererCommand) -> Void, openNewWindowFromFront: @escaping () -> Void
    ) {
        router.onOpenAbout = openAbout
        router.onOpenSettings = openSettings
        router.onOpenHelp = openHelp
        // With no window open or on screen, New Window and the Go menu's places open one.
        router.onCommandWithoutExplorerWindow = openWindowFor
        router.onNewWindowFromOtherWindow = openNewWindowFromFront
    }

    /// Builds the menu with the shortcuts and the text editor chosen in Settings and sets it as the menu bar; called
    /// again when they change.
    func build() {
        let result = ApplicationMenuBuilder.build(
            target: router,
            options: ApplicationMenuOptions(
                shortcuts: shortcuts(), textEditorName: textEditorName(), undoLabels: sync.undoLabels()))
        built = result
        index = MenuItemIndex(result, router: router)
        // The enabled flags belong to the old items; the new ones start on.
        router.resetEnabled()
        NSApp.mainMenu = result.menu
        NSApp.servicesMenu = result.servicesMenu
        NSApp.windowsMenu = result.windowsMenu
        NSApp.helpMenu = result.helpMenu
        sync.menuBuilt()
    }

    /// While Settings has the keyboard the explorer's commands do not apply, and its Undo is its text fields'. A
    /// window that loses the keyboard may leave none with it (Settings closed, a window minimized): the menu then acts
    /// on the window in front only while it is on screen.
    func observeFocus() {
        let center = NotificationCenter.default
        func refresh(_ name: Notification.Name, later: Bool) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if later {
                        // The focus has moved on once this notification's turn is over.
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync.refresh() } }
                    } else {
                        self?.sync.refresh()
                    }
                }
            }
        }
        observers = [
            refresh(NSWindow.didBecomeKeyNotification, later: false),
            refresh(NSWindow.didResignKeyNotification, later: true),
            refresh(NSWindow.didMiniaturizeNotification, later: true),
            refresh(NSWindow.didDeminiaturizeNotification, later: true),
        ]
    }
}
