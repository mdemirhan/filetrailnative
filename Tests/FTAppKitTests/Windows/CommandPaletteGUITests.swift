// The command palette on a real window: ⇧⌘P through the menu bar, a name typed into its field, and Return
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct CommandPaletteGUITests {
        private func key(
            _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
        ) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        // ⇧⌘P is the menu bar's: the box opens over the window with the keyboard in its field, what is typed there
        // narrows it, and Return runs the command in the window, as View ▸ Two Panes would, the keyboard back in the
        // list.
        @Test func theKeyOpensItAndReturnRunsTheCommandTyped() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            // The harness doesn't make the app active: the window has the keyboard as it would on screen.
            let menu = MainMenu(windows: harness.windows, focusedWindow: { window })
            menu.build()
            defer { NSApp.mainMenu = nil }
            harness.windows.onMenuState = { [weak menu] id, state in menu?.sync.setWindowState(windowID: id, state) }
            tab.perform(.focusContentPane)
            #expect(!tab.showsTwoPanes)

            NSApp.sendEvent(try key(35, "p", [.command, .shift], in: window))
            let box = try #require(tab.commandPaletteBox)
            #expect(box.shell.holdsKeyboard)
            for character in "two panes" {
                let code: UInt16 = character == " " ? 49 : 0
                window.sendEvent(try key(code, String(character), in: window))
            }
            #expect(await waitUntil { box.field.stringValue == "two panes" })
            #expect(box.selectedRow?.entry.id == "toggleTwoPanes")
            window.sendEvent(try key(36, "\r", in: window))
            #expect(tab.commandPaletteBox == nil)
            #expect(await waitUntil { tab.showsTwoPanes })
            #expect(tab.focusedPane == .content)
            await harness.close()
        }
    }
}
