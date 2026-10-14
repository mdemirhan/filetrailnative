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

    // F-620 F-673 F-630 F-628 F-629 B-VIEW-178 B-VIEW-179
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

    // F-615 F-616 F-621 F-607 F-622 F-611 B-VIEW-176
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

        // Duplicate Tab (the File menu's, which sends `duplicateTab:` to the tab in front).
        first.duplicateTab(nil)
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
        copy.duplicateTab(nil)
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
}
