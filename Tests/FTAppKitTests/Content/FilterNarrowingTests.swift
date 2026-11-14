// A filter that grows a letter at a time narrows what it kept, and finds what filtering afresh would
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Testing

@testable import FTAppKit

/// The filter's speed over large lists is guarded in `ListFilterTests`, off the main actor: run here, the guards held
/// the main thread every suite of this bundle shares for seconds at a time.
@MainActor
struct FilterNarrowingTests {
    private static let names =
        (0..<300).map { String(format: "item-%03d.txt", $0) } + [
            "Re\u{301}sume\u{301}.pdf", "résumé copy.pdf", "report.txt", "Readme.md",
        ]

    private func pane(_ names: [String] = Self.names) -> ContentPaneController {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_003), loaders: .placeholder)
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        return content
    }

    private func afresh(_ content: ContentPaneController) -> [String] {
        ListFilter.filterByName(content.listed, query: content.filter, mode: content.filterMode).map(\.name)
    }

    @Test(arguments: NameMatchMode.allCases)
    func typingALetterAtATimeFindsWhatFilteringAfreshFinds(_ mode: NameMatchMode) {
        let content = pane()
        content.setDefaultFilterMode(mode)
        for letter in "re" + "sume" {
            content.applyFilterKey(.type(String(letter)))
            #expect(content.entries.map(\.name) == afresh(content), "\(content.filter)")
        }
        // Backspace widens again.
        content.applyFilterKey(.erase)
        content.applyFilterKey(.erase)
        #expect(content.entries.map(\.name) == afresh(content))
        #expect(content.entries.contains { $0.name == "résumé copy.pdf" })
    }

    // A mark typed after a letter makes another letter of it ("ạ" and a circumflex are "ậ"), and a vowel after a jamo
    // a syllable: names the shorter text didn't keep are found.
    @Test(arguments: NameMatchMode.allCases)
    func aKeyThatChangesTheLetterBeforeItFiltersWhole(_ mode: NameMatchMode) {
        let content = pane(["\u{1EAD}m.txt", "\u{1EA1}m.txt", "\u{AC00}.txt", "\u{1100}.txt"])
        content.setDefaultFilterMode(mode)
        content.applyFilterKey(.type("\u{1EA1}"))
        #expect(content.entries.map(\.name) == ["\u{1EA1}m.txt"])
        content.applyFilterKey(.type("\u{302}"))
        #expect(content.entries.map(\.name) == ["\u{1EAD}m.txt"])
        content.applyFilterKey(.clear)
        content.applyFilterKey(.type("\u{1100}"))
        #expect(content.entries.map(\.name) == ["\u{1100}.txt"])
        content.applyFilterKey(.type("\u{1161}"))
        #expect(content.filter == "\u{1100}\u{1161}")
        #expect(content.entries.map(\.name) == ["\u{AC00}.txt"])
    }

    @Test func aFolderReadAgainWhileTypingIsFilteredWhole() {
        let content = pane()
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("e"))
        // A name the shorter text didn't keep, because it wasn't there yet.
        let entries = (Self.names + ["re-added.txt"]).map { ContentModelTests.entry($0) }
        content.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: true)
        content.applyFilterKey(.type("a"))
        #expect(content.entries.map(\.name) == afresh(content))
        #expect(content.entries.contains { $0.name == "re-added.txt" })
    }

    @Test func anotherModeFiltersWhole() {
        let content = pane()
        content.setDefaultFilterMode(.contains)
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("m"))
        #expect(content.entries.isEmpty)
        #expect(content.toggleFilterMode() == .fuzzy)
        #expect(content.entries.map(\.name) == afresh(content))
        #expect(!content.entries.isEmpty)
    }

    // A filter keeps the mode it started with: the default changed meanwhile (Settings, another window's chip) is for
    // the filters to come. Cleared, the next one starts from the default.
    @Test func aFilterKeepsItsModeWhenTheDefaultChanges() {
        let content = pane()
        content.setDefaultFilterMode(.fuzzy)
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("m"))
        let found = content.entries.map(\.name)
        #expect(!found.isEmpty)
        content.setDefaultFilterMode(.contains)
        #expect(content.filterMode == .fuzzy)
        #expect(content.entries.map(\.name) == found)
        content.applyFilterKey(.clear)
        #expect(content.filterMode == .contains)
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("m"))
        #expect(content.entries.isEmpty)
    }

    // The names the filter folded are for the list on screen: they go with the folder or the search results, and no
    // more are kept than the list could need.
    @Test func theNamesAFilterFoldedGoWithTheListTheyWereFor() {
        let names = (0..<3_000).map { "R\u{E9}sum\u{E9} \($0).pdf" }
        let content = pane(names)
        #expect(content.foldedNames.limit == 6_000)
        content.applyFilterKey(.type("r"))
        #expect(content.foldedNames.count == names.count)
        // Read again as it was, the folder keeps them.
        content.show(
            folder: "/f", entries: names.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: true)
        #expect(content.foldedNames.count == names.count)
        content.show(
            folder: "/g", entries: ["Caf\u{E9}.txt"].map { ContentModelTests.entry($0) }, selecting: nil,
            keepingScroll: false)
        #expect(content.foldedNames.count == 0)
        #expect(content.foldedNames.limit == 1_000)
        content.applyFilterKey(.type("c"))
        #expect(content.foldedNames.count == 1)
        content.showSearch(results(["R\u{E9}sum\u{E9}.pdf"]))
        #expect(content.foldedNames.count == 0)
        content.setSearchFilter("r")
        #expect(content.foldedNames.count > 0)
        content.endSearch()
        #expect(content.foldedNames.count == 0)
    }

    // The same name stored composed in one folder and decomposed in another: each is marked on its own units, by the
    // filter and by the search, whichever is asked for first.
    @Test(arguments: [false, true])
    func twoSpellingsOfOneNameAreEachMarkedAsStored(_ decomposedFirst: Bool) throws {
        let composed = "\u{E9}mile.txt"
        let decomposed = "e\u{301}mile.txt"
        let content = pane()
        let highlight = HighlightPattern(names: try #require(NameMatcher("mile", mode: .contains)))
        content.showSearch(
            ContentSearchDisplay(
                rootPath: "/f", viewKey: "search:/f:mile",
                results: ["a/" + composed, "b/" + decomposed].map {
                    SearchResults.item(rootPath: "/f", outputPath: "/f/" + $0)
                }, sortBy: .name, sortDirection: .asc, highlight: highlight, isRunning: false, error: nil,
                errorIsQuiet: false))
        // By where the name's text starts as stored: a dictionary of the two would take them as one key.
        let names = decomposedFirst ? [decomposed, composed] : [composed, decomposed]
        func shift(_ name: String) -> Int { name.utf16.first == 0x65 ? 1 : 0 }
        for name in names + names {
            let start = 1 + shift(name)
            #expect(
                content.nameMarks(name) == [HighlightRange(start: start, end: start + 4)],
                "search, \(Array(name.unicodeScalars))")
        }
        content.setSearchFilter("mi")
        for name in names + names {
            let start = 1 + shift(name)
            #expect(
                content.nameMarks(name) == [HighlightRange(start: start, end: start + 2)],
                "filter, \(Array(name.unicodeScalars))")
        }
    }

    // MARK: What a narrowing filter kept no longer stands

    // The window reads the folder again for another order, and hands it over in that order.
    @Test func anotherOrderBetweenKeystrokesIsFilteredWholeInThatOrder() {
        let content = pane()
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("e"))
        #expect(content.entries.map(\.name).suffix(2) == ["report.txt", "Readme.md"])
        content.setView(sortBy: .name, direction: .desc, foldersFirst: true, includeHidden: false)
        content.show(
            folder: "/f", entries: Self.names.reversed().map { ContentModelTests.entry($0) }, selecting: nil,
            keepingScroll: false)
        content.applyFilterKey(.type("s"))
        #expect(content.filter == "res")
        #expect(content.entries.map(\.name) == afresh(content))
        #expect(content.entries.map(\.name) == ["résumé copy.pdf", "Re\u{301}sume\u{301}.pdf"])
    }

    @Test func hiddenFilesShownBetweenKeystrokesAreLookedThroughToo() {
        let content = pane()
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("e"))
        #expect(!content.entries.contains { $0.name == ".report-draft" })
        let withHidden = [".report-draft", ".zshrc"] + Self.names
        content.setView(sortBy: .name, direction: .asc, foldersFirst: true, includeHidden: true)
        content.show(
            folder: "/f", entries: withHidden.map { ContentModelTests.entry($0) }, selecting: nil, keepingScroll: false)
        content.applyFilterKey(.type("p"))
        #expect(content.entries.map(\.name) == afresh(content))
        #expect(content.entries.map(\.name).first == ".report-draft")
    }

    private func results(_ names: [String]) -> ContentSearchDisplay {
        ContentSearchDisplay(
            rootPath: "/f", viewKey: "search:/f:r",
            results: names.map { SearchResults.item(rootPath: "/f", outputPath: "/f/" + $0) }, sortBy: .name,
            sortDirection: .asc, highlight: nil, isRunning: true, error: nil, errorIsQuiet: false)
    }

    // A search still running hands over more results between two keystrokes of the results' filter.
    @Test func resultsThatArriveBetweenKeystrokesAreLookedThroughToo() {
        let content = pane()
        content.showSearch(results(["report.txt", "Readme.md", "notes.md"]))
        content.setSearchFilter("r")
        content.setSearchFilter("re")
        #expect(content.entries.map(\.name) == ["report.txt", "Readme.md"])
        content.showSearch(results(["report.txt", "Readme.md", "notes.md", "sub/recipe.txt", "sub/plan.md"]))
        #expect(content.filter == "re")
        content.setSearchFilter("rec")
        #expect(content.entries.map(\.name) == ["sub/recipe.txt"].map { NodePath.basename($0) })
        content.setSearchFilter("re")
        #expect(content.entries.map(\.name) == ["report.txt", "Readme.md", "recipe.txt"])
    }

    // MARK: Whoever changes the filter, the results bar's field and Pin Filter hear of it

    /// The pane with what it tells of its filter written down.
    private func heard(_ content: ContentPaneController) -> (texts: () -> [String], states: () -> Int) {
        final class Log {
            var texts: [String] = []
            var states = 0
        }
        let log = Log()
        content.onFilterChanged = { log.texts.append($0) }
        content.onFilterStateChanged = { log.states += 1 }
        return ({ log.texts }, { log.states })
    }

    @Test func selectingAnItemTheTypedFilterHidesClearsItAndSaysSo() {
        let content = pane()
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("e"))
        let (texts, states) = heard(content)
        content.select(paths: ["/f/item-007.txt"])
        #expect(content.filter.isEmpty)
        #expect(texts() == [""])
        #expect(states() == 1)
        #expect(content.selection.paths == ["/f/item-007.txt"])
        #expect(content.entries.count == Self.names.count)
        // An item on show changes nothing of the filter, and nothing is said.
        content.applyFilterKey(.type("r"))
        let before = (texts().count, states())
        content.select(paths: ["/f/report.txt"])
        #expect(content.filter == "r")
        #expect((texts().count, states()) == before)
    }

    @Test func renamingAnItemTheTypedFilterHidesClearsItAndSaysSo() {
        let content = pane()
        content.applyFilterKey(.type("r"))
        content.applyFilterKey(.type("e"))
        let (texts, states) = heard(content)
        #expect(content.beginRename(path: "/f/item-007.txt"))
        #expect(content.filter.isEmpty)
        #expect(texts() == [""])
        #expect(states() == 1)
        #expect(content.inlineRename?.path == "/f/item-007.txt")
    }

    // Over search results a pinned filter and the results' own can both hide items: showing one takes away only the
    // filter that hides it.
    @Test func showingAnItemDropsThePinOnlyWhenThePinIsWhatHidesIt() {
        let content = pane()
        content.applyFilterKey(.type("m"))
        content.applyFilterKey(.type("d"))
        content.pinFilter()
        #expect(content.pinnedFilter?.query == "md")
        content.showSearch(results(["report.txt", "Readme.md", "notes.md", "plan.md", "sub/"]))
        #expect(content.entries.map(\.name) == ["Readme.md", "notes.md", "plan.md", "sub"])
        content.setSearchFilter("no")
        #expect(content.entries.map(\.name) == ["notes.md"])
        let (texts, _) = heard(content)

        // The results' filter hides it, the pin doesn't: the pin stays.
        content.select(paths: ["/f/plan.md"])
        #expect(content.pinnedFilter?.query == "md")
        #expect(content.filter.isEmpty)
        #expect(texts() == [""])
        #expect(content.entries.map(\.name) == ["Readme.md", "notes.md", "plan.md", "sub"])

        // The pin hides it, the results' filter doesn't: the filter stays.
        content.setSearchFilter("r")
        #expect(content.entries.map(\.name) == ["Readme.md"])
        content.select(paths: ["/f/report.txt"])
        #expect(content.pinnedFilter == nil)
        #expect(content.filter == "r")
        #expect(content.entries.map(\.name) == ["report.txt", "Readme.md"])

        // Both hide it: both go.
        content.setPinnedFilter(PinnedListFilter(query: "md", mode: .fuzzy))
        content.setSearchFilter("no")
        content.select(paths: ["/f/report.txt"])
        #expect(content.pinnedFilter == nil)
        #expect(content.filter.isEmpty)
        #expect(content.selection.paths == ["/f/report.txt"])
    }

    @Test func theStatusCountsWhatAPinnedFilterShows() {
        let content = pane(["report.txt", "Readme.md", "notes.md", "plan.md"])
        let status = content.contentShell.pathBarRow.status
        #expect(status.stringValue.hasPrefix("4 items"))
        content.applyFilterKey(.type("m"))
        content.applyFilterKey(.type("d"))
        content.applySelection(.empty)
        #expect(status.stringValue.hasPrefix("3 of 4 items"))
        content.pinFilter()
        #expect(content.filter.isEmpty)
        #expect(status.stringValue.hasPrefix("3 of 4 items"))
        #expect(content.container.filterPill.isPinned)
        content.removeFilter()
        #expect(status.stringValue.hasPrefix("4 items"))
    }
}
