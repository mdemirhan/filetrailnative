import FTFoundation
import Foundation
import os

/// The app's own files: `app-state.json` (preferences, the explorer windows, the window closed last) and, beside it,
/// `visited-folders.json`, `destination-folders.json`, `recent-commands.json` and `folder-views.json`. Sanitizing and
/// migration are `AppStateReader`'s and `PreferencesSanitizer`'s.
///
/// Changes are written in two tiers, at most twice a minute. A deliberate change (a setting, a favorite, a folder's
/// view) is written 1 s later, one write for a burst, or 30 s after the last write when that is later; changes made
/// meanwhile don't put it off. What only follows where the user is (the navigation keys, folder visits, the windows
/// and their bounds) waits for the next write, for quit, or for 5 minutes after the first unsaved change, whichever
/// comes first. Only files with changes are rewritten, each through a `.tmp` file renamed over the target, and a file
/// whose text is what was written last is left alone.
public final class AppStateStore: @unchecked Sendable {
    /// How long after a deliberate change the file is written, at the soonest.
    public static let promptSaveDelayMilliseconds = 1000
    /// The least time between two writes, but at quit: the files are written at most twice a minute.
    public static let minimumSaveIntervalMilliseconds = 30 * 1000
    /// How long after the first unsaved change, at most, navigation waits for a write.
    public static let deferredSaveDelayMilliseconds = 5 * 60 * 1000

    /// The keys that only follow where the user is: the view mode, the sort orders and the other settings of a tab belong
    /// to the tab on screen, so they change whenever another tab comes to the front.
    static let navigationKeys: Set<PreferenceKey> = [
        .lastVisitedPath, .lastVisitedFavoritePath, .treeRootPath, .openTabs, .activeTabIndex, .viewMode,
        .searchViewMode, .sortBy, .sortDirection, .searchResultsSortBy, .searchResultsSortDirection, .includeHidden,
        .foldersFirst, .favoritesExpanded, .locationsExpanded,
    ]

    private enum StoreFile: Hashable { case state, visits, destinations, recentCommands, folderViews }

    private let lock = NSLock()
    public let filePath: String
    private let visitsFilePath: String
    private let destinationsFilePath: String
    private let recentCommandsFilePath: String
    private let folderViewsFilePath: String
    private let defaults: AppPreferences
    private let fileSystem: any StateFileSystem
    private let timer: any StateTimer
    /// Milliseconds on a clock that only goes forward, for the time between writes.
    private let clock: @Sendable () -> Double
    private let onPersistError: @Sendable (any Error) -> Void
    private var state: AppState
    private var visitedFolders: [VisitedFolder]
    private var destinationFolders: [VisitedFolder]
    private var commands: [String]
    private var views: FolderViews
    /// When the files were last written, on `clock`.
    private var lastSaveAt: Double?
    /// The text each file was last written with in this run; a file not written yet has none, so its first change
    /// is always written.
    private var writtenText: [StoreFile: String] = [:]
    /// `folder-views.json` was there and couldn't be read, and is still as it was found: it is set aside before the
    /// first write over it (`setUnreadableFolderViewsAside`).
    private var folderViewsFileUnreadable = false
    private var unsavedFiles: Set<StoreFile> = []
    private var cancelPromptSave: (@Sendable () -> Void)?
    private var cancelDeferredSave: (@Sendable () -> Void)?

    private static let log = Logger(subsystem: AppStatePaths.bundleID, category: "app-state")

