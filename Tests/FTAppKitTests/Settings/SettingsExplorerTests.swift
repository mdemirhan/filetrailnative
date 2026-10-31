// Ports App.commands.test.tsx T-d16d186c and App.menuCommands.test.tsx T-1e8b265a, and checks that what Settings changes
// reaches an explorer window (windowless)
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SettingsExplorerTests {
        private func pages(_ harness: ExplorerHarness) -> PageWindows {
            let pages = PageWindows(model: AppearanceModel(), preferences: { harness.store.preferences() })
            pages.presentsWindows = false
            pages.loadPreferences = { harness.channel.preferences(for: nil) }
            pages.writePreferences = { patch in
                harness.channel.update(AppPreferences.patch(from: patch), from: nil)
                return true
            }
            // Each change is written at once.
            pages.settingsServices.schedule = { _, work in
                work()
                return {}
            }
            pages.settingsServices.missingApps = { _ in [] }
            return pages
        }

        // T-d16d186c T-1e8b265a F-572 F-639 B-DLG-162
        // B-VIEW-231
        @Test func commandCommaTheMenuAndTheToolbarOpenSettingsInItsWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pages = pages(harness)
            // The toolbar's Settings button and the automation's openSettings send the command to the window.
            tab.openSettings = { pages.openSettings() }
            tab.perform(.openSettings)
            let settings = try #require(pages.settingsWindow)
            #expect(settings.activeTab == .general)
            // File Trail › Settings… is ⌘, and opens the same window; Help opens in a window of its own.
            let router = MenuCommandRouter()
            let built = ApplicationMenuBuilder.build(target: router)
            let item = built.menu.items.compactMap(\.submenu).flatMap(\.items).first {
                $0.identifier?.rawValue == ApplicationMenuBuilder.settingsItemID
            }
            #expect(item?.keyEquivalent == ",")
            #expect(item?.keyEquivalentModifierMask == .command)
            let menu = MainMenu(windows: FakeWindowHost().windows)
            menu.connect(
                openSettings: { pages.openSettings() }, openHelp: { pages.openHelp(topic: $0) },
                openWindowFor: { _ in },
                openNewWindowFromFront: {})
            menu.router.choose(itemID: ApplicationMenuBuilder.settingsItemID)
            #expect(pages.settingsWindow === settings)
            menu.router.onOpenHelp?(nil)
            #expect(pages.helpWindow != nil)
            pages.helpWindow?.close()
            settings.close()
            await harness.close()
        }

        // F-891 F-895 F-896 F-904 B-DLG-172 B-DLG-180 B-DLG-181 B-DLG-222 B-DLG-231
        @Test func whatSettingsChangesReachesTheExplorerWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pages = pages(harness)
            pages.openSettings(tab: .browsing)
            let settings = try #require(pages.settingsWindow)
            SettingsTestKit.layout(settings)
            #expect(tab.content.columnState.density == .comfortable)
            try SettingsTestKit.control("Density", SettingsPopup.self, in: settings).choose("compact")
            #expect(tab.content.columnState.density == .compact)
            #expect(tab.preferences.compactTreeView)

            settings.show(tab: .general)
            let marks = try SettingsTestKit.control("Mark copied and cut items", SettingsSwitch.self, in: settings)
            marks.press()
            #expect(!tab.preferences.markClipboardItems)

            // A key given in Settings runs its command in the window.
            settings.show(tab: .shortcuts)
            let view = try #require(settings.settingsView.page?.shortcuts)
            let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
            place.perform()
            _ = place.record(SettingsTestKit.letter("j", [.command, .option], window: settings.window))
            #expect(tab.content.shortcuts.commandByShortcut["Cmd+Option+J"] == .newFolder)

            // A change made in the explorer window is shown in Settings.
            settings.show(tab: .general)
            harness.channel.update(["markClipboardItems": .bool(true)], from: tab.windowID)
            pages.preferencesChanged(
                harness.store.preferences(), PreferencesChange(patch: ["markClipboardItems": .bool(true)], senderID: 1))
            let shown = try SettingsTestKit.control("Mark copied and cut items", SettingsSwitch.self, in: settings)
            #expect(shown.isOn)
            settings.close()
            await harness.close()
        }

        // F-906 B-DLG-221: ⌘D while the recorder records, with an explorer window and the app's menu (a09, 265).
        // AppKit offers a key equivalent to the key window before the menu bar; the menu would claim ⌘D (Duplicate),
        // even dimmed, so the recorder only has it when the window goes first.
        @Test func theRecorderHasAMenuKeyBeforeTheMenuDoes() async throws {
            let harness = try ExplorerHarness.windowless()
            _ = try await harness.open()
            let pages = pages(harness)
            pages.openSettings(tab: .shortcuts)
            let settings = try #require(pages.settingsWindow)
            SettingsTestKit.layout(settings)
            let view = try #require(settings.settingsView.page?.shortcuts)
            let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
            place.perform()
            #expect(settings.window?.firstResponder === place)
            let commandD = SettingsTestKit.letter("d", .command, window: settings.window)
            let router = MenuCommandRouter()
            router.setItem(RendererCommand.duplicateSelection.rawValue, enabled: false)
            let built = ApplicationMenuBuilder.build(target: router)
            #expect(built.menu.performKeyEquivalent(with: commandD))
            #expect(view.model.note == nil)
            #expect(settings.window?.performKeyEquivalent(with: commandD) == true)
            #expect(texts("settings.shortcuts.note", in: view) == ["⌘D is used by Duplicate."])
            settings.close()
            await harness.close()
        }
    }
}
