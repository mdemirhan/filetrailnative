// Ports the search-mode and menu-resize states of
// apps/desktop/src/renderer/components/ExplorerWorkspace.tsx on an explorer window that is never shown
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests.ToolbarTests {
    // B-VIEW-119: in search mode the title names the folder searched; Sort waits (search results are sorted in their
    // headers).
    @Test func titlesTheToolbarWithTheSearchedFolderInSearchMode() async throws {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        let title = try #require(tab.explorerToolbar.titleView)
        #expect(title.field.stringValue == harness.folder.url.lastPathComponent)
        tab.searchRootPath = harness.folder.appending("Alpha").path
        #expect(title.field.stringValue == "Searching “Alpha”")
        #expect(button(tab, .sort)?.isEnabled == false)
        tab.searchRootPath = nil
        #expect(title.field.stringValue == harness.folder.url.lastPathComponent)
        #expect(button(tab, .sort)?.isEnabled == true)
        await harness.close()
    }

    // B-VIEW-126 B-VIEW-127: the Sort menu closes when the toolbar's items change. No window is resized under a system
    // menu, which holds the pointer while it is open (D-022).
    @Test func closesTheSortMenuWhenTheItemsChange() async throws {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        setItems(
            tab, [.folderTree, .back, .forward, .title, .view, .sort, .search, .viewOptions, .infoPanel, .theme],
            harness)
        let sort = try #require(button(tab, .sort))

        // The items change: the Sort menu goes with them.
        _ = sort.accessibilityPerformPress()
        #expect(menu != nil)
        setItems(tab, [.sort, .back, .title, .search, .viewOptions], harness)
        #expect(menu == nil)
        await harness.close()
    }
}
