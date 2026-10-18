// Ports the right-click and customizing states of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx on a
// real explorer window on screen: real mouse events through the window
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests.ToolbarGUITests {
    // T-19d51434 T-bb62d104 F-717 B-VIEW-128: only the title and the empty room offer Customize Toolbar…, which
    // customizes; the other items keep their right-clicks (none, or Back's and Forward's history).
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
        choose("Customize Toolbar…")
        #expect(menu == nil)
        #expect(tab.customizer != nil)
        tab.finishCustomizingToolbar()
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
