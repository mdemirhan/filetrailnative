// Checks that a scenario's key step gives the Shortcuts recorder a menu key before the menu bar (265, a09), windowless
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ReviewRunnerOrderTests {
        // F-906 B-DLG-221: ⌘D in a key step while the recorder records, with the app's menu claiming ⌘D (Duplicate,
        // dimmed): the step offers it to the window first, as NSApplication does, so the recorder shows the conflict.
        @Test func automationKeyStepGivesTheRecorderCommandD() async throws {
            let harness = try ExplorerHarness.windowless()
            _ = try await harness.open()
            let pages = PageWindows(model: AppearanceModel(), preferences: { harness.store.preferences() })
            pages.presentsWindows = false
            pages.loadPreferences = { harness.channel.preferences(for: nil) }
            pages.settingsServices.missingApps = { _ in [] }
            pages.openSettings(tab: .shortcuts)
            let settings = try #require(pages.settingsWindow)
            SettingsTestKit.layout(settings)
            let view = try #require(settings.settingsView.page?.shortcuts)
            let place = try #require(view.slotView(ShortcutSlot(id: .newFolder, index: 1)))
            place.perform()
            let window = try #require(settings.window)
            let commandD = SettingsTestKit.letter("d", .command, window: window)
            let router = MenuCommandRouter()
            router.setItem(RendererCommand.duplicateSelection.rawValue, enabled: false)
            let mainMenu: NSMenu? = ApplicationMenuBuilder.build(target: router).menu
            #expect(KeyEvents.performKeyEquivalent(commandD, window: window, menu: mainMenu))
            #expect(view.model.note != nil)
            settings.close()
            await harness.close()
        }
    }
}

@MainActor
@Suite struct ReviewExpectTextTests {
    // F-896 B-DLG-181: an expect step reads the Density pop-up's text as the original's driver does, from its
    // aria-label ("Density"), not the value it shows ("Custom") (263-settings-density-custom step 9).
    @Test func expectReadsAPopupByItsLabelAsTheOriginalDoes() throws {
        let preferences = AppPreferences.defaults(theme: .light).with { $0.compactIconView = true }
        let (controller, _) = SettingsTestKit.make(tab: .browsing, preferences: preferences)
        let popup = try SettingsTestKit.control("Density", SettingsPopup.self, in: controller)
        #expect(ElementFinder.text(of: popup) == "Custom")
        let spec = Data(
            """
            {"elements": {
              "settings popup": {"electron": {"selector": "select", "textAttribute": "aria-label"},
                                 "swift": "settings.popup"},
              "settings row title": {"electron": {"selector": ".title"}, "swift": "settings.row.title"}}}
            """.utf8)
        let elements = try AutomationElements.parse(spec)
        #expect(elements.labelled == ["settings popup"])
        #expect(ElementFinder.text(of: popup, named: "settings popup", elements: elements) == "Density")
        let title = try SettingsTestKit.row("Density", in: controller).titleText
        #expect(ElementFinder.text(of: title, named: "settings row title", elements: elements) == "Density")
    }
}
