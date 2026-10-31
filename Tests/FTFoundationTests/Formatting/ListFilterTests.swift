// Port of apps/desktop/src/renderer/lib/{listFilter,typeahead,searchRefinement}.test.ts, with the
// list-filter golden recorded from the reference (tools/parity/golden/list-filter.ts).
import FTTestSupport
import Testing

@testable import FTFoundation

struct ListFilterTests {
    struct Entry: ListFilterSearchResult, Codable, Equatable, Sendable {
        var id: Int
        var name: String
        var relativeParentPath: String
    }

    struct Input: Codable, Sendable {
        let entries: [Entry]
        let query: String
        let shown: Int
        let total: Int
    }

    struct Output: Codable, Equatable, Sendable {
        let byName: [Int]
        let bySearch: [Int]
        let selection: Int?
        let count: String
    }

    private let entries = ["Android", "Documents", "my doc.txt", "report (1).pdf", "C++ notes"].enumerated().map {
        Entry(id: $0.offset, name: $0.element, relativeParentPath: "")
    }

    private func names(_ query: String) -> [String] {
        ListFilter.filterByName(entries, query: query).map(\.name)
    }

    // T-74e6332c F-092
    // B-NAV-169
    @Test func keepsTheNamesThatContainTheText() {
        #expect(names("DO") == ["Documents", "my doc.txt"])
        #expect(names("d") == ["Android", "Documents", "my doc.txt", "report (1).pdf"])
        // The text is taken as typed: spaces count, and nothing is a pattern.
        #expect(names("y d") == ["my doc.txt"])
        #expect(names("(1)") == ["report (1).pdf"])
        #expect(names("c++") == ["C++ notes"])
        #expect(names("zzz") == [])
    }

    // T-60a391b3
    @Test func returnsTheSameListWhenThereIsNoFilter() {
        #expect(ListFilter.filterByName(entries, query: "") == entries)
    }

