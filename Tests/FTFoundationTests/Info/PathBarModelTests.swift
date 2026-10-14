// Covers F-742..F-746, F-805 and F-819 (the path bar's logic: B-INFO-102..130); ports the path bar part of ContentPane.tsx
import Foundation
import Testing

@testable import FTFoundation

@Suite("path bar")
struct PathBarModelTests {
    /// A measure that gives every label 8 per character and 12 of padding, like the fallback of the original.
    static func measure(_ label: String, _ isActive: Bool, _ collapsed: Bool, _ uncapped: Bool) -> Double { Double(label.count) * 8 + 12 }

    @Test func rootIsMacintoshHD() {
        #expect(PathBarModel.segments("/") == [PathbarSegment(label: "Macintosh HD", path: "/")])
        #expect(PathBarModel.segments("").first?.label == "No folder selected")
    }

    @Test func aPathStartsAtItsVolume() {
        let segments = PathBarModel.segments("/Volumes/Photos/2026/Trip")
        #expect(segments.map(\.label) == ["Photos", "2026", "Trip"])
        #expect(segments.map(\.path) == ["/Volumes/Photos", "/Volumes/Photos/2026", "/Volumes/Photos/2026/Trip"])
        let home = PathBarModel.segments("/Users/demo")
        #expect(home.map(\.label) == ["Macintosh HD", "Users", "demo"])
    }

    @Test func parentAndLabel() {
        #expect(PathBarModel.parentPath("/Users") == "/")
        #expect(PathBarModel.parentPath("/Users/demo") == "/Users")
        #expect(PathBarModel.label("/") == "Macintosh HD")
        #expect(PathBarModel.label("/Users/demo") == "demo")
    }

    @Test func fourSegmentsOrFewerAlwaysShow() {
        let segments = PathBarModel.segments("/a/b/c")
        let items = PathBarModel.visibleItems(segments, availableWidth: 10, expanded: false, measure: Self.measure)
        #expect(items.count == 4)
    }

    @Test func middleSegmentsCollapseBehindTheEllipsisKeepingTheRootAndTheTail() {
        let segments = PathBarModel.segments("/aaaa/bbbb/cccc/dddd/eeee")
        // Roomy enough for the root, the "…" and a tail of two.
        let items = PathBarModel.visibleItems(segments, availableWidth: 330, expanded: false, measure: Self.measure)
        guard case .segment(let first, false, _) = items.first else { Issue.record("no root"); return }
        #expect(first.label == "Macintosh HD")
        #expect(items.contains { if case .collapsed = $0 { true } else { false } })
        guard case .segment(let last, true, _) = items.last else { Issue.record("no active"); return }
        #expect(last.label == "eeee")
        // Too narrow for the root: it is dropped, and the "…" comes first.
        let narrow = PathBarModel.visibleItems(segments, availableWidth: 200, expanded: false, measure: Self.measure)
        #expect(narrow.first == .collapsed(hiddenCount: 4))
    }

    @Test func theLastResortIsTheEllipsisAndTheCurrentFolder() {
        let segments = PathBarModel.segments("/aaaa/bbbb/cccc/dddd/eeee")
        let items = PathBarModel.visibleItems(segments, availableWidth: 8, expanded: false, measure: Self.measure)
        #expect(items.count == 2)
        #expect(items.first == .collapsed(hiddenCount: 5))
    }

    @Test func expandedShowsEverything() {
        let segments = PathBarModel.segments("/aaaa/bbbb/cccc/dddd/eeee")
        #expect(PathBarModel.visibleItems(segments, availableWidth: 100, expanded: true, measure: Self.measure).count == 6)
    }

    @Test func roomLeftOverGoesBackToCutNames() {
        let measure: PathBarModel.Measure = { label, _, _, uncapped in
            let natural = Double(label.count) * 8 + 12
            return uncapped ? natural : min(natural, 100)
        }
        let segments = [PathbarSegment(label: "x", path: "/x"), PathbarSegment(label: String(repeating: "n", count: 30), path: "/x/n")]
        let items = PathBarModel.resolve(segments, availableWidth: 400, expanded: false, measure: measure)
        guard case .segment(_, true, let width?) = items.last else { Issue.record("not widened"); return }
        #expect(width > 100 && width <= 252)
    }

    @Test func hiddenFoldersLabel() {
        #expect(PathBarModel.showHiddenLabel(1) == "Show 1 More Folder")
        #expect(PathBarModel.showHiddenLabel(3) == "Show 3 More Folders")
    }

