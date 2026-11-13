// Real mouse events through the window, and the system's customizing sheet
import AppKit
import FTFoundation
import FTOperations
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ToolbarGUITests: ToolbarTesting {
        // On screen: the hold's timer fires outside the test's task, so it opens the app's menu, not a windowless test's own.
        @Test func stepsOnAClickAndListsTheFoldersWhenHeld() async throws {
            let harness = try ExplorerHarness()
            let root = harness.folder.url
            let tab = try await harness.open(root.path)
            let back = try #require(button(tab, .back))
            // No history: no menu.
            back.onRightClick?()
            #expect(menu == nil)
            for name in ["Alpha", "Alpha/Inner"] {
                await tab.navigate(to: root.appendingPathComponent(name))
            }
            // A click steps once.
            back.onPress?()
            back.onRelease?(true)
            back.onClick?()
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Alpha" })
            await tab.navigate(to: root.appendingPathComponent("Alpha/Inner"))
            harness.layout(tab)

            // Held 350 ms: the folders behind, nearest first; the click that ends the hold does not step.
            back.onPress?()
            #expect(await waitUntil { menu != nil })
            back.onRelease?(true)
            back.onClick?()
            #expect(tab.currentFolder.lastPathComponent == "Inner")
            #expect(titles(menu).count == 2)
            #expect(menu?.items.first?.title == "Alpha")
            #expect(menu?.markedIndex == 0)
            // Choosing one is a jump, adding nothing to the history.
            menu?.onChoose(1)
            #expect(
                await waitUntil {
                    tab.historyIndex == 0 && tab.currentFolder.lastPathComponent == root.lastPathComponent
                })
            #expect(tab.historyPaths.count == 3)

            // Released before 350 ms: no menu.
            let forward = try #require(button(tab, .forward))
            forward.onPress?()
            forward.onRelease?(true)
            try await Task.sleep(for: .milliseconds(400))
            #expect(menu == nil)
            // A right-click opens it at once; Escape closes it.
            forward.onRightClick?()
            #expect(menu != nil)
            key(53, "\u{1b}", in: tab.window)
            #expect(menu == nil)
            await harness.close()
        }
    }
}

extension ExplorerWindowGUITests.ToolbarGUITests {
    // Customize Toolbar… opens the system's sheet on the window, and the items wait under it, as under
    // any sheet. Ending the sheet lets them go. The empty clipboard and Undo History buttons show while it is up, so
    // they can be moved beside other buttons, and go again after.
    @Test func customizesInTheSystemsSheetAndTheItemsWaitUnderIt() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        let toolbar = tab.explorerToolbar
        let history = UndoHistory()
        toolbar.undoHistory = { history }
        setItems(tab, ToolbarItems.defaultTopItems + [.undoHistory, .newTab], harness)
        #expect(toolbar.item(.clipboard)?.isHidden == true)
        #expect(toolbar.item(.undoHistory)?.isHidden == true)
        let switcher = try #require(toolbar.viewSwitch)
        #expect(switcher.isEnabled && toolbar.button(.sort)?.isEnabled == true)
        tab.perform(.customizeToolbar)
        #expect(await waitUntil { window.attachedSheet != nil })
        #expect(toolbar.isCustomizing && tab.isCustomizingToolbar)
        #expect(await waitUntil { toolbar.item(.clipboard)?.isHidden == false })
        #expect(toolbar.item(.undoHistory)?.isHidden == false)
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
        #expect(await waitUntil { toolbar.item(.clipboard)?.isHidden == true })
        #expect(toolbar.item(.undoHistory)?.isHidden == true)
        await harness.close()
    }

    // In a narrow window the system moves the removable items to its » menu; the required ones stay.
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
}
