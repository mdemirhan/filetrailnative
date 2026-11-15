import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.restoresWindowSeams) struct CommandPaletteBoxTests {
        /// A windowless List and the app's menu over it, the tab's window having the keyboard, as on screen.
        private func open() async throws -> (ExplorerHarness, MainWindowController, MainMenu) {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let menu = MainMenu(windows: harness.windows, focusedWindow: { tab.window })
            let store = harness.store
            menu.recentCommands = { store.recentCommands() }
            menu.recordCommand = { store.recordCommand($0) }
            menu.build()
            harness.windows.onMenuState = { [weak menu] id, state in menu?.sync.setWindowState(windowID: id, state) }
            return (harness, tab, menu)
        }

        private func openBox(_ tab: MainWindowController, _ menu: MainMenu) throws -> CommandPaletteBox {
            menu.toggleCommandPalette()
            let box = try #require(tab.commandPaletteBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            return box
        }

        private func type(_ text: String, into box: CommandPaletteBox) {
            box.field.stringValue = text
            box.textChanged(text)
        }

        // ⇧⌘P opens the box with the keyboard in its field and every command listed; a name typed and Return run the
        // command in the tab, the box gone and the keyboard back in the list.
        @Test func aCommandTypedAndReturnRunItInTheTab() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            #expect(window.makeFirstResponder(tab.content.pane?.focusView))
            #expect(!tab.includeHidden)
            let box = try openBox(tab, menu)
            #expect(box.shell.holdsKeyboard)
            #expect(box.field.placeholderString == "Type a command")
            #expect(box.frame.minY == 60 && box.frame.width == 580)
            // With nothing typed every command is listed under its group.
            #expect(box.rows.count == box.entries.count)
            #expect(box.sections.first?.title == ShortcutGroup.navigation.label)
            // Back and Forward can't run in a window just opened: the first row that can is selected.
            #expect(box.rows.first?.entry.id == "goBack")
            #expect(box.selectedRow?.entry.id == "goEnclosingFolder")

            type("hidden", into: box)
            #expect(box.selectedRow?.entry.title == "Hidden Files")
            #expect(box.rowViews.first?.keysLabel.stringValue == "⇧⌘.")
            #expect(box.rowViews.first?.placeLabel.stringValue == "View")
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.commandPaletteBox == nil)
            #expect(await waitUntil { tab.includeHidden })
            #expect(tab.content.pane?.hasKeyboard == true)
            #expect(harness.store.recentCommands() == ["toggleHiddenFiles"])

            // It comes first next time, checked now, under Recently Used.
            let again = try openBox(tab, menu)
            #expect(again.sections.first?.title == CommandPalette.recentTitle)
            #expect(again.rows.first?.entry.id == "toggleHiddenFiles")
            #expect(again.rows.first?.entry.checked == true)
            #expect(again.rowViews.first?.checkLabel.stringValue == "\u{2713}")
            // ⇧⌘P again closes it; nothing ran.
            menu.toggleCommandPalette()
            #expect(tab.commandPaletteBox == nil)
            #expect(tab.includeHidden)
            await harness.close()
        }

        // Arrows and ⌃N/⌃P move the selection; Esc closes the box and runs nothing.
        @Test func theArrowsMoveAndEscapeClosesWithoutRunning() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            let box = try openBox(tab, menu)
            type("view as", into: box)
            #expect(box.selectedRow?.entry.id == "viewAsIcons")
            #expect(box.helpLabel.stringValue == HelpContent.line(of: .viewAsIcons))
            DialogKeys.press(125, "", in: window)
            #expect(box.selectedRow?.entry.id == "viewAsDetails")
            // Under the list, what the selected command does.
            #expect(box.helpLabel.stringValue == "View as a list, with columns")
            DialogKeys.press(45, "n", modifiers: .control, in: window)
            #expect(box.selectedRow?.entry.id == "viewAsList")
            DialogKeys.press(35, "p", modifiers: .control, in: window)
            DialogKeys.press(126, "", in: window)
            #expect(box.selectedRow?.entry.id == "viewAsIcons")
            DialogKeys.press(53, "\u{1b}", in: window)
            #expect(tab.commandPaletteBox == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(tab.viewMode == .details)
            #expect(harness.store.recentCommands().isEmpty)
            await harness.close()
        }

        // A command that can't run now is dimmed and listed last; Return on it leaves the box up.
        @Test func aDimmedCommandStaysUpAndDoesNotRun() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            // Nothing to go forward to: Forward is dimmed, after Go to Folder… and the rest that fit.
            let box = try openBox(tab, menu)
            type("forward", into: box)
            let forward = try #require(box.rows.firstIndex { $0.entry.id == "goForward" })
            #expect(box.rows[forward].entry.enabled == false)
            #expect(box.rows[forward...].allSatisfy { !$0.entry.enabled })
            box.moveSelection(forward)
            #expect(box.selectedRow?.entry.id == "goForward")
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.commandPaletteBox === box)
            #expect(harness.store.recentCommands().isEmpty)
            DialogKeys.press(53, "\u{1b}", in: window)
            await harness.close()
        }

        // A click on a dimmed row does what Return on it does: nothing, the box staying up.
        @Test func aClickOnADimmedCommandDoesNotRunIt() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let box = try openBox(tab, menu)
            type("forward", into: box)
            let forward = try #require(box.rows.firstIndex { $0.entry.id == "goForward" })
            box.rowClicked(forward)
            #expect(tab.commandPaletteBox === box)
            #expect(harness.store.recentCommands().isEmpty)
            box.onClose()
            await harness.close()
        }

        // The pointer resting where the box opened, or stirring a little after a row was chosen with the keyboard,
        // selects nothing: Return runs the row typed for. Moved clearly, it selects the row it is over.
        @Test func thePointerSelectsOnlyOnceItHasClearlyMoved() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let box = try openBox(tab, menu)
            type("view as", into: box)
            #expect(box.selectedRow?.entry.id == "viewAsIcons")
            box.pointerMoved(over: 2, at: NSPoint(x: 100, y: 100))
            box.pointerMoved(over: 2, at: NSPoint(x: 101, y: 102))
            #expect(box.selectedRow?.entry.id == "viewAsIcons")
            box.pointerMoved(over: 2, at: NSPoint(x: 100, y: 100 + CommandPaletteBox.pointerSlack))
            #expect(box.selectedRow?.entry.id == "viewAsList")
            // From then on it selects as it goes.
            box.pointerMoved(over: 1, at: NSPoint(x: 100, y: 105))
            #expect(box.selectedRow?.entry.id == "viewAsDetails")
            // An arrow chooses again: the pointer has to move clearly once more.
            box.moveSelection(-1)
            box.pointerMoved(over: 3, at: NSPoint(x: 100, y: 105))
            box.pointerMoved(over: 3, at: NSPoint(x: 100, y: 106))
            #expect(box.selectedRow?.entry.id == "viewAsIcons")
            box.onClose()
            await harness.close()
        }

        // Close Window from the palette closes the window with every tab of it, as File ▸ Close Window does.
        @Test func closeWindowClosesEveryTabOfTheWindow() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let group = try #require(tab.group)
            tab.perform(.newTab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let entry = try #require(
                menu.commandPaletteEntries(
                    for: ExplorerCommandTarget(handle: tab, focused: true), ShortcutCommands.defaultBindings
                ).first { $0.id == "closeWindow" })
            menu.runPaletteCommand(entry, in: tab)
            #expect(await waitUntil { harness.windows.count == 0 })
            await harness.close()
        }

        // A key of the palette's that the menu doesn't listen for (one with no ⌘ or ⌃) opens it from the window.
        @Test func aKeyOfThePalettesTheMenuDoesntHearOpensIt() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            tab.updatePreferences { $0.shortcutOverrides = ["showCommandPalette": ["Cmd+Shift+P", "F1"]] }
            let f1 = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\u{F704}", charactersIgnoringModifiers: "\u{F704}", isARepeat: false,
                    keyCode: 122))
            #expect(tab.windowKeyDown(f1))
            let box = try #require(tab.commandPaletteBox)
            box.onClose()
            #expect(tab.commandPaletteBox == nil)
            withExtendedLifetime(menu) {}
            await harness.close()
        }

        // With two panes a command runs in the pane that had the keyboard when the palette opened, and the keyboard
        // is back in it after.
        @Test func aCommandRunsInThePaneThatHadTheKeyboard() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            let left = tab.activePane
            let right = tab.openSecondPane(at: harness.folder.appending("Alpha").path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            harness.layout(tab)
            tab.focusPane(right)
            #expect(tab.activePane === right)

            let box = try openBox(tab, menu)
            // Folders First is a pane's own, so where it changed shows where the command ran.
            type("folders first", into: box)
            #expect(box.selectedRow?.entry.id == "toggleFoldersFirst")
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.commandPaletteBox == nil)
            #expect(await waitUntil { !right.foldersFirst })
            #expect(left.foldersFirst)
            #expect(tab.activePane === right && tab.paneWithKeyboard === right)
            await harness.close()
        }

        // A command that opens a box of its own opens it once the palette has gone.
        @Test func aCommandThatOpensABoxOpensItOnceThePaletteHasGone() async throws {
            let (harness, tab, menu) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            let box = try openBox(tab, menu)
            type("go to folder", into: box)
            #expect(box.selectedRow?.entry.id == "openLocationSheet")
            DialogKeys.press(36, "\r", in: window)
            #expect(tab.commandPaletteBox == nil)
            #expect(await waitUntil { tab.goToBox != nil })
            #expect(harness.store.recentCommands() == ["openLocationSheet"])
            tab.goToBox?.onClose()
            await harness.close()
        }

        // The page moves have no menu item: the palette runs them in the pane that has the keyboard.
        @Test func runsAPageMoveInTheListThatHasTheKeyboard() async throws {
            let (harness, tab, _) = try await open()
            defer { NSApp.mainMenu = nil }
            let window = try #require(tab.window)
            #expect(window.makeFirstResponder(tab.content.pane?.focusView))
            tab.content.select(paths: [tab.content.entries[0].path])
            let first = tab.content.selectedEntries.first?.path
            #expect(tab.runPaletteKeyCommand(.pageDown))
            #expect(tab.content.selectedEntries.first?.path != first)
            await harness.close()
        }
    }
}
