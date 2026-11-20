import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// The values search results are ordered or grouped by: read for the fields needed, in batches, each result once, and
/// let go of when no longer needed.
@MainActor
struct SearchValuesTests {
    @MainActor
    final class Reader {
        var asked: [(field: ItemValueField, paths: [String])] = []
        func read(_ paths: [String], _ field: ItemValueField) async -> [ItemValue] {
            asked.append((field, paths))
            return paths.map { .number(Int64($0.count)) }
        }
    }

    private func store(_ reader: Reader) -> (SearchValues, () -> Int) {
        var changes = 0
        let values = SearchValues(read: { await reader.read($0, $1) })
        values.changed = { changes += 1 }
        return (values, { changes })
    }

    @Test func readsTheFieldsNeededForEveryResultOnce() async {
        let reader = Reader()
        let (values, changes) = store(reader)
        values.need([.size], paths: ["/a", "/bb"])
        values.need([.size], paths: ["/a", "/bb", "/ccc"])
        #expect(await waitUntil { values.value(.size, of: "/ccc") != nil })
        #expect(values.value(.size, of: "/bb") == .number(3))
        // Each result was read once, and only the field asked for.
        #expect(reader.asked.flatMap(\.paths).sorted() == ["/a", "/bb", "/ccc"])
        #expect(Set(reader.asked.map(\.field)) == [.size] && changes() >= 1)
        #expect(values.fields == [.size] && values.value(.modified, of: "/a") == nil)
    }

    @Test func aFieldNoLongerNeededStopsAndItsValuesGo() async {
        let reader = Reader()
        let (values, _) = store(reader)
        values.need([.modified], paths: ["/a"])
        #expect(await waitUntil { values.value(.modified, of: "/a") != nil })
        values.need([.tags], paths: ["/a"])
        #expect(values.fields == [.tags] && values.value(.modified, of: "/a") == nil)
        values.reset()
        #expect(values.fields.isEmpty)
        values.need([], paths: ["/a"])
        #expect(values.fields.isEmpty)
    }

    // Many results are read a batch at a time, the order and groups made again after each.
    @Test func manyResultsAreReadInBatches() async {
        let reader = Reader()
        let (values, changes) = store(reader)
        let paths = (0..<(SearchValues.batchSize * 2 + 1)).map { "/r/\($0)" }
        values.need([.created], paths: paths)
        #expect(await waitUntil { values.value(.created, of: paths.last ?? "") != nil })
        #expect(reader.asked.map(\.paths.count) == [SearchValues.batchSize, SearchValues.batchSize, 1])
        #expect(changes() == 3)
    }

    @Test func eachOrderAndGroupingNamesTheFieldItReads() {
        #expect(
            SearchResultsSortByPreference.allCases.filter(\.readsEveryResult).compactMap(\.valueField) == [
                .modified, .created, .lastOpened, .added, .size,
            ])
        #expect(
            SearchResultsSortByPreference.name.valueField == nil && !SearchResultsSortByPreference.kind.readsEveryResult
        )
        #expect(
            GroupByPreference.allCases.compactMap(\.valueField) == [
                .modified, .created, .lastOpened, .added, .size, .tags,
            ])
    }
}
