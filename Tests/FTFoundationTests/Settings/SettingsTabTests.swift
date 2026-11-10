import Testing

@testable import FTFoundation

struct SettingsTabTests {
    @Test func readsTheTabASettingsWindowIsOnFromItsAddress() {
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/files") == .files)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/shortcuts") == .shortcuts)
    }

    @Test func findsNoTabInAnAddressWithoutOneOrWithOneSettingsDoesNotHave() {
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/rails") == nil)
        // The toolbar is customized in the window now, not in Settings.
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/toolbars") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#about") == nil)
    }

    // A change from another window with one value that isn't valid still brings the others; that one takes its
    // default, as in the app's store.
    @Test func aChangeWithOneBadValueStillAppliesTheOthers() {
        var preferences = AppPreferences.defaults()
        preferences.openItemLimit = 9
        let next = SettingsValues.applying(
            ["theme": .string("dark"), "openItemLimit": .string("many")], to: preferences)
        #expect(next.theme == .dark)
        #expect(next.openItemLimit == AppPreferences.defaults().openItemLimit)
    }
}
