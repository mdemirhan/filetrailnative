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

    // Many results are read a batch at a time, and the order and groups are made again once, when the read ends: a
    // read quicker than the interval moves no row before that.
    @Test func manyResultsAreReadInBatchesAndToldOnceAtTheEnd() async {
        let reader = Reader()
        let (values, changes) = store(reader)
        values.now = { 100 }
        let paths = (0..<(SearchValues.batchSize * 2 + 1)).map { "/r/\($0)" }
        values.need([.created], paths: paths)
        #expect(await waitUntil { values.value(.created, of: paths.last ?? "") != nil })
        #expect(reader.asked.map(\.paths.count) == [SearchValues.batchSize, SearchValues.batchSize, 1])
        #expect(await waitUntil { changes() == 1 })
    }

    // A read that goes on tells of its values once an interval, so a long one shows it is getting on.
    @Test func aLongReadTellsOfItsValuesOnceAnInterval() async {
        let reader = Reader()
        let (values, changes) = store(reader)
        // Each look at the clock is 0.3 s on: one at the start, one after each batch.
        var time = 0.0
        values.now = {
            time += 0.3
            return time
        }
        let paths = (0..<(SearchValues.batchSize * 8)).map { "/r/\($0)" }
        values.need([.size], paths: paths)
        #expect(await waitUntil { values.value(.size, of: paths.last ?? "") != nil })
        #expect(reader.asked.count == 8)
        // Batches 4 (1.2 s after the start) and 8 (1.2 s after that, and the last).
        #expect(await waitUntil { changes() == 2 })
    }

    // Another query in the same folder: the values read stay, only results without one are read, and what waited
    // for results no longer there is not read.
    @Test func resultsThatChangeKeepWhatWasReadAndReadOnlyTheNew() async {
        let reader = Reader()
        let (values, _) = store(reader)
        values.need([.size], paths: ["/a", "/bb"])
        #expect(await waitUntil { values.value(.size, of: "/bb") != nil })
        // Narrowed: nothing to read.
        values.need([.size], paths: ["/bb"])
        // Widened: only the new result, and the one no longer there keeps its value for when it is back.
        values.need([.size], paths: ["/bb", "/ccc"])
        #expect(await waitUntil { values.value(.size, of: "/ccc") != nil })
        #expect(reader.asked.flatMap(\.paths) == ["/a", "/bb", "/ccc"])
        #expect(values.value(.size, of: "/a") == .number(2))
        // Results asked for, then others before their read went out: only the others are read.
        let many = (0..<(SearchValues.batchSize + 5)).map { "/m/\($0)" }
        values.need([.size], paths: many)
        values.need([.size], paths: ["/zzzz"])
        #expect(await waitUntil { values.value(.size, of: "/zzzz") != nil })
        #expect(reader.asked.flatMap(\.paths) == ["/a", "/bb", "/ccc", "/zzzz"])
        #expect(values.value(.size, of: many.last ?? "") == nil)
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
