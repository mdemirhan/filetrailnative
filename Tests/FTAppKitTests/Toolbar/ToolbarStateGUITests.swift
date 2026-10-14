// Ports the right-click, search-mode, menu-resize and customizing states of
// apps/desktop/src/renderer/components/ExplorerWorkspace.tsx on a real explorer window
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests.ToolbarGUITests {
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        window.sendEvent(event)
    }

    func center(of view: NSView) -> NSPoint {
        let rect = view.convert(view.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    // F-717 B-VIEW-128: only the title and the empty room offer Customize Toolbar…; the other items keep their
    // right-clicks (none, or Back's and Forward's history).
    @Test func leavesARightClickOnAnItemAlone() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        setItems(tab, ToolbarItems.defaultTopItems + [.up], harness)
        for id in [ToolbarItemID.sort, .back, .up, .folderTree, .viewOptions] {
            let item = try #require(button(tab, id))
            mouse(.rightMouseDown, at: center(of: item), in: window)
            #expect(menu == nil, "\(id)")
        }
        let switcher = try #require(tab.workspace.toolbar.slotViews["view"]?.content as? ToolbarViewSwitch)
        mouse(.rightMouseDown, at: center(of: switcher.segments[0]), in: window)
        #expect(menu == nil)
        let title = try #require(tab.workspace.toolbar.slotViews["title"]?.content as? ToolbarTitleView)
        mouse(.rightMouseDown, at: center(of: title), in: window)
        #expect(titles(menu) == ["Customize Toolbar…"])
        AppMenuPresenter.shared.close()
        await harness.close()
    }

    // B-VIEW-119: in search mode the title names the folder searched; Sort waits (search results are sorted in their
    // headers).
    @Test func titlesTheToolbarWithTheSearchedFolderInSearchMode() async throws {
        let harness = try ExplorerHarness()
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
        let harness = try ExplorerHarness()
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
        let harness = try ExplorerHarness()
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

    // F-718 B-VIEW-135: a handle pressed with the pointer shows no focus ring; after a drag the handle under the
    // pointer shows the hover ring. A key brings the focus ring back.
    @Test func showsTheFocusRingOnlyForTheKeyboardAndTheHoverRingWhereADragEnds() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        tab.perform(.customizeToolbar)
        let customizer = try #require(tab.customizer)
        harness.layout(tab)
        let back = try #require(customizer.editLayer.handle(for: "back"))
        let sort = try #require(customizer.editLayer.handle(for: "sort"))
        let start = center(of: back)
        let end = center(of: sort)
        mouse(.leftMouseDown, at: start, in: window)
        for step in 1...6 {
            let fraction = Double(step) / 6
            mouse(
                .leftMouseDragged,
                at: NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y), in: window)
        }
        mouse(.leftMouseUp, at: end, in: window)
        harness.layout(tab)
        #expect(customizer.drag == nil)
        let moved = try #require(customizer.editLayer.handle(for: "back"))
        #expect(moved.ring != .focus)
        let under = customizer.editLayer.subviews.compactMap { $0 as? ToolbarHandleView }
            .first { $0.bounds.contains($0.convert(end, from: nil)) }
        #expect(under?.ring == .hover)

        // → from the keyboard: the next handle has the keyboard, with its ring.
        window.makeFirstResponder(moved)
        key(124, "", in: window)
        let focused = try #require(window.firstResponder as? ToolbarHandleView)
        #expect(focused.ring == .focus)
        tab.finishCustomizingToolbar()
        await harness.close()
    }
}