    @Test func statusKeepsAtLeastAShareForThePath() {
        // Room for both.
        let roomy = PathBarModel.rowLayout(contentWidth: 800, statusWidth: 100)
        #expect(roomy.path == 680 && roomy.status == 100)
        // Too narrow: the path keeps 45% and the status gives way.
        let tight = PathBarModel.rowLayout(contentWidth: 400, statusWidth: 300)
        #expect(tight.path == 180)
        #expect(tight.status == 200)
        #expect(PathBarModel.rowLayout(contentWidth: 400, statusWidth: nil).path == 400)
    }

    // MARK: Folder menu (B-INFO-122..129)

    // T-ca1e9d7a F-805 B-INFO-129
    @Test func menuListsAtMost300FoldersCenteredOnTheTickedOne() {
        let folders = (0..<1000).map { PathbarFolder(path: "/f/\($0)", name: "\($0)") }
        let limited = PathbarFolderMenuModel.limit(folders, activePath: "/f/500")
        #expect(limited.shown.count == 300)
        #expect(limited.shown.first?.path == "/f/350")
        #expect(limited.hiddenBefore == 350 && limited.hiddenAfter == 350)
        let start = PathbarFolderMenuModel.limit(folders, activePath: "/f/3")
        #expect(start.hiddenBefore == 0 && start.hiddenAfter == 700)
        let end = PathbarFolderMenuModel.limit(folders, activePath: "/f/999")
        #expect(end.hiddenBefore == 700 && end.hiddenAfter == 0)
        #expect(PathbarFolderMenuModel.limit(Array(folders.prefix(300)), activePath: "/f/1").hiddenAfter == 0)
        #expect(PathbarFolderMenuModel.hiddenLabel(1) == "1 more folder")
        #expect(PathbarFolderMenuModel.hiddenLabel(5) == "5 more folders")
    }

    // T-d2b67f2e F-805 B-INFO-125
    @Test func aLetterJumpsToTheNextFolderStartingWithItAndWraps() {
        let folders = ["alpha", "beta", "Alps", "gamma"].map { PathbarFolder(path: "/\($0)", name: $0) }
        #expect(PathbarFolderMenuModel.jump(letter: "a", from: 0, in: folders) == 2)
        #expect(PathbarFolderMenuModel.jump(letter: "a", from: 2, in: folders) == 0)
        #expect(PathbarFolderMenuModel.jump(letter: "z", from: 0, in: folders) == nil)
    }

    // MARK: Path editor (B-INFO-113..116)

    @Test func arrowsPreviewSuggestionsWithWrap() {
        var state = PathSuggestionState(draft: "/Us")
        state.receive([PathSuggestionRow(path: "/Users", name: "Users"), PathSuggestionRow(path: "/Usr", name: "Usr")])
        #expect(state.nextIndex(down: true) == 0)
        #expect(state.nextIndex(down: false) == 1)
        state.previewSuggestion(0)
        #expect(state.displayed == "/Users/")
        #expect(state.previewSelection == NSRange(location: 3, length: 4))
        #expect(state.nextIndex(down: false) == 1)
        state.previewSuggestion(1)
        #expect(state.nextIndex(down: true) == 0)
    }

    @Test func returnGoesToTheHighlightedSuggestionElseTheTrimmedText() {
        var state = PathSuggestionState(draft: "  /Users/demo  ")
        #expect(state.submission == "/Users/demo")
        state.receive([PathSuggestionRow(path: "/Users/demo/Docs", name: "Docs")])
        state.previewSuggestion(0)
        #expect(state.submission == "/Users/demo/Docs")
        state.setDraft("   ")
        #expect(state.submission == nil)
    }

    @Test func acceptingASuggestionFillsItWithATrailingSlash() {
        var state = PathSuggestionState(draft: "/Us")
        let row = PathSuggestionRow(path: "/Users", name: "Users")
        state.receive([row])
        state.accept(row)
        #expect(state.draft == "/Users/")
        #expect(state.suggestions.isEmpty && state.highlighted == -1 && state.preview == nil)
    }

    @Test func homeShortcutIsExpanded() {
        #expect(PathText2.expandHome("~", homePath: "/Users/demo") == "/Users/demo")
        #expect(PathText2.expandHome("~/Docs", homePath: "/Users/demo") == "/Users/demo/Docs")
        #expect(PathText2.expandHome("~x", homePath: "/Users/demo") == "~x")
        #expect(PathText2.expandHome("~/Docs", homePath: "") == "~/Docs")
    }
}
