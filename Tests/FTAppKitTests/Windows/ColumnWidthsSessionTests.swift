// The column widths a drag sets, kept with the pane as the window saves its session
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ColumnWidthsSessionTests {
        // A dragged width is the pane's own and the app's, and outlives the next navigation, which saves the window's
        // session with the pane's widths in its tab.
        @Test func aDraggedDetailWidthSurvivesANavigation() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            var widths = tab.content.columnState.widths
            widths[.name] = 333
            tab.content.columnWidthsChanged(widths)
            #expect(tab.preferences.detailColumnWidths.name == 333)

            _ = await tab.navigate(to: harness.folder.appending("Alpha"), history: .push)
            tab.group?.saveSession()
            #expect(tab.preferences.detailColumnWidths.name == 333)
            #expect(tab.activePane.viewSizes?.detailColumnWidths.name == 333)
            #expect(tab.content.columnState.widths[.name] == 333)
            #expect(tab.openTab.viewSizes?.detailColumnWidths.name == 333)
            await harness.close()
        }

        // The same for the widths search results keep of their own.
        @Test func aDraggedSearchWidthSurvivesASessionSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            tab.perform(.viewAsDetails)
            engine.finds = { _ in (["note.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { !tab.content.entries.isEmpty })

            var widths = tab.content.columnState.widths
            widths[.folder] = 222
            tab.content.columnWidthsChanged(widths)
            #expect(tab.preferences.searchColumnWidths.folder == 222)

            tab.group?.saveSession()
            #expect(tab.preferences.searchColumnWidths.folder == 222)
            #expect(tab.activePane.viewSizes?.searchColumnWidths.folder == 222)
            #expect(tab.openTab.viewSizes?.searchColumnWidths.folder == 222)
            // A folder's List keeps its own.
            #expect(tab.activePane.viewSizes?.detailColumnWidths == tab.preferences.detailColumnWidths)
            await harness.close()
        }
    }
}
