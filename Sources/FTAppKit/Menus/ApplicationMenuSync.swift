// Port of apps/desktop/src/main/applicationMenuSync.ts and applyApplicationMenuItemStates' hosting
import AppKit
import FTFoundation
import FTOperations

/// What the file undo history says Undo and Redo would do.
struct UndoHistoryMenu: Equatable, Sendable {
    var undo: String?
    var redo: String?
    var cantUndo: Bool

    init(undo: String? = nil, redo: String? = nil, cantUndo: Bool = false) {
        self.undo = undo
        self.redo = redo
        self.cantUndo = cantUndo
    }

    /// What the file history's `menu()` says.
    init(_ labels: UndoMenuLabels) {
        self.init(undo: labels.undo, redo: labels.redo, cantUndo: labels.cantUndo)
    }

    /// Posted (on the main thread) each time the file history changes, with what it says now in `userInfo["menu"]`.
    static let changed = Notification.Name("FileTrailUndoHistoryChanged")

    /// Tells every menu what the history says now (`undoHistory.onChange` → `setUndoHistory`).
    @MainActor
    static func post(_ labels: UndoMenuLabels) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["menu": UndoHistoryMenu(labels)])
    }
}

/// A built menu's items by id, for the states to be applied to.
@MainActor
final class MenuItemIndex {
    let built: BuiltApplicationMenu
    private let router: MenuCommandRouter

    init(_ built: BuiltApplicationMenu, router: MenuCommandRouter) {
        self.built = built
        self.router = router
    }

    func item(_ id: String) -> NSMenuItem? { built.itemsByID[id] }

    /// The `ApplicationMenu.ItemControl` of the item with this id.
    nonisolated func control(_ id: String) -> Control? {
        MainActor.assumeIsolated {
            guard let item = built.itemsByID[id] else { return nil }
            return Control(item: item, id: id, router: router, radioIDs: built.radioItemIDs)
        }
    }

    /// One item as `ApplicationMenu.apply` sets it. Everything here runs on the main actor: the menu is only ever
    /// synced from there.
    final class Control: ApplicationMenu.ItemControl, @unchecked Sendable {
        private nonisolated(unsafe) let item: NSMenuItem
        private let router: MenuCommandRouter
        private let id: String
        private let radioIDs: Set<String>
        var isRadio: Bool { radioIDs.contains(id) }

        init(item: NSMenuItem, id: String, router: MenuCommandRouter, radioIDs: Set<String>) {
            self.item = item
            self.id = id
            self.router = router
            self.radioIDs = radioIDs
        }

        var isEnabled: Bool {
            get { MainActor.assumeIsolated { !router.disabledItemIDs.contains(id) } }
            set {
                MainActor.assumeIsolated {
                    router.setItem(id, enabled: newValue)
                    item.isEnabled = newValue
                }
            }
        }

        var isVisible: Bool {
            get { MainActor.assumeIsolated { !item.isHidden } }
            set { MainActor.assumeIsolated { item.isHidden = !newValue } }
        }

        var isChecked: Bool {
            get { MainActor.assumeIsolated { item.state == .on } }
            set {
                MainActor.assumeIsolated {
                    item.state = newValue ? .on : .off
                    // A radio item switched on switches the others of its group off.
                    guard isRadio, newValue, let siblings = item.menu?.items else { return }
                    for sibling in siblings where sibling !== item {
                        if let siblingID = sibling.identifier?.rawValue, radioIDs.contains(siblingID) {
                            sibling.state = .off
                        }
                    }
                }
            }
        }
    }
}

/// What the application menu shows: the state of the explorer window it acts on (the focused one, the one in front
/// while another window has the keyboard, or with no window focused the one in front while it is on screen), and what
/// Undo and Redo would do. The menu is one for the whole app and is built by the host.
@MainActor
final class ApplicationMenuSync {
    struct Dependencies {
        var windows: any ExplorerWindowListing
        /// The window that has the keyboard, of any kind; nil when the app has none.
        var focusedWindow: () -> NSWindow?
        /// The menu as it is now, or none before it has been built.
        var menu: () -> MenuItemIndex?
        /// Builds the menu again (its labels can't be changed in place), with `undoLabels`.
        var build: () -> Void
        /// Runs `work` once the task that asked for it is done (`setImmediate`).
        var afterCurrentTask: (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    private let dependencies: Dependencies
    /// What each explorer window last said the menu should show, by window id.
    private var states: [Int: ApplicationMenuState] = [:]
    /// What the history says Undo and Redo would do.
    private var undoHistory = UndoHistoryMenu()
    /// The words the menu was last built with.
    private var builtUndoLabels = ""
    /// Whether the menu is to be brought up to date with the history once the task that changed it is done.
    private var undoRefreshQueued = false
    private var historyObserver: (any NSObjectProtocol)?

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        // The file history's labels, as it changes.
        historyObserver = NotificationCenter.default.addObserver(
            forName: UndoHistoryMenu.changed, object: nil, queue: .main
        ) { [weak self] notification in
            guard let menu = notification.userInfo?["menu"] as? UndoHistoryMenu else { return }
            MainActor.assumeIsolated { self?.setUndoHistory(menu) }
        }
    }

