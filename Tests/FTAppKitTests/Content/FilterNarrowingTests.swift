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
}
