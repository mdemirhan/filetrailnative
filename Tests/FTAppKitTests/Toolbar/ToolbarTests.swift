import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
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
        tab.updatePreferences { $0.topToolbarItems = items }
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
        @Test func drawsTheItemsInTheirSavedOrderAndLeavesOutAnEmptyClipboardButton() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            #expect(
                toolbar.rowKeys == [
                    "folderTree", "topSeparator", "back", "forward", "title", "view", "sort", "search", "viewOptions",
                    "twoPanes", "infoPanel",
                ])
            // One system item per command; a space is the system's.
            #expect(toolbar.toolbar.items.first?.itemIdentifier == .sidebarTrackingSeparator)
            #expect(toolbar.toolbar.items.contains { $0.itemIdentifier == .space })
            #expect(toolbar.searchItem != nil)
            #expect(toolbar.item(.clipboard)?.isHidden == true)
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
            #expect(toolbar.item(.clipboard)?.isHidden == false)
            let clipboard = try #require(toolbar.clipboardButton)
            #expect(clipboard.count.stringValue == "2")
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
        }

        // A refresh sets each button's tooltip once, those that say their state (Sort, Theme, the clipboard) too.
        @Test func aRefreshSetsEachTooltipOnce() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            setItems(tab, ToolbarItems.defaultTopItems + [.theme, .clipboard], harness)
            tab.services.clipboard.set(
                .ready(mode: .copy, sourcePaths: ["/a", "/b"], sourceEntries: [:], capturedAt: "1"), from: nil)
            toolbar.reload()
            for id: ToolbarItemID in [.sort, .theme, .clipboard, .viewOptions, .back] {
                let button = try #require(toolbar.button(id), "no \(id)")
                let before = button.tooltipWrites
                toolbar.refreshStates()
                #expect(button.tooltipWrites == before + 1, "\(id)")
            }
            #expect(toolbar.button(.sort)?.tooltip.hasPrefix("Sort By: Name") == true)
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
        }

        // A space at the start, right after another or at the end divides nothing, so it
        // isn't drawn; the saved order keeps it until the user changes the toolbar.
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

        // A capsule is a run of buttons, the view switch and the search field off them. There are no fixed groups, so
        // the system's platters are the capsules, an empty clipboard button leaving no break in its run. Private class name: there is no public way to ask which items share glass.
        @Test func theSystemsPlattersAreCapsules() async throws {
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

        // The clipboard button, with its count, shares a capsule with the buttons beside it, as the Undo History button
        // does: the system gives a button with a title a capsule of its own, so the count is not its title. The icon
        // keeps to the leading side, the count 2 after it.
        @Test func theClipboardAndHistoryButtonsShareTheirNeighboursCapsule() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            let history = UndoHistory()
            history.record(UndoToolbarTests.rename("/p/a", "/p/b"))
            tab.explorerToolbar.undoHistory = { history }
            tab.services.clipboard.set(
                .ready(mode: .copy, sourcePaths: ["/a", "/b"], sourceEntries: [:], capturedAt: "1"), from: nil)
            setItems(tab, [.back, .title, .undo, .clipboard, .undoHistory, .redo, .search], harness)
            let toolbar = tab.explorerToolbar
            let frameView = try #require(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let platters = Views.all(NSView.self, in: frameView).filter {
                String(describing: type(of: $0)) == "NSToolbarPlatterView" && !$0.isHidden
            }
            let held = platters.map { platter in
                Set(ToolbarItemID.allCases.filter { toolbar.button($0)?.isDescendant(of: platter) == true })
            }
            #expect(held.contains([.undo, .clipboard, .undoHistory, .redo]))
            let clipboard = try #require(toolbar.clipboardButton)
            let icon = try #require(clipboard.cell?.imageRect(forBounds: clipboard.bounds))
            #expect(abs(icon.minX - ToolbarClipboardButton.countPadding) < 0.01)
            #expect(abs(clipboard.count.frame.minX - icon.maxX - ToolbarClipboardButton.countGap) < 0.01)
            #expect(clipboard.bounds.width > ToolbarButton.iconOnlyWidth)
            tab.services.clipboard.set(.empty, from: nil)
            await harness.close()
        }

        // Finder's capsules, read from its screenshots to ±1 pt: 36 high, its buttons 36 wide, 8 apart.
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
            #expect(abs(toolbar.searchField.frame.width - DesignTokens.toolbar.searchWidth) <= 0.5)
            // Finder's selected segment is 34 by 28; the system's control takes its height from the toolbar.
            let viewSwitch = try #require(toolbar.viewSwitch)
            for segment in 0..<viewSwitch.segmentCount { #expect(viewSwitch.width(forSegment: segment) == 34) }
            #expect(viewSwitch.frame.height == 36)
            await harness.close()
        }

        // No toggle draws the system's accent-filled on state: on shows the gray pressed look, also after a press.
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

        // The list closes on any press outside it, so the magnifier's own press doesn't keep it open beside the
        // options.
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

        // A press on the magnifier goes through the window, as a real one does: the system's field keeps it from the
        // button under the mouse unless the toolbar takes it first. It never reaches the step of AppKit that brings a window
        // forward. A sheet keeps the
        // press, and the keyboard where it is.
        @Test func aPressOnTheMagnifierOpensTheOptionsAndBringsABackWindowForwardUnlessASheetIsUp() async throws {
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
            // The rest of the field is the field's.
            let text = field.convert(NSPoint(x: field.bounds.maxX - 40, y: field.bounds.midY), to: nil)
            mouse(.leftMouseDown, at: text, in: window)
            mouse(.leftMouseUp, at: text, in: window)
            #expect(presses == 1)
            field.isEnabled = false
            mouse(.leftMouseDown, at: magnifier, in: window)
            mouse(.leftMouseUp, at: magnifier, in: window)
            #expect(presses == 1)
            field.isEnabled = true

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

        // The system's » menu lists what it hides in a menu of its own, which a dialog's scrim covers: nothing in
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

        // The system's »
        // menu takes the removable items, each with what the menu bar calls it; the required ones go last. Which items
        // go is the system's: aNarrowWindowMovesTheRemovableItemsOut on screen.
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

        // The View menu switches to icons, the toolbar's view switch back to the list;
        // the switch's segments say their keys.
        @Test func switchesTheViewFromTheMenuAndBackFromTheToolbar() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsIcons)
            let switcher = try #require(tab.explorerToolbar.viewSwitch)
            #expect(switcher.selected == .icons)
            #expect(
                (0..<switcher.segmentCount).map { switcher.toolTip(forSegment: $0) } == [
                    "View as Icons (⌘1)", "View as List (⌘2)", "View as Compact List (⌘3)", "View as Previews",
                ])
            switcher.choose(segment: 1)
            #expect(tab.viewState.viewMode == .details)
            #expect(switcher.selected == .details)
            await harness.close()
        }

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

        // The customizing is the system's. What the app still owes is below.
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
            tab.updatePreferences { $0.topToolbarItems = [.back, .title] }
            #expect(toolbar.rowKeys == ["back", "title", "search", "viewOptions"])
            tab.updatePreferences { $0.topToolbarItems = ToolbarItems.defaultTopItems }
            #expect(harness.store.preferences().topToolbarItems == ToolbarItems.defaultTopItems)
            #expect(toolbar.toolbar.items.count == ToolbarItems.defaultTopItems.count + 1)
            #expect(toolbar.toolbarDefaultItemIdentifiers(native).count == ToolbarItems.defaultTopItems.count + 1)
            await harness.close()
        }

        // Under a name being edited or a dialog nothing can customize the toolbar, the system's right-click menu included.
        // That menu is the system's and offers Customize Toolbar… by this flag; opening it is a hand check.
        @Test func customizingWaitsUnderARenameOrADialog() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let toolbar = tab.explorerToolbar
            #expect(toolbar.toolbar.allowsUserCustomization)
            tab.perform(.openLocationSheet)
            #expect(!toolbar.toolbar.allowsUserCustomization)
            tab.goToBox?.onClose()
            #expect(toolbar.toolbar.allowsUserCustomization)
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            #expect(tab.content.beginRename(path: note.path))
            toolbar.refreshStates()
            #expect(!toolbar.toolbar.allowsUserCustomization)
            tab.content.renameCancelled()
            #expect(await waitUntil { tab.content.inlineRename == nil })
            toolbar.refreshStates()
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

        @Test func listsTheViewOptionsAndSortsFromTheSortMenu() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            _ = button(tab, .viewOptions)?.accessibilityPerformPress()
            #expect(
                titles(menu) == [
                    "Folders First", "Hidden Files", "-", "Info Panel", "Info Row", "-", "Customize Toolbar…",
                ])
            #expect(
                menu?.items.first?.key
                    == ShortcutDisplay.defaults.written(.toggleFoldersFirst).flatMap(MenuKeyEquivalent.parse))
            // Escape closes it.
            key(53, "\u{1b}", in: tab.window)
            #expect(menu == nil)
            _ = button(tab, .viewOptions)?.accessibilityPerformPress()
            choose("Info Row")
            #expect(await waitUntil { tab.panels.detailRowOpen })

            let sort = try #require(button(tab, .sort))
            #expect(sort.tooltip == "Sort By: Name, Ascending")
            _ = sort.accessibilityPerformPress()
            #expect(titles(menu) == ["Name", "Kind", "Date Modified", "Size", "-", "Ascending", "Descending"])
            #expect(menu?.nsMenu.minimumWidth == 200)
            choose("Size")
            // A new Size order starts descending.
            #expect(tab.viewState.sortBy == .size && tab.viewState.sortDirection == .desc)
            _ = sort.accessibilityPerformPress()
            choose("Ascending")
            #expect(tab.viewState.sortDirection == .asc)
            #expect(sort.tooltip == "Sort By: Size, Ascending")
            // Pressing the button again closes its menu.
            _ = sort.accessibilityPerformPress()
            _ = sort.accessibilityPerformPress()
            #expect(menu == nil)
            await harness.close()
        }

        // Back held 350 ms opens the folders behind, nearest first, and the click that ends the hold doesn't step;
        // released sooner, it opens nothing. (The same on screen: ToolbarStateGUITests.)
        @Test func holdingBackOpensItsHistoryAndReleasingSoonerSteps() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = harness.folder.url
            let tab = try await harness.open(root.path)
            for name in ["Alpha", "Alpha/Inner"] {
                await tab.navigate(to: root.appendingPathComponent(name))
            }
            harness.layout(tab)
            let timers = ManualTimers()
            tab.explorerToolbar.timers = timers
            let back = try #require(button(tab, .back))
            defer { AppMenuPresenter.shared.close() }

            back.onPress?()
            timers.advance(ExplorerToolbar.historyHoldSeconds - 0.05)
            #expect(menu == nil)
            timers.advance(0.05)
            #expect(menu?.identifier == "historyMenu")
            #expect(titles(menu) == ["Alpha", root.lastPathComponent])
            back.onRelease?(true)
            back.onClick?()
            #expect(tab.currentFolder.lastPathComponent == "Inner")
            AppMenuPresenter.shared.close()

            back.onPress?()
            timers.advance(ExplorerToolbar.historyHoldSeconds - 0.05)
            back.onRelease?(true)
            timers.advance(1)
            #expect(menu == nil)
            back.onClick?()
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Alpha" })
            await harness.close()
        }

        // AppKit routes a right press on the toolbar itself: sent to the window, it reaches Forward, whose menu
        // lists the folders ahead, and not the toolbar's own menu, whose tracking would hold the window.
        @Test func aRightPressOnForwardOpensItsHistory() async throws {
            let harness = try ExplorerHarness.windowless()
            let root = harness.folder.url
            let tab = try await harness.open(root.path)
            for name in ["Alpha", "Alpha/Inner"] {
                await tab.navigate(to: root.appendingPathComponent(name))
            }
            tab.goBack(nil)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Alpha" })
            tab.goBack(nil)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == root.lastPathComponent })
            harness.layout(tab)
            let window = try #require(tab.window)
            let forward = try #require(button(tab, .forward))
            #expect(await waitUntil { forward.isEnabled })
            let press = try #require(
                MouseEvents.event(.rightMouseDown, at: MouseEvents.center(of: forward), in: window))
            #expect(ToolbarButton.takingRightPress(at: press.locationInWindow, in: window) === forward)
            window.sendEvent(press)
            #expect(menu?.identifier == "historyMenu")
            #expect(titles(menu) == ["Alpha", "Inner"])
            AppMenuPresenter.shared.close()
            // A sheet keeps the window's presses from it: no folder is picked behind a question about a write.
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.beginSheet(sheet, completionHandler: nil)
            #expect(await waitUntil { window.attachedSheet != nil })
            window.sendEvent(press)
            #expect(menu == nil)
            AppMenuPresenter.shared.close()
            window.endSheet(sheet)
            await harness.close()
        }

        // The system's ✕ has the search bar's tooltip and name, and text of only spaces has none.
        @Test func theSystemsClearButtonIsLabelled() async throws {
            let harness = try ExplorerHarness.windowless()
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
            #expect(await waitUntil { field.clearButton?.alphaValue == 0 })
            #expect(field.clearButton?.isEnabled == false)
            field.stringValue = "abc"
            #expect(await waitUntil { field.clearButton?.alphaValue == 1 })
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
}
