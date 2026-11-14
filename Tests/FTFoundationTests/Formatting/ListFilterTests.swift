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
        ListFilter.filterByName(entries, query: query, mode: .contains).map(\.name)
    }

    private func fuzzy(_ query: String) -> [String] {
        ListFilter.filterByName(entries, query: query, mode: .fuzzy).map(\.name)
    }

    @Test func keepsTheNamesThatContainTheText() {
        #expect(names("DO") == ["Documents", "my doc.txt"])
        #expect(names("d") == ["Android", "Documents", "my doc.txt", "report (1).pdf"])
        // The text is taken as typed: spaces count, and nothing is a pattern.
        #expect(names("y d") == ["my doc.txt"])
        #expect(names("(1)") == ["report (1).pdf"])
        #expect(names("c++") == ["C++ notes"])
        #expect(names("zzz") == [])
    }

    @Test func keepsTheNamesWithTheLettersInOrderWhenFuzzy() {
        #expect(fuzzy("dcs") == ["Documents"])
        #expect(fuzzy("rpt") == ["report (1).pdf"])
        #expect(fuzzy("mdt") == ["my doc.txt"])
        // Whatever Contains keeps, Fuzzy keeps, and more: the d and o of "Android".
        #expect(fuzzy("DO") == ["Android", "Documents", "my doc.txt"])
        #expect(fuzzy("c++") == ["C++ notes"])
        // In order only.
        #expect(fuzzy("tpr") == [])
        #expect(fuzzy("zzz") == [])
    }

    @Test func findsAnAccentedLetterHoweverTheNameStoresIt() {
        // "Café" stored as a letter and its accent (as some disks and apps keep names), and "Résumé" as one character
        // each: what is typed matches both, composed or not.
        let decomposed = "Cafe\u{301}.txt"
        let composed = "R\u{E9}sum\u{E9}.pdf"
        let entries = [
            Entry(id: 1, name: decomposed, relativeParentPath: ""),
            Entry(id: 2, name: composed, relativeParentPath: "Docs/Cafe\u{301}"),
        ]
        func names(_ query: String) -> [String] {
            ListFilter.filterByName(entries, query: query, mode: .contains).map(\.name)
        }
        #expect(names("caf\u{E9}") == [decomposed])
        #expect(names("CAF\u{C9}") == [decomposed])
        #expect(names("re\u{301}sume\u{301}") == [composed])
        #expect(ListFilter.selection(in: entries, query: "caf\u{E9}", mode: .contains)?.id == 1)
        #expect(ListFilter.filterSearchResults(entries, query: "caf\u{E9}", mode: .contains).map(\.id) == [1, 2])
        // Stored names are not changed.
        #expect(
            ListFilter.filterByName(entries, query: "caf\u{E9}", mode: .contains).first?.name.unicodeScalars.count == 9)
    }

    @Test func aPlainLetterFindsItsAccentedFormsButNotTheOtherWayRound() {
        let names = [
            "Cafe\u{301}.txt", "R\u{E9}sum\u{E9}.pdf", "resume.txt", "Zo\u{EB}.png", "Sm\u{F8}rrebr\u{F8}d", "Istanbul",
        ]
        let entries = names.enumerated().map { Entry(id: $0.offset, name: $0.element, relativeParentPath: "") }
        func found(_ query: String) -> [Int] {
            ListFilter.filterByName(entries, query: query, mode: .contains).map(\.id)
        }
        // Plain letters find the letter with or without its accent, however the name stores it.
        #expect(found("cafe") == [0])
        #expect(found("resume") == [1, 2])
        #expect(found("RESUME") == [1, 2])
        #expect(found("zoe") == [3])
        // A letter typed with its accent finds only itself.
        #expect(found("r\u{E9}sum\u{E9}") == [1])
        #expect(found("zo\u{EB}") == [3])
        // A letter that is not an accent on another stays its own: "o" doesn't find "ø", nor "ı" "i".
        #expect(found("smorrebrod") == [])
        #expect(found("sm\u{F8}rrebr\u{F8}d") == [4])
        #expect(found("\u{131}stanbul") == [])
        #expect(found("istanbul") == [5])
    }

    @Test func returnsTheSameListWhenThereIsNoFilter() {
        #expect(ListFilter.filterByName(entries, query: "", mode: .contains) == entries)
        #expect(ListFilter.filterByName(entries, query: "", mode: .fuzzy) == entries)
    }

    @Test func selectsTheFirstNameStartingWithTheText() {
        // "Android" contains "d" and comes first, but "Documents" starts with it.
        func selected(_ query: String, _ mode: NameMatchMode) -> String? {
            ListFilter.selection(
                in: ListFilter.filterByName(entries, query: query, mode: mode), query: query, mode: mode)?
                .name
        }
        #expect(selected("d", .contains) == "Documents")
        #expect(selected("d", .fuzzy) == "Documents")
        // No name starts with it: the first match.
        #expect(selected("oc", .contains) == "Documents")
        #expect(selected("oc", .fuzzy) == "Documents")
        #expect(ListFilter.selection(in: [Entry](), query: "zzz", mode: .fuzzy) == nil)
        #expect(ListFilter.selection(in: entries, query: "", mode: .fuzzy) == nil)
    }

    @Test func selectsTheNameTheLettersFitBestWhenNoneContainsThem() {
        let names = ["a-very-long-name-with-f-t-s.txt", "FileTrailSettings.swift", "fortunes.txt"]
        let entries = names.enumerated().map { Entry(id: $0.offset, name: $0.element, relativeParentPath: "") }
        // None contains "fts"; the letters start words in FileTrailSettings.
        #expect(ListFilter.selection(in: entries, query: "fts", mode: .fuzzy)?.id == 1)
        // A name that contains the text still comes before one the letters fit well.
        let withRun = entries + [Entry(id: 3, name: "gifts.txt", relativeParentPath: "")]
        #expect(ListFilter.selection(in: withRun, query: "fts", mode: .fuzzy)?.id == 3)
    }

    @Test func filtersSearchResultsByNameOrByTheFolderTheyAreIn() {
        let results = [
            Entry(id: 0, name: "App.tsx", relativeParentPath: "src/components"),
            Entry(id: 1, name: "App.test.tsx", relativeParentPath: "tests"),
            Entry(id: 2, name: "src-notes.md", relativeParentPath: "docs"),
        ]
        func found(_ query: String, _ mode: NameMatchMode = .contains) -> [String] {
            ListFilter.filterSearchResults(results, query: query, mode: mode).map(\.name)
        }
        #expect(found("app") == ["App.tsx", "App.test.tsx"])
        // "src" is a folder of one result and part of the name of another.
        #expect(found("SRC") == ["App.tsx", "src-notes.md"])
        #expect(found("tests") == ["App.test.tsx"])
        #expect(found("zzz") == [])
        #expect(ListFilter.filterSearchResults(results, query: "", mode: .fuzzy) == results)
        // Fuzzy goes for the name; the folder is still matched as a run of letters, so "scmp" finds no folder.
        #expect(found("atx", .fuzzy) == ["App.tsx", "App.test.tsx"])
        #expect(found("scmp", .fuzzy) == [])
        #expect(found("src/comp", .fuzzy) == ["App.tsx"])
    }

    @Test func countsTheItemsMentioningTheTotalOnlyWhileSomeAreHidden() {
        #expect(ListFilter.formatItemCount(shown: 240, total: 240) == "240 items")
        #expect(ListFilter.formatItemCount(shown: 1, total: 1) == "1 item")
        #expect(ListFilter.formatItemCount(shown: 3, total: 240) == "3 of 240 items")
        #expect(ListFilter.formatItemCount(shown: 0, total: 1) == "0 of 1 item")
    }

    @Test func listFilterMatchesTheGoldenFile() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "list-filter")
        #expect(cases.count >= 200)
        Golden.expectMatches(cases) { input in
            let byName = ListFilter.filterByName(input.entries, query: input.query, mode: .contains)
            return Output(
                byName: byName.map(\.id),
                bySearch: ListFilter.filterSearchResults(input.entries, query: input.query, mode: .contains).map(\.id),
                selection: ListFilter.selection(in: byName, query: input.query, mode: .contains)?.id,
                count: ListFilter.formatItemCount(shown: input.shown, total: input.total))
        }
    }

    // MARK: Typeahead

    @Test func detectsPrintableCharacterKeys() {
        #expect(Typeahead.isCharacterKey("a"))
        #expect(!Typeahead.isCharacterKey(" "))
        #expect(!Typeahead.isCharacterKey("ArrowDown"))
        #expect(!Typeahead.isCharacterKey(""))
        // A key whose text is one UTF-16 unit types a character; an emoji, a surrogate pair of two units, does not.
        #expect(Typeahead.isCharacterKey("é"))
        #expect(!Typeahead.isCharacterKey("🎉"))
    }

    // MARK: Search refinement

    struct Item: SearchRefinementItem, Equatable {
        let path: String
        var name: String { String(path[(path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex)...]) }
    }

    private let readmeUpper = Item(path: "/Users/demo/Project/README.md")
    private let readmeLower = Item(path: "/Users/demo/docs/readme.txt")
    private let notes = Item(path: "/Users/demo/docs/notes.txt")

    @Test func matchesPlainTextAsTheSearchJudgesIt() {
        func matches(_ item: Item, _ query: String) -> Bool {
            SearchRefinement.matchesTextQuery(item, query: query, scope: .name)
        }
        #expect(matches(readmeUpper, "readme"))
        #expect(matches(readmeLower, "readme"))
        #expect(matches(readmeUpper, "README"))
        // Case aside, always.
        #expect(matches(readmeLower, "README"))
        // A plain letter finds an accented one.
        #expect(matches(Item(path: "/x/R\u{E9}sum\u{E9}.pdf"), "resume"))
        #expect(!matches(Item(path: "/x/resume.pdf"), "r\u{E9}sum\u{E9}"))
        #expect(!matches(notes, "readme"))
        // Nothing is a pattern.
        #expect(matches(Item(path: "/x/report (1).pdf"), "(1).p"))
        #expect(!matches(Item(path: "/x/abc"), "a.c"))
    }

    @Test func looksAtTheWholePathWhenTheSearchMatchesTheFullPath() {
        #expect(!SearchRefinement.matchesTextQuery(notes, query: "docs", scope: .name))
        #expect(SearchRefinement.matchesTextQuery(notes, query: "docs", scope: .path))
        #expect(SearchRefinement.matchesTextQuery(readmeUpper, query: "project", scope: .path))
        #expect(SearchRefinement.matchesTextQuery(readmeUpper, query: "Docs", scope: .path) == false)
        #expect(SearchRefinement.matchesTextQuery(notes, query: "DOCS", scope: .path))
    }

    @Test func knowsWhenLongerTextCanOnlyFindASubset() {
        #expect(SearchRefinement.isNarrower(base: "re", next: "readme"))
        #expect(SearchRefinement.isNarrower(base: "re", next: "more"))
        #expect(SearchRefinement.isNarrower(base: "re", next: "re"))
        // Case doesn't count.
        #expect(SearchRefinement.isNarrower(base: "re", next: "REadme"))
        #expect(SearchRefinement.isNarrower(base: "Re", next: "readme"))
        // An accent added narrows; one taken away widens.
        #expect(SearchRefinement.isNarrower(base: "re", next: "r\u{E9}sum\u{E9}"))
        #expect(!SearchRefinement.isNarrower(base: "r\u{E9}", next: "resume"))
        #expect(!SearchRefinement.isNarrower(base: "re", next: "r"))
        #expect(!SearchRefinement.isNarrower(base: "re", next: "notes"))
        #expect(!SearchRefinement.isNarrower(base: "", next: "anything"))
    }

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

    // The byte-wise path for ASCII names and text gives what folding each name into letters gives.
    @Test func theAsciiFastPathAgreesWithTheFoldedLetters() {
        let names = [
            "IMG_1 Holiday.JPG", "readme", "README.md", "Ünïcode Name", "İstanbul", "KELVIN K", "Σίσυφος", "日本語.txt",
            "a", "", "ab", "Zebra", "Cafe\u{301}",
        ]
        for mode in NameMatchMode.allCases {
            for query in ["i", "img_1", "READ", "k", "K", "ü", "ι", "日", "z", "zz", "a", "AB", "istanbul", "ς", "cafe"]
            {
                guard let matcher = NameMatcher(query, mode: mode) else { continue }
                for name in names {
                    #expect(
                        matcher.matches(name) == matcher.matches(FoldedText(name).letters), "\(mode) \(query) \(name)")
                }
            }
        }
    }

    // A keystroke in a folder of tens of thousands of items is filtered within a few hundred milliseconds.
    @Test func filtersFiftyThousandNamesWithinAFewHundredMillisecondsEvenUnoptimized() {
        let items = (0..<50_000).map { Entry(id: $0, name: "IMG_\($0) holiday photo copy.jpg", relativeParentPath: "") }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (_, seconds) = CPUTime.measureThread {
            for mode in NameMatchMode.allCases {
                let matches = ListFilter.filterByName(items, query: "img_4", mode: mode)
                _ = ListFilter.selection(in: matches, query: "img_4", mode: mode)
            }
        }
        #expect(seconds < 0.4)
    }
}
