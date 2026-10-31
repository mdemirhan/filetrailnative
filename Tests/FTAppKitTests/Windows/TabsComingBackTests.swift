// Ports what the round 3 sweep found of useExplorerTabs.ts (the keyboard on a tab shown), of `navigateTo` keeping the
// metadata cache, and of TreePane.tsx's `treeVisibilityVersion`, on windows that are never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct TabsComingBackTests: SidebarTesting {
        // A tab shown again gives the keyboard to its pane, not to the search field it was left in (209). F-724 B-SRCH-164
        @Test func aTabComingBackGivesTheKeyboardToItsPaneNotTheSearchField() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            first.perform(.focusFileSearch)
            #expect(first.searchField?.isActive == true)
            first.perform(.newTab)
            let group = try #require(first.group)
            #expect(await waitUntil { group.tabs.count == 2 })
            group.select(group.tabs[1])
            group.select(first)
            #expect(first.searchField?.isActive == false)
            #expect(first.window?.firstResponder === first.content.focusView)
            await harness.close()
        }

        // A tab only passed through on the way to another isn't read, and still owes its tree a read when it comes back
        @Test func aTabPassedThroughKeepsItsTreeOutOfDate() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            first.perform(.newTab)
            let group = try #require(first.group)
            #expect(await waitUntil { group.tabs.count == 2 })
            first.treeOutOfDate = true
            first.cameBack()
            #expect(!first.treeOutOfDate)
            first.wentToTheBack(for: group.tabs[1])
            #expect(first.treeOutOfDate)
            await settle()
            #expect(first.treeOutOfDate)
            first.cameBack()
            await settle()
            #expect(!first.treeOutOfDate)
            await harness.close()
        }

        // The folder is read again with hidden files shown: a folder a move went into keeps the date read before,
        // as `navigateTo` keeps the metadata cache (a17). F-683 B-NAV-130
        @Test func showingHiddenFilesLeavesTheDetailsAlreadyRead() async throws {
            let harness = try ExplorerHarness.windowless()
            let manager = FileManager.default
            let inbox = harness.folder.appending("Inbox")
            try manager.createDirectory(at: inbox, withIntermediateDirectories: false)
            let old = Date(timeIntervalSince1970: 1_700_000_000)
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: inbox.path)
            let tab = try await harness.open()
            let path = try #require(tab.content.listed.first { $0.name == "Inbox" }?.path)
            tab.content.requestMetadata(for: [path])
            #expect(await waitUntil { tab.content.metadata(for: path) != nil })
            let read = tab.content.metadata(for: path)?.modifiedAt

            try manager.moveItem(at: harness.folder.appending("note.txt"), to: inbox.appendingPathComponent("note.txt"))
            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { !tab.isNavigating })
            await settle()
            #expect(tab.content.staleMetadata.isEmpty)
            tab.content.requestMetadata(for: [path])
            await settle()
            #expect(tab.content.metadata(for: path)?.modifiedAt == read)
            await harness.close()
        }

        // A favorite more makes the tree shorter: the selected row is brought back into view (a16). F-732 B-TREE-034
        @Test func aFavoriteAddedKeepsTheSelectedTreeRowInView() async throws {
            let harness = try ExplorerHarness.windowless()
            for index in 0..<80 {
                try FileManager.default.createDirectory(
                    at: harness.folder.appending("Zed\(index + 100)"), withIntermediateDirectories: false)
            }
            let tab = try await harness.open(listed(harness, ""))
            tab.updatePreferences(["favoritesPlacement": .string("separate")])
            await rooted(tab, harness)
            let controller = sidebar(tab)
            #expect(await waitUntil { controller.tree.rowCount > 80 })
            let selected = TreeItemID.filesystem(listed(harness, "Zed179"))
            controller.model.selectItem(selected)
            await settle()
            harness.layout(tab)
            let before = try #require(controller.tree.index(ofItem: selected))
            controller.tree.reveal(before)
            #expect(controller.tree.isFullyVisible(before))
            let height = controller.tree.visibleHeight

            controller.toggleFavorite(listed(harness, "Alpha"))
            harness.layout(tab)
            #expect(controller.tree.visibleHeight < height)
            let after = try #require(controller.tree.index(ofItem: selected))
            #expect(controller.tree.isFullyVisible(after))
            await harness.close()
        }

        // The controller can outlive its tab while something still holds it; the clock must not reach the tab then
        @Test func aMinuteTickAfterATabWentDoesNotReachIt() async throws {
            let harness = try ExplorerHarness.windowless()
            var tab: MainWindowController? = try await harness.open()
            let info = try #require(tab?.infoController)
            weak let gone = tab
            tab = nil
            await harness.close()
            #expect(await waitUntil { gone == nil })
            RelativeClock.shared.windowStateDidChange()
            withExtendedLifetime(info) {}
        }
    }
}
