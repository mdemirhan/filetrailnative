import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
@Suite struct SettingsWindowRulesTests {
    typealias Kit = SettingsTestKit

    /// Asking for the tab on screen changes nothing: the Shortcuts search stays.
    @Test func askingForTheTabOnScreenKeepsTheShortcutsSearch() throws {
        let (controller, _) = Kit.make(tab: .shortcuts)
        let before = try #require(controller.settingsView.page?.shortcuts)
        before.setQuery("dup")
        controller.show(tab: .shortcuts)
        let after = try #require(controller.settingsView.page?.shortcuts)
        #expect(after === before)
        #expect(after.searchField.text == "dup")
    }

    /// ColumnList keeps the selected key, so the selection follows its column.
    @Test func columnSelectionFollowsTheColumnAfterRestoreDefaults() throws {
        let (controller, _) = Kit.make(tab: .browsing)
        let list = try Kit.list("Columns in List view", in: controller)
        list.select(2)
        let chosen = list.rows[2].spec.name
        list.move(2, to: 0)
        Kit.layout(controller)
        let moved = try Kit.list("Columns in List view", in: controller)
        #expect(moved.rows[moved.selectedIndex ?? -1].spec.name == chosen)
        let restore = try #require(
            Kit.barButton("Restore the default column order", in: moved))
        restore.press()
        let restored = try Kit.list("Columns in List view", in: controller)
        #expect(restored.rows[restored.selectedIndex ?? -1].spec.name == chosen)
    }

    /// A row dropped in a gap of the table goes to the place the gap shows, the fixed row never counting.
    @Test func aDroppedRowGoesWhereTheGapIs() {
        let target = { (from: Int, row: Int, offset: Int) in
            SettingsListView.dropTarget(from: from, aboveTableRow: row, offset: offset, count: 5)
        }
        // Down: the gap above row 3 is after row 2 once row 0 has left.
        #expect(target(0, 3, 0) == 2)
        // To the end, past the last row.
        #expect(target(0, 5, 0) == 4)
        // Up, to the top; with a fixed row first, the top gap is above table row 1.
        #expect(target(4, 0, 0) == 0)
        #expect(target(4, 1, 1) == 0)
        #expect(target(2, 2, 1) == 1)
        // Next to itself: it stays.
        #expect(target(2, 2, 0) == nil)
        #expect(target(2, 3, 0) == nil)
        #expect(target(2, 4, 1) == nil)
    }

    /// The description at the pinned commit.
    @Test func folderSizeSwitchHasThePinnedDescription() throws {
        let (controller, _) = Kit.make(tab: .general)
        let row = try Kit.row("Calculate folder sizes automatically", in: controller)
        #expect(
            row.descriptionText?.stringValue
                == "In the Info panel and Info Row, for a folder in your home folder or an app.")
    }
}
