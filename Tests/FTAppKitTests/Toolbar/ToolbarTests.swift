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
        tab.explorerToolbar.button(id)
    }

    func setItems(_ tab: MainWindowController, _ items: [ToolbarItemID], _ harness: ExplorerHarness) {
        tab.updatePreferences(["topToolbarItems": .array(items.map { .string($0.rawValue) })])
        harness.layout(tab)
    }

    var menu: AppMenu? { AppMenuPresenter.shared.menu }

    func titles(_ menu: AppMenu?) -> [String] {
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
        // N/A T-b4ef483c (only a primary press on a handle starts a drag): the system's customizing has no handles (D-016).
        // T-88f9e2d3 T-bcb2497c T-e090ff70 F-708 F-709 B-VIEW-107 B-VIEW-108 B-VIEW-109 B-VIEW-110 B-VIEW-112
        @Test func drawsTheItemsInTheirSavedOrderAndLeavesOutAnEmptyClipboardButton() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            #expect(
                toolbar.rowKeys == [
                    "folderTree", "topSeparator", "back", "forward", "title", "view", "sort", "search", "viewOptions",
                    "infoPanel",
                ])
            // One system item per command; the original's space is the system's.
            #expect(toolbar.toolbar.items.first?.itemIdentifier == .sidebarTrackingSeparator)
            #expect(toolbar.toolbar.items.contains { $0.itemIdentifier == .space })
            #expect(toolbar.searchItem != nil)
            if #available(macOS 15, *) { #expect(toolbar.item(.clipboard)?.isHidden == true) }
            #expect(toolbar.item(.back)?.view === toolbar.button(.back))

            // A saved order is drawn as saved, wherever the required items are; a missing required item is added.
            setItems(tab, [.viewOptions, .title, .back, .search], harness)
            #expect(toolbar.rowKeys == ["viewOptions", "title", "back", "search"])
            setItems(tab, [.back], harness)
            #expect(toolbar.rowKeys == ["back", "title", "search", "viewOptions"])

            // Something on the clipboard: the button shows, with its count.
            setItems(tab, ToolbarItems.defaultTopItems, harness)
            tab.services.clipboard.set(
                .ready(mode: .copy, sourcePaths: ["/a", "/b"], sourceEntries: [:], capturedAt: "1"), from: nil)
            toolbar.reload()
            harness.layout(tab)
            #expect(toolbar.rowKeys.contains("clipboard"))
            if #available(macOS 15, *) { #expect(toolbar.item(.clipboard)?.isHidden == false) }
            let clipboard = try #require(toolbar.clipboardButton)
            #expect(clipboard.count.stringValue == "2")
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
        }

        // F-708 `selectTopToolbarSlots`: a space at the start, right after another or at the end divides nothing, so it
        // isn't drawn; the saved order keeps it until the user changes the toolbar, as the original's does.
        @Test func dropsTheSpacesThatDivideNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            let saved: [ToolbarItemID] = [
                .topSeparator, .back, .topSeparator, .topSeparator, .title, .clipboard, .viewOptions, .search,
                .topSeparator,
            ]
            setItems(tab, saved, harness)
            #expect(toolbar.toolbar.items.filter { $0.itemIdentifier == .space }.count == 1)
            #expect(
                toolbar.toolbar.items.map(\.itemIdentifier).dropFirst().prefix(3) == [
                    ExplorerToolbar.identifier(.back), .space, ExplorerToolbar.identifier(.title),
                ])
            #expect(harness.store.preferences().topToolbarItems == saved)
            // A space that does divide stays; the palette still offers it, whatever the row.
            #expect(toolbar.toolbarAllowedItemIdentifiers(toolbar.toolbar).contains(.space))
            // The user's change is what rewrites the order.
            let native = toolbar.toolbar
            native.insertItem(withItemIdentifier: ExplorerToolbar.identifier(.newTab), at: native.items.count)
            #expect(await waitUntil { harness.store.preferences().topToolbarItems.last == .newTab })
            #expect(native.items.filter { $0.itemIdentifier == .space }.count == 1)
            await harness.close()
        }

        // F-708 (`resolveToolbarCapsules`): a capsule is a run of buttons, the view switch and the search field off them.
        // The original has no fixed groups, so the system's platters are the capsules, an empty clipboard button leaving
        // no break in its run. Private class name: there is no public way to ask which items share glass.
        @Test func theSystemsPlattersAreTheOriginalsCapsules() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(
                tab,
                [.back, .clipboard, .forward, .title, .up, .view, .sort, .refresh, .search, .viewOptions, .hidden],
                harness)
            let toolbar = tab.explorerToolbar
            func view(_ id: ToolbarItemID) -> NSView? {
                switch id {
                case .view: toolbar.viewSwitch
                case .search: toolbar.searchField
                default: toolbar.button(id)
                }
            }
            let frameView = try #require(window.contentView?.superview)
            let platters = Views.all(NSView.self, in: frameView).filter {
                String(describing: type(of: $0)) == "NSToolbarPlatterView" && !$0.isHidden
            }
            let held = platters.map { platter in
                Set(ToolbarItemID.allCases.filter { id in view(id)?.isDescendant(of: platter) == true })
            }
            let expected: Set<Set<ToolbarItemID>> = [
                [.back, .forward], [.up], [.view], [.sort, .refresh], [.search], [.viewOptions, .hidden],
            ]
            #expect(Set(held) == expected)
            await harness.close()
        }

        // Finder's capsules, read from its screenshots to ±1 pt: 36 high, its buttons 36 wide, 8 apart (D-015).
        @Test func theCapsulesAreFindersSizes() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(tab, [.back, .forward, .title, .view, .sort, .refresh, .search], harness)
            let toolbar = tab.explorerToolbar
            let frameView = try #require(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let platters = Views.all(NSView.self, in: frameView).filter {
                String(describing: type(of: $0)) == "NSToolbarPlatterView" && !$0.isHidden
            }
            let frames = platters.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
            #expect(frames.count == 5)
            for frame in frames { #expect(abs(frame.height - 36) <= 1) }
            // Back and Forward are apart from the rest, by the title.
            let run = frames.dropFirst()
            for (left, right) in zip(run, run.dropFirst()) { #expect(abs(right.minX - left.maxX - 8) <= 1) }
            #expect(try #require(toolbar.button(.back)).frame.width == 36)
            // The glyphs' box: a mark of the box's middle 16 units comes out 16 points across, with its stroke.
            #expect(toolbar.button(.back)?.image?.size == NSSize(width: 22, height: 22))
            #expect(toolbar.viewSwitch?.image(forSegment: 0)?.size == NSSize(width: 22, height: 22))
            #expect(abs(toolbar.searchField.frame.width - DesignTokens.toolbar.searchWidth) <= 0.5)
            // Finder's selected segment is 34 by 28; the system's control takes its height from the toolbar.
            let viewSwitch = try #require(toolbar.viewSwitch)
            for segment in 0..<viewSwitch.segmentCount { #expect(viewSwitch.width(forSegment: segment) == 34) }
            #expect(viewSwitch.frame.height == 36)
            await harness.close()
        }

        // No toggle draws the system's accent-filled on state: on shows the gray pressed look, also after a press.
        // B-INFO-067
        @Test func aToggleIsOnInGrayThroughAPress() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(tab, [.back, .forward, .title, .folderTree, .infoPanel, .sort, .search], harness)
            let tree = try #require(button(tab, .folderTree))
            let info = try #require(button(tab, .infoPanel))
            #expect(tree.isOn && tree.isHighlighted && tree.state == .off)
            #expect(tree.accessibilityValue() as? Bool == true)
            #expect(!info.isOn && !info.isHighlighted)
            tree.onClick = nil
            info.onClick = nil
            for press in [tree, info] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: center(of: press), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                press.mouseDown(with: event)
                #expect(press.isHighlighted)
                press.mouseUp(with: event)
            }
            #expect(tree.isHighlighted && tree.state == .off)
            #expect(!info.isHighlighted && info.state == .off)
            await harness.close()
        }

        // A press on the magnifier goes through the window, as a real one does: the system's field keeps it from the
        // button under the mouse unless the toolbar takes it first. A dialog's scrim keeps it from the magnifier.
        @Test func aPressOnTheMagnifierOpensTheOptions() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(tab, [.back, .forward, .title, .search], harness)
            let field = tab.explorerToolbar.searchField
            var presses = 0
            field.onOptions = { _ in presses += 1 }
            let magnifier = center(of: field.optionsButton)
            mouse(.leftMouseDown, at: magnifier, in: window)
            #expect(presses == 1)
            mouse(.leftMouseUp, at: magnifier, in: window)
            // The rest of the field is the field's.
            let text = field.convert(NSPoint(x: field.bounds.maxX - 40, y: field.bounds.midY), to: nil)
            mouse(.leftMouseDown, at: text, in: window)
            mouse(.leftMouseUp, at: text, in: window)
            #expect(presses == 1)
            field.isEnabled = false
            mouse(.leftMouseDown, at: magnifier, in: window)
            mouse(.leftMouseUp, at: magnifier, in: window)
            #expect(presses == 1)
            await harness.close()
        }

        // The list closes on any press outside it, as the original's capture-phase `pointerdown` on the window does, so
        // the magnifier's own press doesn't keep it open beside the options.
        @Test func aPressOnTheMagnifierClosesTheClipboardList() async throws {
            let w = try await WritingWindow.open()
            let tab = w.tab
            w.select(["note.txt"])
            tab.perform(.copySelection)
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            w.harness.layout(tab)
            let field = tab.explorerToolbar.searchField
            var presses = 0
            field.onOptions = { _ in presses += 1 }
            tab.perform(.showClipboard)
            #expect(tab.clipboardUI.isOpen)
            let magnifier = center(of: field.optionsButton)
            mouse(.leftMouseDown, at: magnifier, in: window)
            mouse(.leftMouseUp, at: magnifier, in: window)
            #expect(presses == 1)
            #expect(!tab.clipboardUI.isOpen)
            tab.clipboardUI.close()
            await w.close()
        }

        // The press never reaches the step of AppKit that brings a window forward (SearchOptionsMenu.tsx: opened with the
        // mouse, typing still goes to the search field). A sheet keeps the press, and the keyboard where it is.
        @Test func aPressOnTheMagnifierBringsABackWindowForwardUnlessASheetIsUp() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(tab, [.back, .forward, .title, .search], harness)
            let toolbar = tab.explorerToolbar
            let field = toolbar.searchField
            var presses = 0
            var forward: [NSWindow] = []
            field.onOptions = { _ in presses += 1 }
            toolbar.bringForward = { forward.append($0) }
            let magnifier = center(of: field.optionsButton)
            mouse(.leftMouseDown, at: magnifier, in: window)
            mouse(.leftMouseUp, at: magnifier, in: window)
            #expect(presses == 1)
            #expect(forward.count == 1 && forward.first === window)

            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                defer: true)
            window.beginSheet(sheet) { _ in }
            #expect(window.attachedSheet === sheet)
            mouse(.leftMouseDown, at: magnifier, in: window)
            mouse(.leftMouseUp, at: magnifier, in: window)
            #expect(presses == 1)
            #expect(forward.count == 1)
            window.endSheet(sheet)
            await harness.close()
        }

        // F-843: the system's » menu lists what it hides in a menu of its own, which a dialog's scrim covers: nothing in
        // it runs while a dialog is up, the theme's choices, which run no command, included.
        @Test func theOverflowMenuWaitsUnderADialog() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            setItems(tab, ToolbarItems.defaultTopItems + [.theme, .hidden], harness)
            let themeEntry = try #require(toolbar.item(.theme)?.menuFormRepresentation?.submenu?.items.last)
            let hiddenEntry = try #require(toolbar.item(.hidden)?.menuFormRepresentation)
            #expect(toolbar.validateMenuItem(themeEntry))
            #expect(toolbar.validateMenuItem(hiddenEntry))
            tab.perform(.openLocationSheet)
            #expect(!toolbar.validateMenuItem(themeEntry))
            #expect(!toolbar.validateMenuItem(hiddenEntry))
            tab.goToBox?.onClose()
            #expect(toolbar.validateMenuItem(themeEntry))
            await harness.close()
        }

        // T-fa22d272 T-b5ab76c0 T-cd18e312 T-5ee43c38 F-716 B-VIEW-114 B-VIEW-115 B-VIEW-116 B-VIEW-117: the system's »
        // menu takes the removable items, each with what the menu bar calls it; the required ones go last. Which items
        // go is the system's: aNarrowWindowMovesTheRemovableItemsOut on screen.
        // N/A B-VIEW-118 the system places and closes its » menu, as it does the toolbar's other menus (D-022)
        // F-716 B-VIEW-116 B-VIEW-117
        @Test func listsTheItemsUnderTheOverflowMenuAsTheMenuBarWordsThem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            setItems(
                tab, ToolbarItems.defaultTopItems + [.up, .hidden, .theme, .openSelection], harness)
            for id in ToolbarItems.defaultTopItems where ToolbarItems.isRequiredTopItem(id) {
                #expect(
                    (toolbar.item(id)?.visibilityPriority.rawValue ?? 0)
                        >= NSToolbarItem.VisibilityPriority.high.rawValue, "\(id)")
            }
            #expect(toolbar.item(.up)?.visibilityPriority == .standard)
            let hidden = try #require(toolbar.item(.hidden)?.menuFormRepresentation)
            #expect(hidden.title == "Hidden Files" && hidden.state == .off)
            NSApp.sendAction(try #require(hidden.action), to: hidden.target, from: hidden)
            #expect(tab.viewState.includeHidden)
            #expect(toolbar.item(.hidden)?.menuFormRepresentation?.state == .on)
            #expect(toolbar.item(.up)?.menuFormRepresentation?.title == "Enclosing Folder")
            #expect(toolbar.item(.view)?.menuFormRepresentation?.submenu?.items.map(\.title).first == "as Icons")
            #expect(toolbar.item(.sort)?.menuFormRepresentation?.submenu?.items.first?.title == "Sort by Name")
            #expect(
                toolbar.item(.theme)?.menuFormRepresentation?.submenu?.items.map(\.title) == ["Auto", "Light", "Dark"])
            // A command that can't run now says so in the menu too.
            tab.content.focusList()
            toolbar.refreshStates()
            let open = try #require(toolbar.item(.openSelection)?.menuFormRepresentation)
            #expect(toolbar.validateMenuItem(open) == false)
            await harness.close()
        }

        // T-419c42ea T-f1212345 T-b996c44a T-d3420fb9 T-2dedcc21 F-709 B-VIEW-120 B-VIEW-122 B-VIEW-123 B-VIEW-131
        // B-NAV-056
        @Test func togglesSayWhatAClickWillDoAndButtonsRunTheirCommands() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(harness.folder.appending("Alpha").path)
            setItems(
                tab, ToolbarItems.defaultTopItems + [.foldersFirst, .hidden, .infoRow, .up, .openSelection], harness)
            let tree = try #require(button(tab, .folderTree))
            #expect(tree.isOn && tree.isHighlighted && tree.state == .off)
            #expect(tree.tooltip.hasPrefix("Hide Folder Tree"))
            _ = tree.accessibilityPerformPress()
            #expect(await waitUntil { !tab.panels.folderTreeOpen })
            #expect(!tree.isOn && !tree.isHighlighted && tree.state == .off)
            #expect(tree.tooltip.hasPrefix("Show Folder Tree"))

            let hidden = try #require(button(tab, .hidden))
            #expect(hidden.tooltip.hasPrefix("Show Hidden Files"))
            _ = hidden.accessibilityPerformPress()
            #expect(hidden.isOn && hidden.iconName == .hiddenShown)
            #expect(hidden.tooltip.hasPrefix("Hide Hidden Files"))

            // A content-only command is off with nothing selected. (The window opens with the sidebar holding the
            // keyboard, where Open acts on the selected folder, so the file list takes it first.)
            tab.content.focusList()
            tab.explorerToolbar.refreshStates()
            #expect(button(tab, .openSelection)?.isEnabled == false)
            // Enclosing Folder runs its command.
            _ = button(tab, .up)?.accessibilityPerformPress()
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == harness.folder.url.lastPathComponent })
            await harness.close()
        }

        // T-f0cce867 F-711 B-VIEW-234: the View menu switches to icons, the toolbar's view switch back to the list;
        // the switch's segments say their keys.
        // B-VIEW-002
        @Test func switchesTheViewFromTheMenuAndBackFromTheToolbar() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsIcons)
            let switcher = try #require(tab.explorerToolbar.viewSwitch)
            #expect(switcher.selected == .icons)
            #expect(
                (0..<switcher.segmentCount).map { switcher.toolTip(forSegment: $0) } == [
                    "View as Icons (⌘1)", "View as List (⌘2)", "View as Compact List (⌘3)",
                ])
            switcher.choose(segment: 1)
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

        // N/A T-ad6435d1 T-709e0d2c T-612dbec6 T-addfcb64 T-0d8f5ac1 T-3da726ea T-090c3038 T-92946215 T-b58bb216 T-47e212cb
        // T-78565d8f (the original's edit layer, panel and drag ghost): the customizing is the system's (D-016). What the
        // app still owes is below. F-718 F-719 F-720 B-VIEW-132 B-VIEW-133 B-VIEW-134 B-VIEW-135 B-VIEW-136 B-VIEW-137
        // B-VIEW-138 B-VIEW-140 B-VIEW-141
        // F-718 F-719 F-720
        @Test func keepsWhatTheUserChangesInTheToolbarInThePreference() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            let native = toolbar.toolbar
            var opened = 0
            toolbar.runCustomizationPalette = { _ in opened += 1 }
            tab.perform(.customizeToolbar)
            #expect(opened == 1)
            // The sheet offers what the palette did, the space too, and the ones that stay; nothing goes before the
            // sidebar's separator.
            let allowed = toolbar.toolbarAllowedItemIdentifiers(native)
            #expect(allowed.contains(.space) && allowed.contains(ExplorerToolbar.identifier(.newTab)))
            #expect(allowed.contains(ExplorerToolbar.identifier(.search)))
            #expect(!allowed.contains(.flexibleSpace))
            #expect(
                toolbar.toolbar(native, itemIdentifier: ExplorerToolbar.identifier(.back), canBeInsertedAt: 0) == false)
            #expect(
                toolbar.toolbar(native, itemIdentifier: ExplorerToolbar.identifier(.back), canBeInsertedAt: 1) == true)
            #expect(toolbar.toolbarImmovableItemIdentifiers(native) == [.sidebarTrackingSeparator])

            // Added in the toolbar: saved.
            native.insertItem(withItemIdentifier: ExplorerToolbar.identifier(.newTab), at: native.items.count)
            #expect(await waitUntil { harness.store.preferences().topToolbarItems.last == .newTab })
            // Moved.
            let moved = native.items.count - 1
            native.removeItem(at: moved)
            native.insertItem(withItemIdentifier: ExplorerToolbar.identifier(.newTab), at: 1)
            #expect(await waitUntil { harness.store.preferences().topToolbarItems.first == .newTab })
            // Taken off.
            native.removeItem(at: 1)
            #expect(await waitUntil { !harness.store.preferences().topToolbarItems.contains(.newTab) })
            // A required item can't be taken off: it comes back, at the end.
            let search = try #require(
                native.items.firstIndex { $0.itemIdentifier == ExplorerToolbar.identifier(.search) })
            native.removeItem(at: search)
            #expect(await waitUntil { harness.store.preferences().topToolbarItems.last == .search })
            #expect(await waitUntil { toolbar.searchItem?.searchField === toolbar.searchField })

            // Reset to Defaults, an import or the other tab's change come in through the preference.
            tab.updatePreferences(["topToolbarItems": .array([.string("back"), .string("title")])])
            #expect(toolbar.rowKeys == ["back", "title", "search", "viewOptions"])
            tab.updatePreferences(["topToolbarItems": .array(ToolbarItems.defaultTopItems.map { .string($0.rawValue) })]
            )
            #expect(harness.store.preferences().topToolbarItems == ToolbarItems.defaultTopItems)
            #expect(toolbar.toolbar.items.count == ToolbarItems.defaultTopItems.count + 1)
            #expect(toolbar.toolbarDefaultItemIdentifiers(native).count == ToolbarItems.defaultTopItems.count + 1)
            await harness.close()
        }

        // Under a name being edited or a dialog nothing can customize the toolbar, the system's right-click menu included.
        // That menu is the system's (D-016) and offers Customize Toolbar… by this flag; opening it is a hand check.
        // F-717
        @Test func customizingWaitsUnderARenameOrADialog() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            #expect(toolbar.toolbar.allowsUserCustomization)
            tab.perform(.openLocationSheet)
            #expect(!toolbar.toolbar.allowsUserCustomization)
            tab.goToBox?.onClose()
            #expect(toolbar.toolbar.allowsUserCustomization)
            await harness.close()
        }

        // The sheet's copies of the items do nothing, and aren't the ones the capture names.
        @Test func theSheetsItemsAreCopies() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            let identifier = ExplorerToolbar.identifier(.back)
            let copy = toolbar.toolbar(
                toolbar.toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: false)
            #expect(copy?.view !== toolbar.button(.back))
            #expect((copy?.view as? ToolbarButton)?.onClick == nil)
            #expect(copy?.view?.accessibilityIdentifier() == "")
            #expect(copy?.paletteLabel == "Back")
            await harness.close()
        }
    }
}
