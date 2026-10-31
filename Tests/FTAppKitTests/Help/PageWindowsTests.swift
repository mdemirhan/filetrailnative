// The Help, About and Acknowledgements windows as the app opens them (main.ts openHelpWindow, openAboutWindow,
// openAcknowledgementsWindow; B-DLG-246..249, 259) and Help's documentation of the application menu (helpContent.test.ts)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct HelpMenuTests {
    private func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
    }

    // T-ff1d7b21 F-594 F-665 F-667
    @Test func documentsEveryKeyboardShortcutInTheApplicationMenu() {
        _ = NSApplication.shared
        let router = MenuCommandRouter()
        let built = ApplicationMenuBuilder.build(target: router)
        let documented = Set(
            HelpContent.listShortcuts().compactMap { MenuKeyEquivalent.parse($0.shortcut) }
                .map { "\($0.key)|\($0.modifiers.rawValue)" })
        // The items the app's own commands make: the standard items AppKit handles have no key of Help's.
        let items = menuItems(built.menu).filter { $0.target === router && !$0.keyEquivalent.isEmpty }
        #expect(items.count > 10)
        for item in items {
            let key = "\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)"
            #expect(documented.contains(key), "menu shortcut of \(item.title) is missing from Help")
        }
    }

}

@MainActor
@Suite struct PageWindowsTests {
    static func make(_ preferences: AppPreferences = .defaults()) -> (PageWindows, Box) {
        _ = NSApplication.shared
        let box = Box(preferences)
        let pages = PageWindows(model: AppearanceModel(), preferences: { box.preferences })
        pages.aboutActions = AboutActions()
        pages.readAboutInfo = {
            AboutInfo(
                version: "0.1.0", commit: nil, macosVersion: "27.0", architecture: "Apple silicon", fdVersion: "10.5.0")
        }
        pages.readAcknowledgements = { [] }
        pages.presentsWindows = false
        return (pages, box)
    }

    // F-639 F-648: with windows kept off the screen each one is still made once and asked to show
    @Test func keepsItsWindowsOffTheScreenWhenAsked() {
        let (pages, _) = Self.make()
        pages.openAbout()
        let about = pages.aboutWindow
        pages.openAbout()
        #expect(pages.aboutWindow === about)
        #expect(about?.wasPresented == true)
        #expect(about?.window?.isVisible == false)
        pages.openSettings()
        #expect(pages.settingsWindow?.wasPresented == true)
        #expect(pages.settingsWindow?.window?.isVisible == false)
        pages.openHelp()
        #expect(pages.helpWindow?.window?.isVisible == false)
    }

    @MainActor
    final class Box {
        var preferences: AppPreferences
        init(_ preferences: AppPreferences) { self.preferences = preferences }
    }

    // B-DLG-246 F-634: Help is titled "File Trail Help", 900 by 680, at least 560 by 420
    @Test func helpIsAWindowOf900By680() {
        _ = NSApplication.shared
        var told: [HelpTopicID] = []
        let controller = HelpWindowController(
            shortcuts: .defaults, topic: .files, onTopicChange: { told.append($0) }, onCustomize: {},
            model: AppearanceModel())
        let window = controller.window
        #expect(window?.title == "File Trail Help")
        #expect(window?.contentRect(forFrameRect: window?.frame ?? .zero).size == NSSize(width: 900, height: 680))
        #expect(window?.contentMinSize == NSSize(width: 560, height: 420))
        #expect(window?.styleMask.contains(.resizable) == true)
        #expect(window?.styleMask.contains(.miniaturizable) == true)
        // The window opens on the topic asked for, and tells it.
        #expect(controller.helpView.activeTopic == .files)
        #expect(told == [.files])
        // Help is not closed by Escape: Escape clears its search.
        #expect((window as? PageWindow)?.closesOnEscape == false)
    }

    // F-667 B-DLG-255: Customize… opens Settings on the shortcuts tab
    @Test func customizeOpensSettingsOnTheShortcutsTab() {
        _ = NSApplication.shared
        var opened = 0
        let controller = HelpWindowController(
            shortcuts: .defaults, topic: .shortcuts, onTopicChange: { _ in }, onCustomize: { opened += 1 },
            model: AppearanceModel())
        controller.helpView.layoutSubtreeIfNeeded()
        (views("help.action", in: controller.helpView).first as? SystemButton)?.perform()
        #expect(opened == 1)
    }

