// Covers the scenarios 187-trash-command-delete and 196-undo-trash-puts-back through a shown window: the press as the
// capture's driver sends it, the key as the system offers it
import AppKit
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ClickedRowGUITests {
        private func pressTrashKey(in window: NSWindow) throws {
            let key = try #require(KeyEvents.key(named: "Backspace"))
            let down = try #require(KeyEvents.events(key, modifiers: .command, window: window).first)
            if !KeyEvents.performKeyEquivalent(down, window: window, menu: NSApp.mainMenu) {
                window.firstResponder?.keyDown(with: down)
            }
        }

        // F-290 F-378: on screen, ⌘⌫ takes the row just clicked, and the files' Undo puts it back.
        @Test func theTrashKeyTakesTheRowClicked() async throws {
            let harness = try ExplorerHarness()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            let window = try #require(tab.window)
            let row = try #require(list.rowNames.firstIndex(of: "note.txt"))
            #expect(await MouseEvents.click(at: list.center(ofRow: row), in: window, count: 1, modifiers: []))
            #expect(list.selectedNames == ["note.txt"])
            #expect(list.table?.selectedRowIndexes.map { list.rowNames[$0] } == ["note.txt"])
            try pressTrashKey(in: window)
            let note = harness.folder.appending("note.txt").path
            #expect(await waitUntil { !FileManager.default.fileExists(atPath: note) })
            #expect(await waitUntil { !list.rowNames.contains("note.txt") })
            #expect(list.rowNames == ["Alpha", "Beta", "Gamma"])
            let session = writes.session(for: try #require(tab.group))
            #expect(await waitUntil { session.card == nil })
            tab.perform(.undo)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: note) })
            #expect(await waitUntil { list.rowNames.contains("note.txt") })
            await harness.close()
        }

        // F-290: a press that only brings the window forward selects nothing, so the key takes what stayed selected and
        // shown as selected, not the row under that press.
        @Test func aPressThatOnlyBringsTheWindowForwardLeavesTheKeyOnWhatIsShownSelected() async throws {
            let harness = try ExplorerHarness()
            let writes = try harness.writeOperations()
            defer { withExtendedLifetime(writes) {} }
            let (tab, list) = try await harness.openList()
            let window = try #require(tab.window)
            let beta = try #require(list.rowNames.firstIndex(of: "Beta"))
            #expect(await MouseEvents.click(at: list.center(ofRow: beta), in: window, count: 1, modifiers: []))
            #expect(list.selectedNames == ["Beta"])
            let other = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            #expect(!window.isKeyWindow)
            // Event numbers as the window server's: the press is a person's.
            let note = try #require(list.rowNames.firstIndex(of: "note.txt"))
            let point = list.center(ofRow: note)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 7, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)))
            }
            #expect(list.selectedNames == ["Beta"])
            #expect(list.table?.selectedRowIndexes.map { list.rowNames[$0] } == ["Beta"])
            try pressTrashKey(in: window)
            let betaPath = harness.folder.appending("Beta").path
            #expect(await waitUntil { !FileManager.default.fileExists(atPath: betaPath) })
            #expect(FileManager.default.fileExists(atPath: harness.folder.appending("note.txt").path))
            let session = writes.session(for: try #require(tab.group))
            #expect(await waitUntil { session.card == nil })
            tab.perform(.undo)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: betaPath) })
            await harness.close()
        }
    }
}
