// The filter bar: it takes its room at the foot of the list, which ends above it, its modes switch how typing finds
// names for every window, and it says when nothing matches
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FilterBarTests {
        @Test func theListEndsAboveTheBarWhileAFilterShows() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Many", files: 30).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 30 })
            let container = tab.content.container
            container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            container.layoutSubtreeIfNeeded()
            let pane = try #require(container.paneView)
            #expect(pane.frame.height == 400)

            tab.content.applyFilterKey(.type("0"))
            let bar = container.filterBar
            #expect(bar.isShowingFilter)
            // At once, not at the next layout: the selection is brought into view in the list's new height.
            let height = ListFilterBarView.height
            #expect(bar.frame == NSRect(x: 0, y: 400 - height, width: 600, height: height))
            #expect(pane.frame.maxY == bar.frame.minY)
            #expect(container.stateView.frame.maxY <= bar.frame.minY)

            tab.content.applyFilterKey(.clear)
            #expect(!bar.isShowingFilter)
            #expect(bar.isHidden)
            #expect(pane.frame.height == 400)
            await harness.close()
        }

        @Test func theModesSwitchHowTypingFindsNamesAndSettingsShowsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Many", files: 30).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 30 })
            #expect(tab.preferences.listFilterMatch == .fuzzy)
            // "-02": items 020 to 029 have it side by side; 002, 012 and the rest have its letters in order.
            for letter in "-02" { tab.content.applyFilterKey(.type(String(letter))) }
            let bar = tab.content.container.filterBar
            #expect(bar.isShowingFilter)
            #expect(bar.modes.mode == .fuzzy)
            #expect(bar.modes.selectedSegment == 0)
            let fuzzy = tab.content.entries.count

            // The mode shown, pressed again, changes nothing.
            bar.modes.press(.fuzzy)
            #expect(tab.content.filterMode == .fuzzy)
            #expect(tab.content.entries.count == fuzzy)

            bar.modes.press(.contains)
            #expect(tab.preferences.listFilterMatch == .contains)
            #expect(tab.content.filterMode == .contains)
            #expect(bar.modes.mode == .contains)
            #expect(bar.modes.selectedSegment == 1)
            #expect(tab.content.entries.count == 10)
            #expect(fuzzy > 10)
            #expect(tab.content.entries.allSatisfy { $0.name.contains("-02") })

            bar.modes.press(.fuzzy)
            #expect(tab.preferences.listFilterMatch == .fuzzy)
            #expect(bar.modes.selectedSegment == 0)
            #expect(tab.content.entries.count == fuzzy)
            await harness.close()
        }

        // A press on the bar of the pane that isn't active, or on one of its buttons, makes that pane the active
        // one, as a press on its list or its other bars does: what the button changes is then in the pane being used.
        @Test func aPressOnTheBarMakesItsPaneTheActiveOne() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Many", files: 30).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 30 })
            let left = tab.activePane
            let right = tab.openSecondPane(at: harness.folder.path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            harness.layout(tab)
            left.content.applyFilterKey(.type("0"))
            let bar = left.content.container.filterBar
            #expect(bar.isShowingFilter)

            tab.focusPane(right)
            #expect(tab.activePane === right)
            // The mode already shown changes nothing but the pane.
            bar.modes.press(.fuzzy)
            #expect(tab.activePane === left)
            #expect(left.content.filterMode == .fuzzy)

            tab.focusPane(right)
            bar.modes.press(.contains)
            #expect(tab.activePane === left)
            #expect(left.content.filterMode == .contains)

            tab.focusPane(right)
            _ = bar.pin.sendAction(bar.pin.action, to: bar.pin.target)
            #expect(tab.activePane === left)
            #expect((left.content.pinnedFilter != nil))

            tab.focusPane(right)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
            bar.mouseDown(with: event)
            #expect(tab.activePane === left)
            #expect((left.content.pinnedFilter != nil))
            await harness.close()
        }

        @Test func theBarTurnsRedWhenNothingMatchesAndGoesWithTheFilter() async throws {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Few", files: 5).path
            let tab = try await harness.open(path)
            #expect(await waitUntil { tab.content.entries.count == 5 })
            let bar = tab.content.container.filterBar
            tab.content.applyFilterKey(.type("0"))
            #expect(!bar.nothingMatches)
            #expect(bar.edgeColor == tab.content.theme.accent.border)
            tab.content.applyFilterKey(.type("zq"))
            #expect(tab.content.entries.isEmpty)
            #expect(bar.nothingMatches)
            #expect(bar.edgeColor == tab.content.theme.palette.danger)
            tab.content.applyFilterKey(.clear)
            #expect(!bar.isShowingFilter)
            #expect(!bar.nothingMatches)
            await harness.close()
        }
    }
}
