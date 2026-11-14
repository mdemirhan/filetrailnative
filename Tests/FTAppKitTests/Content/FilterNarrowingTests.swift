// A filter that grows a letter at a time narrows what it kept, and finds what filtering afresh would
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Testing

@testable import FTAppKit

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

    // One keystroke over 50,000 search results, by name or by folder, the names beyond ASCII folded once.
    @Test func filtersFiftyThousandResultsWithinAFewHundredMillisecondsEvenUnoptimized() {
        struct Result: ListFilterSearchResult {
            var name: String
            var relativeParentPath: String
        }
        let results = (0..<50_000).map {
            Result(
                name: $0 % 10 == 0 ? "Résumé \($0).pdf" : "IMG_\($0) holiday photo copy.jpg",
                relativeParentPath: "Photos/2026/Trip \($0 % 40)/Day \($0 % 7)")
        }
        let cache = FoldedNameCache()
        _ = ListFilter.filterSearchResults(results, query: "r", mode: .fuzzy, cache: cache)
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (_, seconds) = CPUTime.measureThread {
            let matches = ListFilter.filterSearchResults(results, query: "rsm", mode: .fuzzy, cache: cache)
            _ = ListFilter.selection(in: matches, query: "rsm", mode: .fuzzy)
        }
        #expect(seconds < 0.4)
    }

    // Choosing what a keystroke selects among 150,000 matches when no name starts with the text or holds it as a run,
    // so every name is weighed for how well its letters fit: all plain names, then every other one beyond ASCII.
    // Folding each name again and a table asked for per name took several seconds of an unoptimized build.
    @Test(arguments: [0, 2])
    func picksTheBestFitAmongAHundredAndFiftyThousandMatchesEvenUnoptimized(_ beyondASCIIEvery: Int) {
        struct Entry: ListFilterEntry {
            var name: String
        }
        let entries = (0..<150_000).map {
            Entry(
                name: beyondASCIIEvery > 0 && $0 % beyondASCIIEvery == 0
                    ? "Été \($0) holiday photo copié.jpg" : "IMG_\($0) holiday photo copy.jpg")
        }
        let cache = FoldedNameCache()
        let matches = ListFilter.filterByName(entries, query: "hpc", mode: .fuzzy, cache: cache)
        #expect(matches.count == entries.count)
        let (picked, seconds) = CPUTime.measureThread {
            ListFilter.selection(in: matches, query: "hpc", mode: .fuzzy, cache: cache)
        }
        #expect(picked?.name == entries[0].name)
        #expect(seconds < 2.5)
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
