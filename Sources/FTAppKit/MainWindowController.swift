import AppKit

struct NavigationTiming: Sendable {
    let folder: URL
    let itemCount: Int
    /// Reading the folder from disk, off the main thread.
    let read: Duration
    /// `read` plus the wait for the main thread to take the result.
    let load: Duration
    /// Sorting, reloading the view and drawing it once.
    let display: Duration
}

extension NSToolbarItem.Identifier {
    static let navigation = Self("navigation")
    static let viewMode = Self("viewMode")
    static let search = Self("search")
}

/// One browser window (or tab): sidebar, toolbar, current folder and its history.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation
{
    enum HistoryMove {
        case push, back, forward, none
    }

    static let logsTimings = ProcessInfo.processInfo.environment["FILETRAIL_TIMING"] != nil

    private(set) var folder: URL
    var onClose: (() -> Void)?
    /// Called once, after the first folder has been drawn (used by the launch benchmark).
    var onFirstDraw: (() -> Void)?

    private let sidebar = SidebarViewController()
    private let browser = BrowserViewController()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var navigationToken = 0

    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var viewModeItem: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?

    init(folder: URL) {
        self.folder = folder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "FileTrailBrowser"
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: browser))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 620))
        window.center()

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar

        sidebar.onSelect = { [weak self] url in self?.go(to: url) }
        browser.onOpen = { [weak self] items in self?.open(items) }
        go(to: folder, history: .none)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Navigation

    func go(to url: URL, history: HistoryMove = .push) {
        Task { await navigate(to: url, history: history) }
    }

    /// Reads `url` off the main thread, then shows it. Returns nil when a later
    /// navigation replaced this one or the folder couldn't be read.
    @discardableResult
    func navigate(to url: URL, history: HistoryMove = .push) async -> NavigationTiming? {
        navigationToken += 1
        let token = navigationToken
        let clock = ContinuousClock()
        let started = clock.now
        let (result, read) = await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let started = clock.now
            let result = Result { try FolderLoader.load(url) }
            return (result, clock.now - started)
        }.value
        guard token == navigationToken else { return nil }
        let loaded = clock.now

        let listing: FolderListing
        switch result {
        case .success(let value):
            listing = value
        case .failure(let error):
            if let window { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
            sidebar.select(folder)
            return nil
        }

        let previous = folder
        switch history {
        case .push:
            if url.comparablePath != previous.comparablePath {
                backStack.append(previous)
                forwardStack.removeAll()
            }
        case .back:
            backStack.removeLast()
            forwardStack.append(previous)
        case .forward:
            forwardStack.removeLast()
            backStack.append(previous)
        case .none:
            break
        }
        folder = url

        // Coming back up to a parent selects the folder you came from, as Finder does.
        let cameFromChild = previous.deletingLastPathComponent().comparablePath == url.comparablePath
        window?.title = FileManager.default.displayName(atPath: url.path)
        window?.representedURL = url
        searchItem?.searchField.stringValue = ""
        browser.show(listing, selecting: cameFromChild ? [previous] : [])
        sidebar.select(url)
        updateNavigationItems()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if let callback = onFirstDraw {
            onFirstDraw = nil
            callback()
        }
        Task {
            let capacity = await Task.detached(priority: .utility) {
                FolderLoader.availableCapacity(at: url)
            }.value
            if token == navigationToken { browser.setAvailableCapacity(capacity) }
        }

        let timing = NavigationTiming(
            folder: url, itemCount: listing.items.count, read: read, load: loaded - started,
            display: clock.now - loaded)
        if Self.logsTimings {
            FileHandle.standardError.write(
                Data(
                    String(
                        format: "navigate %@ (%d items): load %.1f ms, display %.1f ms\n",
                        url.path, timing.itemCount, timing.load.milliseconds,
                        timing.display.milliseconds
                    ).utf8))
        }
        return timing
    }

    private func open(_ items: [FileItem]) {
        if items.count == 1, let target = FolderLoader.folderTarget(of: items[0]) {
            go(to: target)
            return
        }
        for item in items {
            if let target = FolderLoader.folderTarget(of: item) {
                (NSApp.delegate as? AppDelegate)?.openTab(at: target, nextTo: self)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private func updateNavigationItems() {
        backItem?.isEnabled = !backStack.isEmpty
        forwardItem?.isEnabled = !forwardStack.isEmpty
        viewModeItem?.selectedIndex = browser.mode.rawValue
    }

    // MARK: Actions

    @objc func goBack(_ sender: Any?) {
        guard let target = backStack.last else { return }
        go(to: target, history: .back)
    }

    @objc func goForward(_ sender: Any?) {
        guard let target = forwardStack.last else { return }
        go(to: target, history: .forward)
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        guard folder.comparablePath != "/" else { return }
        go(to: folder.deletingLastPathComponent())
    }

    @objc func goToPlace(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        go(to: url)
    }

    @objc func openSelection(_ sender: Any?) {
        open(browser.selectedItems)
    }

    @objc func showAsIcons(_ sender: Any?) { setMode(.icons) }

    @objc func showAsList(_ sender: Any?) { setMode(.list) }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        setMode(BrowserViewController.Mode(rawValue: sender.selectedIndex) ?? .list)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        browser.setFilter(sender.stringValue)
    }

    override func newWindowForTab(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openTab(at: folder, nextTo: self)
    }

    private func setMode(_ mode: BrowserViewController.Mode) {
        browser.setMode(mode)
        updateNavigationItems()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goToEnclosingFolder(_:)): return folder.comparablePath != "/"
        case #selector(openSelection(_:)): return !browser.selectedItems.isEmpty
        case #selector(showAsIcons(_:)):
            menuItem.state = browser.mode == .icons ? .on : .off
            return true
        case #selector(showAsList(_:)):
            menuItem.state = browser.mode == .list ? .on : .off
            return true
        default: return true
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .navigation, .flexibleSpace, .viewMode, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .toggleSidebar]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .navigation:
            let back = makeButton("back", label: "Back", symbol: "chevron.left", action: #selector(goBack(_:)))
            let forward = makeButton(
                "forward", label: "Forward", symbol: "chevron.right", action: #selector(goForward(_:)))
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.subitems = [back, forward]
            group.label = "Back/Forward"
            group.isNavigational = true
            backItem = back
            forwardItem = forward
            updateNavigationItems()
            return group
        case .viewMode:
            let images = ["square.grid.2x2", "list.bullet"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
                labels: ["Icons", "List"], target: self, action: #selector(viewModeChanged(_:)))
            group.label = "View"
            group.selectedIndex = browser.mode.rawValue
            viewModeItem = group
            return group
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func makeButton(_ id: String, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(id))
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        item.autovalidates = false
        return item
    }
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
