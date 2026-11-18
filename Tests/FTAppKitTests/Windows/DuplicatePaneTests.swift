import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// A second pane as a copy of the active one: Two Panes with no pane closed in the tab, and Duplicate Pane always.
    @MainActor
    @Suite struct DuplicatePaneTests {
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        /// A tab on Alpha, come to from the harness's folder, in Icons and with the filter in Contains.
        private func tabOnAlpha(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            await tab.activePane.navigate(to: URL(fileURLWithPath: real(harness, "Alpha")))
            tab.perform(.viewAsIcons)
            tab.activePane.content.setViewFilterMode(.contains)
            await arrived(tab.activePane)
            return tab
        }

        private func expectCopy(_ copy: BrowserPane, of source: BrowserPane) {
            #expect(copy !== source)
            #expect(copy.shownFolderPath == source.shownFolderPath)
            #expect(copy.viewMode == source.viewMode)
            #expect(copy.sortBy == source.sortBy)
            #expect(copy.sortDirection == source.sortDirection)
            #expect(copy.foldersFirst == source.foldersFirst)
            #expect(copy.navigationHistory == source.navigationHistory)
            #expect(copy.content.folderFilterMode == source.content.folderFilterMode)
        }

        @Test func twoPanesWithNoPaneClosedOpensACopyOfTheActivePaneWithItsHistoryAndFilterMode() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabOnAlpha(harness)
            let left = tab.activePane

            tab.perform(.toggleTwoPanes)
            let copy = try #require(tab.otherPane)
            await arrived(copy)

            expectCopy(copy, of: left)
            #expect(copy.viewMode == .icons)
            #expect(copy.content.folderFilterMode == .contains)
            #expect(copy.navigationHistory.paths == [real(harness), real(harness, "Alpha")])
            #expect(tab.activePane === left)
            tab.focusPane(copy)
            #expect(tab.canGoBack)
            tab.perform(.goBack)
            await arrived(copy)
            #expect(copy.shownFolderPath == real(harness))
            #expect(left.shownFolderPath == real(harness, "Alpha"))
        }

        @Test func duplicatePaneOpensACopyAndNotThePaneClosedLast() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabOnAlpha(harness)
            let left = tab.activePane
            let gamma = tab.openSecondPane(at: real(harness, "Gamma"))
            await arrived(gamma)
            tab.perform(.toggleTwoPanes)
            #expect(!tab.showsTwoPanes)

            tab.perform(.duplicatePane)
            let copy = try #require(tab.otherPane)
            await arrived(copy)
            expectCopy(copy, of: left)
            #expect(tab.activePane === left)
            #expect(tab.panes.last === copy)

            // The copy is the pane Two Panes brings back once it is closed.
            tab.perform(.toggleTwoPanes)
            tab.perform(.toggleTwoPanes)
            let back = try #require(tab.otherPane)
            await arrived(back)
            #expect(back.shownFolderPath == real(harness, "Alpha"))
        }

        @Test(arguments: [false, true])
        func duplicatePaneWithTwoPanesPutsTheCopyInPlaceOfTheOtherOnItsSide(rightActive: Bool) async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabOnAlpha(harness)
            let left = tab.activePane
            let right = tab.openSecondPane(at: real(harness, "Beta"))
            await arrived(right)
            harness.layout(tab)
            let (active, other) = rightActive ? (right, left) : (left, right)
            tab.focusPane(active)
            tab.workspace.setPaneSplit(0.35)

            tab.perform(.duplicatePane)
            harness.layout(tab)
            let copy = try #require(tab.otherPane)
            await arrived(copy)

            #expect(copy !== other)
            expectCopy(copy, of: active)
            #expect(tab.panes.count == 2)
            #expect(tab.activePane === active)
            #expect(tab.activePaneIndex == (rightActive ? 1 : 0))
            #expect(tab.workspace.activePane == tab.activePaneIndex)
            #expect(tab.paneWithKeyboard === active)
            #expect(tab.workspace.paneSplit == 0.35)
            #expect(tab.workspace.mainCell.content === tab.panes[0].content.view)
            #expect(tab.workspace.secondCell.content === tab.panes[1].content.view)
            #expect(tab.workspace.statusCell.content === tab.panes[0].content.contentShell.pathBarRow)
            #expect(tab.workspace.secondStatusCell.content === tab.panes[1].content.contentShell.pathBarRow)
        }

        @Test func showThisFolderInOtherPaneWithOnePaneOpensTheSameCopy() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await tabOnAlpha(harness)
            let left = tab.activePane
            let gamma = tab.openSecondPane(at: real(harness, "Gamma"))
            await arrived(gamma)
            tab.perform(.toggleTwoPanes)

            tab.perform(.showFolderInOtherPane)
            let copy = try #require(tab.otherPane)
            await arrived(copy)
            expectCopy(copy, of: left)
        }
    }
}
