// Stand-ins for the explorer window controller's tests: windows whose events are fired by hand, a clock moved by hand
// and a store whose writes wait for flush(), as in apps/desktop/src/main/explorerWindowController.test.ts
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation

@testable import FTAppKit

/// A timer that never fires: the store writes only on flush().
final class HeldStateTimer: StateTimer {
    func schedule(afterMilliseconds delay: Int, _ action: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        {}
    }
}

/// A clock moved by hand.
@MainActor
final class HandScheduler: FolderWatchScheduler {
    private struct Job {
        let id: Int
        let at: Double
        let work: @MainActor () -> Void
    }

    private var time: Double = 0
    private var jobs: [Job] = []
    private var nextID = 0

    nonisolated init() {}

    func now() -> Double { time }

    func schedule(afterMilliseconds milliseconds: Double, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        jobs.append(Job(id: id, at: time + milliseconds, work: work))
        return { [weak self] in
            MainActor.assumeIsolated { self?.jobs.removeAll { $0.id == id } }
        }
    }

    func advance(_ milliseconds: Double) {
        time += milliseconds
        while let next = jobs.filter({ $0.at <= time }).min(by: { $0.at < $1.at }) {
            jobs.removeAll { $0.id == next.id }
            next.work()
        }
    }
}

/// Lets tasks waiting on each other run.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

func tab(_ path: String) -> OpenTabPreference {
    OpenTabPreference(
        path: path, treeRootPath: "/Users/demo", favoritePath: nil, viewMode: .list, searchViewMode: .details,
        sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
        locationsExpanded: true)
}

func node<T: Encodable>(_ value: T) -> JSONNode {
    (try? JSONNode.of(value)) ?? .null
}

/// A store on a file of its own, whose writes wait for flush().
func makeStore(_ contents: String = #"{"preferences":{},"windows":[]}"#) throws -> AppStateStore {
    let folder = try TemporaryDirectory(prefix: "filetrail-windows")
    let path = folder.appending("app-state.json").path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return AppStateStore(filePath: path, defaultTheme: .dark, timer: HeldStateTimer())
}

func storedWindow(
    _ store: AppStateStore, _ id: String, _ paths: [String], x: Double? = nil, y: Double? = nil,
    maximized: Bool = false
) -> StoredExplorerWindow {
    StoredExplorerWindow(
        id: id, bounds: StoredWindowState(x: x, y: y, width: 900, height: 600, maximized: maximized),
        session: store.createWindowSession(overrides: ["openTabs": node(paths.map(tab)), "activeTabIndex": .number(0)]))
}

func add(_ store: AppStateStore, _ window: StoredExplorerWindow) {
    store.addExplorerWindow(id: window.id, bounds: window.bounds, session: window.session)
}

/// A stand-in for an explorer window: closing it goes as Electron's does, "close" at once (which can be held) and
/// "closed" a moment later.
@MainActor
final class FakeWindow: ExplorerWindowLike {
    private static var nextID = 1

    let windowID: Int
    let recordID: String
    var events = ExplorerWindowEvents()
    var destroyed = false
    var visible = false
    var minimized = false
    var maximized = false
    var fullScreen = false
    var bounds = WindowBounds(x: 100, y: 80, width: 900, height: 600)
    var normal = WindowBounds(x: 100, y: 80, width: 900, height: 600)
    var told: [ExplorerWindowMessage] = []
    var focused = 0
    private let log: (String) -> Void

    init(recordID: String, log: @escaping (String) -> Void) {
        windowID = Self.nextID
        Self.nextID += 1
        self.recordID = recordID
        self.log = log
    }

    var isDestroyed: Bool { destroyed }
    var isVisible: Bool { visible }
    var isMinimized: Bool { minimized }
    var isMaximized: Bool { maximized }
    var isFullScreen: Bool { fullScreen }
    // As Electron's: the bounds it goes back to, which are its bounds when it is neither zoomed nor full screen.
    var normalBounds: WindowBounds { maximized || fullScreen ? normal : bounds }
    var sheetParent: NSWindow? { nil }

    func close() {
        guard !destroyed, events.shouldClose() else { return }
        log("close \(recordID)")
        Task { @MainActor in
            destroyed = true
            events.closed()
        }
    }

    func show() {
        visible = true
        log("show \(recordID)")
    }