    // B-DLG-249: a topic asked for while Help is open replaces the whole view
    @Test func aTopicAskedForShowsInTheOpenWindow() {
        _ = NSApplication.shared
        let controller = HelpWindowController(
            shortcuts: .defaults, topic: .navigation, onTopicChange: { _ in }, onCustomize: {}, model: AppearanceModel()
        )
        controller.show(topic: .shortcuts)
        #expect(controller.helpView.activeTopic == .shortcuts)
    }

    // B-DLG-254 F-610: the keys Help shows are the ones chosen in Settings, and Return renames while Settings says so
    @Test func helpShowsTheKeysChosenInSettings() {
        let (pages, _) = Self.make()
        var changed = AppPreferences.defaults()
        var bindings = ShortcutCommands.defaultBindings
        bindings[.newTab] = []
        bindings[.goBack] = ["Cmd+Shift+Y"]
        changed.shortcutOverrides = ShortcutCommands.overrides(for: bindings)
        changed.returnKeyAction = .open
        let display = pages.shortcutDisplay(changed)
        #expect(display.written(.newTab) == nil)
        #expect(display.written(.goBack) == "Cmd+Shift+Y")
        #expect(display.written(.renameSelection) == "F2")
        #expect(pages.shortcutDisplay(.defaults()).written(.renameSelection) == "Return")
        // Not open: nothing to follow, and nothing fails.
        pages.preferencesChanged(changed, PreferencesChange(patch: ["shortcutOverrides": .object([:])], senderID: nil))
        #expect(pages.helpWindow == nil)
    }

}

/// Puts the Help, About and Acknowledgements windows on screen: only with FILETRAIL_GUI_TESTS=1, under the GUI lock.
@MainActor
@Suite(.serialized, .holdsMainLoop, .enabled(if: ProcessInfo.processInfo.environment["FILETRAIL_GUI_TESTS"] == "1"))
struct PageWindowsGUITests {
    // F-639 F-648 B-DLG-246 B-DLG-259: one window of each kind; asking again shows the one open. Puts windows on screen.
    // B-VIEW-231
    @Test func opensOneWindowOfEachKindAndRemembersHelpsPage() {
        let (pages, _) = PageWindowsTests.make()
        pages.presentsWindows = true
        pages.openHelp()
        let first = pages.helpWindow
        #expect(first?.helpView.activeTopic == .navigation)
        pages.openHelp(topic: .search)
        #expect(pages.helpWindow === first)
        #expect(first?.helpView.activeTopic == .search)

        pages.openAbout()
        let about = pages.aboutWindow
        pages.openAbout()
        #expect(pages.aboutWindow === about)
        #expect(about?.window?.isVisible == true)

        pages.openAcknowledgements()
        let acknowledgements = pages.acknowledgementsWindow
        pages.openAcknowledgements()
        #expect(pages.acknowledgementsWindow === acknowledgements)

        // While open it follows the keys chosen in Settings.
        var changed = AppPreferences.defaults()
        var bindings = ShortcutCommands.defaultBindings
        bindings[.newTab] = []
        changed.shortcutOverrides = ShortcutCommands.overrides(for: bindings)
        pages.preferencesChanged(changed, PreferencesChange(patch: ["shortcutOverrides": .object([:])], senderID: nil))
        #expect(first?.helpView.shortcuts.written(.newTab) == nil)

        // Help opens on the page it was left on.
        first?.window?.close()
        #expect(pages.helpWindow == nil)
        #expect(pages.lastHelpTopic == .search)
        pages.openHelp()
        #expect(pages.helpWindow?.helpView.activeTopic == .search)

        about?.window?.close()
        acknowledgements?.window?.close()
        pages.helpWindow?.window?.close()
        #expect(pages.aboutWindow == nil)
        #expect(pages.acknowledgementsWindow == nil)
    }
}
