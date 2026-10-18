// An explorer window of the app on a temporary folder, for the window suites: on screen for the end-to-end tests,
// or made and read but never shown for the windowless ones
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// A window of the app on a temporary folder, with the app's preference channel over its own state file.
@MainActor
final class ExplorerHarness {
    let folder: TemporaryDirectory
    let store: AppStateStore
    let quit = QuitCoordinator()
    let windows: ExplorerWindows
    let channel: WindowPreferenceChannel
    let services: ExplorerServices
    /// Whether its windows go on screen. Off, the tab groups are never shown: no window is ordered front and the app
    /// isn't activated, while the tabs keep their windows, read their folders and lay out.
    let onScreen: Bool

    init(onScreen: Bool = true) throws {
        _ = NSApplication.shared
        self.onScreen = onScreen
        folder = try TemporaryDirectory(prefix: "filetrail-toolbar-gui")
        for name in ["Alpha", "Beta", "Gamma"] {
            try FileManager.default.createDirectory(
                at: folder.appending("\(name)/Inner"), withIntermediateDirectories: true)
        }
        try "x".write(to: folder.appending("note.txt"), atomically: true, encoding: .utf8)
        store = AppStateStore(
            filePath: folder.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
        let windows = ExplorerWindows(store: store, quit: quit)
        windows.presentsWindows = onScreen
        self.windows = windows
        channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { id in id.flatMap { windows.tab(windowID: $0)?.group?.recordID } },
            onPreferencesChanged: { _, change in
                for tab in windows.allTabs { tab.preferencesChanged(change) }
            })
        services = ExplorerServices(
            directoryService: DirectoryService(), folderWatches: nil, iconStore: nil, volumeWatcher: nil,
            clipboard: windows.clipboard, preferences: channel)
    }

    /// A harness whose windows never go on screen.
    static func windowless() throws -> ExplorerHarness {
        try ExplorerHarness(onScreen: false)
    }

    func open(_ path: String? = nil) async throws -> MainWindowController {
        windows.openStartupWindows(folder: path ?? folder.path)
        let tab = try #require(windows.front as? MainWindowController)
        // The window's services are this harness's: other suites' windows keep the app's.
        tab.servicesOverride = services
        tab.preferencesChanged(PreferencesChange(patch: [:], senderID: nil))
        if onScreen {
            #expect(await waitUntil { tab.window?.isVisible == true && tab.workspace.isReady })
        } else {
            // Ready as it would be shown: its first folder read (the tab reads it in a task that hasn't run yet).
            var read = false
            let ready = tab.onReady
            tab.onReady = {
                ready?()
                read = true
            }
            #expect(await waitUntil { read && tab.workspace.isReady })
            #expect(tab.window?.isVisible == false)
        }
        layout(tab)
        return tab
    }

    func layout(_ tab: MainWindowController) {
        tab.window?.contentView?.layoutSubtreeIfNeeded()
        tab.workspace.layout()
        tab.workspace.toolbar.layout()
    }

    func close() async {
        AppMenuPresenter.shared.close()
        for tab in windows.allTabs { tab.window?.close() }
        await settle()
        folder.remove()
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

/// The explorer window's end-to-end suites: one at a time, as they share the app's menu and the screen. They put
/// windows on screen: only with FILETRAIL_GUI_TESTS=1, under the GUI lock.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct ExplorerWindowGUITests {}

/// The explorer window's windowless suites: real tabs and views on windows that are never shown, one at a time, as
/// they share the app's menu presenter and its other singletons.
@MainActor
@Suite(.serialized)
struct ExplorerWindowlessTests {}
