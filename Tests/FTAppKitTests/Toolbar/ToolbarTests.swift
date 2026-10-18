// Ports the UI cases of apps/desktop/src/renderer/components/ExplorerWorkspace.test.tsx on an explorer window that
// is never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// What the toolbar suites look at, press and send.
@MainActor
protocol ToolbarTesting {}

extension ToolbarTesting {
    func button(_ tab: MainWindowController, _ id: ToolbarItemID) -> ToolbarButton? {
        tab.workspace.toolbar.slotViews[id.rawValue]?.content as? ToolbarButton
    }

    func setItems(_ tab: MainWindowController, _ items: [ToolbarItemID], _ harness: ExplorerHarness) {
        tab.updatePreferences(["topToolbarItems": .array(items.map { .string($0.rawValue) })])
        harness.layout(tab)
    }

    var menu: AppMenuView? { AppMenuPresenter.shared.menu }

    func titles(_ menu: AppMenuView?) -> [String] {
        menu?.items.map { $0.kind == .separator ? "-" : $0.title } ?? []
    }

    func choose(_ title: String) {
        guard let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else {
            Issue.record("no menu item \(title)")
            return
        }
        menu.onChoose(index)
    }

    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow?) {
        guard let window,
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return }
        window.sendEvent(event)
    }

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
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ToolbarTests: ToolbarTesting {
        // N/A T-950f5cb5 T-52a1e901 T-31c46dd8 T-e5501fcb T-0d626566 T-af6e6f0a T-a669a0e1 T-9b0b8821 T-91333069 T-3e4a1c9f
        // T-12547eab T-0a9009c4 T-05bfc5d2 T-5f4a2239 T-4dabc4eb T-1be0c4f9 T-2fd182cd (TabStrip.test.tsx): the tab strip is
        // the system's tab bar (D-001, D-002, D-003, D-013, P4-02/P4-04); F-721 F-722 F-723 F-725 F-726 likewise.
        // N/A T-36bede3d (HistoryButton): the toolbar is not measured from a hidden copy; its widths are computed.
        // covered-by-feature F-718 T-b4ef483c (only a primary press on a handle starts a drag, in its mouseDown)
        // T-88f9e2d3 T-bcb2497c T-e090ff70 F-708 F-709 B-VIEW-107 B-VIEW-108 B-VIEW-109 B-VIEW-110 B-VIEW-112
        @Test func drawsTheItemsInTheirSavedOrderAndLeavesOutAnEmptyClipboardButton() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.workspace.toolbar
            #expect(
                toolbar.rowKeys == [
                    "folderTree", "topSeparator", "back", "forward", "title", "view", "sort", "search", "viewOptions",
                    "infoPanel",
                ])
            // Buttons side by side share a capsule; the separator ends one.
            #expect(toolbar.slotViews["folderTree"]?.edges == ToolbarCapsuleEdges(start: true, end: true))
            #expect(toolbar.slotViews["back"]?.edges == ToolbarCapsuleEdges(start: true, end: false))
            #expect(toolbar.slotViews["title"]?.edges == nil)

            // A saved order is drawn as saved, wherever the required items are; a missing required item is added.
            setItems(tab, [.viewOptions, .title, .back, .search], harness)
            #expect(toolbar.rowKeys == ["viewOptions", "title", "back", "search"])
            setItems(tab, [.back], harness)
            #expect(toolbar.rowKeys == ["back", "title", "search", "viewOptions"])

            // Something on the clipboard: the button shows, with its count, on a capsule with View Options.
            setItems(tab, ToolbarItems.defaultTopItems, harness)
            tab.services.clipboard.set(
                .ready(mode: .copy, sourcePaths: ["/a", "/b"], sourceEntries: [:], capturedAt: "1"), from: nil)
            toolbar.reload()
            harness.layout(tab)
            #expect(toolbar.rowKeys.contains("clipboard"))
            let clipboard = try #require(toolbar.slotViews["clipboard"]?.content as? ToolbarClipboardButton)
            #expect(clipboard.count.stringValue == "2")
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
        }

        // T-fa22d272 T-b5ab76c0 T-cd18e312 T-5ee43c38 F-716 B-VIEW-114 B-VIEW-115 B-VIEW-116 B-VIEW-117
        @Test func hidesTheItemsNearestTheEndInANarrowWindowAndListsThemUnderTheOverflowButton() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.workspace.toolbar
            setItems(
                tab, [.folderTree, .back, .forward, .title, .view, .sort, .search, .viewOptions, .hidden, .up], harness)
            tab.window?.setContentSize(NSSize(width: 820, height: 600))
            harness.layout(tab)
            #expect(!toolbar.overflowSlots.isEmpty)
            #expect(toolbar.overflowSlots.map(\.key).last == "up")
            // The required items always stay.
            for key in ["title", "search", "viewOptions"] { #expect(toolbar.rowKeys.contains(key)) }

            // The » menu lists what has no room, as the menu bar words it.
            let overflow = try #require(
                toolbar.subviews.compactMap { ($0 as? ToolbarSlotView)?.content as? ToolbarButton }
                    .first { $0.accessibilityIdentifier() == "toolbar.overflow" })
            _ = overflow.accessibilityPerformPress()
            #expect(titles(menu).contains("Enclosing Folder"))
            if toolbar.overflowSlots.contains(where: { $0.id == .hidden }) {
                #expect(menu?.items.first { $0.title == "Hidden Files" }?.checked == false)
                choose("Hidden Files")
                #expect(tab.viewState.includeHidden)
            }
            // With no room for anything else, only the required items stay.
            tab.window?.setContentSize(NSSize(width: Double(MainWindowController.minimumSize.width), height: 600))
            tab.updatePanels {
                $0.folderTreeOpen = true
                $0.treeWidth = 520
            }
            harness.layout(tab)
            #expect(toolbar.visibleOptionalCount < 7)
            await harness.close()
        }

        // T-419c42ea T-f1212345 T-b996c44a T-d3420fb9 T-2dedcc21 F-709 B-VIEW-120 B-VIEW-122 B-VIEW-123 B-VIEW-131
        @Test func togglesSayWhatAClickWillDoAndButtonsRunTheirCommands() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(harness.folder.appending("Alpha").path)
            setItems(
                tab, ToolbarItems.defaultTopItems + [.foldersFirst, .hidden, .infoRow, .up, .openSelection], harness)
            let tree = try #require(button(tab, .folderTree))
            #expect(tree.isOn)
            #expect(tree.tooltip.hasPrefix("Hide Folder Tree"))
            _ = tree.accessibilityPerformPress()
            #expect(await waitUntil { !tab.panels.folderTreeOpen })
            #expect(!tree.isOn)
            #expect(tree.tooltip.hasPrefix("Show Folder Tree"))

            let hidden = try #require(button(tab, .hidden))
            #expect(hidden.tooltip.hasPrefix("Show Hidden Files"))
            _ = hidden.accessibilityPerformPress()
            #expect(hidden.isOn && hidden.icon.name == .hiddenShown)
            #expect(hidden.tooltip.hasPrefix("Hide Hidden Files"))

            // A content-only command is off with nothing selected. (The window opens with the sidebar holding the
            // keyboard, where Open acts on the selected folder, so the file list takes it first.)
            tab.content.focusList()
            tab.workspace.toolbar.refreshStates()
            #expect(button(tab, .openSelection)?.isEnabled == false)
            // Enclosing Folder runs its command.
            _ = button(tab, .up)?.accessibilityPerformPress()
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == harness.folder.url.lastPathComponent })
            await harness.close()
        }

        // T-f0cce867 F-711 B-VIEW-234: the View menu switches to icons, the toolbar's view switch back to the list;
        // the switch's segments say their keys.
        @Test func switchesTheViewFromTheMenuAndBackFromTheToolbar() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsIcons)
            let switcher = try #require(tab.workspace.toolbar.slotViews["view"]?.content as? ToolbarViewSwitch)
            #expect(switcher.selected == .icons)
            #expect(
                switcher.segments.map(\.tooltip) == [
                    "View as Icons (⌘1)", "View as List (⌘2)", "View as Compact List (⌘3)",
                ])
            _ = switcher.segments[1].accessibilityPerformPress()
            #expect(tab.viewState.viewMode == .details)
            #expect(switcher.selected == .details)
            await harness.close()
        }

        // T-dbfcc99f F-806 B-DLG-244 B-VIEW-130
        @Test func choosesAutoLightOrDarkFromTheThemeButtonsMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            setItems(tab, ToolbarItems.defaultTopItems + [.theme], harness)
            let theme = try #require(button(tab, .theme))
            #expect(theme.tooltip == "Theme: Light")
            _ = theme.accessibilityPerformPress()
            #expect(titles(menu) == ["Auto", "Light", "Dark"])
            #expect(menu?.items.first { $0.checked == true }?.title == "Light")
            #expect(theme.menuOpen)
            choose("Dark")
            #expect(menu == nil)
            #expect(harness.store.preferences().theme == .dark)
            #expect(theme.tooltip == "Theme: Dark")
            await harness.close()
        }

        // T-ad6435d1 T-709e0d2c T-612dbec6 T-addfcb64 T-0d8f5ac1 F-718 F-719 F-720 B-VIEW-132 B-VIEW-133 B-VIEW-134
        // B-VIEW-138 B-VIEW-140 B-VIEW-141
        @Test func editsTheToolbarInPlaceFromThePanelAndTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.customizeToolbar)
            let customizer = try #require(tab.customizer)
            harness.layout(tab)
            // The row does nothing; the rest of the window waits under the veil.
            #expect(button(tab, .back)?.isInert == true)
            #expect(tab.workspace.subviews.contains { $0 is WorkspaceScrim && !$0.isHidden })
            // The panel offers what the toolbar does not hold, and the space.
            #expect(customizer.panel.items.first == .topSeparator)
            #expect(!customizer.panel.items.contains(.back))
            #expect(customizer.panel.items.contains(.newTab))
            // A click adds an item at the far right.
            customizer.panel.itemViews.first { $0.id == .newTab }?.onRelease(false)
            #expect(await waitUntil { harness.store.preferences().topToolbarItems.last == .newTab })
            // ⌥← moves it, Delete takes it off.
            harness.layout(tab)
            let count = tab.workspace.toolbar.savedItems.count
            let handled = customizer.handleKey(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)),
                key: "newTab")
            #expect(handled)
            #expect(harness.store.preferences().topToolbarItems[count - 2] == .newTab)
            _ = customizer.handleKey(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)),
                key: "newTab")
            #expect(!harness.store.preferences().topToolbarItems.contains(.newTab))
            // A required item can't be taken off.
            _ = customizer.handleKey(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)),
                key: "title")
            #expect(harness.store.preferences().topToolbarItems.contains(.title))
            // Restore Defaults puts back the default toolbar; Escape ends customizing.
            tab.updatePreferences(["topToolbarItems": .array([.string("back"), .string("title")])])
            customizer.panel.onRestoreDefaults()
            #expect(harness.store.preferences().topToolbarItems == ToolbarItems.defaultTopItems)
            #expect(!customizer.panel.restoreEnabled == customizer.isDefault)
            key(53, "\u{1b}", in: tab.window)
            #expect(tab.customizer == nil)
            #expect(button(tab, .back)?.isInert == false)
            await harness.close()
        }

        // T-3da726ea T-090c3038 T-92946215 T-b58bb216 T-47e212cb T-78565d8f F-718 B-VIEW-135 B-VIEW-136 B-VIEW-137
        @Test func movesAddsAndTakesOffItemsByDragging() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.customizeToolbar)
            let customizer = try #require(tab.customizer)
            let toolbar = tab.workspace.toolbar
            harness.layout(tab)
            func center(_ key: String) -> NSPoint {
                let frame = toolbar.convert(toolbar.slotViews[key]?.frame ?? .zero, to: nil)
                return NSPoint(x: frame.midX, y: frame.midY)
            }
            // Drag Back along the row, past Sort.
            let start = center("back")
            customizer.pressHandle("back", at: start)
            customizer.pointerMoved(to: NSPoint(x: start.x + 2, y: start.y))
            #expect(customizer.drag == nil)
            customizer.pointerMoved(to: NSPoint(x: center("sort").x + 20, y: start.y))
            #expect(customizer.drag?.targetIndex != nil)
            customizer.pointerUp()
            var saved = harness.store.preferences().topToolbarItems
            #expect(saved.firstIndex(of: .back)! > saved.firstIndex(of: .sort)!)
            harness.layout(tab)

            // Away from the toolbar: taken off; a required item keeps its place.
            customizer.pressHandle("forward", at: center("forward"))
            customizer.pointerMoved(to: NSPoint(x: center("forward").x, y: center("forward").y - 200))
            #expect(customizer.removing)
            customizer.pointerUp()
            saved = harness.store.preferences().topToolbarItems
            #expect(!saved.contains(.forward))
            harness.layout(tab)
            customizer.pressHandle("search", at: center("search"))
            customizer.pointerMoved(to: NSPoint(x: center("search").x, y: center("search").y - 200))
            customizer.pointerUp()
            #expect(harness.store.preferences().topToolbarItems.contains(.search))

            // From the panel: let go over the toolbar adds it there, once; away from it, nothing.
            harness.layout(tab)
            let titleCenter = center("title")
            customizer.press(
                itemID: .newTab, fromIndex: nil, key: nil, at: NSPoint(x: titleCenter.x, y: titleCenter.y - 120))
            customizer.pointerMoved(to: titleCenter)
            customizer.pointerUp()
            #expect(harness.store.preferences().topToolbarItems.filter { $0 == .newTab }.count == 1)
            customizer.press(
                itemID: .help, fromIndex: nil, key: nil, at: NSPoint(x: titleCenter.x, y: titleCenter.y - 120))
            customizer.pointerMoved(to: NSPoint(x: titleCenter.x, y: titleCenter.y - 300))
            customizer.pointerUp()
            #expect(!harness.store.preferences().topToolbarItems.contains(.help))

            // Escape stops a drag and changes nothing.
            harness.layout(tab)
            let before = harness.store.preferences().topToolbarItems
            customizer.pressHandle("sort", at: center("sort"))
            customizer.pointerMoved(to: NSPoint(x: center("sort").x - 200, y: center("sort").y))
            key(53, "\u{1b}", in: tab.window)
            #expect(customizer.drag == nil)
            #expect(harness.store.preferences().topToolbarItems == before)
            #expect(tab.customizer != nil)
            tab.finishCustomizingToolbar()
            await harness.close()
        }
    }
}
