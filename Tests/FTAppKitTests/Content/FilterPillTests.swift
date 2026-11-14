// The filter pill: its mode chip switches how typing finds names, for every window, and it says when nothing matches
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FilterPillTests {
        @Test func theChipSwitchesHowTypingFindsNamesAndSettingsShowsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Many", files: 30).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 30 })
            #expect(tab.preferences.listFilterMatch == .fuzzy)
            // "-02": items 020 to 029 have it side by side; 002, 012 and the rest have its letters in order.
            for letter in "-02" { tab.content.applyFilterKey(.type(String(letter))) }
            let pill = tab.content.container.filterPill
            #expect(pill.isShowingFilter)
            #expect(pill.chip.mode == .fuzzy)
            let fuzzy = tab.content.entries.count

            #expect(pill.chip.accessibilityPerformPress())
            #expect(tab.preferences.listFilterMatch == .contains)
            #expect(tab.content.filterMode == .contains)
            #expect(pill.chip.mode == .contains)
            #expect(tab.content.entries.count == 10)
            #expect(fuzzy > 10)
            #expect(tab.content.entries.allSatisfy { $0.name.contains("-02") })

            #expect(pill.chip.accessibilityPerformPress())
            #expect(tab.preferences.listFilterMatch == .fuzzy)
            #expect(tab.content.entries.count == fuzzy)
            await harness.close()
        }

        @Test func thePillTurnsRedWhenNothingMatchesAndGoesWithTheFilter() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Few", files: 5).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 5 })
            let pill = tab.content.container.filterPill
            for letter in "zq" { tab.content.applyFilterKey(.type(String(letter))) }
            #expect(tab.content.entries.isEmpty)
            #expect(pill.layer?.borderColor == NSColor(tab.content.theme.palette.danger).cgColor)
            tab.content.applyFilterKey(.clear)
            #expect(!pill.isShowingFilter)
            await harness.close()
        }
    }
}
