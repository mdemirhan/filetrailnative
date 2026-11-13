// The app's windows on a state file, as a launch opens them, for the tests of whole windows
import AppKit
import FTFileSystem
import FTTestSupport
import Foundation

@testable import FTAppKit

@MainActor
struct NativeApp {
    let store: AppStateStore
    let quit: QuitCoordinator
    let windows: ExplorerWindows

    var groupCount: Int { windows.count }

    var frontTab: MainWindowController? { windows.front as? MainWindowController }

    func closeAll() async {
        for tab in windows.allTabs { tab.window?.close() }
        await settle()
    }

    /// The menu bar on these windows, wired as the app delegate wires it.
    func menuBar() -> MainMenu {
        let menu = MainMenu(windows: windows)
        menu.connect(
            openWindowFor: { [windows] command in windows.openDefaultWindow(initialCommand: command) },
            openNewWindowFromFront: { [windows] in windows.openNewWindowFromFront() })
        menu.build()
        windows.onWindowsChanged = { [weak menu] in menu?.sync.windowsChanged() }
        windows.onMenuState = { [weak menu] windowID, state in menu?.sync.setWindowState(windowID: windowID, state) }
        return menu
    }

    /// A folder holding a.txt and Sub/inside.txt.
    static func folders(prefix: String) throws -> TemporaryDirectory {
        let folder = try TemporaryDirectory.shallow(prefix: prefix)
        try "alpha".write(to: folder.appending("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appending("Sub"), withIntermediateDirectories: false)
        try "inside".write(to: folder.appending("Sub/inside.txt"), atomically: true, encoding: .utf8)
        return folder
    }
}
