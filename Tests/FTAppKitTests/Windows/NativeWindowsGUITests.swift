// Ports the flows of apps/desktop/e2e/windows.spec.ts on real windows and native tabs, in process
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// Puts windows on screen: only with FILETRAIL_GUI_TESTS=1, under the GUI lock.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct NativeWindowsGUITests {
    private struct App {
        let store: AppStateStore
        let quit: QuitCoordinator
        let windows: ExplorerWindows
    }

    /// The app's windows on a state file, as a launch opens them.
    private func launch(_ statePath: String) -> App {
        _ = NSApplication.shared
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
        let folder = try TemporaryDirectory(prefix: "filetrail-windows-gui")
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

    // T-a9d9c6ee F-620 F-673 F-630 F-628 F-629 B-VIEW-178 B-VIEW-179 B-VIEW-162
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

    // F-673 F-674 F-675 B-VIEW-159 B-VIEW-161 B-VIEW-163
    @Test func closesAndReopensTabsAndStepsThroughThem() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true })
        first.perform(.newTab)
        let group = try #require(first.group)
        #expect(await waitUntil { group.tabs.count == 2 })
        group.tabs[1].go(to: folder.appending("Sub"))
        #expect(await waitUntil { group.tabs[1].folder.lastPathComponent == "Sub" })

        group.tabs[1].perform(.selectNextTab)
        #expect(await waitUntil { group.selected === first })
        first.perform(.selectPreviousTab)
        #expect(await waitUntil { group.selected === group.tabs[1] })

        // ⌘W on the tab on screen: the one on its left takes over, as it was last.
        group.tabs[1].perform(.closeTab)
        #expect(await waitUntil { group.tabs.count == 1 && group.selected === first })
        #expect(group.session.closedTabs.map(\.currentPath) == [folder.appending("Sub").path])

        // ⇧⌘T brings it back, at its folder, after the tab on screen.
        first.perform(.reopenClosedTab)
        #expect(await waitUntil { group.tabs.count == 2 })
        #expect(group.tabs[1].folder.path == folder.appending("Sub").path)
        #expect(group.selected === group.tabs[1])

        await closeAll(app)
    }

    // T-959a0c89 F-615 F-616 F-621 F-607 F-622 F-611 B-VIEW-176
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

    // F-675 B-VIEW-158 B-TREE-183 B-VIEW-155 T-ed89ad6e T-c5b59b87
    @Test func duplicatesATabWithItsHistoryRightAfterItAndInFrontButNoTabPastTheLimit() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        var notices: [WindowNotice] = []
        app.windows.showNotice = { notice, _ in notices.append(notice) }
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        first.go(to: folder.appending("Sub"))
        #expect(await waitUntil { first.folder.lastPathComponent == "Sub" })
        first.perform(.newTab)
        let group = try #require(first.group)
        #expect(await waitUntil { group.tabs.count == 2 })
        group.select(first)
        #expect(await waitUntil { group.selected === first })

        // File › Duplicate Tab, from the menu, to the tab in front.
        let menu = menuBar(app)
        defer { NSApp.mainMenu = nil }
        menu.router.focusedWindow = { first.window }
        menu.router.choose(itemID: RendererCommand.duplicateTab.rawValue)
        #expect(await waitUntil { group.tabs.count == 3 })
        let copy = group.tabs[1]
        #expect(copy !== first)
        #expect(group.selected === copy)
        #expect(await waitUntil { copy.folder.path == folder.appending("Sub").path })
        #expect(copy.snapshot.historyPaths == [folder.path, folder.appending("Sub").path])
        #expect(copy.snapshot.historyIndex == 1)
        #expect(copy.treeRootPath == first.treeRootPath)
        #expect(copy.viewMode == first.viewMode)

        // No copy past the limit; a notice says why.
        group.addTabs(Array(repeating: first.openTab, count: 120))
        #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)
        copy.perform(.duplicateTab)
        #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)
        #expect(notices == [.tabLimit])
        await closeAll(app)
    }

    /// The Window menu's entry for `window`.
    private func windowsMenuTitle(of window: NSWindow?) -> String? {
        NSApp.windowsMenu?.items.first { $0.target as? NSWindow === window }?.title
    }

    // F-652 T-40d16427
    @Test func namesEachWindowInTheWindowMenuAfterItsTabsLabelAndTheToolbarAfterItsFolder() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let other = try TemporaryDirectory(prefix: "filetrail-windows-gui-other")
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
        // The toolbar keeps the folder's own name, as the original's toolbar does.
        #expect(second.window?.title == "Sub")

        // Bringing the other tab to the front leaves the names as they are.
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        #expect(windowsMenuTitle(of: first.window) == firstLabel)
        #expect(windowsMenuTitle(of: second.window) == secondLabel)
        await closeAll(app)
    }

    #if DEBUG
        // F-593
        @Test func automationStepsActOnTheTabInFrontAfterTheTabsChange() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder.appending("app-state.json").path)
            app.windows.openStartupWindows(folder: folder.path)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.window?.isVisible == true })
            let windows = app.windows
            let runner = AutomationRunner(
                options: .init(scenario: folder.appending("none.json"), out: folder.url, elements: nil)
            ) { windows.front as? MainWindowController }
            first.perform(.newTab)
            let group = try #require(first.group)
            #expect(await waitUntil { group.tabs.count == 2 && group.selected === group.tabs[1] })
            runner.current = group.tabs[1].window

            // Show Previous Tab, sent by the menu or a key, puts the tab `current` was on behind.
            group.tabs[1].perform(.selectPreviousTab)
            #expect(await waitUntil { group.selected === first })
            #expect(runner.currentWindow === first.window)
            #expect(runner.currentController === first)
            await closeAll(app)
        }
    #endif

    // F-672 B-VIEW-155
    @Test func opensNoMoreThanAHundredTabsAndSaysSo() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        var notices: [WindowNotice] = []
        app.windows.showNotice = { notice, _ in notices.append(notice) }
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true })
        let group = try #require(first.group)
        group.addTabs(Array(repeating: first.openTab, count: 120))
        #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)

        first.perform(.newTab)

        #expect(group.tabs.count == AppPreferenceLimits.openTabsLimit)
        #expect(notices == [.tabLimit])
        #expect(WindowNotice.tabLimit.title == "A window can have up to 100 tabs")
        await closeAll(app)
    }

    // MARK: e2e windows.spec.ts

    /// The menu bar of the app on `app`'s windows, wired as the app delegate wires it.
    private func menuBar(_ app: App) -> MainMenu {
        let menu = MainMenu(windows: app.windows)
        menu.connect(
            openWindowFor: { command in
                app.windows.openDefaultWindow(initialCommand: command == .newWindow ? nil : command)
            },
            openNewWindowFromFront: { app.windows.openNewWindowFromFront() })
        menu.build()
        app.windows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
        app.windows.onMenuState = { [weak menu] windowID, state in menu?.sync.setWindowState(windowID: windowID, state)
        }
        return menu
    }

    // T-f5fc5b34 F-620 F-615 F-622 B-VIEW-177
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

    // Not ported yet: windows.spec.ts "pastes in one window what was copied in another" (T-317cfcc8, B-VIEW-184).
    // A window copies no file (Copy and Paste reach only text fields; Copy, Cut and the clipboard button are P5-08's)
    // and nothing pastes one (a paste is a write operation, P3-05's). The app-wide clipboard the windows will share
    // is `ExplorerWindows.clipboard`; the flow is ported with P5-08, on these windows.

    // T-90c6b35c F-622 F-623 F-619
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

        // A place in the Go menu opens a window there. Applications rather than the original's Desktop, whose
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

    // MARK: Tabs that follow the disk

    // F-676 B-VIEW-172
    @Test func tabsFollowAFolderRenamedOrMovedByAnyWindow() async throws {
        let folder = try folders()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.appending("Sub/Deep"), withIntermediateDirectories: false)
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        first.perform(.newTab)
        let group = try #require(first.group)
        #expect(await waitUntil { group.tabs.count == 2 })
        let deep = group.tabs[1]
        deep.go(to: folder.appending("Sub"))
        #expect(await waitUntil { deep.folder.lastPathComponent == "Sub" })
        deep.go(to: folder.appending("Sub/Deep"))
        #expect(await waitUntil { deep.folder.lastPathComponent == "Deep" })
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        // Another window, on the folder that moves.
        group.openNewWindow(from: first, path: folder.appending("Sub").path)
        #expect(await waitUntil { groupCount(app) == 2 && frontTab(app)?.loaded == true })
        let other = try #require(frontTab(app))
        #expect(await waitUntil { other.folder.lastPathComponent == "Sub" })

        try FileManager.default.moveItem(at: folder.appending("Sub"), to: folder.appending("Moved"))
        // Every window hears the operation's progress, as the original's `onWriteOperationProgress`: nothing moves
        // while it runs, and the tabs follow it once it has finished.
        let rename = WriteOperationOutcome(
            action: "rename", mode: nil,
            items: [
                WriteEffectItem(
                    sourcePath: folder.appending("Sub").path, destinationPath: folder.appending("Moved").path)
            ])
        app.windows.writeOperationProgress(WriteOperationProgress(status: "running", result: rename))
        #expect(deep.folder.path == folder.appending("Sub/Deep").path)
        app.windows.writeOperationProgress(WriteOperationProgress(status: "completed", result: rename))

        // The tab in the background goes along, history and all, and reads its folder when it is shown.
        #expect(deep.folder.path == folder.appending("Moved/Deep").path)
        #expect(
            deep.snapshot.historyPaths == [
                folder.path, folder.appending("Moved").path, folder.appending("Moved/Deep").path,
            ])
        #expect(deep.stale)
        // A tab elsewhere stays.
        #expect(first.folder.path == folder.path)
        // The other window's tab on screen reads the folder at its new place.
        #expect(await waitUntil { other.folder.path == folder.appending("Moved").path })
        #expect(await waitUntil { other.window?.title == "Moved" })

        group.select(deep)
        #expect(await waitUntil { !deep.stale && group.selected === deep })
        #expect(await waitUntil { deep.window?.title == "Deep" })
        await closeAll(app)
    }

    /// A folder of `folder` that the windows take for a disk of its own.
    private func fakeDisk(_ app: App, _ folder: TemporaryDirectory) throws -> String {
        let disk = folder.appending("Disk")
        try FileManager.default.createDirectory(at: folder.appending("Disk/Inner"), withIntermediateDirectories: true)
        let diskPath = disk.path
        app.windows.home = folder.path
        app.windows.volumeRoot = { path in
            path == diskPath || path.hasPrefix(diskPath + "/") ? diskPath : ExplorerTabs.volumeRootPath(path)
        }
        return diskPath
    }

    // F-676 B-VIEW-173 B-VIEW-162
    @Test func tabsOnAnUnmountedDiskCloseAndAWindowAllOnItCloses() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        let disk = try fakeDisk(app, folder)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        let group = try #require(first.group)
        group.openTab(path: disk, from: first)
        #expect(await waitUntil { group.tabs.count == 2 })
        group.openTab(path: disk + "/Inner", from: group.tabs[1])
        #expect(await waitUntil { group.tabs.count == 3 && group.selected === group.tabs[2] })
        group.openNewWindow(from: first, path: disk)
        #expect(await waitUntil { groupCount(app) == 2 })

        app.windows.disksUnmounted([disk])

        // The window all on the disk closes; in the other the tabs on it close, and Reopen doesn't offer them.
        #expect(await waitUntil { groupCount(app) == 1 && group.tabs.count == 1 })
        #expect(group.tabs.first === first)
        #expect(await waitUntil { group.selected === first })
        #expect(group.session.closedTabs.isEmpty)
        // Another disk's going leaves the window as it is.
        app.windows.disksUnmounted(["/Volumes/FileTrailNoSuchDisk"])
        #expect(group.tabs.count == 1)
        await closeAll(app)
    }

    // F-676 B-VIEW-173 B-VIEW-154 B-VIEW-180 B-NAV-189
    @Test func tabsOnAnUnmountedDiskGoHomeWhileASheetIsOpen() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        let disk = try fakeDisk(app, folder)
        app.windows.openStartupWindows(folder: disk)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        let group = try #require(first.group)
        first.perform(.newTab)
        #expect(await waitUntil { group.tabs.count == 2 })
        let background = group.tabs[1]
        background.go(to: URL(fileURLWithPath: disk + "/Inner"))
        #expect(await waitUntil { background.folder.lastPathComponent == "Inner" })
        group.select(first)
        #expect(await waitUntil { group.selected === first })
        let window = try #require(first.window)
        let alert = NSAlert()
        alert.messageText = "Busy"
        alert.beginSheetModal(for: window, completionHandler: nil)
        #expect(await waitUntil { window.attachedSheet != nil })

        // While the sheet is open the tabs don't change, and Merge All Windows hears the window is busy.
        first.perform(.newTab)
        first.perform(.selectNextTab)
        first.perform(.closeTab)
        await settle()
        #expect(group.tabs.count == 2)
        #expect(group.selected === first)
        #expect(group.mergeAnswer.busy)
        #expect(group.mergeAnswer.tabs.map(\.path) == [disk, disk + "/Inner"])

        app.windows.disksUnmounted([disk])

        // The tabs stay; the one in the background goes Home, dropping what of its history was on the disk, and the
        // one on screen opens Home.
        #expect(group.tabs.count == 2)
        #expect(background.folder.path == folder.path)
        #expect(background.snapshot.historyPaths == [folder.path])
        #expect(background.treeRootPath == folder.path)
        #expect(await waitUntil { first.folder.path == folder.path })
        #expect(first.snapshot.historyPaths == [disk, folder.path])
        window.endSheet(alert.window)
        #expect(await waitUntil { window.attachedSheet == nil })
        await closeAll(app)
    }

    // MARK: The tab bar

    // The rules of the original's own tab strip that the system tab bar takes over (DEVIATIONS D-001 to D-003):
    // N/A B-VIEW-145 the system tab bar owns clicks, keys and focus on tabs; middle-click is not available (D-002)
    // N/A B-VIEW-147 the system tab bar keeps the tab in front in view
    // N/A B-VIEW-148 the system tab bar owns tab drags (D-013)
    // N/A B-VIEW-150 no tab menu of the app's on the system tab bar; Duplicate Tab is in the File menu (D-001)
    // N/A B-VIEW-151 no tab menu of the app's on the system tab bar (D-001)
    // N/A B-VIEW-152 the system tab bar takes no file drags (D-003)
    // N/A B-VIEW-153 the system tab bar takes no file drops and has no spring-loaded tabs (D-003)

    // F-673 B-VIEW-142 B-VIEW-146 B-VIEW-156 B-VIEW-157
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

    // F-615 B-VIEW-149
    @Test func savesTheTabsInTheOrderOfTheTabBar() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let app = launch(folder.appending("app-state.json").path)
        app.windows.openStartupWindows(folder: folder.path)
        let first = try #require(frontTab(app))
        #expect(await waitUntil { first.window?.isVisible == true && first.loaded })
        let group = try #require(first.group)
        group.openTab(path: folder.appending("Sub").path, from: first)
        #expect(await waitUntil { group.tabs.count == 2 })

        // The system tab bar has the tabs in another order (a tab dragged along it).
        group.replaceTabs(group.tabs.reversed())
        #expect(
            app.store.windowPreferences(group.recordID).openTabs.map(\.path) == [
                folder.appending("Sub").path, folder.path,
            ])
        await closeAll(app)
    }

    // F-616 B-VIEW-175 B-NAV-187 B-NAV-188
    @Test func restoredTabsWaitUnreadUntilShownAndOnesWhoseFolderIsGoneAreDropped() async throws {
        let folder = try folders()
        defer { folder.remove() }
        let statePath = folder.appending("app-state.json").path
        let app = launch(statePath)
        add(
            app.store,
            storedWindow(
                app.store, "window-1",
                [folder.path, folder.appending("Gone").path, folder.appending("Sub").path]))
        app.windows.openStartupWindows(folder: nil)
        #expect(await waitUntil { frontTab(app)?.loaded == true })
        let front = try #require(frontTab(app))
        let group = try #require(front.group)
        #expect(group.tabs.map(\.folder.path) == [folder.path, folder.appending("Sub").path])
        #expect(front.folder.path == folder.path)
        let waiting = group.tabs[1]
        #expect(!waiting.loaded)
        group.select(waiting)
        #expect(await waitUntil { waiting.loaded && waiting.window?.title == "Sub" })
        await closeAll(app)
    }
}
