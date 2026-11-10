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

    /// A notification center that counts the observers taken off it.
    final class CountingCenter: NotificationCenter, @unchecked Sendable {
        var removed = 0
        override func removeObserver(_ observer: Any) {
            removed += 1
            super.removeObserver(observer)
        }
    }

    // One tracker for each sidebar and toolbar that opens: one let go takes its observers off with it.
    @Test func takesItsObserversOffWhenItGoes() {
        let window = makeOffscreenWindow()
        let center = CountingCenter()
        var activity: WindowActivity? = WindowActivity(hasFocus: { true }, window: window, center: center)
        #expect(activity != nil)
        activity = nil
        #expect(center.removed == 2)
    }

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

    @Test func startsInactiveWhenTheWindowOpensInTheBackground() {
        let window = makeOffscreenWindow()
        let center = NotificationCenter()
        let activity = WindowActivity(hasFocus: { false }, window: window, center: center)
        #expect(!activity.isActive)
        activity.stop()
        // A window nothing tracks counts as active.
        #expect(activity.isActive)
    }

    // Only the notifications of the window tracked count
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

    // A window not on screen has not been made key
    @Test func aWindowThatWasNeverMadeKeyIsInactive() {
        let activity = WindowActivity(window: makeOffscreenWindow(), center: NotificationCenter())
        #expect(!activity.isActive)
        activity.stop()
    }

    // Selection colors: the accent with white text in the focused pane, grey otherwise
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

    // The grey selection is #dcdce1 in the light theme and #2a2d36 in the dark one, as the built stylesheet has it:
    // its minifier drops the source's later #3a3a3e rule
    @Test func theUnfocusedSelectionColors() {
        #expect(Theme(appearance: .light, accentHex: "#007aff").palette.bgActiveInactive.hexString == "#dcdce1")
        #expect(ThemePalette.dark.bgActiveInactive.hexString == "#2a2d36")
    }
}
