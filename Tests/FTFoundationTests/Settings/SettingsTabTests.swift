import Testing

@testable import FTFoundation

struct SettingsTabTests {

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
