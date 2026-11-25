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
                await tab.navigate(to: root.appendingPathComponent(name).path)
            }
            // A click steps once.
            back.onPress?()
            back.onRelease?(true)
            back.onClick?()
            #expect(await waitUntil { NodePath.basename(tab.folderPath) == "Alpha" })
            await tab.navigate(to: root.appendingPathComponent("Alpha/Inner").path)
            harness.layout(tab)

            // Held 350 ms: the folders behind, nearest first; the click that ends the hold does not step.
            back.onPress?()
            #expect(await waitUntil { menu != nil })
            back.onRelease?(true)
            back.onClick?()
            #expect(NodePath.basename(tab.folderPath) == "Inner")
            #expect(titles(menu).count == 2)
            #expect(menu?.items.first?.title == "Alpha")
            #expect(menu?.markedIndex == 0)
            // Choosing one is a jump, adding nothing to the history.
            menu?.onChoose(1)
            #expect(
                await waitUntil {
                    tab.historyIndex == 0 && NodePath.basename(tab.folderPath) == root.lastPathComponent
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
        let switcher = try #require(toolbar.button(.viewMenu))
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
        #expect(toolbar.item(.title)?.isVisible == true)
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

    // In a full toolbar the field takes its wider width from the title and the items the system moves to its » menu.
    // Let go empty with Esc, it is back at its own width in one step, the items with it, and stays open: no folding to
    // the magnifier and opening again. A click and ⌘F both widen it before it takes the keyboard.
    @Test func aFieldInAFullToolbarWidensAndNarrowsInOneStep() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        let toolbar = tab.explorerToolbar
        setItems(
            tab,
            [
                .folderTree, .back, .forward, .refresh, .title, .newFolder, .view, .viewOptions, .search, .up,
                .hidden, .newTab, .infoPanel,
            ], harness)
        let title = try #require(toolbar.titleView)
        let field = try #require(tab.searchField)
        let layout = DesignTokens.toolbar
        // Room for the field at its own width, with some to spare, and not for its wider one.
        let spare = Double(title.frame.width) - layout.titleMinWidth
        window.setContentSize(NSSize(width: window.contentLayoutRect.width - spare + 60, height: 600))
        harness.layout(tab)
        #expect(await waitUntil { toolbar.searchOpen && title.frame.width > layout.titleMinWidth + 30 })
        try await Task.sleep(for: .milliseconds(200))

        func widened(_ way: String) {
            #expect(field.holdsKeyboard, "\(way)")
            // Its whole wider width, not only wider than its own: a system that kept the field to its own limit of
            // 325 points (`ExplorerToolbar.liftSystemSearchWidthLimit` lifts it, by what AppKit's views are today)
            // fails here.
            #expect(
                abs(Double(field.frame.width) - layout.searchFocusedWidth) < 1,
                "\(way): the field is \(field.frame.width) wide with the keyboard, not \(layout.searchFocusedWidth)")
            #expect(!overflowed(toolbar).isEmpty, "\(way): nothing went to the » menu")
        }
        func letGoAndWatch(_ way: String) async throws {
            key(53, "\u{1b}", in: window)
            #expect(!field.holdsKeyboard, "\(way): Esc left the keyboard in the field")
            try await Task.sleep(for: .milliseconds(30))
            #expect(abs(Double(field.frame.width) - layout.searchWidth) < 1, "\(way): \(field.frame.width)")
            #expect(overflowed(toolbar).isEmpty, "\(way): items stayed in the » menu: \(overflowed(toolbar))")
            var seen: Set<String> = []
            let end = ContinuousClock.now + .milliseconds(500)
            while ContinuousClock.now < end {
                seen.insert(toolbar.searchOpen && field.window != nil ? "\(Int(field.frame.width))" : "folded")
                try await Task.sleep(for: .milliseconds(4))
            }
            #expect(seen == ["\(Int(layout.searchWidth))"], "\(way): \(seen)")
        }

        mouse(.leftMouseDown, at: center(of: field), in: window)
        mouse(.leftMouseUp, at: center(of: field), in: window)
        widened("a click")
        try await letGoAndWatch("a click")

        // ⌘F: the system's item gives the field the keyboard without the field's becomeFirstResponder.
        tab.search.focusField()
        widened("⌘F")
        // As a person would: Esc at once comes before the system's item is done giving the field the keyboard, and it
        // gives it back.
        try await Task.sleep(for: .milliseconds(400))
        try await letGoAndWatch("⌘F")
        await harness.close()
    }

    // A toolbar with room for the field only folded. Opened by its magnifier and let go empty, the field folds again
    // once it is back at its own width, and the items it put in the » menu come back: it rests as it was, not open
    // with them in the » menu.
    @Test func aFieldLetGoWhereItDoesntFitFoldsAgain() async throws {
        let harness = try ExplorerHarness()
        let tab = try await harness.open()
        let window = try #require(tab.window)
        let toolbar = tab.explorerToolbar
        setItems(
            tab,
            [
                .folderTree, .back, .forward, .refresh, .title, .newFolder, .view, .viewOptions, .search, .up,
                .hidden, .newTab, .infoPanel,
            ], harness)
        let title = try #require(toolbar.titleView)
        let layout = DesignTokens.toolbar
        // The title would have 100 pt to spare with the field folded: short of what it needs to open.
        let spare = Double(title.frame.width) - layout.titleMinWidth
        let folded = layout.searchWidth - ToolbarButton.iconOnlyWidth
        window.setContentSize(NSSize(width: window.contentLayoutRect.width - spare - folded + 100, height: 600))
        harness.layout(tab)
        #expect(await waitUntil { !toolbar.searchOpen && overflowed(toolbar).isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        let resting = title.frame.width

        let magnifier = try #require(toolbar.item(.search)?.view as? ToolbarButton)
        magnifier.onClick?()
        let field = try #require(tab.searchField)
        #expect(toolbar.searchOpen && field.holdsKeyboard)
        // As a person would: Esc at once comes before the system's item is done giving the field the keyboard, and it
        // gives it back.
        try await Task.sleep(for: .milliseconds(400))
        key(53, "\u{1b}", in: window)
        #expect(!field.holdsKeyboard)
        try await Task.sleep(for: .milliseconds(900))
        #expect(!toolbar.searchOpen, "the field stayed open")
        #expect(overflowed(toolbar).isEmpty, "items stayed in the » menu: \(overflowed(toolbar))")
        #expect(abs(title.frame.width - resting) < 1)
        await harness.close()
    }
}

/// The app's items in the system's » menu.
@MainActor
private func overflowed(_ toolbar: ExplorerToolbar) -> [String] {
    toolbar.toolbar.items.compactMap { item in
        guard let id = ExplorerToolbar.itemID(item.itemIdentifier), id != .topSeparator, !item.isVisible,
            !item.isHidden
        else { return nil }
        return id.rawValue
    }
}
