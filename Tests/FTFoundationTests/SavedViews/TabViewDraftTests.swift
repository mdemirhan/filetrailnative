// Checks Tab View Options' draft: what it starts with for a new tab view and for one edited, what each choice keeps,
// and Reset
import Foundation
import Testing

@testable import FTFoundation

struct TabViewDraftTests {
    static func tab(_ folders: [String], active: Int = 0, split: Double = 0.5) -> TabState {
        TabState(panes: folders.map { TabViewsTests.pane($0) }, active: active, split: split)
    }

    @Test func aNewTabViewKeepsThePanesAndEachPanesViewToBeginWith() {
        let draft = TabViewDraft(tab: Self.tab(["/a", "/b"]), columnWidth: 1009)
        #expect(
            draft.keeps
                == TabViewKeeps(
                    panes: 2, left: PaneKeeps(view: FolderViewKeeps(view: .icons)),
                    right: PaneKeeps(view: FolderViewKeeps(view: .icons))))
        #expect(draft.paneGroups == [.left, .right])
        // Each folder row offers the folders shown now, by pane.
        #expect(draft.foldersNow.map(\.path) == ["/a", "/b"])
        #expect(draft.foldersNow.map(\.pane) == ["the Left Pane Now", "the Right Pane Now"])
    }

    @Test func aValueChosenIsKeptAndAKeepUncheckedIsNot() {
        var draft = TabViewDraft(tab: Self.tab(["/a"]), columnWidth: 1009)
        draft[.onePane].set(.sort) { $0.sort = FolderViewSort(by: .size, direction: .desc) }
        draft[.onePane].keep(.view, false)
        #expect(draft.keeps.pane?.view == FolderViewKeeps(sort: FolderViewSort(by: .size, direction: .desc)))
        draft[.onePane].folder = "/x"
        #expect(draft.keeps.pane?.folder == nil)
        draft[.onePane].keepsFolder = true
        #expect(draft.keeps.pane?.folder == "/x")
    }

    @Test func eachDividerChoiceKeepsWhatItSays() {
        var draft = TabViewDraft(tab: Self.tab(["/a", "/b"], split: 0.62), columnWidth: 1009)
        draft.keepsDivider = true
        #expect(draft.keeps.divider == .share(0.62))
        draft.divider = .widthNow
        #expect(draft.keeps.divider == .leftWidth(620))
        draft.divider = .even
        #expect(draft.keeps.divider == .even)
        draft.divider = .custom
        draft.customShare = 0.05
        // Held within what a drag of the divider allows.
        #expect(draft.keeps.divider == .share(PaneSplit.minimum))
        // No divider without two panes kept.
        draft.panes = 1
        #expect(draft.keeps.divider == nil)
    }

    @Test func panesNotKeptGiveTheActivePanesRows() {
        var draft = TabViewDraft(tab: Self.tab(["/a", "/b"], active: 1), columnWidth: 1009)
        draft.keepsPanes = false
        #expect(draft.paneGroups == [.activePane])
        #expect(draft.keeps.panes == nil && draft.keeps.left == nil && draft.keeps.pane != nil)
    }

    @Test func editingShowsWhatIsSavedOverWhatTheTabShows() {
        let saved = TabView(
            id: "t", name: "Saved",
            keeps: TabViewKeeps(
                panes: 2, divider: .leftWidth(400),
                left: PaneKeeps(folder: "/saved", view: FolderViewKeeps(view: .details), folderViews: .notUsed)))
        let draft = TabViewDraft(tab: Self.tab(["/a"]), columnWidth: 1009, editing: saved)
        #expect(draft.name == "Saved" && draft.editingID == "t")
        #expect(draft.divider == .saved && draft.savedDivider == .leftWidth(400))
        #expect(draft.left.folder == "/saved" && draft.left.keepsFolder)
        #expect(draft.left.values.view == .details && draft.left.kept == [.view])
        #expect(draft.left.folderViews == .notUsed)
        // What isn't kept shows the tab's.
        #expect(draft.right.kept.isEmpty && draft.right.values.view == .icons)
        // Saved again unchanged, it keeps what it kept.
        #expect(draft.keeps == saved.keeps)
    }

    @Test func resetKeepsNothing() {
        var draft = TabViewDraft(tab: Self.tab(["/a", "/b"]), columnWidth: 1009)
        draft.keepsHidden = true
        draft.left.folderViews = .tabViewFirst
        draft.reset()
        #expect(draft.keeps.isEmpty)
    }

    @Test func whatAKeepsSaysOfItself() {
        let keeps = TabViewKeeps(
            panes: 2, divider: .share(0.62),
            left: PaneKeeps(folder: "/u/Downloads", view: FolderViewKeeps(view: .details), folderViews: .tabViewFirst),
            right: PaneKeeps(view: FolderViewKeeps(foldersFirst: false)))
        #expect(
            SavedViewText.parts(keeps) == [
                "Two panes", "Divider 62% / 38%", "Left: opens \u{201C}Downloads\u{201D}", "Left: List",
                "Left: over folder views", "Right: folders mixed in",
            ])
        #expect(
            SavedViewText.parts(TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .previews))))
                == ["Active pane: Previews", "Folders from the tab"])
    }
}
