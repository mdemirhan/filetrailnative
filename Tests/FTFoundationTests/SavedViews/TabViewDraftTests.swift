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

    // A pane showing the viewer now, beside the other's list or in place of its folder, opens it to begin with, its
    // view kept too; any pane opens the viewer, each on its own. Read or Edit and Follow start as the pane's own, and
    // are kept apart.
    @Test func anyPaneOpensTheViewer() {
        var state = Self.tab(["/a", "/b"])
        state.panes[1].viewer = PaneViewer(follows: true, editing: true)
        state.panes[1].viewerDefaults = PaneViewer(follows: false, editing: true)
        var draft = TabViewDraft(tab: state, columnWidth: 1009)
        #expect(draft.keeps.right == PaneKeeps(view: FolderViewKeeps(view: .icons), opensViewer: true))
        #expect(draft.keeps.left == PaneKeeps(view: FolderViewKeeps(view: .icons)))
        #expect(draft.right.viewer == PaneViewer(follows: false, editing: true))
        // Both panes can.
        draft.setOpensViewer(.left, true)
        #expect(draft.left.opensViewer && draft.right.opensViewer)
        #expect(draft.keeps.left == PaneKeeps(view: FolderViewKeeps(view: .icons), opensViewer: true))
        // The view kept or not, the viewer is opened: it is not a view.
        draft[.left].keep(.view, false)
        #expect(draft.keeps.left == PaneKeeps(opensViewer: true))
        draft.setOpensViewer(.left, false)
        #expect(draft.keeps.left == nil)
        // Read or Edit and Follow, each kept on its own.
        draft[.left].viewer.editing = true
        draft[.left].keepsEditing = true
        #expect(draft.keeps.left == PaneKeeps(viewerEditing: true))
        // One pane: a file shown in place opens the viewer to begin with, and it is kept.
        var one = Self.tab(["/a"])
        one.panes[0].viewerInPlace = true
        var single = TabViewDraft(tab: one, columnWidth: 1009)
        #expect(single.keeps.pane == PaneKeeps(view: FolderViewKeeps(view: .icons), opensViewer: true))
        single[.onePane].keepsFollows = true
        single[.onePane].viewer.follows = false
        #expect(
            single.keeps.pane
                == PaneKeeps(view: FolderViewKeeps(view: .icons), opensViewer: true, viewerFollows: false))
        // Edited, a saved viewer shows Opens the Viewer checked, with its Read or Edit; Follow as the pane has it.
        let saved = TabView(
            id: "v", name: "V", keeps: TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerEditing: true)))
        let edited = TabViewDraft(tab: Self.tab(["/a", "/b"]), columnWidth: 1009, editing: saved)
        #expect(edited.right.opensViewer && edited.right.keepsEditing && !edited.right.keepsFollows)
        #expect(edited.right.viewer == PaneViewer(follows: true, editing: true))
    }

    // Each view's size is kept apart: a value chosen keeps that view's alone, at the density it was chosen at.
    @Test func eachViewsSizeIsKeptApart() {
        var draft = TabViewDraft(tab: Self.tab(["/a"]), columnWidth: 1009)
        draft[.onePane].set(.icons, 96, at: .standard)
        let sizes = draft.keeps.pane?.sizes
        #expect(sizes?.kept == [.icons])
        #expect(sizes?.iconSizes?.standard == 96)
        #expect(draft.keeps.pane?.view.size == nil)
        draft[.onePane].keep(.previews, true)
        #expect(draft.keeps.pane?.sizes?.kept == [.icons, .previews])
        draft[.onePane].keep(.icons, false)
        #expect(draft.keeps.pane?.sizes?.kept == [.previews])
        // Edited, each size kept shows checked, with its value; the others as the pane has them.
        let saved = TabView(
            id: "s", name: "S",
            keeps: TabViewKeeps(
                pane: PaneKeeps(sizes: ViewSizesKeeps(compactListWidths: DensitySizes(standard: 400, finder: 360)))))
        let edited = TabViewDraft(tab: Self.tab(["/a"]), columnWidth: 1009, editing: saved)
        #expect(edited.active.sizesKept == [.compactList])
        #expect(edited.active.values.size?.compactListWidths.standard == 400)
        #expect(edited.active.values.size?.iconSizes == TabViewsTests.pane("/a").settings.size?.iconSizes)
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
                left: PaneKeeps(folder: "/saved", view: FolderViewKeeps(view: .details))))
        let draft = TabViewDraft(tab: Self.tab(["/a"]), columnWidth: 1009, editing: saved)
        #expect(draft.name == "Saved" && draft.editingID == "t")
        #expect(draft.divider == .saved && draft.savedDivider == .leftWidth(400))
        #expect(draft.left.folder == "/saved" && draft.left.keepsFolder)
        #expect(draft.left.values.view == .details && draft.left.kept == [.view])
        // What isn't kept shows the tab's.
        #expect(draft.right.kept.isEmpty && draft.right.values.view == .icons)
        // Saved again unchanged, it keeps what it kept.
        #expect(draft.keeps == saved.keeps)
    }

    @Test func resetKeepsNothing() {
        var draft = TabViewDraft(tab: Self.tab(["/a", "/b"]), columnWidth: 1009)
        draft.keepsHidden = true
        draft.left.opensViewer = true
        draft.left.keepsEditing = true
        draft.left.sizesKept = [.icons]
        draft.reset()
        #expect(draft.keeps.isEmpty)
    }

    @Test func whatAKeepsSaysOfItself() {
        let keeps = TabViewKeeps(
            panes: 2, divider: .share(0.62),
            left: PaneKeeps(folder: "/u/Downloads", view: FolderViewKeeps(view: .details)),
            right: PaneKeeps(view: FolderViewKeeps(foldersFirst: false)))
        #expect(
            SavedViewText.parts(keeps) == [
                "Two panes", "Divider 62% / 38%", "Left: opens \u{201C}Downloads\u{201D}", "Left: List",
                "Right: folders mixed in",
            ])
        #expect(
            SavedViewText.parts(TabViewKeeps(pane: PaneKeeps(view: FolderViewKeeps(view: .previews))))
                == ["Active pane: Previews", "Folders from the tab"])
        #expect(
            SavedViewText.parts(TabViewKeeps(panes: 2, right: PaneKeeps(opensViewer: true, viewerEditing: true)))
                == ["Two panes", "Right: viewer", "Right: edit", "Folders from the tab"])
        #expect(
            SavedViewText.parts(
                TabViewKeeps(
                    panes: 2,
                    left: PaneKeeps(
                        view: FolderViewKeeps(view: .icons), opensViewer: true, viewerFollows: false,
                        viewerEditing: false)))
                == [
                    "Two panes", "Left: Icons", "Left: viewer", "Left: viewer stays on its file", "Left: read",
                    "Folders from the tab",
                ])
        let sizes = ViewSizesKeeps(iconSizes: .iconDefaults, previewCounts: .previewCountDefaults)
        #expect(
            SavedViewText.parts(TabViewKeeps(pane: PaneKeeps(sizes: sizes)))
                == ["Active pane: icon size", "Active pane: previews at a time", "Folders from the tab"])
    }

    // The pane groups are called by the pane they set, plainly.
    @Test func eachPaneGroupIsCalledByItsPane() {
        #expect(
            [TabViewDraft.PaneGroup.left, .right, .onePane, .activePane].map(\.title) == [
                "Left Pane", "Right Pane", "The Pane", "The Active Pane",
            ])
    }
}
