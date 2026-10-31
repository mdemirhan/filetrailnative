// The Settings window built for a test: never shown, its writes recorded, its pickers answered by the test
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

/// What a Settings window under test wrote and asked for.
@MainActor
final class SettingsRecorder {
    var patches: [PreferencesPatch] = []
    var refuseWrites = false
    var pending: [() -> Void] = []
    var pickedApplication: ApplicationSelection?
    var pickedDirectory: String?
    var pickerFails = false
    var directoryRequests: [String?] = []
    var missing: Set<String> = []
    var pickedColor: String?

    /// Every write so far, merged.
    var saved: PreferencesPatch { patches.reduce(into: [:]) { $0.merge($1) { _, new in new } } }
}

/// The error a picker that could not be shown throws.
struct PickerFailed: Error {}

@MainActor
enum SettingsTestKit {
    /// A Settings window on `tab`, laid out at its size and never put on screen.
    static func make(
        tab: SettingsTab = .general, preferences: AppPreferences = .defaults(theme: .light), loads: Bool = true,
        homePath: String = "/Users/demo"
    ) -> (SettingsWindowController, SettingsRecorder) {
        _ = NSApplication.shared
        let recorder = SettingsRecorder()
        var services = SettingsServices()
        services.schedule = { _, work in
            recorder.pending.append(work)
            return {}
        }
        services.pickApplication = { _ in
            if recorder.pickerFails { throw PickerFailed() }
            return recorder.pickedApplication
        }
        services.pickDirectory = { path, _ in
            recorder.directoryRequests.append(path)
            if recorder.pickerFails { throw PickerFailed() }
            return recorder.pickedDirectory
        }
        services.missingApps = { _ in recorder.missing }
        let controller = SettingsWindowController(
            tab: tab,
            load: {
                guard loads else { throw PickerFailed() }
                return preferences
            }, homePath: homePath,
            write: { patch in
                recorder.patches.append(patch)
                return !recorder.refuseWrites
            }, services: services, model: AppearanceModel())
        controller.openColorPicker = { _, picked in
            if let color = recorder.pickedColor { picked(color) }
        }
        layout(controller)
        return (controller, recorder)
    }

    static func layout(_ controller: SettingsWindowController) {
        controller.window?.layoutIfNeeded()
        controller.settingsView.layoutSubtreeIfNeeded()
        controller.settingsView.layout()
        controller.settingsView.layoutSubtreeIfNeeded()
    }

    /// Lets the tasks the window started (pickers, the check for missing apps) finish.
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    static func view(_ controller: SettingsWindowController) -> NSView { controller.settingsView }

    static func page(_ controller: SettingsWindowController) throws -> SettingsPageView {
        try #require(controller.settingsView.page)
    }

    /// The control of the row titled `title`.
    static func control<T: NSView>(_ title: String, _ type: T.Type, in controller: SettingsWindowController) throws -> T
    {
        let rows = views("settings.row", in: controller.settingsView).compactMap { $0 as? SettingsRowView }
        let row = try #require(rows.first { $0.titleText.stringValue == title }, "no row \(title)")
        return try #require(row.control as? T)
    }

    static func row(_ title: String, in controller: SettingsWindowController) throws -> SettingsRowView {
        let rows = views("settings.row", in: controller.settingsView).compactMap { $0 as? SettingsRowView }
        return try #require(rows.first { $0.titleText.stringValue == title }, "no row \(title)")
    }

    static func lists(in controller: SettingsWindowController) -> [SettingsListView] {
        views("settings.list", in: controller.settingsView).compactMap { $0 as? SettingsListView }
    }

    static func list(_ label: String, in controller: SettingsWindowController) throws -> SettingsListView {
        try #require(lists(in: controller).first { $0.label == label }, "no list \(label)")
    }

    static func button(_ label: String, in root: NSView) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.accessibilityLabel() == label,
                view is SettingsControlView || view is SystemButton || view is SettingsSwitch
            {
                return view
            }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return walk(root)
    }

    /// Clicks a Settings control or push button.
    static func click(_ view: NSView?) {
        if let control = view as? SettingsControlView { control.press() }
        if let settingsSwitch = view as? SettingsSwitch { settingsSwitch.press() }
        if let button = view as? SystemButton { button.perform() }
        if let text = view as? TextControl { text.perform() }
    }

    static func names(_ list: SettingsListView) -> [String] { list.rows.map(\.spec.name) }

    /// Writes what is waiting, as 300 ms after the last change does.
    static func flush(_ controller: SettingsWindowController) { controller.flushPending() }

    /// A key press made into an event for `window`.
    static func key(
        _ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false,
        ignoring: String? = nil, window: NSWindow?
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters, isARepeat: isRepeat, keyCode: code)!
    }

    static let escape: (String, UInt16) = ("\u{1b}", 53)
    static let tab: (String, UInt16) = ("\t", 48)
    static let backspace: (String, UInt16) = ("\u{7f}", 51)
    static let returnKey: (String, UInt16) = ("\r", 36)
    static let space: (String, UInt16) = (" ", 49)
    static let up: (String, UInt16) = (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)
    static let down: (String, UInt16) = (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)

    static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46, ".": 47, "/": 44,
    ]

    /// A letter with modifiers, as the keyboard sends it.
    static func letter(_ letter: Character, _ modifiers: NSEvent.ModifierFlags = [], window: NSWindow?) -> NSEvent {
        let plain = String(letter)
        let typed = modifiers.contains(.shift) ? plain.uppercased() : plain
        return key(typed, code: letterCodes[letter] ?? 0, modifiers: modifiers, ignoring: plain, window: window)
    }
}
