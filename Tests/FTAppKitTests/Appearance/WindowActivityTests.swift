// Ports apps/desktop/src/renderer/lib/windowActivity.test.ts and the selection colors of styles.css (F-932)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct WindowActivityTests {
    @MainActor
    final class Focus {
        var has = true
    }

    // T-955da199 F-932 F-649
    @Test func marksTheWindowInactiveWhileItDoesNotHaveTheFocus() {
        let window = makeOffscreenWindow()
        let center = NotificationCenter()
        let focus = Focus()
        let activity = WindowActivity(hasFocus: { focus.has }, window: window, center: center)
        var changes: [Bool] = []
        activity.onChange = { changes.append($0) }
        #expect(activity.isActive)

        focus.has = false
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!activity.isActive)

        focus.has = true
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(activity.isActive)
        #expect(changes == [false, true])
        activity.stop()
    }

    // T-a21ed124 F-932 F-649
    @Test func startsInactiveWhenTheWindowOpensInTheBackground() {
        let window = makeOffscreenWindow()
        let center = NotificationCenter()
        let activity = WindowActivity(hasFocus: { false }, window: window, center: center)
        #expect(!activity.isActive)
        activity.stop()
        // A window nothing tracks counts as active.
        #expect(activity.isActive)
    }

    // F-932 only the notifications of the window tracked count
    @Test func ignoresOtherWindows() {
        let window = makeOffscreenWindow()
        let other = makeOffscreenWindow()
        let center = NotificationCenter()
        let focus = Focus()
        let activity = WindowActivity(hasFocus: { focus.has }, window: window, center: center)
        focus.has = false
        center.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(activity.isActive)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!activity.isActive)
        activity.stop()
    }

    // F-932 F-649: a window not on screen has not been made key
    @Test func aWindowThatWasNeverMadeKeyIsInactive() {
        let activity = WindowActivity(window: makeOffscreenWindow(), center: NotificationCenter())
        #expect(!activity.isActive)
        activity.stop()
    }

    // F-932 selection colors: the accent with white text in the focused pane, grey otherwise
    @Test func selectsWithTheAccentInTheFocusedPaneOfTheActiveWindow() {
        for appearance in ThemeAppearance.allCases {
            let theme = Theme(appearance: appearance, accentHex: "#a550a7")
            let focused = theme.selection(paneFocused: true, windowActive: true)
            #expect(focused.background == theme.accent.selectionBg)
            #expect(focused.text == RGBA.white)
            #expect(focused.secondaryText == theme.accent.onSelectionSoft)
            let grey = theme.palette.bgActiveInactive
            for (paneFocused, windowActive) in [(false, true), (true, false), (false, false)] {
                let colors = theme.selection(paneFocused: paneFocused, windowActive: windowActive)
                #expect(colors.background == grey)
                #expect(colors.text == theme.palette.textPrimary)
                #expect(colors.secondaryText == theme.palette.textSecondary)
            }
        }
    }

    // F-932 the grey selection is #dcdce1 in the light theme and #3a3a3e in the dark one (ui.md section 5.5)
    @Test func theUnfocusedSelectionColors() {
        #expect(Theme(appearance: .light, accentHex: "#007aff").palette.bgActiveInactive.hexString == "#dcdce1")
        #expect(ThemePalette.dark.bgActiveInactive.hexString != ThemePalette.light.bgActiveInactive.hexString)
    }

    // F-646 B-DLG-239 the selection never uses the system accent: it is computed from the accent chosen in the app
    @Test func neverUsesTheSystemAccent() {
        let theme = Theme(appearance: .light, accentHex: "#ffc600")
        let system = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let selection = theme.selection(paneFocused: true, windowActive: true).background
        #expect(selection != RGBA(red: Double(system?.redComponent ?? 0), green: Double(system?.greenComponent ?? 0), blue: Double(system?.blueComponent ?? 0)))
        #expect(selection == theme.accent.selectionBg)
    }
}
