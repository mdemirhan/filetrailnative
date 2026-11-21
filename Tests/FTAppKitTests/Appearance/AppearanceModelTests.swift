import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct AppearanceModelTests {
    /// What macOS says, and what the model told the app's native parts.
    @MainActor
    final class System {
        var dark = false
        var native: [ThemePreference] = []
        /// The accent of System Settings, as the lookup tells it.
        var accent = "#007aff"
    }

    private func make(
        theme: ThemePreference = .auto, accent: String = "#007aff", _ system: System = System()
    ) -> (AppearanceModel, System) {
        _ = NSApplication.shared
        let model = AppearanceModel(
            theme: theme, accent: accent, systemPrefersDark: { system.dark }, systemAccent: { system.accent },
            setNativeAppearance: { system.native.append($0) })
        return (model, system)
    }

    @Test func paintsLightOrDarkAsChosenAndFollowsMacOSOnAuto() {
        let (model, system) = make()
        #expect(model.theme.appearance == .light)

        model.apply(theme: .dark)
        #expect(model.theme.appearance == .dark)
        model.apply(theme: .light)
        #expect(model.theme.appearance == .light)
        // Auto follows macOS, live: a change of macOS is followed while it is on.
        model.apply(theme: .auto)
        #expect(model.theme.appearance == .light)
        system.dark = true
        model.systemAppearanceChanged()
        #expect(model.theme.appearance == .dark)
        system.dark = false
        model.systemAppearanceChanged()
        #expect(model.theme.appearance == .light)
        // The native parts were told each change of the preference: Light and Dark pin them, Auto lets them follow.
        #expect(system.native == [.dark, .light, .auto])
    }

    @Test func ignoresMacOSWhileLightOrDarkIsChosen() {
        let (model, system) = make(theme: .light)
        var told: [Theme] = []
        let observation = model.observe { told.append($0) }
        system.dark = true
        model.systemAppearanceChanged()
        #expect(model.theme.appearance == .light)
        #expect(told.isEmpty)
        observation.cancel()
    }

    @Test func picksTheThemesPaletteAndAppliesTheAccent() {
        let (model, _) = make()
        model.apply(theme: .dark, accent: "#2CB5A0")
        let theme = model.theme
        #expect(theme.appearance == .dark)
        #expect(theme.accentHex == "#2cb5a0")
        #expect(theme.palette == ThemePalette.dark)
        #expect(theme.accent == AccentPalette(hex: "#2cb5a0", appearance: .dark))
        #expect(theme.accent.solid == RGBA(hex: "#2cb5a0"))
        #expect(model.preference == .dark)
    }

    // One accent everywhere, and no color of the palette follows it
    @Test func usesOneAccentEverywhere() {
        let red = Theme(appearance: .light, accentHex: "#e8729a")
        let blue = Theme(appearance: .light, accentHex: "#007aff")
        #expect(red.palette == blue.palette)
        #expect(red.accent != blue.accent)
        #expect(red.accent.solid.hexString == "#e8729a")
    }

    // The accents to choose from, and each one is painted as itself
    @Test func paintsEachAccentOptionAsItself() {
        #expect(
            AppPreferenceLimits.accentOptions.map(\.label) == [
                "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Graphite", "Copper",
            ])
        #expect(AppPreferenceLimits.accentOptions.first?.value == AppPreferenceLimits.blueAccent)
        for option in AppPreferenceLimits.accentOptions {
            #expect(Theme(appearance: .light, accentHex: option.value).accent.solid.hexString == option.value)
        }
    }

    // A picked color is accepted only as #rrggbb, trimmed and kept in lower case
    @Test func acceptsAPickedAccentOnlyAsAHexColor() {
        let (model, _) = make()
        model.apply(accent: " #D84A4A ")
        #expect(model.accentHex == "#d84a4a")
        for rejected in ["", "red", "d84a4a", "#d84a4", "#d84a4a5", "rgb(1,2,3)", "#ggg000"] {
            model.apply(accent: rejected)
            #expect(model.accentHex == "#d84a4a", "\(rejected)")
        }
        // A model started with a bad accent has the default one, System.
        let system = System()
        system.accent = "#f7821b"
        let (other, _) = make(accent: "nonsense", system)
        #expect(other.accent == AppPreferenceLimits.defaultAccent)
        #expect(other.accentHex == "#f7821b")
    }

    // System paints the accent of System Settings, follows it when it changes, and leaves a chosen color alone
    @Test func paintsTheSystemAccentAndFollowsItsChanges() {
        let system = System()
        system.accent = "#a550a7"
        let (model, _) = make(accent: " System ", system)
        #expect(model.accent == "system")
        #expect(model.accentHex == "#a550a7")
        #expect(model.theme.accentHex == "#a550a7")
        #expect(model.theme.accent == AccentPalette(hex: "#a550a7", appearance: .light))
        var told: [Theme] = []
        let observation = model.observe { told.append($0) }
        system.accent = "#62ba46"
        model.systemAccentChanged()
        #expect(model.accentHex == "#62ba46")
        #expect(told.map(\.accentHex) == ["#62ba46"])
        // Nothing changed: no one is told.
        model.systemAccentChanged()
        #expect(told.count == 1)
        // A chosen color stays as it is when System Settings changes; System shows what it would paint.
        model.apply(accent: "#e0383e")
        system.accent = "#ffc600"
        model.systemAccentChanged()
        #expect(model.accentHex == "#e0383e")
        #expect(model.systemAccentHex == "#ffc600")
        // Back to System, it is the accent System Settings has now.
        model.apply(accent: "system")
        #expect(model.accentHex == "#ffc600")
        // A lookup that gives no color paints the app's blue.
        system.accent = "nonsense"
        model.systemAccentChanged()
        #expect(model.accentHex == "#007aff")
        observation.cancel()
    }

    // The system's accent is looked up only once the app asks for it, and then followed when macOS says its colors
    // changed; until then System is the app's blue, so tests and scripted runs paint the same on every Mac
    @Test func followsTheSystemAccentOnlyOnceAskedAndOnMacOSNotice() {
        _ = NSApplication.shared
        let unasked = AppearanceModel(
            theme: .light, accent: "system", systemPrefersDark: { false }, setNativeAppearance: { _ in })
        #expect(unasked.accentHex == "#007aff")
        #expect(unasked.systemAccentHex == "#007aff")

        let system = System()
        system.accent = "#e0383e"
        let center = NotificationCenter()
        unasked.followSystemAccent({ system.accent }, center: center)
        #expect(unasked.accentHex == "#e0383e")
        system.accent = "#8c8c8c"
        center.post(name: NSColor.systemColorsDidChangeNotification, object: nil)
        #expect(unasked.accentHex == "#8c8c8c")
    }

    // The accent of System Settings is read as #rrggbb, whatever the app's theme
    @Test func readsTheMacOSAccentAsAHexColor() {
        _ = NSApplication.shared
        let hex = AppearanceModel.macOSAccentHex()
        #expect(AppPreferenceLimits.normalizeAccentColor(hex) == hex)
        var dark = ""
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = AppearanceModel.macOSAccentHex() }
        #expect(dark == hex)
    }

    // The tokens derived from the accent: pill text in a deep shade 18% darker in the light theme, a 30% border,
    // alphas that differ for light and dark
    @Test func derivesTheAccentTokensFromTheAccentColor() {
        let light = Theme(appearance: .light, accentHex: "#007aff").accent
        let dark = Theme(appearance: .dark, accentHex: "#007aff").accent
        #expect(light.border.alpha == 0.3)
        #expect(light.folderTint.alpha == 0.16)
        #expect(dark.folderTint.alpha == 0.14)
    }

    // The default button is the accent with white text, or black text on a light accent
    @Test func drawsTheDefaultButtonWithTheAccentAndReadableText() {
        let blue = Theme(appearance: .light, accentHex: "#007aff")
        let button = SystemButton(title: "OK", theme: blue)
        button.isDefault = true
        #expect(button.bezelColor == NSColor(blue.accent.solidButton))
        #expect(blue.accent.onSolid == .white)
        #expect(button.titleColor == nil)
        // Disabled, it has the system's own look, tint and title.
        button.isEnabled = false
        #expect(button.bezelColor == nil)
        #expect(button.titleColor == nil)
        button.isEnabled = true
        #expect(button.bezelColor == NSColor(blue.accent.solidButton))
        let yellow = Theme(appearance: .light, accentHex: "#ffc600")
        #expect(yellow.accent.onSolid == .black)
        #expect(yellow.accent.solidButton == yellow.accent.solid)
        button.applyTheme(yellow)
        #expect(button.titleColor == .black)
        button.isDefault = false
        #expect(button.bezelColor == nil)
        #expect(button.titleColor == nil)
    }

    @Test func putsEveryAppearanceSettingBackAsANewInstallHasIt() {
        let system = System()
        system.accent = "#f74f9e"
        let (model, _) = make(theme: .dark, accent: "#d84a4a", system)
        model.apply(.defaults())
        #expect(model.preference == AppPreferences.defaults().theme)
        #expect(model.accent == AppPreferences.defaults().accent)
        #expect(model.preference == .auto)
        #expect(model.accent == "system")
        #expect(model.accentHex == "#f74f9e")
    }

    // The preference channel's change reaches the appearance only for the theme and the accent
    @Test func followsTheThemeAndAccentOfAPreferenceChange() {
        let (model, _) = make()
        var preferences = AppPreferences.defaults()
        preferences.theme = .dark
        preferences.accent = "#a550a7"
        model.preferencesChanged(preferences, PreferencesChange(keys: [.viewMode], senderID: 1))
        #expect(model.preference == .auto)
        model.preferencesChanged(
            preferences,
            PreferencesChange(keys: [.theme, .accent], senderID: nil))
        #expect(model.theme.appearance == .dark)
        #expect(model.accentHex == "#a550a7")
    }

    // Every window that observes is told once for a change, and not for none
    @Test func tellsEveryObserverOnceAndOnlyWhenTheLookChanged() {
        let (model, _) = make()
        var first: [Theme] = []
        var second: [Theme] = []
        let one = model.observe { first.append($0) }
        let two = model.observe { second.append($0) }
        model.apply(theme: .dark, accent: "#f74f9e")
        model.apply(theme: .dark, accent: "#f74f9e")
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first.first?.accentHex == "#f74f9e")
        one.cancel()
        model.apply(theme: .light)
        #expect(first.count == 1)
        #expect(second.count == 2)
        two.cancel()
    }

    // Windows other than explorer windows get the background, explorer windows none
    @Test func givesPageWindowsAnOpaqueBackgroundAndLeavesExplorerWindowsAlone() {
        let (model, _) = make(theme: .light)
        let page = makeOffscreenWindow()
        let explorer = makeOffscreenWindow()
        let before = explorer.backgroundColor
        model.register(pageWindow: page)
        #expect(page.backgroundColor == NSColor(RGBA(hex: "#f4f5f8") ?? .white))
        model.apply(theme: .dark)
        #expect(page.backgroundColor == NSColor(RGBA(hex: "#161618") ?? .black))
        model.apply(theme: .light)
        #expect(page.backgroundColor == NSColor(RGBA(hex: "#f4f5f8") ?? .white))
        #expect(explorer.backgroundColor == before)
        #expect(Theme(appearance: .dark, accentHex: "#007aff").pageWindowBackground.hexString == "#161618")
        #expect(Theme(appearance: .light, accentHex: "#007aff").pageWindowBackground.hexString == "#f4f5f8")
    }

    // Everything is drawn in the system font
    @Test func drawsEverythingInTheSystemFont() {
        #expect(ThemeFonts.sans(13) == NSFont.systemFont(ofSize: 13))
        #expect(ThemeFonts.sans(13, .semibold) == NSFont.systemFont(ofSize: 13, weight: .semibold))
        #expect(ThemeFonts.mono(12) == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }
}
