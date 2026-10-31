// Covers Esc outside the content pane (useExplorerShortcuts.ts:1605) on a tab whose window is never shown, over the
// stand-in fd runtime
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
}
