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

    // The app tells every window of an edit as it is made, Settings included, which reads it back: the page is
    // refreshed once for it, not again when the edit returns.
    @Test func refreshesThePageOnceForAnEdit() {
        var app = AppPreferences.defaults(theme: .light)
        weak var heard: SettingsStore?
        let shared = SettingsPreferences(
            read: { app },
            update: { change in
                change(&app)
                heard?.reload()
            })
        let store = SettingsStore(preferences: app, homePath: "", shared: shared)
        heard = store
        var refreshes = 0
        store.onChange = { refreshes += 1 }
        store.update { $0.theme = .dark }
        #expect(refreshes == 1)
        #expect(store.preferences.theme == .dark)
    }
}