    func showInactive() {
        visible = true
        log("showInactive \(recordID)")
    }

    func focus() {
        focused += 1
        events.focus()
    }

    func restore() { minimized = false }

    func maximize() {
        maximized = true
        log("maximize \(recordID)")
    }

    func tell(_ message: ExplorerWindowMessage) { told.append(message) }
}

/// The controller with stand-in windows, a held store and a quit coordinator.
@MainActor
final class WindowSetup {
    struct Question {
        let question: StopQuestion
        let answer: (Int) -> Void
    }

    let store: AppStateStore
    let scheduler = HandScheduler()
    let quit: QuitCoordinator
    private(set) var controller: ExplorerWindowController<FakeWindow>!
    var log: [String] = []
    var windows: [FakeWindow] = []
    var questions: [Question] = []
    var operation: BusyOperationKind?
    var windowsChanged = 0
    var exits = 0
    var launches: [String: ExplorerLaunchContext] = [:]
    /// What each window says when Merge All Windows asks for its tabs; left out, the tabs it last saved.
    var tabAnswers: [Int: WindowTabsAnswer?] = [:]
    /// While set, Merge All Windows' requests for tabs wait for it to be let go.
    private var heldTabs: [CheckedContinuation<Void, Never>]?
    var shutDownHeld = false
    private var windowCount = 0

    init(store: AppStateStore? = nil) throws {
        let store = try store ?? makeStore()
        self.store = store
        quit = QuitCoordinator()
        quit.hooks.activeOperation = { [unowned self] in operation }
        quit.hooks.anyWindowOpen = { [unowned self] in windows.contains { !$0.destroyed } }
        quit.hooks.showStopQuestion = { [unowned self] question, _ in
            await withCheckedContinuation { continuation in
                questions.append(Question(question: question) { continuation.resume(returning: $0) })
            }
        }
        quit.hooks.recordAllBounds = { [unowned self] in controller.recordAllBounds() }
        quit.hooks.flushStore = { store.flush() }
        quit.hooks.bringStopQuestionForward = { [unowned self] in controller.bringStopQuestionForward() }
        quit.hooks.shutDown = { [unowned self] in
            if shutDownHeld { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
        }
        quit.hooks.exit = { [unowned self] in exits += 1 }

        var host = ExplorerWindowController<FakeWindow>.Host(
            store: store,
            createWindow: { [unowned self] record, launch in
                let window = FakeWindow(recordID: record.id) { [unowned self] in log.append($0) }
                windows.append(window)
                launches[record.id] = launch
                return window
            },
            workArea: { _ in WindowBounds(x: 0, y: 0, width: 1600, height: 1000) },
            requestTabs: { [unowned self] windows in
                if heldTabs != nil {
                    await withCheckedContinuation { heldTabs?.append($0) }
                }
                return windows.map { window in
                    if let answer = tabAnswers[window.windowID] { return answer }
                    return WindowTabsAnswer(tabs: store.windowPreferences(window.recordID).openTabs, busy: false)
                }
            },
            scheduler: scheduler)
        host.newWindowID = { [unowned self] in
            windowCount += 1
            return "window-new-\(windowCount)"
        }
        host.windowsChanged = { [unowned self] in windowsChanged += 1 }
        controller = ExplorerWindowController(host: host, quit: quit)
    }

    /// The app with windows open: each opened from the one before, the last in front.
    static func withWindows(_ count: Int) throws -> WindowSetup {
        let setup = try WindowSetup()
        setup.controller.openStartupWindows(folder: nil)
        for index in 1..<max(1, count) {
            setup.controller.openWindowFrom(nil, tabs: [tab("/Users/demo/\(index)")], activeTabIndex: 0)
        }
        return setup
    }

    func window(_ recordID: String) -> FakeWindow? {
        windows.first { $0.recordID == recordID }
    }

    func answerTabs(_ window: FakeWindow, _ answer: WindowTabsAnswer?) {
        tabAnswers[window.windowID] = .some(answer)
    }

    /// Holds Merge All Windows' requests for tabs until the returned function is called.
    func holdTabAnswers() -> () -> Void {
        heldTabs = []
        return { [unowned self] in
            let waiting = heldTabs ?? []
            heldTabs = nil
            for continuation in waiting { continuation.resume() }
        }
    }

    func runOperation(_ kind: BusyOperationKind?) {
        operation = kind
    }
}
