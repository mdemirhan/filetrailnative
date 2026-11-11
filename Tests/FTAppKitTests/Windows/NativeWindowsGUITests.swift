import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// Puts windows on screen: only with FILETRAIL_GUI_TESTS=1.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct NativeWindowsGUITests {
    private struct App {
        let store: AppStateStore
        let quit: QuitCoordinator
        let windows: ExplorerWindows
    }

    /// The app's windows on a state file, as a launch opens them.
    private func launch(_ statePath: String) -> App {
        _ = NSApplication.shared
        TestServices.install()
        let store = AppStateStore(filePath: statePath, defaultTheme: .light, timer: HeldStateTimer())
        let quit = QuitCoordinator()
        let windows = ExplorerWindows(store: store, quit: quit)
        quit.hooks.recordAllBounds = { windows.controller.recordAllBounds() }
        quit.hooks.flushStore = { store.flush() }
        quit.hooks.anyWindowOpen = { !windows.allTabs.isEmpty }
        return App(store: store, quit: quit, windows: windows)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func folders() throws -> TemporaryDirectory {
        let folder = try TemporaryDirectory.shallow(prefix: "filetrail-windows-gui")
        try "alpha".write(to: folder.appending("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending("Sub"), withIntermediateDirectories: false)
        try "inside".write(to: folder.appending("Sub/inside.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    private func groupCount(_ app: App) -> Int { app.windows.count }

    private func frontTab(_ app: App) -> MainWindowController? { app.windows.front as? MainWindowController }

    private func closeAll(_ app: App) async {
        for tab in app.windows.allTabs { tab.window?.close() }
        await settle()
    }

    @Test func opensTabsMovesOneToAWindowOfItsOwnAndMergesTheWindowsBack() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true })

        first.perform(.newTab)
        #expect(await waitUntil { first.window?.tabbedWindows?.count == 2 })
        let group = try #require(first.group)
        #expect(group.tabs.count == 2)
        // The new tab is right after the one it came from, in front.
        #expect(group.selected === group.tabs[1])
        group.tabs[1].go(to: folder.appending("Sub"))
        #expect(await waitUntil { group.tabs[1].window?.tab.title == "Sub" })

        // Move Tab to New Window: the tab leaves for a window of its own.
        group.tabs[1].perform(.moveTabToNewWindow)
        #expect(await waitUntil { groupCount(app) == 2 && group.tabs.count == 1 })
        // A tab moved to a window of its own is not offered by Reopen Closed Tab.
        #expect(group.session.closedTabs.isEmpty)
        let moved = try #require(frontTab(app))
        #expect(await waitUntil { moved.window?.isVisible == true && moved.window?.title == "Sub" })
        #expect(moved.group !== group)

        // Merge All Windows: the other window's tabs join this one's, after them, and it closes.
        first.perform(.mergeAllWindows)
        #expect(await waitUntil { groupCount(app) == 1 && group.tabs.count == 2 })
        #expect(group.tabs.map(\.folder.lastPathComponent) == [folder.url.lastPathComponent, "Sub"])
        #expect(first.window?.tabbedWindows?.count == 2)
        // Merged windows weren't closed by hand.
        #expect(app.store.lastClosedWindow() == nil)

        await closeAll(app)
    }

    // While a name is edited a press on a tab does nothing and the field stays. The system's tab bar has no type to
    // ask, so this checks its class names too.
    @Test func theTabBarTakesNoPressWhileANameIsEdited() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        first.perform(.newTab)
        let group = try #require(first.group)
        #expect(await waitUntil { group.tabs.count == 2 })
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        let window = try #require(first.window)
        let frameView = try #require(window.contentView?.superview)
        func tabButton(in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == "NSTabButton" { return view }
            return view.subviews.lazy.compactMap(tabButton(in:)).first
        }
        #expect(await waitUntil { tabButton(in: frameView) != nil })
        let tab = try #require(tabButton(in: frameView))
        let center = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        #expect(ExplorerTabGroup.isTabBarPress(at: center, in: window))
        let press = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!WindowEventRouting.intercept(press, in: window))

        #expect(first.content.beginRename(path: folder.appending("a.txt").path))
        #expect(group.isBlocked)
        #expect(WindowEventRouting.intercept(press, in: window))
        #expect(first.content.inlineRename != nil)

        first.content.renameCancelled()
        #expect(!group.isBlocked)
        #expect(!WindowEventRouting.intercept(press, in: window))

        // `blocked` while a dialog is up.
        first.openLocationSheet()
        #expect(group.holdsTabBar)
        // The Window menu's list goes through the other tab's window.
        group.tabs.last?.window?.makeKeyAndOrderFront(nil)
        #expect(group.selected === first)
        // Under the dialog the scrim's veil lies over the bar and takes the point: a tab is one of the band's controls,
        // so a press on it is a press on the scrim, which closes the Go To box.
        #expect(!ExplorerTabGroup.isTabBarPress(at: center, in: window))
        #expect(DialogScrim.front(in: window)?.titlebarPress(at: center) == .scrim)
        #expect(WindowEventRouting.intercept(press, in: window))
        #expect(first.goToBox == nil)
        #expect(group.selected === first)
        #expect(!WindowEventRouting.intercept(press, in: window))
        await closeAll(app)
    }

    @Test func bringsBackEachWindowsPlaceTabsAndWhichWasInFrontAtTheNextLaunch() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let statePath = folder.appending("app-state.json").path
        let app = launch(statePath)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true })
        first.perform(.newTab)
        #expect(await waitUntil { first.group?.tabs.count == 2 })
        first.group?.select(first)

        // Open in New Window, as on a selected folder; then each window somewhere of its own.
        first.group?.openNewWindow(from: first, path: folder.appending("Sub").path)
        #expect(await waitUntil { groupCount(app) == 2 && frontTab(app)?.window?.isVisible == true })
        let second = try #require(frontTab(app))
        #expect(second.group !== first.group)
        let firstFrame = ScreenGeometry.frame(of: WindowBounds(x: 60, y: 60, width: 1000, height: 700))
        let secondFrame = ScreenGeometry.frame(of: WindowBounds(x: 220, y: 140, width: 900, height: 620))
        second.window?.setFrame(secondFrame, display: true)
        first.window?.setFrame(firstFrame, display: true)
        first.window?.makeKeyAndOrderFront(nil)
        first.group?.events.focus()

        // Quitting keeps the windows.
        #expect(await app.quit.quit() == .exited)
        await closeAll(app)
        #expect(app.store.explorerWindows().count == 2)

        let relaunched = launch(statePath)
        relaunched.windows.openStartupWindows(folder: nil)
        #expect(await waitUntil { groupCount(relaunched) == 2 })
        #expect(await waitUntil { frontTab(relaunched)?.window?.isVisible == true })
        let front = try #require(frontTab(relaunched))
        let frontGroup = try #require(front.group)
        #expect(frontGroup.tabs.count == 2)
        #expect(front.folder.path == folder.path)
        let frame = try #require(front.window?.frame)
        #expect(ScreenGeometry.bounds(of: frame) == WindowBounds(x: 60, y: 60, width: 1000, height: 700))
        let other = try #require(relaunched.windows.allTabs.first { $0.group !== frontGroup })
        #expect(other.folder.lastPathComponent == "Sub")
        let otherFrame = try #require(other.window?.frame)
        #expect(ScreenGeometry.bounds(of: otherFrame) == WindowBounds(x: 220, y: 140, width: 900, height: 620))

        // Closed by hand, the last window is remembered with its front tab only, and the app has none open.
        other.group?.closeAsCloseButton()
        front.group?.closeAsCloseButton()
        await settle()
        #expect(groupCount(relaunched) == 0)
        #expect(relaunched.store.explorerWindows().isEmpty)
        #expect(relaunched.store.lastClosedWindow()?.session.openTabs.map(\.path) == [folder.path])

        // With none open, a window opens where the last one closed (the Dock icon, New Window).
        relaunched.windows.openDefaultWindow(initialCommand: nil)
        #expect(await waitUntil { frontTab(relaunched)?.window?.isVisible == true })
        let reopened = try #require(frontTab(relaunched)?.window?.frame)
        #expect(ScreenGeometry.bounds(of: reopened) == WindowBounds(x: 60, y: 60, width: 1000, height: 700))
        #expect(frontTab(relaunched)?.folder.path == folder.path)
        await closeAll(relaunched)
    }

    /// The Window menu's entry for `window`.
    private func windowsMenuTitle(of window: NSWindow?) -> String? {
        NSApp.windowsMenu?.items.first { $0.target as? NSWindow === window }?.title
    }

    @Test func namesEachWindowInTheWindowMenuAfterItsTabsLabelAndTheToolbarAfterItsFolder() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let other = try TemporaryDirectory.shallow(prefix: "filetrail-windows-gui-other")
        defer { other.remove() }
        try FileManager.default.createDirectory(at: other.appending("Sub"), withIntermediateDirectories: false)
        let app = launch(folder.appending("app-state.json").path)
        let menu = MainMenu(windows: app.windows)
        menu.build()
        defer { NSApp.mainMenu = nil }
        app.windows.openStartupWindows(folder: folder.appending("Sub").path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        #expect(await waitUntil { windowsMenuTitle(of: first.window) == "Sub" })

        first.perform(.newTab)
        let group = try #require(first.group)
        #expect(await waitUntil { group.tabs.count == 2 })
        let second = group.tabs[1]
        second.go(to: other.appending("Sub"))
        #expect(await waitUntil { second.folder.path == other.appending("Sub").path })
        let firstLabel = "Sub — \(folder.url.lastPathComponent)"
        let secondLabel = "Sub — \(other.url.lastPathComponent)"
        #expect(await waitUntil { windowsMenuTitle(of: second.window) == secondLabel })
        #expect(windowsMenuTitle(of: first.window) == firstLabel)
        #expect(second.window?.tab.title == secondLabel)
        // The toolbar keeps the folder's own name.
        #expect(second.window?.title == "Sub")

        // Bringing the other tab to the front leaves the names as they are.
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        #expect(windowsMenuTitle(of: first.window) == firstLabel)
        #expect(windowsMenuTitle(of: second.window) == secondLabel)
        await closeAll(app)
    }

    // MARK: Opening and closing windows

    /// The menu bar of the app on `app`'s windows, wired as the app delegate wires it.
    private func menuBar(_ app: App) -> MainMenu {
        let menu = MainMenu(windows: app.windows)
        menu.connect(
            openWindowFor: { command in app.windows.openDefaultWindow(initialCommand: command) },
            openNewWindowFromFront: { app.windows.openNewWindowFromFront() })
        menu.build()
        app.windows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
        app.windows.onMenuState = { [weak menu] windowID, state in menu?.sync.setWindowState(windowID: windowID, state)
        }
        return menu
    }

    @Test func opensWindowsOnTheFolderOnScreenAndBringsBackThoseOpenAtQuit() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let statePath = folder.appending("app-state.json").path
        let app = launch(statePath)
        let menu = menuBar(app)
        defer { NSApp.mainMenu = nil }
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })

        // File › New Window, from the menu.
        menu.router.focusedWindow = { first.window }
        menu.router.choose(itemID: RendererCommand.newWindow.rawValue)
        #expect(await waitUntil { groupCount(app) == 2 && frontTab(app)?.window?.isVisible == true })
        let second = try #require(frontTab(app))
        #expect(second !== first)
        #expect(await waitUntil { second.loaded && second.folder.path == folder.path })
        let firstFrame = try #require(first.window?.frame)
        let secondFrame = try #require(second.window?.frame)
        // Same size, a step down and to the right of the first.
        #expect(secondFrame.width == firstFrame.width)
        #expect(abs(secondFrame.minX - firstFrame.minX) > 0)

        // Open in New Window, on a selected folder.
        first.group?.openNewWindow(from: first, path: folder.appending("Sub").path)
        #expect(await waitUntil { groupCount(app) == 3 && frontTab(app)?.window?.title == "Sub" })
        let sub = try #require(frontTab(app))
        #expect(
            app.windows.allTabs.map { $0.window?.title ?? "" }.sorted()
                == [
                    folder.url.lastPathComponent, folder.url.lastPathComponent, "Sub",
                ].sorted())

        // Closing a window that isn't the last leaves the others, and it doesn't come back.
        sub.group?.closeAsCloseButton()
        #expect(await waitUntil { groupCount(app) == 2 })

        #expect(await app.quit.quit() == .exited)
        await closeAll(app)
        #expect(app.store.explorerWindows().count == 2)

        let relaunched = launch(statePath)
        relaunched.windows.openStartupWindows(folder: nil)
        #expect(await waitUntil { groupCount(relaunched) == 2 })
        #expect(await waitUntil { relaunched.windows.allTabs.allSatisfy { $0.window?.isVisible == true } })
        #expect(relaunched.windows.allTabs.map(\.folder.path) == [folder.path, folder.path])
        await closeAll(relaunched)
    }

    @Test func staysOpenWithNoWindowAndOpensOneWhereTheLastOneClosed() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let statePath = folder.appending("app-state.json").path
        let app = launch(statePath)
        let menu = menuBar(app)
        defer { NSApp.mainMenu = nil }
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        first.go(to: folder.appending("Sub"))
        #expect(await waitUntil { first.folder.lastPathComponent == "Sub" })

        func closeOnlyWindow() async {
            for tab in app.windows.allTabs { tab.group?.closeAsCloseButton() }
            _ = await waitUntil { groupCount(app) == 0 }
        }
        await closeOnlyWindow()
        #expect(groupCount(app) == 0)
        // Still there, with only what opens a window on offer.
        menu.router.focusedWindow = { nil }
        menu.sync.sync()
        let disabled = menu.router.disabledItemIDs
        #expect(!disabled.contains(RendererCommand.newWindow.rawValue))
        #expect(!disabled.contains(RendererCommand.goApplications.rawValue))
        #expect(disabled.contains(RendererCommand.goBack.rawValue))
        #expect(disabled.contains(RendererCommand.emptyTrash.rawValue))

        // The Dock icon is clicked: a window opens where the last one was.
        ShellActions.activate(hasVisibleWindows: false, shutdownInProgress: false, host: app.windows)
        #expect(await waitUntil { groupCount(app) == 1 && frontTab(app)?.loaded == true })
        #expect(await waitUntil { frontTab(app)?.folder.path == folder.appending("Sub").path })
        await closeOnlyWindow()

        // A place in the Go menu opens a window there. Applications rather than Desktop, whose
        // contents macOS asks the user before showing.
        menu.router.choose(itemID: RendererCommand.goApplications.rawValue)
        #expect(await waitUntil { groupCount(app) == 1 && frontTab(app)?.folder.path == "/Applications" })
        #expect(await waitUntil { frontTab(app)?.window?.title == "Applications" })
        await closeOnlyWindow()
        #expect(await app.quit.quit() == .exited)

        // The next launch opens one window, where the last one was.
        let relaunched = launch(statePath)
        relaunched.windows.openStartupWindows(folder: nil)
        #expect(await waitUntil { groupCount(relaunched) == 1 && frontTab(relaunched)?.loaded == true })
        #expect(await waitUntil { frontTab(relaunched)?.folder.path == "/Applications" })
        await closeAll(relaunched)
    }

    // MARK: The tab bar

    @Test func showsTheTabBarWithMoreThanOneTabAndOpensTabsAfterTheOneOnScreen() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        let group = try #require(first.group)
        first.perform(.viewAsDetails)
        #expect(first.window?.tabGroup?.isTabBarVisible != true)

        // The tab bar's "+" button: a tab on this folder, right after it, with a history of its own and its view.
        first.newWindowForTab(nil)
        #expect(await waitUntil { group.tabs.count == 2 && first.window?.tabGroup?.isTabBarVisible == true })
        let added = group.tabs[1]
        #expect(group.selected === added)
        #expect(added.folder.path == folder.path)
        #expect(added.snapshot.historyPaths == [folder.path])
        #expect(added.viewMode == .details)
        #expect(added.treeRootPath == first.treeRootPath)

        // Open in New Tab: the folder in a tab right after the one on screen, as a visit of its own.
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        group.openTab(path: folder.appending("Sub").path, from: first)
        #expect(await waitUntil { group.tabs.count == 3 })
        let opened = group.tabs[1]
        #expect(opened.folder.path == folder.appending("Sub").path)
        #expect(opened.snapshot.historyPaths == [folder.appending("Sub").path])
        #expect(group.selected === opened)

        // Back to one tab: no tab bar.
        opened.perform(.closeTab)
        #expect(await waitUntil { group.tabs.count == 2 })
        group.selected?.perform(.closeTab)
        #expect(await waitUntil { group.tabs.count == 1 })
        #expect(await waitUntil { group.tabs[0].window?.tabGroup?.isTabBarVisible != true })
        await closeAll(app)
    }

    // Chosen in the system's tab bar, a tab reads its folder again.
    @Test func aTabChosenInTheTabBarReadsItsFolderAgain() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        let group = try #require(first.group)
        group.openTab(path: folder.appending("Sub").path, from: first)
        let other = try #require(group.tabs.last)
        #expect(await waitUntil { other.shownFolderPath == folder.appending("Sub").path && !other.isNavigating })
        try "x".write(to: folder.appending("Made Meanwhile.txt"), atomically: true, encoding: .utf8)
        first.services.directoryService.cache.clear()
        first.window?.tabGroup?.selectedWindow = first.window
        #expect(await waitUntil { first.content.listed.contains { $0.name == "Made Meanwhile.txt" } })
        await closeAll(app)
    }

}
