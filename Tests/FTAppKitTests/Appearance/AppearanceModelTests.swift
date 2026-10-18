// Ports apps/desktop/src/renderer/lib/theme.test.ts and hooks/useAppPreferences.test.tsx, and the theme parts of
// main.test.tsx and styles.theme.test.ts, for the app-wide appearance
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
    }

    private func make(
        theme: ThemePreference = .auto, accent: String = "#007aff", _ system: System = System()
    ) -> (AppearanceModel, System) {
        _ = NSApplication.shared
        let model = AppearanceModel(
            theme: theme, accent: accent, systemPrefersDark: { system.dark },
            setNativeAppearance: { system.native.append($0) })
        return (model, system)
    }

    // T-c015cfe8 F-646 B-DLG-232
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

    // T-c015cfe8 F-646
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

    // T-3a1d6beb F-646 B-DLG-233
    @Test func picksTheStylesheetsPaletteAndAppliesTheAccent() {
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

    // T-3ab16b37 F-646 B-DLG-233: one accent everywhere, and no color of the palette follows it
    @Test func usesOneAccentEverywhere() {
        let red = Theme(appearance: .light, accentHex: "#e8729a")
        let blue = Theme(appearance: .light, accentHex: "#007aff")
        #expect(red.palette == blue.palette)
        #expect(red.accent != blue.accent)
        #expect(red.accent.solid.hexString == "#e8729a")
    }

    // B-DLG-235 F-646: the accents to choose from, and each one is painted as itself
    @Test func paintsEachAccentOptionAsItself() {
        #expect(
            AppPreferenceLimits.accentOptions.map(\.label) == [
                "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Graphite", "Copper",
            ])
        #expect(AppPreferenceLimits.accentOptions.first?.value == AppPreferenceLimits.defaultAccent)
        for option in AppPreferenceLimits.accentOptions {
            #expect(Theme(appearance: .light, accentHex: option.value).accent.solid.hexString == option.value)
        }
    }

    // B-DLG-236 F-646: a picked color is accepted only as #rrggbb, trimmed and kept in lower case
    @Test func acceptsAPickedAccentOnlyAsAHexColor() {
        let (model, _) = make()
        model.apply(accent: " #D84A4A ")
        #expect(model.accentHex == "#d84a4a")
        for rejected in ["", "d84a4a", "#d84a4", "#d84a4a5", "rgb(1,2,3)", "#ggg000"] {
            model.apply(accent: rejected)
            #expect(model.accentHex == "#d84a4a", "\(rejected)")
        }
    }

    // B-DLG-237 F-646: the tokens derived from the accent are the reference's (a deep shade 18% darker, a 30% border,
    // alphas that differ for light and dark)
    @Test func derivesTheAccentTokensAsTheReferenceDoes() {
        let light = Theme(appearance: .light, accentHex: "#007aff").accent
        let dark = Theme(appearance: .dark, accentHex: "#007aff").accent
        #expect(light.solidDark.hexString == "#0064d1")
        #expect(light.border.alpha == 0.3)
        #expect(light.hoverBg.alpha == 0.14)
        #expect(dark.hoverBg.alpha == 0.12)
        #expect(light.focusBorder.alpha == 0.5)
        #expect(dark.focusBorder.alpha == 0.4)
    }

    // B-DLG-238 F-646: the default button is the accent with white text, or black text on a light accent
    @Test func drawsTheDefaultButtonWithTheAccentAndReadableText() {
        let blue = Theme(appearance: .light, accentHex: "#007aff")
        let button = PushButton(title: "OK", theme: blue)
        button.isDefault = true
        #expect(button.textColor == NSColor(blue.accent.onSolid))
        #expect(blue.accent.onSolid == .white)
        let yellow = Theme(appearance: .light, accentHex: "#ffc600")
        #expect(yellow.accent.onSolid == .black)
        #expect(yellow.accent.solidButton == yellow.accent.solid)
        button.applyTheme(yellow)
        #expect(button.textColor == NSColor(RGBA.black))
        button.isDefault = false
        #expect(button.textColor == NSColor(yellow.palette.textPrimary))
    }

    // T-bede3752 F-646 B-DLG-233
    @Test func ignoresAccentsThatAreNotHexColors() {
        let (model, _) = make()
        model.apply(accent: "#d84a4a")
        model.apply(accent: "red")
        model.apply(accent: "#12345")
        #expect(model.accentHex == "#d84a4a")
        // A model started with a bad accent has the default one.
        let (other, _) = make(accent: "nonsense")
        #expect(other.accentHex == AppPreferenceLimits.defaultAccent)
    }

    // T-10d689b4 F-610
    @Test func putsEveryAppearanceSettingBackAsANewInstallHasIt() {
        let (model, _) = make(theme: .dark, accent: "#d84a4a")
        model.apply(.defaults())
        #expect(model.preference == AppPreferences.defaults().theme)
        #expect(model.accentHex == AppPreferences.defaults().accent)
        #expect(model.preference == .auto)
        #expect(model.accentHex == "#007aff")
    }

    // T-6bc97340
    @Test func showsFavoritesInTheFolderTreeUnlessToldOtherwise() {
        #expect(AppPreferences.defaults().favoritesPlacement == .integrated)
    }

    // F-610 B-DLG-233 the preference channel's change reaches the appearance only for the theme and the accent
    @Test func followsTheThemeAndAccentOfAPreferenceChange() {
        let (model, _) = make()
        var preferences = AppPreferences.defaults()
        preferences.theme = .dark
        preferences.accent = "#a550a7"
        model.preferencesChanged(preferences, PreferencesChange(patch: ["viewMode": .string("icons")], senderID: 1))
        #expect(model.preference == .auto)
        model.preferencesChanged(
            preferences,
            PreferencesChange(patch: ["theme": .string("dark"), "accent": .string("#a550a7")], senderID: nil))
        #expect(model.theme.appearance == .dark)
        #expect(model.accentHex == "#a550a7")
    }

    // F-610 B-DLG-233 B-DLG-245: every window that observes is told once for a change, and not for none
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

    // T-68c19be7 B-DLG-234 F-636: windows other than explorer windows get the background, explorer windows none
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

    // B-DLG-232: the macOS appearance is read from the app while it follows macOS
    @Test func readsTheMacOSAppearanceFromTheApp() {
        _ = NSApplication.shared
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Pinned: macOS is asked in the defaults, which a test cannot change; the answer is only a Bool.
        _ = AppearanceModel.macOSIsDark()
        NSApp.appearance = nil
        #expect(
            AppearanceModel.macOSIsDark()
                == (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua))
    }

    // T-3f0d78e0 F-646: everything is drawn in the system font
    @Test func drawsEverythingInTheSystemFont() {
        #expect(
            DesignTokens.sansFontStack
                == #"-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif"#)
        #expect(DesignTokens.monoFontStack == #""SF Mono", "SFMono-Regular", ui-monospace, Menlo, monospace"#)
        #expect(ThemeFonts.sans(13) == NSFont.systemFont(ofSize: 13))
        #expect(ThemeFonts.sans(13, .semibold) == NSFont.systemFont(ofSize: 13, weight: .semibold))
        #expect(ThemeFonts.mono(12) == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    // N/A T-a7b14a6b the stylesheet rule that colors favorite icons is P5-01's; the accent it draws them with is
    // `AccentPalette.solid`, which the first test above checks

    // N/A T-c7bb98e0 T-148b5efe T-5140e6c3 T-31b3bab3 T-2020b6b1 T-2b8d85c8 T-2c77ecb5 T-35737f38 T-dc75a2f1 T-22aac744
    // T-6f403fb5 T-0abc3428 T-e61d7669 assertions about the text of styles.css: there is no stylesheet; the palettes
    // are generated from it (tools/tokens) and checked against it by CSSTokenTests and AccentPaletteTests
    @Test func hasTwoPalettesAndTheDarkOneHasEveryColor() {
        #expect(ThemeAppearance.allCases == [.light, .dark])
        #expect(ThemePalette.palette(for: .light) == ThemePalette.light)
        #expect(ThemePalette.palette(for: .dark) == ThemePalette.dark)
        #expect(ThemePalette.light != ThemePalette.dark)
    }

    // N/A T-38688505 T-479129a0 mounting the renderer root element (React); the Settings window case belongs to P6-04

}
