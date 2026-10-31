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
    /// Stands in for the clipboard, which stays the user's.
    let pasteboard = NSPasteboard.withUniqueName()

    init(onScreen: Bool = true) throws {
        _ = NSApplication.shared
        self.onScreen = onScreen
        folder = try TemporaryDirectory.shallow(prefix: "filetrail-toolbar-gui")
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
        // Weakly: the tabs hold the channel through their services, so it mustn't hold the harness's windows.
        channel = WindowPreferenceChannel(
            store: store,
            explorerWindowID: { [weak windows] id in id.flatMap { windows?.tab(windowID: $0)?.group?.recordID } },
            onPreferencesChanged: { [weak windows] _, change in
                for tab in windows?.allTabs ?? [] { tab.preferencesChanged(change) }
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
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct ExplorerWindowGUITests {}

/// The explorer window's windowless suites: real tabs and views on windows that are never shown, a few at a time
/// (`WindowlessSlots`), each with a menu presenter of its own. A suite or test that replaces one of the app's globals
/// (a hook of `MainWindowController` or `TabDragDrop`, the app's file operations, the shared presenters) is marked
/// `.windowlessAlone` and runs with no other.
@MainActor
@Suite(.windowless)
struct ExplorerWindowlessTests {}

/// How the windowless suites' tests take turns: they all run on the main thread, so a few at a time fill the time one
/// spends waiting on a read or a timer, and more would only make each one's waits run out.
struct WindowlessSlots: TestTrait, SuiteTrait, TestScoping {
    /// How many run at once (`FILETRAIL_WINDOWLESS_SLOTS`).
    static let slots = TestSlots(
        width: ProcessInfo.processInfo.environment["FILETRAIL_WINDOWLESS_SLOTS"].flatMap { Int($0) } ?? 3)

    let alone: Bool

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        guard !test.isSuite, testCase != nil else { return nil }
        // A test marked alone (or in a suite marked so) takes only that scope, not its parent suite's too.
        if !alone && test.traits.contains(where: { ($0 as? Self)?.alone == true }) { return nil }
        return self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainLoopHold.begin()
        try await Self.slots.run(alone: alone) {
            let presenter = await MainActor.run { AppMenuPresenter() }
            try await AppMenuPresenter.withOwn(presenter) { try await function() }
        }
    }
}

extension Trait where Self == WindowlessSlots {
    /// A windowless test in a slot of the group, with a menu presenter of its own.
    static var windowless: Self { WindowlessSlots(alone: false) }
    /// A windowless test that runs with no other: it replaces a global the others would see.
    static var windowlessAlone: Self { WindowlessSlots(alone: true) }
}
