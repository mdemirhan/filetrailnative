// The Settings window shows what the app keeps after an edit, even when the edit makes something new each time it
// runs, such as a pinned app's id
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SettingsStoreTests {
    @Test func showsWhatTheAppKeptAfterAnEdit() {
        var app = AppPreferences.defaults(theme: .light)
        let shared = SettingsPreferences(read: { app }, update: { change in change(&app) })
        let store = SettingsStore(preferences: app, homePath: "", shared: shared)
        var made = 0
        store.update { preferences in
            made += 1
            preferences.openWithApplications.append(
                OpenWithApplication(id: "app-\(made)", appPath: "/Applications/A.app", appName: "A"))
        }
        #expect(store.preferences == app)
        #expect(store.preferences.openWithApplications.map(\.id) == app.openWithApplications.map(\.id))
    }

    @Test func anEditThatChangesNothingIsNotSent() {
        var app = AppPreferences.defaults(theme: .light)
        var sent = 0
        let shared = SettingsPreferences(
            read: { app },
            update: { change in
                sent += 1
                change(&app)
            })
        let store = SettingsStore(preferences: app, homePath: "", shared: shared)
        store.update { $0.theme = app.theme }
        #expect(sent == 0)
    }
}
