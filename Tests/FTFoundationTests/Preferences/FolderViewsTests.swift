import Foundation
import Testing

@testable import FTFoundation

struct FolderViewsTests {
    private static let previews = FolderViewKeeps(
        view: .previews, sort: FolderViewSort(by: .modified, direction: .desc), foldersFirst: true)

    private func views() -> FolderViews {
        FolderViews([
            FolderView(path: "/Users/me/Pictures", subfolders: true, keeps: Self.previews),
            FolderView(path: "/Users/me/Pictures/Scans", keeps: FolderViewKeeps(view: .previews)),
            FolderView(path: "/Users/me/Pictures/Work", subfolders: true),
        ])
    }

    @Test func aFolderUsesItsOwnViewOrTheNearestOneAboveThatCoversTheFoldersInside() {
        let views = views()
        #expect(views.use(for: "/Users/me/Pictures")?.own == true)
        let trip = views.use(for: "/Users/me/Pictures/Iceland 2026/Day 1")
        #expect(trip?.own == false)
        #expect(trip?.view.path == "/Users/me/Pictures")
        #expect(views.use(for: "/Users/me/Pictures/Scans")?.view.keeps == FolderViewKeeps(view: .previews))
        // Scans' view doesn't cover its folders, so Receipts uses Pictures'.
        #expect(views.use(for: "/Users/me/Pictures/Scans/Receipts")?.view.path == "/Users/me/Pictures")
        // Work's view keeps nothing and covers its folders: its branch stops using Pictures'.
        let client = views.use(for: "/Users/me/Pictures/Work/Client A")
        #expect(client?.view.path == "/Users/me/Pictures/Work")
        #expect(client?.view.keeps.isEmpty == true)
        #expect(views.use(for: "/Users/me/Downloads") == nil)
        #expect(views.use(for: "/Users/me/PicturesOld") == nil)
    }

    @Test func aViewKeptForAnotherDiskAtTheSamePathIsNotThisFolders() {
        let views = FolderViews([FolderView(path: "/Volumes/Photos", volume: "A", keeps: Self.previews)])
        #expect(views.use(for: "/Volumes/Photos", volume: "A") != nil)
        #expect(views.use(for: "/Volumes/Photos", volume: "B") == nil)
        #expect(views.use(for: "/Volumes/Photos", volume: nil) != nil)
    }

    @Test func anEmptyViewIsNotKept() {
        var views = views()
        views.set(FolderView(path: "/Users/me/Downloads"))
        #expect(views.own("/Users/me/Downloads") == nil)
        views.set(FolderView(path: "/Users/me/Pictures/Scans"))
        #expect(views.own("/Users/me/Pictures/Scans") == nil)
        #expect(views.own("/Users/me/Pictures/Work") != nil)
    }

    @Test func aMovedFolderTakesItsViewAndEveryViewInsideIt() {
        var views = views()
        views.moved(from: "/Users/me/Pictures", to: "/Users/me/Photos")
        #expect(
            views.all.map(\.path) == ["/Users/me/Photos", "/Users/me/Photos/Scans", "/Users/me/Photos/Work"])
        views.moved(from: "/Users/me/Photos/Scans", to: "/Users/me/Archive/Scans")
        #expect(views.own("/Users/me/Archive/Scans") != nil)
        #expect(views.inside("/Users/me/Photos").map(\.path) == ["/Users/me/Photos/Work"])
    }

    @Test func aFolderRenamedOutsideTheAppTakesOverTheViewWithItsFileID() {
        var views = FolderViews([FolderView(path: "/Users/me/Old", volume: "A", fileID: 42, keeps: Self.previews)])
        let whileThere = views.adopt(path: "/Users/me/New", volume: "A", fileID: 42, exists: { $0 == "/Users/me/Old" })
        #expect(!whileThere)
        let gone = views.adopt(path: "/Users/me/New", volume: "A", fileID: 42, exists: { _ in false })
        #expect(gone)
        #expect(views.own("/Users/me/New")?.keeps == Self.previews)
        #expect(views.own("/Users/me/Old") == nil)
    }

    @Test func differencesNameTheSettingsWithAnotherValueOrKeptInOneOnly() {
        var changed = Self.previews
        changed.view = .icons
        #expect(changed.differences(from: Self.previews) == [.view])
        #expect(Self.previews.differences(from: Self.previews).isEmpty)
        // Kept on one side only: a Keep box checked or unchecked and not saved.
        changed = Self.previews
        changed.foldersFirst = nil
        #expect(changed.differences(from: Self.previews) == [.foldersFirst])
        #expect(Self.previews.differences(from: changed) == [.foldersFirst])
    }

    @Test func aDraftIsAViewNotSavedThatKeepsItsChangesOnlyOnScreen() {
        var draft = FolderViewOnScreen.draft(FolderView(path: "/Users/me/New", keeps: FolderViewKeeps()))
        #expect(draft.isDraft && !draft.isOwnSaved && !draft.hasUnsavedChanges)
        draft.shown.view = .previews
        draft.shownSubfolders = true
        #expect(draft.unsaved == [.view] && draft.subfoldersUnsaved && draft.hasUnsavedChanges)
        // Saved in another window: what is changed here stays on screen, the rest is what is saved.
        let saved = FolderView(path: "/Users/me/New", keeps: FolderViewKeeps(view: .icons, foldersFirst: false))
        let next = draft.taking(FolderViewUse(view: saved, own: true))
        #expect(!next.isDraft && next.shown.view == .previews && next.shown.foldersFirst == false)
        #expect(next.shownSubfolders)
    }

    @Test func theFileIsReadBackAsWrittenAndAViewThatCantBeReadIsLeftOut() throws {
        let views = views()
        let text = views.serialize()
        #expect(FolderViews.parse(Data(text.utf8)) == views)
        #expect(views.serialize() == FolderViews.parse(Data(text.utf8)).serialize())
        let broken = """
            {"version":1,"views":[{"path":"/a","subfolders":false,"keeps":{"view":"list"}},{"path":3},
            {"path":"relative","subfolders":false,"keeps":{"view":"list"}}]}
            """
        #expect(FolderViews.parse(Data(broken.utf8)).all.map(\.path) == ["/a"])
        #expect(FolderViews.parse(Data("not json".utf8)).isEmpty)
    }
}
