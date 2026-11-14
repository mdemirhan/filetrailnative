// An explorer window of the app on a temporary folder, for the window suites: on screen for the end-to-end tests,
// or made and read but never shown for the windowless ones
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// The app's services for the tests' windows, installed once as the app installs its own when it starts. A tab with no
/// services of its own (one its window opened, rather than the test) uses them.
@MainActor
enum TestServices {
    /// The one icon store of the tests' windows.
    static let icons = FileIconStore()

    static func install() {
        guard ExplorerServices.installed == nil else { return }
        ExplorerServices.installed = ExplorerServices(
            directoryService: DirectoryService(), iconStore: icons, clipboard: SharedClipboard(), preferences: nil)
    }
}

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
    /// Stands in for the clipboard, which stays the user's.
    let pasteboard = NSPasteboard.withUniqueName()

    init(onScreen: Bool = true) throws {
        _ = NSApplication.shared
        TestServices.install()
        self.onScreen = onScreen
        folder = try TemporaryDirectory.shallow(prefix: onScreen ? "filetrail-gui" : "filetrail-windowless")
        for name in ["Alpha", "Beta", "Gamma"] {
            try FileManager.default.createDirectory(
                at: folder.appending("\(name)/Inner"), withIntermediateDirectories: true)
        }
        try "x".write(to: folder.appending("note.txt"), atomically: true, encoding: .utf8)
        store = AppStateStore(
            filePath: folder.appending("app-state.json").path, defaultTheme: .light, timer: HeldStateTimer())
        let windows = ExplorerWindows(store: store, quit: quit)
        windows.presentsWindows = onScreen
        // The tree starts at this folder instead of `/`: following the folders above it is most of what opening a window
        // costs. A test of the tree above it, or of Home, sets its own.
        windows.home = folder.path
        self.windows = windows
        // Weakly: the tabs hold the channel through their services, so it mustn't hold the harness's windows.
        channel = WindowPreferenceChannel(
            store: store,
            explorerWindowID: { [weak windows] id in id.flatMap { windows?.tab(windowID: $0)?.group?.recordID } },
            onPreferencesChanged: { [weak windows] _, change in
                for tab in windows?.allTabs ?? [] { tab.preferencesChanged(change) }
            })
        services = ExplorerServices(
            directoryService: DirectoryService(), iconStore: TestServices.icons, clipboard: windows.clipboard,
            preferences: channel)
    }

    /// For a test of the tree above the folder: windows opened after this start it at the disk, as the app's do.
    func startsTheTreeAtTheDisk() {
        windows.home = FileManager.default.homeDirectoryForCurrentUser.path
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
        tab.preferencesChanged(PreferencesChange(keys: [], senderID: nil))
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
        // The tree's first read too: it reads the folder itself, and a test that counts reads starts after it.
        let model = tab.sidebarController.model
        #expect(
            await waitUntil {
                let root = model.nodes[model.rootPath]
                return root?.loaded == true || root?.error != nil
            }, "the tree's first read ended")
        leaveTheMacAlone(tab)
        layout(tab)
        return tab
    }

    /// What the tab does past its own windows goes nowhere: a test that wants to see it gives its own spy.
    private func leaveTheMacAlone(_ tab: MainWindowController) {
        let opener = SystemOpener(
            openPath: { _ in "" }, openWithApplication: { _, _ in }, reveal: { _ in }, openURL: { _ in })
        tab.opener = opener
        tab.openFile = { _ in }
        tab.contextMenus.opener = opener
        tab.contextMenus.setDefaultApplication = { _, _ in .success }
        tab.contextMenus.pasteboard = pasteboard
        tab.systemClipboard.pasteboard = pasteboard
        tab.infoController?.actions.opener = opener
        tab.infoController?.actions.setDefaultApplication = { _, _ in .success }
        tab.infoController?.actions.pasteboard = pasteboard
        // A press on the magnifier would put a window that stays off screen on it.
        if !onScreen { tab.explorerToolbar.bringForward = { _ in } }
    }

    func layout(_ tab: MainWindowController) {
        // The window's frame view: the content, and the title bar with the toolbar's row.
        tab.window?.layoutIfNeeded()
        tab.window?.contentView?.layoutSubtreeIfNeeded()
        tab.workspace.layout()
    }

    func close() async {
        AppMenuPresenter.shared.close()
        for tab in windows.allTabs { tab.window?.close() }
        await settle()
        pasteboard.releaseGlobally()
        folder.remove()
    }
}

/// Waits by the clock, as a busy Mac can spend seconds on one read: the time only matters to a test that is failing, and
/// that one says where it gave up.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    if condition() { return true }
    FileHandle.standardError.write(
        Data("waitUntil gave up after \(timeout) at \(sourceLocation.fileID):\(sourceLocation.line)\n".utf8))
    return false
}

/// The explorer window's end-to-end suites: one at a time, as they share the app's menu and the screen. They put
/// windows on screen: only with FILETRAIL_GUI_TESTS=1.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct ExplorerWindowGUITests {}

/// The explorer window's windowless suites: real tabs and views on windows that are never shown, one test at a time in
/// a process. Almost all of their time is the main thread's work, so what speeds them up is more processes
/// (`scripts/ci.sh`), not tests side by side.
@MainActor
@Suite(.serialized, .windowless)
struct ExplorerWindowlessTests {}

/// A windowless test: the main loop held, and a menu presenter of its own, as a process run by `swift test` has other
/// suites beside it.
struct WindowlessScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite || testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainLoopHold.begin()
        let presenter = await MainActor.run { AppMenuPresenter() }
        try await AppMenuPresenter.withOwn(presenter) { try await function() }
    }
}

extension Trait where Self == WindowlessScope {
    static var windowless: Self { WindowlessScope() }
}