    isolated deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    /// What an explorer window says the menu should show; other windows are not heard.
    func setWindowState(windowID: Int?, _ state: ApplicationMenuState) {
        guard let windowID, dependencies.windows.handle(windowID: windowID) != nil, states[windowID] != state else {
            return
        }
        states[windowID] = state
        refresh()
    }

    /// The menu is about to be used: what the window it acts on can do now, whatever has changed without saying so
    /// (a dialog, a sheet). Only what is on and off changes: a menu being opened can't be built again.
    func readWindowState() {
        let focused = dependencies.focusedWindow()
        guard let entry = focused.flatMap({ dependencies.windows.handle(for: $0) }) ?? dependencies.windows.front,
            let state = entry.currentMenuState, states[entry.windowID] != state
        else { return }
        states[entry.windowID] = state
        sync()
    }

    /// The state an explorer window last reported (`INITIAL` before it has).
    func state(of target: ExplorerCommandTarget) -> ApplicationMenuState {
        states[target.handle.windowID] ?? .initial
    }

    /// A window opened or closed: what a closed one said is let go of. With the last one closed, Undo and Redo are no
    /// longer the files' and stop naming what they would do.
    func windowsChanged() {
        for windowID in Array(states.keys) where dependencies.windows.handle(windowID: windowID) == nil {
            states[windowID] = nil
        }
        refresh()
    }

    /// The history changes as an operation ends, just before its window is told: the menu, which can take a while to
    /// build, is brought up to date after that, once for all the changes made in the meantime.
    func setUndoHistory(_ history: UndoHistoryMenu) {
        undoHistory = history
        guard !undoRefreshQueued else { return }
        undoRefreshQueued = true
        dependencies.afterCurrentTask { [weak self] in
            self?.undoRefreshQueued = false
            self?.refresh()
        }
    }

    /// What the files' Undo and Redo say, for the menu being built. While a text field has the keyboard the menu shows
    /// its own Undo and Redo instead, so these words don't change.
    func undoLabels() -> (undo: String, redo: String) {
        ApplicationMenu.undoLabels(
            undo: undoHistory.undo, redo: undoHistory.redo, cantUndo: undoHistory.cantUndo, textEditing: false)
    }

    private func undoLabelKey() -> String {
        let labels = undoLabels()
        return "\(labels.undo)\u{0}\(labels.redo)"
    }

    /// Called once the host has built and set the menu.
    func menuBuilt() {
        builtUndoLabels = undoLabelKey()
        sync()
    }

    /// The explorer window a menu command goes to: the focused window when it is one, else the one in front while
    /// Settings has the keyboard. With no window focused (every window minimized, say) it is the one in front only
    /// while it is on screen: a command must not act unseen on a minimized window's selection.
    func explorerFor(_ focusedWindow: NSWindow?) -> ExplorerCommandTarget? {
        if let focusedWindow, let entry = dependencies.windows.handle(for: focusedWindow) {
            return ExplorerCommandTarget(handle: entry, focused: true)
        }
        guard let front = dependencies.windows.front else { return nil }
        if focusedWindow == nil, !front.isOnScreen { return nil }
        return ExplorerCommandTarget(handle: front, focused: focusedWindow == nil)
    }

    /// A menu item's label can't be changed in place: the menu is built again when Undo or Redo should say something
    /// else. Otherwise only what is on and off changes.
    func refresh() {
        guard dependencies.menu() != nil else { return }
        if undoLabelKey() != builtUndoLabels {
            dependencies.build()
            return
        }
        sync()
    }

    /// Dims, checks and shows the menu's items for the state the explorer window the menu acts on last reported.
    func sync() {
        guard let menu = dependencies.menu() else { return }
        let current = currentExplorer()
        let facts = ApplicationMenu.WindowFacts(
            explorerFocused: current.explorerFocused, explorerWindowCount: dependencies.windows.count,
            otherWindowFocused: current.otherWindowFocused,
            undoAvailable: (undo: undoHistory.undo != nil, redo: undoHistory.redo != nil))
        ApplicationMenu.apply(ApplicationMenu.itemStates(current.state, window: facts)) { menu.control($0) }
    }

    /// The explorer window the menu shows, and whether it has the keyboard. With no window focused (the app is in the
    /// background) the front window's state stays while it is on screen; with every explorer window minimized or none
    /// open there is none to act on.
    private func currentExplorer() -> (state: ApplicationMenuState, explorerFocused: Bool, otherWindowFocused: Bool) {
        let focused = dependencies.focusedWindow()
        let focusedEntry = focused.flatMap { dependencies.windows.handle(for: $0) }
        let front = dependencies.windows.front
        let entry = focusedEntry ?? front
        let frontOnScreen = front?.isOnScreen ?? false
        return (
            entry.flatMap { states[$0.windowID] } ?? .initial,
            focusedEntry != nil || (focused == nil && frontOnScreen),
            focused != nil && focusedEntry == nil
        )
    }
}
