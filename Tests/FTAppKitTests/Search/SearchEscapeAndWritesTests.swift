// Covers Esc outside the content pane (useExplorerShortcuts.ts:1605) and the search run again after a move
// (App.search.test.tsx) on a tab whose window is never shown, over the stand-in fd runtime
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SearchEscapeTests {
        // B-SRCH-076
        @Test func escapeInTheTreeLeavesTheResultsAndInTheListHidesThem() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            let session = tab.search.session
            #expect(await waitUntil { session.resultsVisible })
            let window = try #require(tab.window)
            let escape = try systemKeyEvent(53)

            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)
            #expect(!WindowEventRouting.intercept(escape, in: window))
            #expect(session.isSearchMode)
            #expect(session.resultsVisible)

            tab.content.focusList()
            #expect(WindowEventRouting.intercept(escape, in: window))
            #expect(!session.resultsVisible)
            await harness.close()
        }
    }

    @MainActor
    @Suite(.windowlessAlone) struct SearchAfterAWriteTests {
        // T-636f3c2e
        @Test func aMoveOfASelectedResultRunsTheSearchAgainOnceItEnds() async throws {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            let moved = harness.folder.appending("Alpha/notes.md")
            try "x".write(to: moved, atomically: true, encoding: .utf8)
            engine.finds = { _ in (["Alpha/notes.md"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "notes"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.search.session.resultsVisible })
            #expect(engine.starts.count == 1)

            tab.content.applySelection(.single(harness.folder.path + "/Alpha/notes.md"))
            tab.content.focusList()
            tab.perform(.moveSelection)
            let box = try #require(tab.goToBox)
            tab.window?.contentView?.layoutSubtreeIfNeeded()
            DialogKeys.type(harness.folder.appending("Beta").path, into: box)
            DialogKeys.press(36, "\r", in: tab.window)
            let landed = harness.folder.appending("Beta/notes.md").path
            #expect(await waitUntil { FileManager.default.fileExists(atPath: landed) })
            #expect(await waitUntil { engine.starts.count == 2 })
            #expect(engine.starts.last?.query == engine.starts.first?.query)
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
