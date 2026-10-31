// Ports the right-click and customizing states of apps/desktop/src/renderer/components/ExplorerWorkspace.tsx on a
// real explorer window on screen: real mouse events through the window, and the system's customizing sheet
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests.ToolbarGUITests {
    // N/A T-19d51434 T-bb62d104 the toolbar's right-click menu is the system's, with Customize Toolbar… (D-016); F-717
    // likewise. Back's and Forward's history stay theirs: stepsOnAClickAndListsTheFoldersWhenHeld.
    // F-718 F-719 F-720: Customize Toolbar… opens the system's sheet on the window, and the items wait under it, as under
    // any sheet. Ending the sheet lets them go.
    // F-718 F-719 F-720
    @Test func customizesInTheSystemsSheetAndTheItemsWaitUnderIt() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        setItems(tab, ToolbarItems.defaultTopItems + [.newTab], harness)
        let toolbar = tab.explorerToolbar
        let switcher = try #require(toolbar.viewSwitch)
        #expect(switcher.isEnabled && toolbar.button(.sort)?.isEnabled == true)
        tab.perform(.customizeToolbar)
        #expect(await waitUntil { window.attachedSheet != nil })
        #expect(toolbar.isCustomizing && tab.isCustomizingToolbar)
        #expect(!switcher.isEnabled)
        #expect(toolbar.button(.sort)?.isEnabled == false)
        #expect(toolbar.button(.newTab)?.isEnabled == false)
        let sheet = try #require(window.attachedSheet)
        // The scenarios wait for the sheet by this name.
        AutomationTags.apply(in: sheet)
        #expect(sheet.contentView?.accessibilityIdentifier() == "toolbar.customize")
        // A space stays where it was put while the sheet is up, and goes with it if it ended up dividing nothing.
        let native = toolbar.toolbar
        native.insertItem(withItemIdentifier: .space, at: native.items.count)
        try await Task.sleep(for: .milliseconds(200))
        #expect(native.items.last?.itemIdentifier == .space)
        window.endSheet(sheet)
        #expect(await waitUntil { window.attachedSheet == nil })
        #expect(await waitUntil { native.items.last?.itemIdentifier != .space })
        #expect(await waitUntil { switcher.isEnabled })
        #expect(toolbar.button(.sort)?.isEnabled == true)
        #expect(toolbar.button(.newTab)?.isEnabled == true)
        await harness.close()
    }

    // In a narrow window the system moves the removable items to its » menu; the required ones stay.
    // F-716
    @Test func aNarrowWindowMovesTheRemovableItemsOut() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        setItems(
            tab, [.folderTree, .back, .forward, .title, .view, .sort, .search, .viewOptions, .hidden, .up, .newTab],
            harness)
        window.setContentSize(MainWindowController.minimumSize)
        harness.layout(tab)
        let toolbar = tab.explorerToolbar
        #expect(await waitUntil { toolbar.item(.newTab)?.isVisible == false })
        #expect(toolbar.item(.viewOptions)?.isVisible == true)
        // Under a dialog the system's » button is covered as the items are.
        let frameView = try #require(window.contentView?.superview)
        let overflow = try #require(
            Views.all(NSView.self, in: frameView).first {
                String(describing: type(of: $0)) == "NSToolbarClippedItemsIndicator"
            })
        tab.perform(.openLocationSheet)
        let scrim = try #require(tab.dialogs.first)
        let center = overflow.convert(NSPoint(x: overflow.bounds.midX, y: overflow.bounds.midY), to: nil)
        #expect(scrim.titlebarPress(at: center) == .scrim)
        tab.goToBox?.onClose()
        await harness.close()
    }

    // F-807: the system's ✕ says what the original's does, and text of only spaces has none.
    // B-SRCH-053
    @Test func theSystemsClearButtonSaysWhatTheOriginalsDoes() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let field = try #require(tab.searchField)
        field.stringValue = "abc"
        #expect(await waitUntil { field.clearButton?.isHidden == false })
        let clear = try #require(field.clearButton)
        #expect(clear.toolTip == SearchBarText.clearSearchTitle)
        #expect(clear.accessibilityLabel() == SearchBarText.clearSearchName)
        #expect(clear.accessibilityIdentifier() == "toolbar.search.clear")
        #expect(clear.alphaValue == 1 && clear.isEnabled)
        field.stringValue = "   "
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.clearButton?.alphaValue == 0)
        #expect(field.clearButton?.isEnabled == false)
        field.stringValue = "abc"
        try await Task.sleep(for: .milliseconds(300))
        #expect(field.clearButton?.alphaValue == 1)
        var cleared = 0
        let onClear = field.onClear
        field.onClear = {
            cleared += 1
            onClear()
        }
        field.clearButton?.performClick(nil)
        #expect(cleared == 1)
        await harness.close()
    }
}
