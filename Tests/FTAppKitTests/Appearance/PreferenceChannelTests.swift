// The preference channel the app makes (F-610, B-DLG-233, B-DLG-245): a change of theme or accent made in any window
// reaches the appearance, and with it every window that draws with it
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct PreferenceChannelTests {
    private struct Heard {
        var preferences: AppPreferences
        var change: PreferencesChange
    }

    // F-610 B-DLG-233: the theme and accent chosen in a window are stored, and the appearance follows
    @Test func aChangeOfThemeAndAccentReachesTheAppearance() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        let model = AppearanceModel(
            theme: .light, accent: "#007aff", systemPrefersDark: { false }, setNativeAppearance: { _ in })
        var observed: [Theme] = []
        let observation = model.observe { observed.append($0) }
        var heard: [Heard] = []
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil },
            onPreferencesChanged: { preferences, change in
                heard.append(Heard(preferences: preferences, change: change))
                model.preferencesChanged(preferences, change)
            })

        let preferences = channel.update(["theme": .string("dark"), "accent": .string("#a550a7")], from: nil)

        #expect(preferences.theme == .dark)
        #expect(store.preferences().accent == "#a550a7")
        #expect(heard.count == 1)
        #expect(model.theme.appearance == .dark)
        #expect(model.accentHex == "#a550a7")
        #expect(observed.count == 1)
        observation.cancel()
    }

    // F-610: a change a window makes of its own session is not the whole app's
    @Test func aChangeOfTheWindowsOwnSessionIsNotToldToTheApp() throws {
        _ = NSApplication.shared
        let store = try makeStore()
        var heard: [PreferencesChange] = []
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil }, onPreferencesChanged: { _, change in heard.append(change) })
        channel.update(["theme": .string("light"), "treeWidth": .number(300)], from: 7)
        #expect(heard.first?.senderID == 7)
        #expect(heard.first?.patch["theme"] == .string("light"))
        #expect(heard.first?.patch["treeWidth"] == nil)
        let model = AppearanceModel(
            theme: .dark, accent: "#007aff", systemPrefersDark: { false }, setNativeAppearance: { _ in })
        // An unrelated change leaves the look alone.
        model.preferencesChanged(store.preferences(), PreferencesChange(patch: ["treeWidth": .number(300)], senderID: nil))
        #expect(model.theme.appearance == .dark)
    }

    // B-DLG-245 F-610: a window that only follows (About, Help, Acknowledgements) is redrawn with the new theme
    @Test func aPageWindowIsRedrawnWithANewThemeAndAccent() {
        _ = NSApplication.shared
        let model = AppearanceModel(
            theme: .light, accent: "#007aff", systemPrefersDark: { false }, setNativeAppearance: { _ in })
        let controller = AboutWindowController(
            info: AboutInfo(version: "1", commit: nil, macosVersion: "27.0", architecture: "Apple silicon", fdVersion: "10"),
            actions: AboutActions(), model: model)
        let view = controller.aboutView
        #expect(view.theme.appearance == .light)

        model.apply(theme: .dark, accent: "#f74f9e")

        #expect(view.theme.appearance == .dark)
        #expect(view.copyButton.theme.accent.solid.hexString == "#f74f9e")
        #expect(view.copyButton.theme.palette == ThemePalette.dark)
        #expect(controller.window?.backgroundColor == NSColor(model.theme.pageWindowBackground))
    }
}
