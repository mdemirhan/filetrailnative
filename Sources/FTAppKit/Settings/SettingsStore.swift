// The preferences the window edits, the pickers it opens, and how its edits are saved
import AppKit
import FTFileSystem
import FTFoundation

/// What Settings asks of the app: the system's pickers and the check for pinned apps that are gone. Each picker answers
/// nil when it was cancelled, and throws when it could not be shown.
@MainActor
struct SettingsServices {
    var pickApplication: (NSWindow?) async throws -> ApplicationSelection? = { window in
        let choice = await SystemPickers.pickApplication(window: window)
        guard !choice.canceled, let path = choice.appPath, let name = choice.appName else { return nil }
        return ApplicationSelection(appPath: path, appName: name)
    }
    var pickDirectory: (String?, NSWindow?) async throws -> String? = { defaultPath, window in
        let choice = await SystemPickers.pickDirectory(defaultPath: defaultPath, window: window)
        return choice.canceled ? nil : choice.path
    }
    /// The pinned apps that are not where they were.
    var missingApps: ([String]) async -> Set<String> = { paths in
        let lookup = await SystemActions.openWithApplications(paths: [], pinnedAppPaths: paths)
        return Set(
            paths.enumerated().filter {
                !lookup.pinnedApps.indices.contains($0.offset) || lookup.pinnedApps[$0.offset] == nil
            }.map(\.element))
    }
    init() {}
}

/// The app's preferences as Settings reads and changes them: `read` gives them as they are now (nil when they can't be
/// read), `update` changes them, and every window is told.
@MainActor
struct SettingsPreferences {
    var read: () -> AppPreferences?
    var update: (_ change: (inout AppPreferences) -> Void) -> Void
}

/// The preferences as the Settings window shows them, and the edits it makes. Each edit changes the app's preferences
/// at once, which the other windows are told of and the state store writes; the views follow.
@MainActor
final class SettingsStore {
    /// The app's preferences as last read or changed here.
    private(set) var preferences: AppPreferences
    let homePath: String
    private let shared: SettingsPreferences
    /// Pinned apps that aren't where they were: flagged in the list.
    private(set) var missingOpenWithAppPaths: Set<String> = []
    /// The views follow.
    var onChange: () -> Void = {}

    init(preferences: AppPreferences, homePath: String, shared: SettingsPreferences) {
        self.preferences = preferences
        self.homePath = homePath
        self.shared = shared
    }

    /// An edit made here: the app's preferences change, and the views follow. The edit runs on this copy, to see
    /// whether it changes anything, and again on the app's; what is shown is the app's, as an edit that makes something
    /// new each time it runs (a pinned app's id) leaves the two copies different. The app tells this window of the edit
    /// as it is made (`reload`), and the views follow once.
    func update(_ change: (inout AppPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        shared.update(change)
        let current = shared.read() ?? next
        guard current != preferences else { return }
        preferences = current
        onChange()
    }

    /// The app's preferences changed, here or in another window: shown as they are now. Nothing is written.
    func reload() {
        guard let current = shared.read(), current != preferences else { return }
        preferences = current
        onChange()
    }

    func setMissingApps(_ paths: Set<String>) {
        guard paths != missingOpenWithAppPaths else { return }
        missingOpenWithAppPaths = paths
        onChange()
    }
}
