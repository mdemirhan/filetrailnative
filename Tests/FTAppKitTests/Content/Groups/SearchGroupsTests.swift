import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// Search results' own Group By, over the stand-in fd runtime: by name, folder or kind, apart from the folder's.
    @MainActor
    @Suite struct SearchGroupsTests {
        @Test func searchResultsGroupByWhatTheyCarryApartFromTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            tab.perform(.viewAsDetails)
            tab.perform(.groupByKind)
            #expect(await waitUntil { !tab.content.groups.isEmpty })
            engine.finds = { _ in (["note.txt", "Alpha/note.pdf", "Alpha/no.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.entries.count == 3 })
            // The results start without groups: the folder's are its own.
            #expect(tab.groupTitles.isEmpty && tab.menuState.groupBy == GroupByPreference.none)
            // The fields results don't carry are dimmed; Folder is theirs.
            let canRun = tab.commandAvailability()
            #expect(canRun(.groupByFolder) && canRun(.groupByName) && canRun(.groupByKind))
            #expect(!canRun(.groupByModified) && !canRun(.groupBySize) && !canRun(.groupByTags))
            tab.perform(.groupByFolder)
            #expect(tab.activePane.searchGroupBy == .folder && tab.activePane.groupBy == .kind)
            #expect(tab.groupTitles.count == 2 && tab.groupTitles.last == "Alpha")
            #expect(tab.menuState.groupBy == .folder)
            // A field results can't be grouped by changes nothing.
            tab.perform(.groupBySize)
            #expect(tab.activePane.searchGroupBy == .folder)
            tab.perform(.groupByKind)
            #expect(tab.groupTitles == ["Documents", "PDFs"])
            #expect(tab.openTab.searchGroupBy == .kind)
            // Put away, the folder comes back in its own groups.
            tab.search.session.hideResults()
            #expect(await waitUntil { tab.searchRootPath == nil && tab.content.searchDisplay == nil })
            #expect(tab.content.activeGroupBy == .kind && !tab.content.groups.isEmpty)
            await harness.close()
        }
    }
}
