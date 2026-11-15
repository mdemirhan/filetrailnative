import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// ⌘W in a tab with two panes closes the pane it is in; with one pane, or with ⌥ (Close Tab), the tab.
    @MainActor
    @Suite struct ClosePaneTests {
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        /// A tab with its second pane on Alpha; the left pane is active.
        private func twoPanes(_ harness: ExplorerHarness) async throws -> (
            MainWindowController, BrowserPane, BrowserPane
        ) {
            let tab = try await harness.open()
            let left = tab.activePane
            let right = tab.openSecondPane(at: real(harness, "Alpha"))
            await arrived(right)
            harness.layout(tab)
            return (tab, left, right)
        }

        /// A second tab, after `tab`.
        private func newTab(after tab: MainWindowController) async throws -> MainWindowController {
            let group = try #require(tab.group)
            let count = group.tabs.count
            group.openNewTab(from: tab)
            #expect(await waitUntil { group.tabs.count == count + 1 })
            let index = try #require(group.tabs.firstIndex { $0 === tab })
            let new = group.tabs[index + 1]
            new.servicesOverride = tab.servicesOverride
            #expect(await waitUntil { new.panes.allSatisfy { $0.loaded && !$0.isNavigating } })
            return new
        }

        @Test func closesTheRightPaneWhenItIsActiveAndCmdBackslashBringsItBack() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            let group = try #require(tab.group)
            tab.focusPane(right)
            #expect(tab.menuState.twoPanesShown)

            tab.perform(.closePane)
            #expect(tab.panes.count == 1)
            #expect(tab.activePane === left)
            #expect(tab.paneWithKeyboard === left)
            #expect(group.tabs.contains { $0 === tab })
            #expect(!tab.menuState.twoPanesShown)

            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.shownFolderPath == real(harness, "Alpha"))
        }

        @Test func closesTheLeftPaneWhenItIsActiveAndTheRightOneTakesItsPlaceActiveWithTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            left.content.focusList()
            #expect(tab.activePane === left)

            tab.perform(.closePane)
            #expect(tab.panes.count == 1)
            #expect(tab.activePane === right)
            #expect(tab.activePaneIndex == 0)
            #expect(tab.paneWithKeyboard === right)
            #expect(tab.shownFolderPath == real(harness, "Alpha"))
            #expect(tab.workspace.mainCell.content === right.content.view)
            #expect(!tab.workspace.showsTwoPanes)

            // ⌘\ opens the closed one again, on the right, where it was.
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.shownFolderPath == left.shownFolderPath)
            #expect(tab.activePane === right)
        }

        @Test func withOnePaneClosesTheTab() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let second = try await newTab(after: tab)

            second.perform(.closePane)
            #expect(await waitUntil { group.tabs.count == 1 })
            #expect(group.tabs.first === tab)
        }

        @Test func closeTabClosesATabWithBothItsPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let second = try await newTab(after: tab)
            let other = second.openSecondPane()
            await arrived(other)

            second.perform(.closeTab)
            #expect(await waitUntil { group.tabs.count == 1 })
            #expect(group.tabs.first === tab)
        }
    }
}
