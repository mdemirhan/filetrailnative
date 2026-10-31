// Port of apps/desktop/src/main/settingsWindowTab.test.ts
import Testing

@testable import FTFoundation

struct SettingsTabTests {
    // T-63f9bb62 F-633 B-DLG-164
    @Test func readsTheTabASettingsWindowIsOnFromItsAddress() {
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/files") == .files)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/shortcuts") == .shortcuts)
    }

    // T-3364df33 F-633 B-DLG-164
    @Test func findsNoTabInAnAddressWithoutOneOrWithOneSettingsDoesNotHave() {
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/rails") == nil)
        // The toolbar is customized in the window now, not in Settings.
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#settings/toolbars") == nil)
        #expect(SettingsTab.read(fromURL: "file:///app/renderer/index.html#about") == nil)
    }
}
