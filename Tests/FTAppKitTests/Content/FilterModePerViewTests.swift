// Fuzzy and Contains belong to each view: a folder's list or a search's results keeps its own, and the setting and
// other views' choices only decide what views opened later start with
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FilterModePerViewTests {
        /// A tab with two panes on the harness's folder and its Alpha, both read, the left one active.
        private func twoPanes() async throws -> (ExplorerHarness, MainWindowController) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let right = tab.openSecondPane(at: harness.folder.appending("Alpha").path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            harness.layout(tab)
            tab.activate(tab.panes[0])
            #expect(tab.preferences.listFilterMatch == .fuzzy)
            return (harness, tab)
        }

        /// `pane` shows the results of a stand-in search that finds `note.txt`.
        @discardableResult
        private func search(_ tab: MainWindowController, _ pane: BrowserPane, _ query: String = "no") async
            -> FakeSearchEngine
        {
            let engine = FakeSearchEngine()
            engine.finds = { _ in (["note.txt"], false, false) }
            pane.search.session.engine = engine
            pane.search.session.submit(query)
            #expect(await waitUntil { pane.search.session.isSearchMode && pane.content.entries.count == 1 })
            return engine
        }

        private func chip(_ pane: BrowserPane) -> NameMatchMode { pane.search.header.filter.modeChip.mode }

        // In two folders with nothing typed, Contains chosen in one leaves the other in Fuzzy; a pane opened next starts
        // in Contains.
        @Test func aFolderChosenInOnePaneLeavesTheOther() async throws {
            let (harness, tab) = try await twoPanes()
            let (left, right) = (tab.panes[0], tab.panes[1])

            left.content.onToggleFilterMode?()
            #expect(left.content.filterMode == .contains)
            #expect(right.content.filterMode == .fuzzy)
            #expect(tab.preferences.listFilterMatch == .contains)
            // Typing in each starts in its own.
            left.content.applyFilterKey(.type("a"))
            right.content.applyFilterKey(.type("i"))
            #expect(left.content.filterMode == .contains)
            #expect(right.content.filterMode == .fuzzy)
            // Cleared, each keeps its own; another folder in the same pane too.
            left.content.applyFilterKey(.clear)
            right.content.applyFilterKey(.clear)
            #expect(left.content.filterMode == .contains)
            #expect(right.content.filterMode == .fuzzy)
            right.go(to: harness.folder.appending("Beta"))
            #expect(await waitUntil { right.folder.lastPathComponent == "Beta" && !right.isNavigating })
            #expect(right.content.filterMode == .fuzzy)

            // The right pane closed and opened again is a new view: it starts in Contains.
            tab.activate(right)
            tab.closePane()
            let reopened = tab.openSecondPane(at: harness.folder.path)
            #expect(await waitUntil { reopened.loaded && reopened.hasShownFolder && !reopened.isNavigating })
            #expect(reopened.content.filterMode == .contains)
            #expect(tab.panes[0].content.filterMode == .contains)
            await harness.close()
        }

        // The setting changes no view open: not one with nothing typed, nor one in another folder after; a pane opened
        // after it starts in it.
        @Test func theSettingChangesNoViewOpen() async throws {
            let (harness, tab) = try await twoPanes()
            let (left, right) = (tab.panes[0], tab.panes[1])
            try await search(tab, right)
            #expect(chip(right) == .fuzzy)

            tab.updatePreferences { $0.listFilterMatch = .contains }
            #expect(await waitUntil { tab.preferences.listFilterMatch == .contains })
            for _ in 0..<5 { await Task.yield() }
            #expect(left.content.filterMode == .fuzzy)
            #expect(right.content.filterMode == .fuzzy)
            #expect(chip(right) == .fuzzy)
            left.go(to: harness.folder.appending("Gamma"))
            #expect(await waitUntil { left.folder.lastPathComponent == "Gamma" && !left.isNavigating })
            #expect(left.content.filterMode == .fuzzy)

            right.search.session.hideResults()
            tab.activate(right)
            tab.closePane()
            #expect(tab.panes.count == 1 || !tab.showsTwoPanes)
            let reopened = tab.openSecondPane(at: harness.folder.path)
            #expect(await waitUntil { reopened.loaded && reopened.hasShownFolder && !reopened.isNavigating })
            #expect(reopened.content.filterMode == .contains)
            await harness.close()
        }

        // Two panes of search results with nothing typed: Contains chosen in one leaves the other's chip in Fuzzy.
        // Done gives the folder back in its own mode; results brought back come in theirs; a search opened next starts
        // in Contains, and a new query in results already open keeps their mode.
        @Test func resultsKeepTheirOwnMode() async throws {
            let (harness, tab) = try await twoPanes()
            let (left, right) = (tab.panes[0], tab.panes[1])
            try await search(tab, left)
            tab.activate(right)
            try await search(tab, right)
            tab.activate(left)

            left.search.header.filter.onToggleMode()
            #expect(chip(left) == .contains)
            #expect(left.content.filterMode == .contains)
            #expect(chip(right) == .fuzzy)
            #expect(right.content.filterMode == .fuzzy)
            #expect(tab.preferences.listFilterMatch == .contains)

            // A new query in results already open keeps their mode.
            right.search.session.submit("not")
            #expect(await waitUntil { right.search.session.committedQuery == "not" })
            #expect(chip(right) == .fuzzy)

            // Done: the folder comes back in the mode it had, Fuzzy.
            left.search.session.hideResults()
            #expect(!left.search.session.isSearchMode)
            #expect(left.content.filterMode == .fuzzy)
            // Brought back, the results are in Contains, as they were left.
            left.search.session.showCachedResults()
            #expect(left.search.session.isSearchMode)
            #expect(left.content.filterMode == .contains)
            #expect(chip(left) == .contains)

            // Results opened again from the folder, for a new search, start in Contains.
            right.search.session.hideResults()
            #expect(right.content.filterMode == .fuzzy)
            tab.activate(right)
            try await search(tab, right, "note")
            #expect(right.content.filterMode == .contains)
            #expect(chip(right) == .contains)
            left.search.session.hideResults()
            right.search.session.hideResults()
            await harness.close()
        }
    }
}
