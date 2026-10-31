// Port of the state of apps/desktop/src/renderer/SettingsWindowApp.tsx: the preferences the window edits, the pickers it
// opens, and how its edits are saved (usePreferencesSync)
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
    /// Runs a closure after a delay in milliseconds; the returned closure cancels it.
    var schedule: PreferencesSync.Schedule = { milliseconds, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + milliseconds / 1000, execute: item)
        return { item.cancel() }
    }

    init() {}
}

/// The preferences as the Settings window shows them, and the edits it makes. Each edit is saved through
/// `PreferencesSync` (only the keys that changed, 300 ms after the last), and told to the views.
@MainActor
final class SettingsStore {
    private(set) var preferences: AppPreferences
    let homePath: String
    let sync: PreferencesSync
    /// Pinned apps that aren't where they were: flagged in the list.
    private(set) var missingOpenWithAppPaths: Set<String> = []
    /// The views follow.
    var onChange: () -> Void = {}

    init(
        preferences: AppPreferences, homePath: String, write: @escaping PreferencesSync.Write,
        schedule: @escaping PreferencesSync.Schedule
    ) {
        self.preferences = preferences
        self.homePath = homePath
        sync = PreferencesSync(write: write, schedule: schedule)
        // The values loaded on start count as synced.
        sync.markSynced(SettingsValues.payload(preferences))
    }

    /// An edit made here.
    func update(_ change: (inout AppPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        sync.changed(SettingsValues.payload(next))
        onChange()
    }

    /// An edit made in another window: applied here, never written back.
    func remote(_ patch: PreferencesPatch) {
        let shared = sync.remote(patch.filter { SettingsValues.payloadKeys.contains($0.key) })
        guard !shared.isEmpty else { return }
        preferences = SettingsValues.applying(shared, to: preferences)
        sync.changed(SettingsValues.payload(preferences))
        onChange()
    }

    func setMissingApps(_ paths: Set<String>) {
        guard paths != missingOpenWithAppPaths else { return }
        missingOpenWithAppPaths = paths
        onChange()
    }
}
