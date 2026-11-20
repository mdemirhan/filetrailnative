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

    // A view is its path's and nothing else's: the same path on another disk of the same name uses it too.
    @Test func aViewIsFoundByItsPathAloneAndGoesWithAMoveToAnotherDisk() {
        var views = views()
        views.moved(from: "/Users/me/Pictures", to: "/Volumes/Photos/Pictures")
        #expect(
            views.all.map(\.path) == [
                "/Volumes/Photos/Pictures", "/Volumes/Photos/Pictures/Scans", "/Volumes/Photos/Pictures/Work",
            ])
        #expect(views.use(for: "/Volumes/Photos/Pictures")?.own == true)
        #expect(views.use(for: "/Volumes/Photos/Pictures/Iceland")?.view.path == "/Volumes/Photos/Pictures")
        #expect(views.use(for: "/Users/me/Pictures") == nil)
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

    // One operation's moves all start from where the folders were before it: a batch rename that hands names along.
    @Test func foldersRenamedOneOntoTheNextEachKeepTheirOwnView() {
        var views = FolderViews([
            FolderView(path: "/d/A1", keeps: FolderViewKeeps(view: .icons)),
            FolderView(path: "/d/A2", keeps: FolderViewKeeps(view: .details)),
        ])
        views.moved([(from: "/d/A1", to: "/d/A2"), (from: "/d/A2", to: "/d/A3")])
        #expect(views.all.map(\.path) == ["/d/A2", "/d/A3"])
        #expect(views.own("/d/A2")?.keeps.view == .icons)
        #expect(views.own("/d/A3")?.keeps.view == .details)
        // In the other order too: what the moves are listed in decides nothing.
        views.moved([(from: "/d/A3", to: "/d/A4"), (from: "/d/A2", to: "/d/A3")])
        #expect(views.own("/d/A3")?.keeps.view == .icons)
        #expect(views.own("/d/A4")?.keeps.view == .details)
        #expect(views.own("/d/A2") == nil)
    }

    @Test func foldersThatSwapNamesSwapTheirViewsAndTheViewsInsideThem() {
        var views = FolderViews([
            FolderView(path: "/d/A1", subfolders: true, keeps: FolderViewKeeps(view: .icons)),
            FolderView(path: "/d/A1/Inner", keeps: FolderViewKeeps(view: .previews)),
            FolderView(path: "/d/A2", keeps: FolderViewKeeps(view: .details)),
            FolderView(path: "/d/A2/Inner", keeps: FolderViewKeeps(view: .list)),
            FolderView(path: "/d/A2/Other", keeps: FolderViewKeeps(foldersFirst: false)),
            FolderView(path: "/d/A20", keeps: FolderViewKeeps(view: .list)),
        ])
        views.moved([(from: "/d/A1", to: "/d/A2"), (from: "/d/A2", to: "/d/A1")])
        #expect(
            views.all.map(\.path) == ["/d/A1", "/d/A1/Inner", "/d/A1/Other", "/d/A2", "/d/A2/Inner", "/d/A20"])
        #expect(views.own("/d/A1")?.keeps.view == .details && views.own("/d/A1")?.subfolders == false)
        #expect(views.own("/d/A1/Inner")?.keeps.view == .list)
        #expect(views.own("/d/A1/Other")?.keeps.foldersFirst == false)
        #expect(views.own("/d/A2")?.keeps.view == .icons && views.own("/d/A2")?.subfolders == true)
        #expect(views.own("/d/A2/Inner")?.keeps.view == .previews)
        // A folder whose name only starts the same is no part of it.
        #expect(views.own("/d/A20")?.keeps.view == .list)
    }

    // The deepest move that holds a view's folder is the one it goes with, and where a move ended is asked only of
    // the moves that carry a view, once each.
    @Test func aFolderMovedOutOfAFolderRenamedInTheSameOperationGoesWhereItWent() {
        var views = views()
        var asked: [String] = []
        views.moved(
            [
                (from: "/Users/me/Pictures", to: "/Users/me/Photos"),
                (from: "/Users/me/Pictures/Scans", to: "/Users/me/Archive/Scans"),
                (from: "/Users/me/Music", to: "/Users/me/Songs"),
            ],
            destination: {
                asked.append($0)
                return $0 == "/Users/me/Photos" ? "/Volumes/Real/Photos" : $0
            })
        #expect(
            views.all.map(\.path) == ["/Users/me/Archive/Scans", "/Volumes/Real/Photos", "/Volumes/Real/Photos/Work"])
        #expect(asked.sorted() == ["/Users/me/Archive/Scans", "/Users/me/Photos"])
        // No view among the moved: nothing is asked, and nothing changes.
        let before = views
        asked = []
        views.moved(
            [(from: "/Users/me/Music", to: "/Users/me/Songs")],
            destination: {
                asked.append($0)
                return $0
            })
        #expect(asked.isEmpty && views == before)
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
        #expect(throws: (any Error).self) { try FolderViews.read(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try FolderViews.read(Data("[1, 2]".utf8)) }
    }

    // A file written while a view was found by its disk and file ID has both with each view: it loads, without them.
    @Test func aFileThatKeptADiskAndAFileIDWithEachViewLoadsWithoutThem() throws {
        let old = """
            {"version":1,"views":[
            {"path":"/Users/me/Pictures","volume":"6B1F2C1E-0000-4000-8000-000000000001","fileID":4242,
             "subfolders":true,"keeps":{"view":"previews","sort":{"by":"modified","direction":"desc"}}},
            {"path":"/Volumes/Photos/Scans","fileID":7,"subfolders":false,"keeps":{"foldersFirst":false}}]}
            """
        let views = try FolderViews.read(Data(old.utf8))
        #expect(
            views.own("/Users/me/Pictures")
                == FolderView(
                    path: "/Users/me/Pictures", subfolders: true,
                    keeps: FolderViewKeeps(view: .previews, sort: FolderViewSort(by: .modified, direction: .desc))))
        #expect(views.own("/Volumes/Photos/Scans")?.keeps == FolderViewKeeps(foldersFirst: false))
        // Written again, neither is there any more.
        #expect(!views.serialize().contains("volume") && !views.serialize().contains("fileID"))
    }

    // A view keeps its grouping as a sixth setting; one saved before groups keeps none, and one naming a grouping this
    // build doesn't know, or search results' own Folder, keeps none either while the rest of it loads.
    @Test func aViewKeepsItsGroupingAndOneSavedBeforeKeepsNone() throws {
        let saved = """
            {"version":1,"views":[
            {"path":"/a","subfolders":false,"keeps":{"view":"list","groupBy":"modified"}},
            {"path":"/b","subfolders":false,"keeps":{"view":"icons"}},
            {"path":"/c","subfolders":false,"keeps":{"view":"icons","groupBy":"color"}},
            {"path":"/d","subfolders":false,"keeps":{"view":"icons","groupBy":"folder"}}]}
            """
        let views = try FolderViews.read(Data(saved.utf8))
        #expect(views.own("/a")?.keeps == FolderViewKeeps(view: .list, groupBy: .modified))
        #expect(views.own("/a")?.keeps.kept == [.view, .groupBy])
        for path in ["/b", "/c", "/d"] { #expect(views.own(path)?.keeps == FolderViewKeeps(view: .icons), "\(path)") }
        #expect(FolderViewKeeps(groupBy: .folder).isEmpty)
        // Taken, forgotten and told apart as the other settings are.
        var keeps = FolderViewKeeps(view: .list)
        keeps.take(.groupBy, from: FolderViewKeeps(groupBy: .size))
        #expect(keeps.groupBy == .size && keeps.keeps(.groupBy))
        #expect(keeps.differences(from: FolderViewKeeps(view: .list)) == [.groupBy])
        keeps.forget(.groupBy)
        #expect(keeps == FolderViewKeeps(view: .list))
        #expect(FolderViewSetting.allCases.prefix(3) == [.view, .groupBy, .sort])
    }

    // A column added to the app later is missing from every view saved before it: such a view keeps its columns, the
    // new ones as they first are, and the views beside it are kept too.
    @Test func aViewWhoseColumnsLackTheNewerOnesLoadsWithTheOthersKept() throws {
        let saved = """
            {"version":1,"views":[
            {"path":"/a","subfolders":false,"keeps":{"view":"details","columns":{
              "visibility":{"modified":false,"size":true,"kind":false,"created":true,"permissions":true},
              "order":["size","created","permissions","modified","kind","someday"],
              "widths":{"name":410,"modified":160,"size":90,"kind":148,"created":152,"permissions":108,"someday":50}}}},
            {"path":"/b","subfolders":true,"keeps":{"view":"someday","size":{"iconSizes":{"standard":96}}}},
            {"path":"/c","subfolders":false,"keeps":{"view":"list"}}]}
            """
        let views = try FolderViews.read(Data(saved.utf8))
        #expect(views.all.map(\.path) == ["/a", "/b", "/c"])
        let columns = try #require(views.own("/a")?.keeps.columns)
        var visibility = DetailColumnVisibility.defaults
        visibility.modified = false
        visibility.kind = false
        visibility.created = true
        visibility.permissions = true
        #expect(columns.visibility == visibility)
        #expect(!columns.visibility.added && !columns.visibility.lastOpened)
        // The order saved first, then the columns it doesn't have, in the menus' order.
        #expect(columns.order == [.size, .created, .permissions, .modified, .kind, .lastOpened, .added])
        #expect(columns.widths.name == 410 && columns.widths.size == 90)
        #expect(columns.widths.added == DetailColumnWidths.defaults.added)
        #expect(views.own("/a")?.keeps.view == .details)
        // A view the app doesn't know is not kept; the size beside it is, the sizes it lacks as they first are.
        let other = try #require(views.own("/b"))
        #expect(other.subfolders && other.keeps.view == nil)
        #expect(other.keeps.size?.iconSizes == DensitySizes(standard: 96, finder: DensitySizes.iconDefaults.finder))
        #expect(other.keeps.size?.previewCounts == .previewCountDefaults)
    }

    // A number of any size can stand in a file edited by hand: one no Previews count could be reads as the default,
    // and the app still starts.
    @Test func aPreviewsCountNoNumberCouldBeReadsAsTheDefault() throws {
        let saved = """
            {"version":1,"views":[{"path":"/a","keeps":{"size":{"previewCounts":{"standard":1e30,"finder":-1e30}}}}]}
            """
        let sizes = try #require(try FolderViews.read(Data(saved.utf8)).own("/a")?.keeps.size)
        #expect(sizes.previewCounts.standard == PreviewGrid.defaultCount)
        #expect(sizes.previewCounts.finder == PreviewGrid.defaultCount)
        #expect(PreviewGrid.valid(read: 9.4) == 9 && PreviewGrid.valid(read: .infinity) == PreviewGrid.defaultCount)
    }

    @Test func aViewThatKeepsColumnsAndSizeIsReadBackAsWritten() throws {
        var visibility = DetailColumnVisibility.defaults
        visibility.added = true
        visibility.size = false
        var widths = DetailColumnWidths.defaults
        widths.name = 512
        widths.lastOpened = 201
        let view = FolderView(
            path: "/Users/me/Downloads", subfolders: true,
            keeps: FolderViewKeeps(
                view: .details, sort: FolderViewSort(by: .added, direction: .desc), foldersFirst: false,
                columns: FolderViewColumns(
                    visibility: visibility,
                    order: [.added, .modified, .created, .lastOpened, .size, .kind, .permissions], widths: widths),
                size: FolderViewSizes(
                    iconSizes: DensitySizes(standard: 96, finder: 48),
                    compactListWidths: DensitySizes(standard: 400, finder: 252),
                    previewCounts: DensitySizes(standard: 9, finder: 1))))
        let views = FolderViews([view])
        let read = try FolderViews.read(Data(views.serialize().utf8))
        #expect(read.own("/Users/me/Downloads") == view)
        #expect(read.serialize() == views.serialize())
    }

    /// Every order of `keys`.
    private func orders(_ keys: [OptionalDetailColumnKey]) -> [[OptionalDetailColumnKey]] {
        guard keys.count > 1 else { return [keys] }
        return keys.indices.flatMap { index -> [[OptionalDetailColumnKey]] in
            var rest = keys
            let first = rest.remove(at: index)
            return orders(rest).map { [first] + $0 }
        }
    }

    // Reading checks each width and size against its limits and takes a setting it can't read as not kept, so the
    // next write would leave that setting out. Neither may touch what the app writes itself: every width a column can
    // have, every icon size, Compact List width and Previews count at both densities, every order of the columns
    // with every choice of which are shown, and every view and order are read back as they were written.
    @Test func everythingTheAppCanWriteIsReadBackAsWritten() throws {
        var views: [FolderView] = []
        func add(_ keeps: FolderViewKeeps, subfolders: Bool = false) {
            views.append(FolderView(path: "/folder/\(views.count)", subfolders: subfolders, keeps: keeps))
        }
        let standard = OptionalDetailColumnKey.menuOrder
        // Each column from its least width to its greatest, a point at a time.
        let widest = DetailColumnKey.allCases.map(\.widthLimits.count).max() ?? 0
        for step in 0..<widest {
            var widths = DetailColumnWidths.defaults
            for key in DetailColumnKey.allCases {
                widths[key] = min(key.widthLimits.lowerBound + step, key.widthLimits.upperBound)
            }
            add(FolderViewKeeps(columns: FolderViewColumns(visibility: .defaults, order: standard, widths: widths)))
        }
        // Every order, each with another choice of the columns shown: all 128 choices come by many times over.
        for (number, order) in orders(standard).enumerated() {
            var visibility = DetailColumnVisibility.defaults
            for (bit, key) in OptionalDetailColumnKey.allCases.enumerated() { visibility[key] = number >> bit & 1 == 1 }
            add(FolderViewKeeps(columns: FolderViewColumns(visibility: visibility, order: order, widths: .defaults)))
        }
        // Every size, the two densities apart.
        let icons = Array(
            stride(
                from: AppPreferenceLimits.iconSizeRange.lowerBound,
                through: AppPreferenceLimits.iconSizeRange.upperBound,
                by: AppPreferenceLimits.iconSizeStep))
        let range = AppPreferenceLimits.compactListWidthRange
        let counts = PreviewGrid.counts
        for (number, width) in range.enumerated() {
            add(
                FolderViewKeeps(
                    size: FolderViewSizes(
                        iconSizes: DensitySizes(
                            standard: icons[number % icons.count], finder: icons[(number / icons.count) % icons.count]),
                        compactListWidths: DensitySizes(
                            standard: width, finder: range.upperBound - (width - range.lowerBound)),
                        previewCounts: DensitySizes(
                            standard: counts[number % counts.count],
                            finder: counts[(number / counts.count) % counts.count]))))
        }
        // The sizes before any is set: the Compact List's are between two steps.
        add(
            FolderViewKeeps(
                size: FolderViewSizes(
                    iconSizes: .iconDefaults, compactListWidths: .compactListDefaults,
                    previewCounts: .previewCountDefaults)))
        // Every view, in every order, folders first or not, covering the folders inside or not.
        for view in ExplorerViewMode.allCases {
            for field in SortByPreference.allCases {
                for direction in SortDirectionPreference.allCases {
                    for foldersFirst in [true, false] {
                        add(
                            FolderViewKeeps(
                                view: view, sort: FolderViewSort(by: field, direction: direction),
                                foldersFirst: foldersFirst), subfolders: foldersFirst)
                    }
                }
            }
        }
        // Every grouping a folder can keep.
        for field in [GroupByPreference.none] + GroupByPreference.menuOrder { add(FolderViewKeeps(groupBy: field)) }
        // A view that keeps nothing and covers the folders inside is kept too.
        add(FolderViewKeeps(), subfolders: true)

        let written = FolderViews(views)
        #expect(written.all.count == views.count)
        let read = try FolderViews.read(Data(written.serialize().utf8))
        #expect(read == written)
        #expect(read.serialize() == written.serialize())
    }

    // Keep Columns chosen in a folder that uses a view from above is a view of its own to come at Save. It stays
    // that while the view above is saved again elsewhere, and is there no more once the folder has a view of its own.
    @Test func aViewOfItsOwnToComeStaysWhileTheViewAboveIsSavedAgainAndGoesOnceTheFolderHasOne() {
        let above = FolderView(path: "/Users/me/Pictures", subfolders: true, keeps: Self.previews)
        var pending = FolderViewOnScreen(FolderViewUse(view: above, own: false))
        #expect(!pending.hasUnsavedChanges)
        pending.becomesOwn = true
        #expect(pending.hasUnsavedChanges && pending.unsaved.isEmpty)
        // Not the same as the view with nothing chosen: a pane that compares the two shows the change.
        #expect(pending != FolderViewOnScreen(FolderViewUse(view: above, own: false)))

        var changed = above
        changed.keeps.view = .icons
        let stillPending = pending.taking(FolderViewUse(view: changed, own: false))
        #expect(stillPending.becomesOwn && stillPending.shown.view == .icons && stillPending.hasUnsavedChanges)

        let own = FolderView(path: "/Users/me/Pictures/Scans", keeps: Self.previews)
        let saved = pending.taking(FolderViewUse(view: own, own: true))
        #expect(!saved.becomesOwn && !saved.hasUnsavedChanges && saved.isOwnSaved)
        // The same folder's view from above taken over as its own (the folder above itself): never set there.
        #expect(!pending.taking(FolderViewUse(view: above, own: true)).becomesOwn)
    }
}
