import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    /// Search results' own Group By and order, over the stand-in fd runtime: every field, a date, the size and the
    /// tags read for every result only while the order or the groups need them.
    @MainActor
    @Suite struct SearchGroupsTests {
        /// The reads of values the results asked for, by field.
        @MainActor
        final class Reads {
            var fields: [ItemValueField] = []
            var paths: [String] = []
        }

        /// A window on the grouped folder, searching it with three results, reads of values counted.
        private func searched(_ harness: ExplorerHarness) async throws -> (MainWindowController, Reads) {
            let tab = try await harness.open(try harness.makeGroupedFolder().path)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            tab.perform(.viewAsDetails)
            let reads = Reads()
            let real = tab.content.loaders.values
            tab.content.loaders.values = { paths, field in
                reads.fields.append(field)
                reads.paths += paths
                return await real(paths, field)
            }
            engine.finds = { _ in (["a-today.pdf", "c-yesterday.png", "d-old.txt"], false, false) }
            let field = try #require(tab.searchField)
            // A search starts from two characters; the stand-in engine finds what it is told.
            field.stringValue = "zz"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.entries.count == 3 })
            return (tab, reads)
        }

        @Test func searchResultsGroupByEveryFieldApartFromTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, reads) = try await searched(harness)
            // The results start without groups, and nothing is read for them.
            #expect(tab.groupTitles.isEmpty && tab.menuState.groupBy == GroupByPreference.none)
            #expect(tab.content.searchFieldsNeeded.isEmpty && reads.fields.isEmpty)
            let canRun = tab.commandAvailability()
            #expect(GroupByPreference.allCases.allSatisfy { canRun($0.command) })
            // By name, folder or kind: what each result carries, nothing read.
            tab.perform(.groupByFolder)
            #expect(tab.activePane.searchGroupBy == .folder && tab.groupTitles == ["Grouped"])
            tab.perform(.groupByKind)
            #expect(tab.groupTitles == ["Documents", "Images", "PDFs"])
            #expect(reads.fields.isEmpty)
            // By a date: the date of every result is read, and only that.
            tab.perform(.groupByModified)
            #expect(await waitUntil { tab.groupTitles == ["Today", "Yesterday", "2020"] })
            #expect(Set(reads.fields) == [.modified] && reads.paths.count == 3)
            #expect(tab.menuState.groupBy == .modified && tab.openTab.searchGroupBy == .modified)
            // By size, smallest first; the dates read go.
            tab.perform(.groupBySize)
            #expect(await waitUntil { tab.groupTitles == ["Zero bytes", "100 KB to 1 MB", "1 to 10 MB"] })
            #expect(tab.content.searchFieldsNeeded == [.size])
            #expect(tab.content.searchValues.fields == [.size])
            // By tags: the first tag of every result; those without, last.
            let tagged = harness.folder.appending("Grouped/a-today.pdf")
            try (tagged as NSURL).setResourceValue(["Work"], forKey: .tagNamesKey)
            tab.perform(.groupByTags)
            #expect(await waitUntil { tab.groupTitles == ["Work", "No Tags"] })
            #expect(tab.content.searchValues.fields == [.tags])
            // Back to name: nothing is read any more.
            tab.perform(.groupByName)
            #expect(tab.groupTitles == ["A", "C", "D"] && tab.content.searchValues.fields.isEmpty)
            // Put away, the folder comes back with its own grouping, and the values go.
            tab.search.session.hideResults()
            #expect(await waitUntil { tab.searchRootPath == nil && tab.content.searchDisplay == nil })
            #expect(tab.content.activeGroupBy == GroupByPreference.none && tab.content.searchValues.fields.isEmpty)
            await harness.close()
        }

        // Ordered by a date or the size, the results' values are read, and they come in that order, the newest and
        // the largest first; ordered by name again, nothing is read.
        @Test func searchResultsSortByADateOrTheSizeReadOnlyThen() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, reads) = try await searched(harness)
            #expect(DetailsSorting.sortKey(for: .size, search: true) == "size")
            #expect(DetailsSorting.sortKey(for: .permissions, search: true) == nil)
            tab.search.session.sortByColumn(.size)
            #expect(tab.search.session.sortDirection == .desc)
            #expect(
                await waitUntil {
                    tab.content.entries.map(\.name) == ["c-yesterday.png", "a-today.pdf", "d-old.txt"]
                })
            #expect(reads.fields == [.size])
            tab.search.session.sortByColumn(.size)
            #expect(
                await waitUntil {
                    tab.content.entries.map(\.name) == ["d-old.txt", "a-today.pdf", "c-yesterday.png"]
                })
            tab.search.session.sortByColumn(.modified)
            #expect(
                await waitUntil {
                    tab.content.entries.map(\.name) == ["a-today.pdf", "c-yesterday.png", "d-old.txt"]
                })
            #expect(tab.content.searchValues.fields == [.modified])
            // Sorted by a date and grouped by the size: both read, each once.
            tab.perform(.groupBySize)
            #expect(await waitUntil { tab.content.searchValues.fields == [.modified, .size] })
            tab.search.session.sortByColumn(.name)
            tab.perform(.groupByNone)
            #expect(await waitUntil { tab.content.searchValues.fields.isEmpty })
            #expect(tab.content.entries.map(\.name) == ["a-today.pdf", "c-yesterday.png", "d-old.txt"])
            await harness.close()
        }
    }
}
