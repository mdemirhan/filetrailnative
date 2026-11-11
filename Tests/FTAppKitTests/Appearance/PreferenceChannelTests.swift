// The preference channel the app makes: a change of theme or accent made in any window
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

    // The theme and accent chosen in a window (the toolbar's Theme menu, Settings) are
    // stored, and the appearance follows
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

        let preferences = channel.update(from: nil) {
            $0.theme = .dark
            $0.accent = "#a550a7"
        }

        #expect(preferences.theme == .dark)
        #expect(store.preferences().accent == "#a550a7")
        #expect(heard.count == 1)
        #expect(model.theme.appearance == .dark)
        #expect(model.accentHex == "#a550a7")
        #expect(observed.count == 1)
        observation.cancel()
    }

    // Every window is told the keys a change set that the whole app shares, a key set to the value it had among them;
    // a window's own keys are not told, and a change of those alone is still told, with no keys
    @Test func tellsTheSharedKeysSetEvenWithTheValueTheyHad() throws {
        let store = try makeStore()
        var heard: [PreferencesChange] = []
        let channel = WindowPreferenceChannel(
            store: store, explorerWindowID: { _ in nil }, onPreferencesChanged: { heard.append($1) })
        let theme = store.preferences().theme
        channel.update(from: 3) {
            $0.theme = theme
            $0.treeWidth = 300
            $0.markClipboardItems = false
        }
        channel.update(from: nil) { $0.viewMode = .list }
        #expect(
            heard == [
                PreferencesChange(keys: [.theme, .markClipboardItems], senderID: 3),
                PreferencesChange(keys: [], senderID: nil),
            ])
    }

    // A window that only follows (About, Help, Acknowledgements) is redrawn with the new theme
    @Test func aPageWindowIsRedrawnWithANewThemeAndAccent() {
        _ = NSApplication.shared
        let model = AppearanceModel(
            theme: .light, accent: "#007aff", systemPrefersDark: { false }, setNativeAppearance: { _ in })
        let controller = AboutWindowController(
            info: AboutInfo(
                version: "1", commit: nil, macosVersion: "27.0", architecture: "Apple silicon", fdVersion: "10"),
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