    // T-0d4539c1
    // B-NAV-169 B-VIEW-239
    @Test func selectsTheFirstNameStartingWithTheText() {
        // "Android" contains "d" and comes first, but "Documents" starts with it.
        #expect(ListFilter.selection(in: ListFilter.filterByName(entries, query: "d"), query: "d")?.name == "Documents")
        // No name starts with it: the first match.
        #expect(
            ListFilter.selection(in: ListFilter.filterByName(entries, query: "oc"), query: "oc")?.name == "Documents")
        #expect(ListFilter.selection(in: [Entry](), query: "zzz") == nil)
        #expect(ListFilter.selection(in: entries, query: "") == nil)
    }

    // T-95a42904
    // B-SRCH-116
    @Test func filtersSearchResultsByNameOrByTheFolderTheyAreIn() {
        let results = [
            Entry(id: 0, name: "App.tsx", relativeParentPath: "src/components"),
            Entry(id: 1, name: "App.test.tsx", relativeParentPath: "tests"),
            Entry(id: 2, name: "src-notes.md", relativeParentPath: "docs"),
        ]
        func found(_ query: String) -> [String] { ListFilter.filterSearchResults(results, query: query).map(\.name) }
        #expect(found("app") == ["App.tsx", "App.test.tsx"])
        // "src" is a folder of one result and part of the name of another.
        #expect(found("SRC") == ["App.tsx", "src-notes.md"])
        #expect(found("tests") == ["App.test.tsx"])
        #expect(found("zzz") == [])
        #expect(ListFilter.filterSearchResults(results, query: "") == results)
    }

    // T-f76d7a77 F-092
    // B-NAV-174
    @Test func countsTheItemsMentioningTheTotalOnlyWhileSomeAreHidden() {
        #expect(ListFilter.formatItemCount(shown: 240, total: 240) == "240 items")
        #expect(ListFilter.formatItemCount(shown: 1, total: 1) == "1 item")
        #expect(ListFilter.formatItemCount(shown: 3, total: 240) == "3 of 240 items")
        #expect(ListFilter.formatItemCount(shown: 0, total: 1) == "0 of 1 item")
    }

    // B-SRCH-116
    @Test func listFilterMatchesTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "list-filter")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { input in
            let byName = ListFilter.filterByName(input.entries, query: input.query)
            return Output(
                byName: byName.map(\.id),
                bySearch: ListFilter.filterSearchResults(input.entries, query: input.query).map(\.id),
                selection: ListFilter.selection(in: byName, query: input.query)?.id,
                count: ListFilter.formatItemCount(shown: input.shown, total: input.total))
        }
    }

    // MARK: Typeahead

    // T-eb1d7cfe
    // B-NAV-093
    @Test func detectsPrintableCharacterKeys() {
        #expect(Typeahead.isCharacterKey("a"))
        #expect(!Typeahead.isCharacterKey(" "))
        #expect(!Typeahead.isCharacterKey("ArrowDown"))
        #expect(!Typeahead.isCharacterKey(""))
        // One UTF-16 unit is one character; a pair is two, as `key.length` counts.
        #expect(Typeahead.isCharacterKey("é"))
        #expect(!Typeahead.isCharacterKey("🎉"))
    }

    // T-df5c84b6
    @Test func matchesTheFirstVisibleTreeNodeByPrefix() {
        let nodes: [String: TypeaheadTreeNode] = [
            "/Users/demo": TypeaheadTreeNode(
                path: "/Users/demo", name: "demo", expanded: true,
                childPaths: ["/Users/demo/Desktop", "/Users/demo/Documents"]),
            "/Users/demo/Desktop": TypeaheadTreeNode(
                path: "/Users/demo/Desktop", name: "Desktop", expanded: false, childPaths: []),
            "/Users/demo/Documents": TypeaheadTreeNode(
                path: "/Users/demo/Documents", name: "Documents", expanded: false, childPaths: []),
        ]
        #expect(
            Typeahead.findTreeMatch(rootPath: "/Users/demo", nodes: nodes, query: "doc")?.path
                == "/Users/demo/Documents")
        #expect(Typeahead.findTreeMatch(rootPath: "/Users/demo", nodes: nodes, query: "  ") == nil)
        #expect(Typeahead.findTreeMatch(rootPath: "/missing", nodes: nodes, query: "d") == nil)
    }

    @Test func treeTypeaheadSkipsCollapsedDescendants() {
        let nodes: [String: TypeaheadTreeNode] = [
            "/r": TypeaheadTreeNode(path: "/r", name: "r", expanded: true, childPaths: ["/r/a", "/r/b"]),
            "/r/a": TypeaheadTreeNode(path: "/r/a", name: "alpha", expanded: false, childPaths: ["/r/a/x"]),
            "/r/a/x": TypeaheadTreeNode(path: "/r/a/x", name: "xray", expanded: false, childPaths: []),
            "/r/b": TypeaheadTreeNode(path: "/r/b", name: "beta", expanded: false, childPaths: []),
        ]
        #expect(Typeahead.findTreeMatch(rootPath: "/r", nodes: nodes, query: "x") == nil)
        #expect(Typeahead.findTreeMatch(rootPath: "/r", nodes: nodes, query: "be")?.path == "/r/b")
    }

    // MARK: Search refinement

    struct Item: SearchRefinementItem, Equatable {
        let path: String
        var name: String { String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...]) }
    }

    private let readmeUpper = Item(path: "/Users/demo/Project/README.md")
    private let readmeLower = Item(path: "/Users/demo/docs/readme.txt")
    private let notes = Item(path: "/Users/demo/docs/notes.txt")

    // T-e566169a
    // B-SRCH-027
    @Test func matchesPlainTextAsFdDoes() {
        func matches(_ item: Item, _ query: String) -> Bool {
            SearchRefinement.matchesTextQuery(item, query: query, scope: .name)
        }
        #expect(matches(readmeUpper, "readme"))
        #expect(matches(readmeLower, "readme"))
        #expect(matches(readmeUpper, "README"))
        #expect(!matches(readmeLower, "README"))
        #expect(!matches(notes, "readme"))
        // Nothing is a pattern.
        #expect(matches(Item(path: "/x/report (1).pdf"), "(1).p"))
        #expect(!matches(Item(path: "/x/abc"), "a.c"))
    }

    // T-dc2d82a3
    // B-SRCH-028
    @Test func looksAtTheWholePathWhenTheSearchMatchesTheFullPath() {
        #expect(!SearchRefinement.matchesTextQuery(notes, query: "docs", scope: .name))
        #expect(SearchRefinement.matchesTextQuery(notes, query: "docs", scope: .path))
        #expect(SearchRefinement.matchesTextQuery(readmeUpper, query: "project", scope: .path))
        #expect(!SearchRefinement.matchesTextQuery(readmeUpper, query: "Docs", scope: .path))
    }

    // T-9dadd92e
    // B-SRCH-025 B-SRCH-026 B-SRCH-029
    @Test func knowsWhenLongerTextCanOnlyFindASubset() {
        #expect(SearchRefinement.isNarrower(base: "re", next: "readme"))
        #expect(SearchRefinement.isNarrower(base: "re", next: "more"))
        #expect(SearchRefinement.isNarrower(base: "re", next: "re"))
        // A capital in the longer text only makes it stricter.
        #expect(SearchRefinement.isNarrower(base: "re", next: "REadme"))
        // A capital in the shorter text was matched exactly, so the longer one must keep it.
        #expect(SearchRefinement.isNarrower(base: "Re", next: "Readme"))
        #expect(!SearchRefinement.isNarrower(base: "Re", next: "readme"))
        #expect(!SearchRefinement.isNarrower(base: "re", next: "r"))
        #expect(!SearchRefinement.isNarrower(base: "re", next: "notes"))
        #expect(!SearchRefinement.isNarrower(base: "", next: "anything"))
    }

    // T-2d1cc088
    // B-SRCH-033 B-SRCH-036
    @Test func keepsTheResultsOnScreenThatTheNewTextAlsoFinds() {
        let results = [readmeUpper, readmeLower, notes]
        func keep(_ items: [Item], _ previous: String, _ query: String) -> [Item] {
            SearchRefinement.keepMatching(items, previousQuery: previous, query: query, scope: .name)
        }
        // Longer text: only what still matches.
        #expect(keep([readmeUpper, readmeLower], "re", "readme.t") == [readmeLower])
        // Shorter text: everything found so far still matches.
        #expect(keep([readmeUpper, readmeLower], "readme", "re") == [readmeUpper, readmeLower])
        // Unrelated text: nothing is known to match.
        #expect(keep(results, "readme", "notes") == [])
        #expect(keep(results, "", "re") == [])
    }

    // The byte-wise path for ASCII names gives what the full case mapping gives, for every kind of name.
    @Test func theAsciiFastPathAgreesWithTheFullCaseMapping() {
        let names = [
            "IMG_1 Holiday.JPG", "readme", "README.md", "Ünïcode Name", "İstanbul", "KELVIN K", "Σίσυφος", "日本語.txt",
            "a", "", "ab", "Zebra",
        ]
        let items = names.enumerated().map { Entry(id: $0.offset, name: $0.element, relativeParentPath: "") }
        for query in ["i", "img_1", "READ", "k", "K", "ü", "ι", "日", "z", "zz", "a", "AB", "istanbul", "ς"] {
            let lowered = JSString.lowercased(query)
            let expected = items.filter { JSString.includes(JSString.lowercased($0.name), lowered) }
            #expect(ListFilter.filterByName(items, query: query) == expected, "\(query)")
            let prefixed =
                expected.first { JSString.hasPrefix(JSString.lowercased($0.name), lowered) } ?? expected.first
            #expect(ListFilter.selection(in: expected, query: query) == prefixed, "\(query)")
        }
    }

    // A keystroke in a folder of tens of thousands of items stays in the original's ballpark (about 5 ms there).
    @Test func filtersFiftyThousandNamesWithinAFewHundredMillisecondsEvenUnoptimized() {
        let items = (0..<50_000).map { Entry(id: $0, name: "IMG_\($0) holiday photo copy.jpg", relativeParentPath: "") }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let matches = ListFilter.filterByName(items, query: "img_4")
            _ = ListFilter.selection(in: matches, query: "img_4")
        }
        #expect(elapsed < .milliseconds(400))
    }
}
