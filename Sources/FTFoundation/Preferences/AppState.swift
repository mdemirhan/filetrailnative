// Port of the pure parts of apps/desktop/src/main/appStateStore.ts (:470-510, :1021-1098): reading a saved state, with
// its migrations. File I/O is the state store's.
import Foundation

/// A window's place and size; its position is optional.
public struct StoredWindowState: Codable, Equatable, Sendable {
    public var x: Double?
    public var y: Double?
    public var width: Double
    public var height: Double
    public var maximized: Bool

    public init(x: Double? = nil, y: Double? = nil, width: Double, height: Double, maximized: Bool) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.maximized = maximized
    }

    /// DEFAULT_WINDOW_STATE.
    public static let `default` = StoredWindowState(width: 1200, height: 760, maximized: false)
}

/// An explorer window as it is brought back at the next launch.
public struct StoredExplorerWindow: Codable, Equatable, Sendable {
    public var id: String
    public var bounds: StoredWindowState
    public var session: WindowSession

    public init(id: String, bounds: StoredWindowState, session: WindowSession) {
        self.id = id
        self.bounds = bounds
        self.session = session
    }
}

/// The contents of `app-state.json`.
public struct AppState: Codable, Equatable, Sendable {
    public var preferences: AppPreferences?
    /// Front to back.
    public var windows: [StoredExplorerWindow]?
    /// The window closed last, with only the tab that was in front: where a window opened with none open starts (and
    /// the app, when it quit with no window open).
    public var lastClosedWindow: StoredExplorerWindow?

    public init(
        preferences: AppPreferences? = nil, windows: [StoredExplorerWindow]? = nil,
        lastClosedWindow: StoredExplorerWindow? = nil
    ) {
        self.preferences = preferences
        self.windows = windows
        self.lastClosedWindow = lastClosedWindow
    }
}

public enum AppStateReader {
    /// STORED_EXPLORER_WINDOWS_LIMIT: no more windows are read back than anyone keeps open; a damaged file can't make
    /// more.
    public static let windowsLimit = 50

    /// The id the one window saved before there were several is given.
    public static let legacyWindowID = "window-1"

    /// `readState` once the file is parsed: loading is best-effort, corrupt state never blocks startup. The result is
    /// empty for anything that is not an object; a file that is not JSON is the caller's to treat the same way
    /// (`read(data:)` throws for it).
    public static func read(
        _ parsed: JSONNode, defaults: AppPreferences, batchRename: BatchRenameSanitizers = .passthrough
    ) -> AppState {
        guard let file = parsed.object else { return AppState() }
        let preferences = PreferencesSanitizer.sanitize(
            file["preferences"], defaults: defaults, batchRename: batchRename)
        let lastClosedWindow = sanitizeWindows(
            JSONNode.array([file["lastClosedWindow"] ?? .null]), preferences: preferences, batchRename: batchRename
        )?.first
        let windows: [StoredExplorerWindow]
        if let saved = sanitizeWindows(file["windows"], preferences: preferences, batchRename: batchRename) {
            windows = saved
        } else if lastClosedWindow != nil {
            // A file with a window closed last was saved with several windows, and has lost its list of them: one
            // window opens, as the window closed last ended.
            windows = []
        } else {
            // Saved before there could be more than one window: the one window, with the tabs and panels the
            // preferences held.
            windows = [
                StoredExplorerWindow(
                    id: legacyWindowID, bounds: windowState(file["window"]), session: preferences.windowSession)
            ]
        }
        return AppState(preferences: preferences, windows: windows, lastClosedWindow: lastClosedWindow)
    }

    /// `readState` for the file's bytes: throws when they are not JSON.
    public static func read(
        data: Data, defaults: AppPreferences, batchRename: BatchRenameSanitizers = .passthrough
    ) throws -> AppState {
        read(try JSONNode.parse(data), defaults: defaults, batchRename: batchRename)
    }

    /// `sanitizeExplorerWindows`: the saved windows, or nil when the file has no list of them (it was saved before there
    /// could be several). A window that doesn't make sense is dropped; one whose session is missing a value takes the
    /// app's.
    static func sanitizeWindows(
        _ value: JSONNode?, preferences: AppPreferences, batchRename: BatchRenameSanitizers
    ) -> [StoredExplorerWindow]? {
        guard let candidates = value?.array else { return nil }
        var windows: [StoredExplorerWindow] = []
        for candidate in candidates {
            guard let record = candidate.object, let id = record["id"]?.string, !id.isEmpty,
                !windows.contains(where: { JSString.equals($0.id, id) })
            else { continue }
            let saved = record["session"]?.object ?? [:]
            let merged = PreferencesSanitizer.apply(
                WindowSessionKeys.pick(saved), to: preferences, defaults: preferences, batchRename: batchRename)
            var session = merged.windowSession
            session.activeTabIndex = session.frontTabIndex
            windows.append(StoredExplorerWindow(id: id, bounds: windowState(record["bounds"]), session: session))
            if windows.count == windowsLimit {
                break
            }
        }
        return windows
    }

    /// `sanitizeWindowState`: the position is optional, but the size is always put into a safe range.
    public static func windowState(_ value: JSONNode?) -> StoredWindowState {
        guard let record = value?.object else { return .default }
        func size(_ key: String, _ fallback: Double) -> Double {
            if let number = record[key]?.number, number >= 320, number <= 6000 {
                return number
            }
            return fallback
        }
        return StoredWindowState(
            x: record["x"]?.number, y: record["y"]?.number,
            width: size("width", StoredWindowState.default.width),
            height: size("height", StoredWindowState.default.height), maximized: record["maximized"]?.bool == true)
    }
}

extension WindowSessionKeys {
    /// `pickWindowSession` given a patch: the session keys of `value`.
    public static func pick(_ value: [String: JSONNode]) -> [String: JSONNode] {
        value.filter { isSessionKey($0.key) }
    }
}

extension PreferencesSanitizer {
    /// `sanitizePreferences({ ...current, ...patch }, defaults)`: a change applied to preferences. A patch value that
    /// is not valid for its key gives the key's default from `defaults`, as in the original's `updatePreferences`.
    public static func apply(
        _ patch: [String: JSONNode], to current: AppPreferences, defaults: AppPreferences,
        batchRename: BatchRenameSanitizers = .passthrough
    ) -> AppPreferences {
        var record = (try? JSONNode.of(current))?.object ?? [:]
        for (key, value) in patch {
            record[key] = value
        }
        return sanitize(.object(record), defaults: defaults, batchRename: batchRename)
    }
}
