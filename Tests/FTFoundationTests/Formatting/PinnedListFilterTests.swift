// A pinned filter keeps every folder and the files it matches; typing then selects names instead of filtering
import Testing

@testable import FTFoundation

struct PinnedListFilterTests {
    struct Entry: ListFilterEntry, Equatable {
        var name: String
        var isFolder = false
    }

    private let entries = [
        Entry(name: "Projects", isFolder: true), Entry(name: "Screenshot 10.02.png"),
        Entry(name: "Taxes", isFolder: true),
        Entry(name: "Q3 report.pdf"), Entry(name: "screen notes.md"), Entry(name: "Évaluation.pdf"),
    ]

    private func kept(_ pin: PinnedListFilter?) -> [String] {
        ListFilter.filterPinned(entries, pin: pin, isFolder: \.isFolder).map(\.name)
    }

    @Test func keepsEveryFolderAndTheFilesThatMatch() {
        #expect(
            kept(PinnedListFilter(query: "scr", mode: .fuzzy)) == [
                "Projects", "Screenshot 10.02.png", "Taxes", "screen notes.md",
            ])
        #expect(
            kept(PinnedListFilter(query: ".pdf", mode: .contains)) == [
                "Projects", "Taxes", "Q3 report.pdf", "Évaluation.pdf",
            ])
    }

    @Test func matchesInTheModeItWasPinnedWith() {
        // "srt" has its letters in order in "Screenshot", not side by side.
        #expect(kept(PinnedListFilter(query: "srt", mode: .fuzzy)).contains("Screenshot 10.02.png"))
        #expect(kept(PinnedListFilter(query: "srt", mode: .contains)) == ["Projects", "Taxes"])
    }

    @Test func noPinKeepsEverything() {
        #expect(kept(nil) == entries.map(\.name))
        #expect(kept(PinnedListFilter(query: "", mode: .fuzzy)) == entries.map(\.name))
    }
}

struct ListTypeToSelectTests {
    private let names = ["Projects", "Q3 report.pdf", "Screenshot 09.12.png", "Screenshot 10.02.png", "Évaluation.pdf"]
        .map { PinnedListFilterTests.Entry(name: $0) }

    @Test func lettersTypedTogetherPickTheFirstNameThatStartsWithThem() {
        var typed = ListTypeToSelect()
        #expect(typed.type("s", at: 0) == "s")
        #expect(typed.type("c", at: 0.3) == "sc")
        #expect(ListTypeToSelect.match(in: names, query: "sc")?.name == "Screenshot 09.12.png")
        #expect(ListTypeToSelect.match(in: names, query: "Screenshot 1")?.name == "Screenshot 10.02.png")
        // A name is found by its start only.
        #expect(ListTypeToSelect.match(in: names, query: "report") == nil)
    }

    @Test func aPauseStartsOver() {
        var typed = ListTypeToSelect()
        _ = typed.type("s", at: 0)
        #expect(typed.type("q", at: 0.99) == "sq")
        #expect(typed.type("q", at: 2) == "q")
        #expect(ListTypeToSelect.match(in: names, query: "q")?.name == "Q3 report.pdf")
    }

    @Test func escLetsGoOfTheLetters() {
        var typed = ListTypeToSelect()
        _ = typed.type("p", at: 0)
        typed.clear()
        #expect(typed.query.isEmpty)
        #expect(typed.type("q", at: 0.1) == "q")
    }

    @Test func aPlainLetterFindsTheAccentedOne() {
        #expect(ListTypeToSelect.match(in: names, query: "eval")?.name == "Évaluation.pdf")
    }
}
