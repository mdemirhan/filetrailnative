// A window kept maximized is zoomed while still hidden, before its folder is laid out, and keeps its normal frame
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct MaximizedLaunchTests {
        /// The app's windows on a state file holding one window kept with `bounds`, as a launch opens them, never shown.
        private func launch(_ folder: TemporaryDirectory, bounds: StoredWindowState) -> NativeApp {
            _ = NSApplication.shared
            TestServices.install()
            let store = AppStateStore(
                filePath: folder.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
            store.addExplorerWindow(id: "window-kept", bounds: bounds)
            let quit = QuitCoordinator()
            let windows = ExplorerWindows(store: store, quit: quit)
            windows.presentsWindows = false
            windows.home = folder.path
            let app = NativeApp(store: store, quit: quit, windows: windows)
            windows.openStartupWindows(folder: folder.path)
            return app
        }

        @Test func aWindowKeptMaximizedIsZoomedBeforeItsFolderIsLaidOut() async throws {
            let folder = try NativeApp.folders(prefix: "filetrail-maximized")
            defer { folder.remove() }
            let app = launch(folder, bounds: StoredWindowState(x: 40, y: 60, width: 900, height: 600, maximized: true))
            let tab = try #require(app.frontTab)
            let window = try #require(tab.window)
            // Zoomed as it was made, hidden, before its first read.
            #expect(window.isZoomed)
            #expect(!window.isVisible)
            #expect(window.frame.width > 900 && window.frame.height > 600)
            #expect(tab.group?.isMaximized == true)
            // The size it goes back to when it is no longer maximized.
            let normal = try #require(tab.group?.normalBounds)
            #expect(normal.width == 900 && normal.height == 600)
            // Its folder is read and laid out at the zoomed size.
            #expect(await waitUntil { tab.folderPath == folder.path && tab.workspace.isReady })
            #expect(window.isZoomed)
            #expect(abs(tab.workspace.frame.width - window.contentLayoutRect.width) <= 1)
            // Un-maximize goes back to the normal size.
            window.zoom(nil)
            #expect(!window.isZoomed)
            #expect(window.frame.width == 900 && window.frame.height == 600)
            await app.closeAll()
        }

        // Un-maximize from a tab AppKit didn't zoom itself (one given the zoomed frame as it joined the tab group) goes
        // to the window's normal size, not to a size of AppKit's own.
        @Test func unMaximizeGoesToTheNormalSizeWhereAppKitWouldGoElsewhere() async throws {
            let folder = try NativeApp.folders(prefix: "filetrail-maximized")
            defer { folder.remove() }
            let app = launch(folder, bounds: StoredWindowState(x: 40, y: 60, width: 900, height: 600, maximized: true))
            let tab = try #require(app.frontTab)
            let window = try #require(tab.window)
            #expect(window.isZoomed)
            // What AppKit proposed for a tab it never zoomed, on the owner's Mac.
            let appKitsOwn = NSRect(x: 0, y: 20, width: 1646, height: 1064)
            #expect(!tab.windowShouldZoom(window, toFrame: appKitsOwn))
            #expect(!window.isZoomed)
            #expect(window.frame.width == 900 && window.frame.height == 600)
            // Zooming in, and a proposal that is the normal frame already, are AppKit's own.
            #expect(tab.windowShouldZoom(window, toFrame: window.frame))
            await app.closeAll()
        }

        @Test func aWindowNotKeptMaximizedKeepsItsSize() async throws {
            let folder = try NativeApp.folders(prefix: "filetrail-maximized")
            defer { folder.remove() }
            let app = launch(folder, bounds: StoredWindowState(x: 40, y: 60, width: 900, height: 600, maximized: false))
            let tab = try #require(app.frontTab)
            let window = try #require(tab.window)
            #expect(!window.isZoomed)
            #expect(window.frame.width == 900 && window.frame.height == 600)
            #expect(tab.group?.isMaximized == false)
            await app.closeAll()
        }
    }
}
