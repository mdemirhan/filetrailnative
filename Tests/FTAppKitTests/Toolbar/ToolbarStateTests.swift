// Ports the search-mode, menu-resize and customizing states of
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
        let toolbar = tab.workspace.toolbar
        let title = try #require(toolbar.slotViews["title"]?.content as? ToolbarTitleView)
        #expect(title.field.stringValue == harness.folder.url.lastPathComponent)
        tab.searchRootPath = harness.folder.appending("Alpha").path
        #expect(title.field.stringValue == "Searching “Alpha”")
        #expect(button(tab, .sort)?.isEnabled == false)
        tab.searchRootPath = nil
        #expect(title.field.stringValue == harness.folder.url.lastPathComponent)
        #expect(button(tab, .sort)?.isEnabled == true)
        await harness.close()
    }

    // B-VIEW-126 B-VIEW-127: Sort follows its button as the window is resized and closes when the row's items
    // change; View Options stays open; Theme closes on a resize.
    @Test func keepsTheSortAndViewOptionsMenusOpenWhileTheWindowIsResized() async throws {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        let toolbar = tab.workspace.toolbar
        // No separator: a toolbar with one never leaves items out (it measures 0 wide, as in the original).
        setItems(
            tab, [.folderTree, .back, .forward, .title, .view, .sort, .search, .viewOptions, .infoPanel, .theme],
            harness)
        window.setContentSize(NSSize(width: 1400, height: 700))
        harness.layout(tab)
        let sort = try #require(button(tab, .sort))
        _ = sort.accessibilityPerformPress()
        #expect(menu != nil)
        window.setContentSize(NSSize(width: 1460, height: 700))
        harness.layout(tab)
        let opened = try #require(menu)
        let host = try #require(window.contentView)
        let anchor = sort.convert(sort.bounds, to: host)
        let left = max(12, min(anchor.minX, host.bounds.width - 200 - 12))
        #expect(abs(opened.frame.minX - left) < 0.5)

        _ = button(tab, .viewOptions)?.accessibilityPerformPress()
        #expect(menu != nil)
        window.setContentSize(NSSize(width: 1450, height: 700))
        harness.layout(tab)
        #expect(menu != nil)

        _ = button(tab, .theme)?.accessibilityPerformPress()
        #expect(menu != nil)
        window.setContentSize(NSSize(width: 1440, height: 700))
        harness.layout(tab)
        #expect(menu == nil)

        // Narrower until an item leaves the row: the Sort menu goes with it.
        _ = sort.accessibilityPerformPress()
        #expect(menu != nil)
        let before = toolbar.rowKeys
        var width = 1440.0
        while toolbar.rowKeys == before, width > Double(MainWindowController.minimumSize.width) {
            width -= 20
            window.setContentSize(NSSize(width: width, height: 700))
            harness.layout(tab)
        }
        #expect(toolbar.rowKeys != before)
        #expect(menu == nil)
        await harness.close()
    }

    // The row's commands wait while the toolbar is customized (`sheetOpen`): drawn dimmed, as disabled.
    @Test func disablesTheViewSwitchSortAndCommandsWhileCustomizing() async throws {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        setItems(tab, ToolbarItems.defaultTopItems + [.newTab], harness)
        let switcher = try #require(tab.workspace.toolbar.slotViews["view"]?.content as? ToolbarViewSwitch)
        #expect(switcher.isEnabled && button(tab, .sort)?.isEnabled == true)
        tab.perform(.customizeToolbar)
        harness.layout(tab)
        #expect(!switcher.isEnabled)
        #expect(button(tab, .sort)?.isEnabled == false)
        #expect(button(tab, .newTab)?.isEnabled == false)
        tab.finishCustomizingToolbar()
        harness.layout(tab)
        #expect(switcher.isEnabled)
        #expect(button(tab, .sort)?.isEnabled == true)
        #expect(button(tab, .newTab)?.isEnabled == true)
        await harness.close()
    }
}
