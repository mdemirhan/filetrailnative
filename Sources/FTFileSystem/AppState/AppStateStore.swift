// Port of apps/desktop/src/main/appStateStore.ts (the I/O, the save tiers, the window records and the visited-folders file)
import FTFoundation
import Foundation
import os

/// The app's own files: `app-state.json` (preferences, the explorer windows, the window closed last) and, beside it,
/// `visited-folders.json`. Sanitizing and migration are `AppStateReader`'s and `PreferencesSanitizer`'s.
///
/// Changes are written in two tiers. A deliberate change (a setting, a favorite) is written 150 ms later, one write for
/// a burst. What only follows where the user is (the navigation keys, folder visits, the windows and their bounds) waits
/// for the next write, for quit, or for 5 minutes after the first unsaved change, whichever comes first. Only files with
/// changes are rewritten, each through a `.tmp` file renamed over the target.
public final class AppStateStore: @unchecked Sendable {
    /// How long after a deliberate change the file is written.
    public static let promptSaveDelayMilliseconds = 150
    /// How long after the first unsaved change, at most, navigation waits for a write.
    public static let deferredSaveDelayMilliseconds = 5 * 60 * 1000

    /// The keys that only follow where the user is: the view mode and the sort orders belong to the tab on screen, so
    /// they change whenever another tab comes to the front.
    static let navigationKeys: Set<String> = [
        "lastVisitedPath", "lastVisitedFavoritePath", "treeRootPath", "openTabs", "activeTabIndex", "viewMode",
        "searchViewMode", "sortBy", "sortDirection", "searchResultsSortBy", "searchResultsSortDirection",
    ]

    private enum StoreFile: Hashable { case state, visits }

    private let lock = NSLock()
    public let filePath: String
    private let visitsFilePath: String
    private let defaults: AppPreferences
    private let fileSystem: any StateFileSystem
    private let timer: any StateTimer
    private let onPersistError: @Sendable (any Error) -> Void
    private var state: AppState
    private var visitedFolders: [VisitedFolder]
    private var unsavedFiles: Set<StoreFile> = []
    private var cancelPromptSave: (@Sendable () -> Void)?
    private var cancelDeferredSave: (@Sendable () -> Void)?

    private static let log = Logger(subsystem: AppStatePaths.bundleID, category: "app-state")

    public init(
        filePath: String, defaultTheme: ThemePreference = .auto, fileSystem: any StateFileSystem = DiskFileSystem(),
        timer: any StateTimer = DispatchStateTimer(),
        onReadError: (@Sendable (any Error) -> Void)? = nil, onPersistError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.filePath = filePath
        self.fileSystem = fileSystem
        self.timer = timer
        let readFailed =
            onReadError ?? { error in
                Self.log.error("[filetrail] failed reading app state \(String(describing: error), privacy: .public)")
            }
        self.onPersistError =
            onPersistError ?? { error in
                Self.log.error(
                    "[filetrail] failed persisting app state \(String(describing: error), privacy: .public)")
            }
        defaults = AppPreferences.defaults(theme: defaultTheme)
        visitsFilePath = AppStatePaths.visitedFolders(besideAppState: URL(fileURLWithPath: filePath)).path
        state = Self.readState(filePath, fileSystem, defaults, readFailed)
        visitedFolders = Self.readVisitedFolders(visitsFilePath, fileSystem, readFailed)
    }

    // MARK: Preferences

    public func preferences() -> AppPreferences {
        locked { currentPreferences }
    }

    /// `updatePreferences`: applies a change (a patch of preference keys, each checked as when a file is read) and
    /// returns the preferences now. A key whose value is the same is no change and writes nothing.
    @discardableResult
    public func updatePreferences(_ patch: [String: JSONNode]) -> AppPreferences {
        locked { update(patch) }
    }

    /// `updatePreferences` for a change written as code: the keys that differ afterwards are the patch.
    @discardableResult
    public func updatePreferences(_ change: (inout AppPreferences) -> Void) -> AppPreferences {
        locked {
            var changed = currentPreferences
            change(&changed)
            return update(Self.difference(from: currentPreferences, to: changed))
        }
    }

    // MARK: Visited folders

    public func folders() -> [VisitedFolder] {
        locked { visitedFolders }
    }

    /// Visits follow where the user goes, so they wait like the window state does.
    public func recordFolderVisit(_ path: String, kind: FolderVisitKind, now: Double = AppClock.now.epochMilliseconds) {
        locked {
            let recorded = VisitedFolders.record(visitedFolders, path: path, kind: kind, now: now)
            if recorded == visitedFolders { return }
            visitedFolders = recorded
            markUnsaved(.visits)
            saveLater()
        }
    }

    /// Removing a folder from Go To is something the user did on purpose.
    @discardableResult
    public func forgetVisitedFolder(_ path: String) -> [VisitedFolder] {
        locked {
            let remaining = VisitedFolders.forget(visitedFolders, path: path)
            if remaining.count != visitedFolders.count {
                markUnsaved(.visits)
                saveSoon()
            }
            visitedFolders = remaining
            return remaining
        }
    }

