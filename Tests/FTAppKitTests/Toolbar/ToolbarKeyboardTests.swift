// Checks the toolbar's keys and presses against apps/desktop/src/renderer/components/ExplorerWorkspace.tsx,
// HistoryButton.tsx and ClearButton.tsx, on a real tab whose window is never shown
import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ToolbarKeyboardTests: ToolbarTesting {
        private func tab(key code: UInt16, _ characters: String, shift: Bool = false, _ window: NSWindow) throws
            -> NSEvent
        {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        // ExplorerWorkspace.tsx:1183-1186: a plain button goes disabled, and nothing focuses the search input. The
        // keyboard goes back to the pane.
        @Test func aButtonThatDimsWithTheKeyboardGivesItToThePaneNotTheSearchField() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .search], harness)
            opened.content.focusList()
            let up = try #require(opened.explorerToolbar.button(.up))
            up.isEnabled = true
            #expect(up.takeKeyboard())

            up.isEnabled = false
            #expect(opened.explorerToolbar.searchField.isActive == false)
            #expect(window.firstResponder === opened.content.focusView)
            await harness.close()
        }

        @Test func aButtonThatDimsWithTheKeyboardGivesItBackToTheTreeWhenTheTreeHadIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .search], harness)
            opened.perform(.focusTreePane)
            #expect(opened.focusedPane == .tree)
            let up = try #require(opened.explorerToolbar.button(.up))
            up.isEnabled = true
            #expect(up.takeKeyboard())

            up.isEnabled = false
            #expect(opened.focusedPane == .tree)
            await harness.close()
        }

        // ExplorerWorkspace.tsx:1846-1855: the Info panel's resizer handles only ←/→, so Tab is the browser's: on from
        // it, and back to the content. Its Hide button takes no keyboard in the port, so Tab goes past the panel.
        @Test func tabLeavesTheInfoPanelsResizerBothWays() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .sort, .search], harness)
            opened.updatePanels { $0.propertiesOpen = true }
            let up = try #require(opened.explorerToolbar.button(.up))
            up.isEnabled = true
            let first = try #require(ToolbarKeyboard.stops(in: window).first as? ToolbarButton)
            let resizer = opened.workspace.inspectorResizer

            #expect(window.makeFirstResponder(resizer))
            resizer.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === first)

            #expect(window.makeFirstResponder(resizer))
            resizer.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === opened.content.focusView)
            await harness.close()
        }

        // F-714: the items are plain buttons in the Tab order: Tab from the field reaches the ✕ and the next buttons, where
        // Return or Space presses them; Shift-Tab goes back through the options button to the buttons before it. Past the
        // last the content has the keyboard. A click still leaves the keyboard where it is.
        @Test func tabFromTheFieldReachesTheClearButtonAndTheToolbarButtons() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .sort, .search, .hidden], harness)
            let toolbar = opened.explorerToolbar
            let field = toolbar.searchField
            let hidden = try #require(toolbar.button(.hidden))
            let sort = try #require(toolbar.button(.sort))
            var options = 0
            field.onOptions = { _ in options += 1 }

            #expect(!hidden.acceptsFirstResponder)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(window.firstResponder === hidden)
            var clicks = 0
            hidden.onClick = { clicks += 1 }
            hidden.keyDown(with: try tab(key: 49, " ", window))
            #expect(clicks == 1)
            // On through the required items after it, to the content.
            var steps = 0
            while let button = window.firstResponder as? ToolbarButton, steps < 8 {
                button.keyDown(with: try tab(key: 48, "\t", window))
                steps += 1
            }
            #expect(window.firstResponder === opened.content.focusView, "\(String(describing: window.firstResponder))")

            #expect(field.optionsButton.takeKeyboard())
            field.optionsButton.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === sort)
            sort.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === field.optionsButton)
            #expect(options == 0)
            await harness.close()
        }

        // F-714, ExplorerWorkspace.tsx:1197-1231: the view switch is three plain buttons in the row. Tab walks them; Return or
        // Space presses the one it is at; a click leaves the keyboard where it is. Disabled in search mode, none is a stop.
        @Test func tabWalksTheViewSwitchAndSpacePressesASegment() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .view, .sort, .search], harness)
            let toolbar = opened.explorerToolbar
            let switcher = try #require(toolbar.viewSwitch)
            let up = try #require(toolbar.button(.up))
            let sort = try #require(toolbar.button(.sort))
            up.isEnabled = true
            #expect(!switcher.acceptsFirstResponder)

            #expect(up.takeKeyboard())
            up.keyDown(with: try tab(key: 48, "\t", window))
            try #require(window.firstResponder === switcher)
            #expect(switcher.keyboardSegment == 0)
            switcher.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === switcher)
            #expect(switcher.keyboardSegment == 1)
            switcher.keyDown(with: try tab(key: 49, " ", window))
            #expect(opened.viewMode == .details)
            #expect(switcher.selected == .details)
            switcher.keyDown(with: try tab(key: 48, "\t", window))
            #expect(switcher.keyboardSegment == 2)
            switcher.keyDown(with: try tab(key: 36, "\r", window))
            #expect(opened.viewMode == .list)
            switcher.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === sort)

            // Back in, at the last segment, and on out by the first.
            sort.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === switcher)
            #expect(switcher.keyboardSegment == 2)
            switcher.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            switcher.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(switcher.keyboardSegment == 0)
            switcher.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === up)

            switcher.isEnabled = false
            #expect(!ToolbarKeyboard.stops(in: window).contains { $0 === switcher })
            await harness.close()
        }

        // ExplorerWorkspace.tsx:1813-1833: the tree's resizer comes right before the toolbar, and with the tree closed it
        // isn't there. Neither is in a pane, so Tab there is the browser's too.
        @Test func shiftTabPastTheFirstStopReachesTheTreesResizer() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.up, .sort, .search], harness)
            let up = try #require(opened.explorerToolbar.button(.up))
            up.isEnabled = true
            let first = try #require(ToolbarKeyboard.stops(in: window).first as? ToolbarButton)
            let resizer = opened.workspace.treeResizer

            #expect(first.takeKeyboard())
            first.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === resizer)
            resizer.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === first)

            #expect(window.makeFirstResponder(resizer))
            resizer.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(opened.sidebarController.isInside(window.firstResponder))

            opened.perform(.toggleFolderTree)
            #expect(first.takeKeyboard())
            first.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(window.firstResponder === opened.content.focusView)
            await harness.close()
        }

        // In search mode the results bar is what comes after the toolbar: its first scope. From there, and from every
        // button of the bar, Tab and Shift-Tab are `paneTabSwitch`: to the tree, or the pane with the tree closed.
        @Test func inSearchModeTabLeavesTheToolbarForTheFirstScopeAndTheBarForTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            opened.search.session.engine = engine
            opened.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.search, .hidden], harness)
            let field = opened.explorerToolbar.searchField
            field.stringValue = "no"
            opened.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            let header = opened.search.header
            try #require(opened.content.contentShell.searchHeader === header)
            let track = try #require(Views.first(SearchSegmentTrack.self, in: header) { _ in true })
            let hidden = try #require(opened.explorerToolbar.button(.hidden))

            // Past the required items at the row's end, to the bar.
            #expect(hidden.takeKeyboard())
            var steps = 0
            while let button = window.firstResponder as? ToolbarButton, steps < 8 {
                button.keyDown(with: try tab(key: 48, "\t", window))
                steps += 1
            }
            #expect(window.firstResponder === track, "\(String(describing: window.firstResponder))")
            #expect(track.keyboardSegment == 0)

            track.keyDown(with: try tab(key: 48, "\t", window))
            #expect(opened.sidebarController.isInside(window.firstResponder))

            #expect(header.doneButton.takeKeyboard())
            header.doneButton.keyDown(with: try tab(key: 48, "\t", window))
            #expect(opened.sidebarController.isInside(window.firstResponder))

            #expect(track.takeKeyboard())
            track.keyDown(with: try tab(key: 48, "\t", shift: true, window))
            #expect(opened.sidebarController.isInside(window.firstResponder))

            // With the tree closed the pane keeps the keyboard, and the tree stays closed.
            opened.perform(.toggleFolderTree)
            #expect(header.doneButton.takeKeyboard())
            header.doneButton.keyDown(with: try tab(key: 48, "\t", window))
            #expect(window.firstResponder === opened.content.focusView)
            #expect(!opened.panels.folderTreeOpen)
            await harness.close()
        }

        // ClearButton.tsx: with text in the field, Tab stops at the ✕, and Return there clears it.
        @Test func returnOnTheClearStopClearsTheField() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            window.setContentSize(NSSize(width: 1400, height: 500))
            setItems(opened, [.search, .hidden], harness)
            let field = opened.explorerToolbar.searchField
            var cleared = 0
            field.onClear = { cleared += 1 }
            field.stringValue = "abc"
            #expect(!field.clearStop.isHidden)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(window.firstResponder === field.clearStop)
            field.clearStop.keyDown(with: try tab(key: 36, "\r", window))
            #expect(cleared == 1)
            await harness.close()
        }

        // HistoryButton.tsx:183-187, ExplorerWorkspace.tsx:999-1003: a Mac control-click is the right-click, with no click
        // after it. On Back it opens the history and doesn't step back.
        @Test func aControlClickOnBackListsTheHistoryInsteadOfSteppingBack() throws {
            let button = ToolbarButton(icon: .back, label: "Back", identifier: "toolbar.back")
            var clicks = 0
            var rights = 0
            var presses = 0
            button.onClick = { clicks += 1 }
            button.onPress = { presses += 1 }
            button.onRightClick = { rights += 1 }
            button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                defer: true)
            host.contentView?.addSubview(button)
            let point = MouseEvents.center(of: button)
            let down = try #require(MouseEvents.event(.leftMouseDown, at: point, in: host, modifiers: [.control]))
            let up = try #require(MouseEvents.event(.leftMouseUp, at: point, in: host, modifiers: [.control]))
            button.mouseDown(with: down)
            button.mouseUp(with: up)
            #expect(rights == 1)
            #expect(presses == 0)
            #expect(clicks == 0)
        }

        // HistoryButton.tsx:181 `onPointerLeave={cancelHold}`: sliding off ends the hold at once.
        @Test func slidingOffAHeldHistoryButtonEndsTheHold() throws {
            let button = ToolbarButton(icon: .back, label: "Back", identifier: "toolbar.back")
            var ended: [Bool] = []
            var clicks = 0
            button.onRelease = { ended.append($0) }
            button.onClick = { clicks += 1 }
            button.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                defer: true)
            host.contentView?.addSubview(button)
            let inside = MouseEvents.center(of: button)
            let outside = NSPoint(x: 90, y: 90)
            button.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: inside, in: host)))
            button.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: inside, in: host)))
            #expect(ended.isEmpty)
            button.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: outside, in: host)))
            #expect(ended == [false])
            button.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: outside, in: host)))
            #expect(ended == [false])
            button.mouseUp(with: try #require(MouseEvents.event(.leftMouseUp, at: outside, in: host)))
            #expect(clicks == 0)
        }

        // HistoryButton.tsx:158-163: a dimmed Back or Forward opens no menu, the toolbar's own included (D-016).
        @Test func aRightClickOnADimmedHistoryButtonDoesNothing() async throws {
            let harness = try ExplorerHarness.windowless()
            let opened = try await harness.open()
            let window = try #require(opened.window)
            let back = try #require(opened.explorerToolbar.button(.back))
            #expect(!back.isEnabled)
            let down = try #require(MouseEvents.event(.rightMouseDown, at: MouseEvents.center(of: back), in: window))
            back.rightMouseDown(with: down)
            #expect(AppMenuPresenter.shared.menu == nil)
            await harness.close()
        }

        // aria-haspopup and aria-expanded of the buttons that open a menu; a dimmed history button is a plain button.
        @Test func theButtonsThatOpenMenusSaySo() {
            let sort = ToolbarButton(icon: .up, label: "Sort", identifier: "toolbar.sort")
            #expect(sort.accessibilityRole() == .menuButton)
            #expect(!sort.isAccessibilityExpanded())
            sort.menuOpen = true
            #expect(sort.isAccessibilityExpanded())
            sort.menuOpen = false
            #expect(!sort.isAccessibilityExpanded())
            let back = ToolbarButton(icon: .back, label: "Back", identifier: "toolbar.back")
            #expect(back.accessibilityRole() == .menuButton)
            back.isEnabled = false
            #expect(back.accessibilityRole() == .button)
            let hidden = ToolbarButton(icon: .hidden, label: "Hidden", identifier: "toolbar.hidden")
            #expect(hidden.accessibilityRole() == .button)
        }
    }
}