    public init(
        filePath: String, defaultTheme: ThemePreference = .auto, fileSystem: any StateFileSystem = DiskFileSystem(),
        timer: any StateTimer = DispatchStateTimer(),
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 },
        onReadError: (@Sendable (any Error) -> Void)? = nil, onPersistError: (@Sendable (any Error) -> Void)? = nil
    ) {
        self.filePath = filePath
        self.fileSystem = fileSystem
        self.timer = timer
        self.clock = clock
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
        destinationsFilePath = AppStatePaths.destinationFolders(besideAppState: URL(fileURLWithPath: filePath)).path
        recentCommandsFilePath = AppStatePaths.recentCommands(besideAppState: URL(fileURLWithPath: filePath)).path
        folderViewsFilePath = AppStatePaths.folderViews(besideAppState: URL(fileURLWithPath: filePath)).path
        state = Self.readState(filePath, fileSystem, defaults, readFailed)
        visitedFolders = Self.readVisitedFolders(visitsFilePath, fileSystem, readFailed)
        destinationFolders = Self.readVisitedFolders(destinationsFilePath, fileSystem, readFailed)
        commands = Self.readRecentCommands(recentCommandsFilePath, fileSystem, readFailed)
        let readViews = Self.readFolderViews(folderViewsFilePath, fileSystem, readFailed)
        views = readViews.views
        folderViewsFileUnreadable = readViews.unreadable
    }

    // MARK: Preferences

    public func preferences() -> AppPreferences {
        locked { currentPreferences }
    }

    /// Changes the app's preferences and returns them: `change` sets fields as on `AppPreferences`
    /// (`store.update { $0.theme = .dark }`), and each field it sets is checked as when the file is read. A field
    /// given the value it had is no change and writes nothing.
    @discardableResult
    public func update(_ change: (inout EditedPreferences) -> Void) -> AppPreferences {
        locked { updateApp(change) }
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

    /// Removing a folder from Go To is something the user did on purpose. It leaves the folders chosen in Move To and
    /// Extract To too.
    @discardableResult
    public func forgetVisitedFolder(_ path: String) -> [VisitedFolder] {
        locked {
            let remaining = VisitedFolders.forget(visitedFolders, path: path)
            if remaining.count != visitedFolders.count {
                markUnsaved(.visits)
                saveSoon()
            }
            visitedFolders = remaining
            let destinations = VisitedFolders.forget(destinationFolders, path: path)
            if destinations.count != destinationFolders.count {
                markUnsaved(.destinations)
                saveSoon()
            }
            destinationFolders = destinations
            return remaining
        }
    }

    // MARK: Destination folders

    /// The folders that Move To and Extract To sent items into, ranked as the opened folders are.
    public func destinations() -> [VisitedFolder] {
        locked { destinationFolders }
    }

    /// A folder chosen in Move To or Extract To: each choice counts as a visit picked in the Go To box does.
    public func recordDestination(_ path: String, now: Double = AppClock.now.epochMilliseconds) {
        locked {
            let recorded = VisitedFolders.record(destinationFolders, path: path, kind: .goTo, now: now)
            if recorded == destinationFolders { return }
            destinationFolders = recorded
            markUnsaved(.destinations)
            saveLater()
        }
    }

    // MARK: Recent commands

    /// The commands run from the command palette, the last first.
    public func recentCommands() -> [String] {
        locked { commands }
    }

    /// A command run from the command palette: it comes first. Written with the next write, as the visited folders.
    public func recordCommand(_ id: String) {
        locked {
            let recorded = CommandPalette.remembering(id, in: commands)
            if recorded == commands { return }
            commands = recorded
            markUnsaved(.recentCommands)
            saveLater()
        }
    }

    // MARK: Folder views

    /// Every folder's view (View ▸ Folder View).
    public func folderViews() -> FolderViews {
        locked { views }
    }

    /// Changes the folders' views and returns them. A folder's view is saved on purpose (Update, Remember, a Keep box),
    /// so it is written soon; no change writes nothing.
    @discardableResult
    public func updateFolderViews(_ change: (inout FolderViews) -> Void) -> FolderViews {
        locked {
            var changed = views
            change(&changed)
            if changed != views {
                views = changed
                markUnsaved(.folderViews)
                saveSoon()
            }
            return views
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

    /// A change made in the window `windowID`, to the preferences as it sees them. The session keys it sets are the
    /// window's own; every key it sets also becomes the app's latest value, even one the window already had. For a
    /// window not known, the change is the app's alone.
    @discardableResult
    public func updateWindow(_ windowID: String, _ change: (inout EditedPreferences) -> Void) -> AppPreferences {
        locked {
            guard let window = windows.first(where: { Self.sameID($0.id, windowID) }) else { return updateApp(change) }
            let app = currentPreferences
            let seen = window.session.applied(to: app)
            let (next, written) = edit(seen, change)
            var preferences = app
            for key in written {
                preferences.take(key, from: next)
            }
            state.preferences = preferences
            let session = next.windowSession
            let windowKeys = next.keys(differingFrom: seen).filter(\.isWindowSessionKey)
            if !windowKeys.isEmpty {
                var changed = window
                changed.session = session
                replaceWindow(changed)
            }
            // The app's copy of a session key is only the last window's value: a window sending its own again, after
            // another window sent a different one, is no new choice.
            let appKeys = preferences.keys(differingFrom: app)
            saveChanges(
                windowKeys + appKeys.filter { !$0.isWindowSessionKey },
                following: appKeys.filter(\.isWindowSessionKey))
            return session.applied(to: preferences)
        }
    }

    /// A window's session as a new window would start it: the app's latest values, changed by `change` and checked as
    /// when the file is read.
    public func createWindowSession(_ change: (inout WindowSession) -> Void = { _ in }) -> WindowSession {
        locked { newWindowSession(change) }
    }

    /// Adds a window in front of the others. Only open windows are kept, so none is dropped to keep to
    /// `AppStateReader.windowsLimit`: that is for reading a damaged file.
    public func addExplorerWindow(id: String, bounds: StoredWindowState, session: WindowSession? = nil) {
        locked {
            let session = newWindowSession { if let session { $0 = session } }
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
            var moved = window
            moved.bounds = bounds
            replaceWindow(moved)
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

    // Ids are compared as strings of UTF-16 units; Swift's == would treat canonically equal ones as the same.
    private static func sameID(_ left: String, _ right: String) -> Bool {
        left.utf16.elementsEqual(right.utf16)
    }

    private func updateApp(_ change: (inout EditedPreferences) -> Void) -> AppPreferences {
        let current = currentPreferences
        let next = edit(current, change).preferences
        state.preferences = next
        saveChanges(next.keys(differingFrom: current))
        return next
    }

    // `preferences` changed by `change`, each field it set checked as when the file is read; and the keys it set.
    private func edit(_ preferences: AppPreferences, _ change: (inout EditedPreferences) -> Void)
        -> (preferences: AppPreferences, written: [PreferenceKey])
    {
        var edited = EditedPreferences(preferences)
        change(&edited)
        let checked = PreferencesSanitizer.sanitize(edited.written, of: edited.preferences, defaults: defaults)
        return (checked, edited.written)
    }

    // Saves the state file, soon when `keys` hold a deliberate change. `following` changed too, but never hurries it.
    private func saveChanges(_ keys: [PreferenceKey], following: [PreferenceKey] = []) {
        guard !keys.isEmpty || !following.isEmpty else { return }
        markUnsaved(.state)
        if keys.contains(where: { !Self.navigationKeys.contains($0) }) {
            saveSoon()
        } else {
            saveLater()
        }
    }

    private func newWindowSession(_ change: (inout WindowSession) -> Void) -> WindowSession {
        let app = currentPreferences
        var session = app.windowSession
        change(&session)
        return PreferencesSanitizer.sanitize(WindowSession.keys, of: session.applied(to: app), defaults: defaults)
            .windowSession
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
        cancelDeferredSave?()
        cancelDeferredSave = nil
        // One write takes in a burst of changes (a drag, repeated toggles), and the changes after it don't put it off.
        guard cancelPromptSave == nil else { return }
        var delay = Self.promptSaveDelayMilliseconds
        if let lastSaveAt {
            let wait = lastSaveAt + Double(Self.minimumSaveIntervalMilliseconds) - clock()
            delay = max(delay, Int(wait.rounded(.up)))
        }
        cancelPromptSave = timer.schedule(afterMilliseconds: delay) { [weak self] in
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
        // A file whose write failed stays unsaved: the next write, or the one at quit, tries it again.
        if unsavedFiles.contains(.visits), write(.visits, visitsFilePath, VisitedFolders.serialize(visitedFolders)) {
            unsavedFiles.remove(.visits)
        }
        if unsavedFiles.contains(.destinations),
            write(.destinations, destinationsFilePath, VisitedFolders.serialize(destinationFolders))
        {
            unsavedFiles.remove(.destinations)
        }
        if unsavedFiles.contains(.recentCommands),
            write(.recentCommands, recentCommandsFilePath, Self.serializeRecentCommands(commands))
        {
            unsavedFiles.remove(.recentCommands)
        }
        if unsavedFiles.contains(.folderViews) {
            setUnreadableFolderViewsAside()
            if write(.folderViews, folderViewsFilePath, views.serialize()) {
                unsavedFiles.remove(.folderViews)
            }
        }
        if unsavedFiles.contains(.state) {
            do {
                if write(.state, filePath, try AppStateJSON.serialize(state)) {
                    unsavedFiles.remove(.state)
                }
            } catch {
                onPersistError(error)
            }
        }
    }

    /// What a `folder-views.json` that couldn't be read is renamed to, beside it.
    static let unreadableSuffix = ".unreadable"

    /// A `folder-views.json` that couldn't be read gave no views, and the write to come holds only what was saved
    /// since: the file is renamed first (over one set aside before), so every folder's view in it can still be mended
    /// by hand. Where it can't be renamed that is reported, and the write goes ahead. A file that read, or wasn't
    /// there, costs nothing here.
    private func setUnreadableFolderViewsAside() {
        guard folderViewsFileUnreadable else { return }
        folderViewsFileUnreadable = false
        guard fileSystem.exists(folderViewsFilePath) else { return }
        do {
            try fileSystem.rename(folderViewsFilePath, folderViewsFilePath + Self.unreadableSuffix)
        } catch {
            onPersistError(error)
        }
    }

    /// Writes `file` unless its text is what was written last. Whether it is on disk as `text`.
    private func write(_ file: StoreFile, _ path: String, _ text: String) -> Bool {
        if writtenText[file] == text { return true }
        guard writeAtomically(path, text) else { return false }
        writtenText[file] = text
        lastSaveAt = clock()
        return true
    }

    // Write a sibling temp file and rename it over the target so a crash mid-write leaves the previous state intact
    // instead of a truncated file.
    /// Whether it was written.
    private func writeAtomically(_ path: String, _ contents: String) -> Bool {
        let temporary = path + ".tmp"
        do {
            try fileSystem.createDirectory((path as NSString).deletingLastPathComponent)
            try fileSystem.write(temporary, contents)
            try fileSystem.rename(temporary, path)
            return true
        } catch {
            onPersistError(error)
            return false
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

    private static func readFolderViews(
        _ path: String, _ fileSystem: any StateFileSystem, _ onReadError: @Sendable (any Error) -> Void
    ) -> (views: FolderViews, unreadable: Bool) {
        guard fileSystem.exists(path) else { return (FolderViews(), false) }
        do {
            return (try FolderViews.read(try fileSystem.read(path)), false)
        } catch {
            onReadError(error)
            return (FolderViews(), true)
        }
    }

    private static func readRecentCommands(
        _ path: String, _ fileSystem: any StateFileSystem, _ onReadError: @Sendable (any Error) -> Void
    ) -> [String] {
        guard fileSystem.exists(path) else { return [] }
        do {
            let parsed = try JSONSerialization.jsonObject(with: try fileSystem.read(path))
            return CommandPalette.sanitizeRecent((parsed as? [String: Any])?["commands"])
        } catch {
            onReadError(error)
            return []
        }
    }

    /// The file's text: one id to a line, as the visited folders are written.
    static func serializeRecentCommands(_ commands: [String]) -> String {
        let lines = commands.compactMap { id in
            (try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        return lines.isEmpty ? "{\"commands\":[]}\n" : "{\"commands\":[\n\(lines.joined(separator: ",\n"))\n]}\n"
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
    /// Whole milliseconds since 1970, rounded down.
    public var epochMilliseconds: Double { (timeIntervalSince1970 * 1000).rounded(.down) }
}