    // MARK: Explorer windows

    /// The explorer windows to bring back, front to back.
    public func explorerWindows() -> [StoredExplorerWindow] {
        locked { windows }
    }

    /// The app's preferences as the window `windowID` sees them: with its own session.
    public func windowPreferences(_ windowID: String) -> AppPreferences {
        locked {
            guard let window = windows.first(where: { Self.sameID($0.id, windowID) }) else { return currentPreferences }
            return window.session.applied(to: currentPreferences)
        }
    }

    /// A change made in the window `windowID`. Its session keys are the window's own; every key also becomes the app's
    /// latest value. For a window not known, the change is the app's alone.
    @discardableResult
    public func updateWindowPreferences(_ windowID: String, _ patch: [String: JSONNode]) -> AppPreferences {
        locked {
            let preferences = update(patch)
            guard let window = windows.first(where: { Self.sameID($0.id, windowID) }) else { return preferences }
            let current = window.session.applied(to: preferences)
            let session = PreferencesSanitizer.apply(
                WindowSessionKeys.pick(patch), to: current, defaults: current
            ).windowSession
            let before = Self.sessionNode(window.session)
            let after = Self.sessionNode(session)
            let changedKeys = WindowSessionKeys.all.filter { before[$0] != after[$0] }
            if !changedKeys.isEmpty {
                replaceWindow(StoredExplorerWindow(id: window.id, bounds: window.bounds, session: session))
                markUnsaved(.state)
                if changedKeys.contains(where: { !Self.navigationKeys.contains($0) }) {
                    saveSoon()
                } else {
                    saveLater()
                }
            }
            return session.applied(to: preferences)
        }
    }

    /// A window's session as a new window would start it: the app's latest values, with `overrides` on top.
    public func createWindowSession(overrides: [String: JSONNode] = [:]) -> WindowSession {
        locked { newWindowSession(overrides) }
    }

    /// Adds a window in front of the others. Only open windows are kept, so none is dropped to keep to
    /// `AppStateReader.windowsLimit`: that is for reading a damaged file.
    public func addExplorerWindow(id: String, bounds: StoredWindowState, session: WindowSession? = nil) {
        locked {
            let session = newWindowSession(session.map(Self.sessionNode) ?? [:])
            let added = StoredExplorerWindow(
                id: id, bounds: AppStateReader.windowState(try? JSONNode.of(bounds)), session: session)
            setWindows([added] + windows.filter { !Self.sameID($0.id, id) })
        }
    }

    /// The window closed last, or none yet.
    public func lastClosedWindow() -> StoredExplorerWindow? {
        locked { state.lastClosedWindow }
    }

    /// Remembers the window `windowID` as it closes, keeping only the tab that was in front: a window opened when none is
    /// open starts from it.
    public func rememberClosedWindow(_ windowID: String) {
        locked {
            guard let window = windows.first(where: { Self.sameID($0.id, windowID) }) else { return }
            var session = window.session
            let front =
                session.openTabs.indices.contains(session.frontTabIndex) ? session.openTabs[session.frontTabIndex] : nil
            session.openTabs = front.map { [$0] } ?? []
            session.activeTabIndex = 0
            let closed = StoredExplorerWindow(id: window.id, bounds: window.bounds, session: session)
            if closed == state.lastClosedWindow { return }
            state.lastClosedWindow = closed
            markUnsaved(.state)
            saveLater()
        }
    }

    public func removeExplorerWindow(_ windowID: String) {
        locked {
            if windows.contains(where: { Self.sameID($0.id, windowID) }) {
                setWindows(windows.filter { !Self.sameID($0.id, windowID) })
            }
        }
    }

    /// Puts the windows in this order, front to back: the order the open windows are in. Any not named stay behind them.
    public func setExplorerWindowOrder(_ windowIDs: [String]) {
        locked {
            let current = windows
            let named = windowIDs.compactMap { id in current.first { Self.sameID($0.id, id) } }
            let ordered = named + current.filter { window in !windowIDs.contains { Self.sameID($0, window.id) } }
            if ordered == current { return }
            setWindows(ordered)
        }
    }

    public func setExplorerWindowBounds(_ windowID: String, _ value: StoredWindowState) {
        locked {
            guard let window = windows.first(where: { Self.sameID($0.id, windowID) }) else { return }
            let bounds = AppStateReader.windowState(try? JSONNode.of(value))
            if bounds == window.bounds { return }
            replaceWindow(StoredExplorerWindow(id: window.id, bounds: bounds, session: window.session))
            markUnsaved(.state)
            saveLater()
        }
    }

    // MARK: Writing

    /// Writes whatever has not been written yet. Called when the app quits.
    public func flush() {
        locked {
            if !unsavedFiles.isEmpty { save() }
        }
    }

    // MARK: Internals (the lock is held)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var currentPreferences: AppPreferences { state.preferences ?? defaults }
    private var windows: [StoredExplorerWindow] { state.windows ?? [] }

