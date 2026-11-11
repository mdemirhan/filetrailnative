import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct NativeWindowsTests {
        private struct App {
            let store: AppStateStore
            let quit: QuitCoordinator
            let windows: ExplorerWindows
        }

        /// The app's windows on a state file, as a launch opens them, none of them shown.
        private func launch(_ folder: TemporaryDirectory) -> App {
            _ = NSApplication.shared
            let store = AppStateStore(
                filePath: folder.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
            let quit = QuitCoordinator()
            let windows = ExplorerWindows(store: store, quit: quit)
            windows.presentsWindows = false
            windows.home = folder.path
            return App(store: store, quit: quit, windows: windows)
        }

        private func folders() throws -> TemporaryDirectory {
            let folder = try TemporaryDirectory.shallow(prefix: "filetrail-windows")
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

        /// The menu bar of the app on `app`'s windows, wired as the app delegate wires it.
        private func menuBar(_ app: App) -> MainMenu {
            let menu = MainMenu(windows: app.windows)
            menu.connect(
                openWindowFor: { command in app.windows.openDefaultWindow(initialCommand: command) },
                openNewWindowFromFront: { app.windows.openNewWindowFromFront() })
            menu.build()
            app.windows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
            app.windows.onMenuState = { [weak menu] windowID, state in
                menu?.sync.setWindowState(windowID: windowID, state)
            }
            return menu
        }

        @Test func closesAndReopensTabsAndStepsThroughThem() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
            app.windows.openStartupWindows(folder: folder.path)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.loaded })
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

        @Test func duplicatesATabWithItsHistoryRightAfterItAndInFrontButNoTabPastTheLimit() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
            var notices: [WindowNotice] = []
            app.windows.showNotice = { notice, _ in notices.append(notice) }
            app.windows.openStartupWindows(folder: folder.path)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.loaded })
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

        @Test func tabsFollowAFolderRenamedOrMovedByAnyWindow() async throws {
            let folder = try folders()
            defer { folder.remove() }
            try FileManager.default.createDirectory(
                at: folder.appending("Sub/Deep"), withIntermediateDirectories: false)
            let app = launch(folder)
            app.windows.openStartupWindows(folder: folder.path)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.loaded })
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
            // Every window hears the operation's progress: nothing moves while it runs, and the tabs follow it once it
            // has finished.
            let rename = WriteOperationOutcome(
                action: .rename, mode: nil,
                items: [
                    WriteEffectItem(
                        sourcePath: folder.appending("Sub").path, destinationPath: folder.appending("Moved").path)
                ])
            app.windows.writeOperationProgress(WriteOperationProgress(status: .running, result: rename))
            #expect(deep.folder.path == folder.appending("Sub/Deep").path)
            app.windows.writeOperationProgress(WriteOperationProgress(status: .completed, result: rename))

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
            try FileManager.default.createDirectory(
                at: folder.appending("Disk/Inner"), withIntermediateDirectories: true)
            let diskPath = disk.path
            app.windows.home = folder.path
            app.windows.volumeRoot = { path in
                path == diskPath || path.hasPrefix(diskPath + "/") ? diskPath : ExplorerTabs.volumeRootPath(path)
            }
            return diskPath
        }

        @Test func tabsOnAnUnmountedDiskCloseAndAWindowAllOnItCloses() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
            let disk = try fakeDisk(app, folder)
            app.windows.openStartupWindows(folder: folder.path)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.loaded })
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

        @Test func anUnmountedDisksItemsComeOffTheClipboard() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
            let disk = try fakeDisk(app, folder)
            let clipboard = app.windows.clipboard
            let home = folder.appending("note.txt").path
            let copied = ClipboardRules.set(.copy, [disk + "/Inner", disk + "/Inner/a.txt", home], capturedAt: "t")
            clipboard.set(copied, from: nil)

            // Another disk's going leaves it as it is, even one whose name starts the same.
            app.windows.disksUnmounted(["/Volumes/FileTrailNoSuchDisk", disk + "2"])
            #expect(clipboard.contents == copied)

            // Only what was on the disk goes, and the rest is still the same copy.
            app.windows.disksUnmounted([disk])
            #expect(clipboard.contents.sourcePaths == [home])
            #expect(clipboard.contents.capturedAt == "t")

            // Nothing left of it empties the clipboard; a cut of anything on the disk is cancelled.
            clipboard.set(ClipboardRules.set(.copy, [disk + "/a.txt"], capturedAt: "u"), from: nil)
            app.windows.disksUnmounted([disk])
            #expect(clipboard.contents == .empty)
            clipboard.set(ClipboardRules.set(.cut, [disk + "/a.txt", home], capturedAt: "v"), from: nil)
            app.windows.disksUnmounted([disk])
            #expect(clipboard.contents == .empty)
        }

        @Test func tabsOnAnUnmountedDiskGoHomeWhileASheetIsOpen() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
            let disk = try fakeDisk(app, folder)
            app.windows.openStartupWindows(folder: disk)
            let first = try #require(frontTab(app))
            #expect(await waitUntil { first.loaded })
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

        @Test func restoredTabsWaitUnreadUntilShownAndOnesWhoseFolderIsGoneAreDropped() async throws {
            let folder = try folders()
            defer { folder.remove() }
            let app = launch(folder)
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
}
