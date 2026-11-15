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

        // With the keyboard in the folder tree, the active pane closes and the keyboard stays in the tree.
        @Test func withTheKeyboardInTheTreeTheActivePaneClosesAndTheTreeKeepsTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            tab.focusPane(right)
            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)

            tab.perform(.closePane)
            #expect(tab.panes.count == 1)
            #expect(tab.activePane === left)
            #expect(tab.focusedPane == .tree)
        }

        // A name being edited holds the pane, as it holds the tab: nothing closes, and the name stays open.
        @Test func aNameBeingEditedHoldsThePane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, _) = try await twoPanes(harness)
            let note = try #require(left.content.entries.first { $0.name == "note.txt" }?.path)
            #expect(left.content.beginRename(path: note))

            tab.perform(.closePane)
            #expect(tab.panes.count == 2)
            #expect(left.content.inlineRename?.path == note)
            left.content.renameCancelled()
        }

        // A pane closed while it shows search results: its search goes with it, and the tab shows the other pane's
        // folder with no search on screen.
        @Test func closingAPaneThatShowsSearchResultsEndsItsSearch() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            tab.focusPane(right)
            let engine = FakeSearchEngine()
            engine.finds = { _ in (["a.txt"], false, false) }
            right.search.session.engine = engine
            right.search.session.submit("a")
            #expect(await waitUntil { right.search.session.isSearchMode })
            #expect(tab.searchRootPath != nil)

            tab.perform(.closePane)
            #expect(tab.panes.count == 1)
            #expect(tab.activePane === left)
            #expect(tab.searchRootPath == nil)
            // ⌘\ brings the pane back on its folder, without the search.
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.searchRootPath == nil)
            #expect(back.shownFolderPath == real(harness, "Alpha"))
        }

        // The tab is saved with the pane that is left as its only one, the right one too once the left has closed.
        @Test func theTabIsSavedWithThePaneThatIsLeft() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, _) = try await twoPanes(harness)
            left.content.focusList()
            #expect(tab.snapshot.secondPane != nil)

            tab.perform(.closePane)
            let saved = tab.snapshot
            #expect(saved.secondPane == nil)
            #expect(saved.currentPath == real(harness, "Alpha"))
            #expect(saved.activePane == 0)
        }

        // Show Previews at a count changes the active pane alone: the other keeps the count it had.
        @Test func aPreviewCountIsTheActivePanesAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness)
            let before = right.content.previewCount
            tab.focusPane(left)
            tab.perform(.showPreviews1)
            #expect(left.viewMode == .previews && left.content.previewCount == 1)
            #expect(right.viewMode != .previews && right.content.previewCount == before)
            #expect(before != 1)
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