    // JavaScript compares ids as strings of UTF-16 units; Swift's == would treat canonically equal ones as the same.
    private static func sameID(_ left: String, _ right: String) -> Bool {
        left.utf16.elementsEqual(right.utf16)
    }

    private func update(_ patch: [String: JSONNode]) -> AppPreferences {
        let current = currentPreferences
        let next = PreferencesSanitizer.apply(patch, to: current, defaults: defaults)
        let before = (try? JSONNode.of(current))?.object ?? [:]
        let after = (try? JSONNode.of(next))?.object ?? [:]
        let changedKeys = after.keys.filter { before[$0] != after[$0] }
        state.preferences = next
        if !changedKeys.isEmpty {
            markUnsaved(.state)
        }
        if changedKeys.contains(where: { !Self.navigationKeys.contains($0) }) {
            saveSoon()
        } else if !changedKeys.isEmpty {
            saveLater()
        }
        return next
    }

    private static func difference(from old: AppPreferences, to new: AppPreferences) -> [String: JSONNode] {
        let before = (try? JSONNode.of(old))?.object ?? [:]
        let after = (try? JSONNode.of(new))?.object ?? [:]
        return after.filter { before[$0.key] != $0.value }
    }

    private static func sessionNode(_ session: WindowSession) -> [String: JSONNode] {
        (try? JSONNode.of(session))?.object ?? [:]
    }

    private func newWindowSession(_ overrides: [String: JSONNode]) -> WindowSession {
        PreferencesSanitizer.apply(overrides, to: currentPreferences, defaults: defaults).windowSession
    }

    private func replaceWindow(_ window: StoredExplorerWindow) {
        state.windows = windows.map { Self.sameID($0.id, window.id) ? window : $0 }
    }

    // Which windows there are and their order follow where the user is, like navigation.
    private func setWindows(_ updated: [StoredExplorerWindow]) {
        state.windows = updated
        markUnsaved(.state)
        saveLater()
    }

    private func markUnsaved(_ file: StoreFile) {
        unsavedFiles.insert(file)
    }

    private func saveSoon() {
        cancelPromptSave?()
        cancelDeferredSave?()
        cancelDeferredSave = nil
        // Debounced so a burst of changes (a drag, repeated toggles) is one write.
        cancelPromptSave = timer.schedule(afterMilliseconds: Self.promptSaveDelayMilliseconds) { [weak self] in
            self?.flushFromTimer()
        }
    }

    private func saveLater() {
        // Not pushed back by later changes: it bounds how much a crash can lose.
        guard cancelPromptSave == nil, cancelDeferredSave == nil else { return }
        cancelDeferredSave = timer.schedule(afterMilliseconds: Self.deferredSaveDelayMilliseconds) { [weak self] in
            self?.flushFromTimer()
        }
    }

    private func flushFromTimer() {
        locked { save() }
    }

    // Writes only the files that changed since they were last written.
    private func save() {
        cancelPromptSave?()
        cancelPromptSave = nil
        cancelDeferredSave?()
        cancelDeferredSave = nil
        if unsavedFiles.contains(.visits) {
            writeAtomically(visitsFilePath, VisitedFolders.serialize(visitedFolders))
        }
        if unsavedFiles.contains(.state) {
            do {
                writeAtomically(filePath, try AppStateJSON.serialize(state))
            } catch {
                onPersistError(error)
            }
        }
        unsavedFiles.removeAll()
    }

    // Write a sibling temp file and rename it over the target so a crash mid-write leaves the previous state intact
    // instead of a truncated file.
    private func writeAtomically(_ path: String, _ contents: String) {
        let temporary = path + ".tmp"
        do {
            try fileSystem.createDirectory((path as NSString).deletingLastPathComponent)
            try fileSystem.write(temporary, contents)
            try fileSystem.rename(temporary, path)
        } catch {
            onPersistError(error)
        }
    }

    // Loading is best-effort. Corrupt state should never block startup.
    private static func readState(
        _ path: String, _ fileSystem: any StateFileSystem, _ defaults: AppPreferences,
        _ onReadError: @Sendable (any Error) -> Void
    ) -> AppState {
        guard fileSystem.exists(path) else { return AppState() }
        do {
            return try AppStateReader.read(data: try fileSystem.read(path), defaults: defaults)
        } catch {
            onReadError(error)
            return AppState()
        }
    }

    private static func readVisitedFolders(
        _ path: String, _ fileSystem: any StateFileSystem, _ onReadError: @Sendable (any Error) -> Void
    ) -> [VisitedFolder] {
        guard fileSystem.exists(path) else { return [] }
        do {
            let parsed = try JSONSerialization.jsonObject(with: try fileSystem.read(path))
            return (parsed as? [String: Any]).map { VisitedFolders.sanitize($0["folders"]) } ?? []
        } catch {
            onReadError(error)
            return []
        }
    }
}

extension Date {
    /// `Date.now()`: milliseconds since 1970.
    public var epochMilliseconds: Double { (timeIntervalSince1970 * 1000).rounded(.down) }
}
