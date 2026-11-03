// Checks that a scenario's key step gives the Shortcuts recorder a menu key before the menu bar (265, a09), windowless
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct ReviewRunnerOrderTests {
    // F-906 B-DLG-221: ⌘D in a key step while the recorder records, with the app's menu claiming ⌘D (Duplicate, dimmed):
    // the step offers it to the window first, as NSApplication does, so the recorder shows the conflict.
    @Test func automationKeyStepGivesTheRecorderCommandD() throws {
        let (settings, _) = SettingsTestKit.make(tab: .shortcuts)
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
    }
}

@MainActor
@Suite struct ReviewExpectTextTests {
    // F-896 B-DLG-181: an expect step reads a pop-up's text as the original's driver does, from its aria-label
    // ("Sizes"), not the value it shows ("Match Finder") (263-settings-density-custom step 9).
    @Test func expectReadsAPopupByItsLabelAsTheOriginalDoes() throws {
        let preferences = AppPreferences.defaults(theme: .light).with { $0.density = .finder }
        let (controller, _) = SettingsTestKit.make(tab: .browsing, preferences: preferences)
        let popup = try SettingsTestKit.control("Sizes", SettingsPopup.self, in: controller)
        #expect(ElementFinder.text(of: popup) == "Match Finder")
        let spec = Data(
            """
            {"elements": {
              "settings popup": {"electron": {"selector": "select", "textAttribute": "aria-label"},
                                 "swift": "settings.popup"},
              "settings row title": {"electron": {"selector": ".title"}, "swift": "settings.row.title"}}}
            """.utf8)
        let elements = try AutomationElements.parse(spec)
        #expect(elements.labelled == ["settings popup"])
        #expect(ElementFinder.text(of: popup, named: "settings popup", elements: elements) == "Sizes")
        let title = try SettingsTestKit.row("Sizes", in: controller).titleText
        #expect(ElementFinder.text(of: title, named: "settings row title", elements: elements) == "Sizes")
    }
}
