import CoreGraphics
import FTFileSystem
import FTFoundation
import FTOperations
import Testing

@testable import FTAppKit

@Suite struct ExplorerTabsTests {
    private let tabs = ["a", "b", "c"]

    @Test func namesATabAfterItsFolderOrAfterItsSearchWhileResultsAreShowing() {
        func describe(
            _ path: String, visible: Bool = false, query: String = "", root: String = "", running: Bool = false
        ) -> TabDescription {
            ExplorerTabs.describe(
                currentPath: path, searchVisible: visible, searchQuery: query, searchRootPath: root,
                searchRunning: running, homePath: "/Users/demo")
        }
        let folder = describe("/Users/demo/Documents")
        #expect(folder.label == "Documents")
        #expect(folder.kind == .folder)
        #expect(describe("/").label == "Macintosh HD")
        #expect(describe("").label == "Favorites")
        let search = describe(
            "/Users/demo/Documents", visible: true, query: "invoice", root: "/Users/demo", running: true)
        #expect(search.label == "“invoice” in demo")
        #expect(search.kind == .search)
        #expect(search.searching)
        #expect(search.tooltip == "Searching /Users/demo")
        // A search that was put away leaves the tab named after its folder.
        #expect(describe("/Users/demo/Documents", query: "invoice").kind == .folder)
    }

    @Test func handsAClosedTabsPlaceToTheTabOnItsRightOrItsLeftWhenItWasLast() {
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "a") == "b")
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "b") == "c")
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "c") == "b")
        #expect(ExplorerTabs.tabAfterClose(["a"], closing: "a") == nil)
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "missing") == nil)
    }

    @Test func stepsToTheNextAndPreviousTabWrappingAround() {
        #expect(ExplorerTabs.adjacentTab(tabs, active: "a", .next) == "b")
        #expect(ExplorerTabs.adjacentTab(tabs, active: "c", .next) == "a")
        #expect(ExplorerTabs.adjacentTab(tabs, active: "a", .previous) == "c")
        #expect(ExplorerTabs.adjacentTab(["a"], active: "a", .next) == nil)
    }

    @Test func stopsASavedTreeFromWaitingForAnswersThatWentToAnotherTab() {
        let node = TreeNodeState(path: "/a", name: "a", expanded: true, loaded: true)
        let settled = TreeNodes([node])
        #expect(ExplorerTabs.settleTreeNodes(settled) == settled)
        var loading = node
        loading.path = "/b"
        loading.loading = true
        let nodes = ExplorerTabs.settleTreeNodes(TreeNodes([node, loading]))
        #expect(nodes["/b"]?.loading == false)
        #expect(nodes["/a"] == node)
    }

    @Test func keepsAClosedTabsHistoryAndWhatItHadOnScreenButTheErrorThere() {
        var view = TabViewState()
        view.contentSelection = .single("/Users/demo/work/a")
        view.listFilterQuery = "a"
        view.contentScroll.y = 40
        view.directoryError = FolderReadError(message: "No access", errnum: 13)
        var snapshot = TabSnapshot(
            currentPath: "/Users/demo/work", historyPaths: ["/Users/demo", "/Users/demo/work"], historyIndex: 1,
            viewMode: .details, searchViewMode: .icons, sortBy: .size, sortDirection: .desc,
            treeRootPath: "/Users/demo", focusedPane: .tree, favoritesExpanded: false, view: view)
        let second = OpenPanePreference(
            path: "/Users/demo/b", viewMode: .icons, searchViewMode: .details, sortBy: .name, sortDirection: .asc,
            includeHidden: false, foldersFirst: true)
        snapshot.secondPane = PaneSnapshot(
            pane: second, historyPaths: ["/Users/demo", "/Users/demo/b"], historyIndex: 0, view: view)

        var expected = snapshot
        expected.view?.directoryError = nil
        expected.secondPane?.view?.directoryError = nil
        #expect(ExplorerTabs.reopenable(snapshot) == expected)
    }

    @Test func aViewLeavingSearchResultsKeepsThePinnedFilterAndTheFoldersPlacesOnly() {
        var view = TabViewState()
        view.contentSelection = .single("/Users/demo/work/a")
        view.listFilterQuery = "a"
        view.listFilterMode = .contains
        view.contentScroll = CGPoint(x: 3, y: 40)
        view.pinnedListFilter = PinnedListFilter(query: "no", mode: .fuzzy)
        view.folderViewMemories = ["/Users/demo": FolderViewMemory(selection: .single("/Users/demo/work"))]

        var expected = TabViewState()
        expected.pinnedListFilter = view.pinnedListFilter
        expected.folderViewMemories = view.folderViewMemories
        #expect(view.leavingSearchResults() == expected)
    }

    // `openNewTab`
    @Test func startsANewTabWithTheTreeAndAHistoryOfItsOwnAndNothingSelectedOrTyped() {
        var view = TabViewState()
        view.treeNodes = TreeNodes([TreeNodeState(path: "/Users/demo/open", expanded: true)])
        view.treeScrollTop = 30
        view.contentSelection = .single("/Users/demo/work/a")
        view.listFilterQuery = "a"
        view.contentScroll.y = 40
        view.folderViewMemories = ["/Users/demo": FolderViewMemory(selection: .empty, scrollTop: 1, scrollLeft: 0)]
        let snapshot = TabSnapshot(
            currentPath: "/Users/demo/work", historyPaths: ["/Users/demo", "/Users/demo/work"], historyIndex: 1,
            treeRootPath: "/Users/demo", focusedPane: .tree, view: view)

        let new = ExplorerTabs.newTab(from: snapshot)

        #expect(new.historyPaths == ["/Users/demo/work"])
        #expect(new.historyIndex == 0)
        #expect(new.focusedPane == .tree)
        var kept = TabViewState()
        kept.treeNodes = view.treeNodes
        kept.treeScrollTop = 30
        #expect(new.view == kept)

        var released = snapshot
        released.currentPath = ""
        #expect(ExplorerTabs.newTab(from: released).historyPaths.isEmpty)
        #expect(ExplorerTabs.newTab(from: released).historyIndex == -1)
    }

    @Test func tellsTabsOnFoldersOfTheSameNameApartByTheFolderEachIsIn() {
        func tab(_ label: String, _ path: String, _ kind: TabDescription.Kind = .folder) -> TabLabel {
            TabLabel(label: label, kind: kind, path: path)
        }
        let items = [
            tab("src", "/Users/demo/filetrail/src"),
            tab("src", "/Users/demo/codetrail/src"),
            tab("Documents", "/Users/demo/Documents"),
            // Two tabs on the same folder are the same place.
            tab("Downloads", "/Users/demo/Downloads"),
            tab("Downloads", "/Users/demo/Downloads"),
            tab("“src” in demo", "/Users/demo", .search),
            // A folder in the Trash is told apart by the Trash, as the path bar calls it.
            tab("notes", "/Users/demo/notes"),
            tab("notes", "/Users/demo/.Trash/notes"),
        ]
        let labels = ExplorerTabs.disambiguate(items, homePath: "/Users/demo").map(\.label)
        #expect(
            labels == [
                "src — filetrail", "src — codetrail", "Documents", "Downloads", "Downloads", "“src” in demo",
                "notes — demo", "notes — Trash",
            ])
    }

    @Test func listsAFolderAndTheFoldersAboveItNearestFirst() {
        #expect(
            ExplorerTabs.pathAndAncestors("/Users/demo/Folder") == ["/Users/demo/Folder", "/Users/demo", "/Users", "/"])
        #expect(ExplorerTabs.pathAndAncestors("").isEmpty)
    }

    // MARK: followMovedItems

    private func snapshot(_ currentPath: String) -> TabSnapshot {
        TabSnapshot(
            currentPath: currentPath, historyPaths: ["/Users/demo", currentPath], historyIndex: 1,
            treeRootPath: "/Users/demo", selectedTreeItemID: "fs:\(currentPath)", view: TabViewState())
    }

    @Test func followsARenamedOrMovedFolderAndFoldersInsideIt() {
        let moves = [PathMove(from: "/Users/demo/Projects", to: "/Users/demo/Work")]

        let followed = ExplorerTabs.followMovedItems(snapshot("/Users/demo/Projects/app"), moves)

        #expect(followed.currentPath == "/Users/demo/Work/app")
        #expect(followed.historyPaths == ["/Users/demo", "/Users/demo/Work/app"])
        #expect(followed.selectedTreeItemID == "fs:/Users/demo/Work/app")
        // Its listing is read again at the new place.
        #expect(followed.view == nil)
    }

    @Test func leavesATabOnAnotherFolderAsItIs() {
        let tab = snapshot("/Users/demo/Projects2")
        #expect(
            ExplorerTabs.followMovedItems(tab, [PathMove(from: "/Users/demo/Projects", to: "/Users/demo/Work")]) == tab)
    }

    // MARK: collectFollowedMoves

    private func result(_ action: WriteOperationAction, mode: CopyPasteMode? = nil) -> WriteOperationOutcome {
        WriteOperationOutcome(
            action: action, mode: mode,
            items: [
                WriteEffectItem(sourcePath: "/a", destinationPath: "/b", status: .completed),
                WriteEffectItem(sourcePath: "/c", destinationPath: "/c 2", status: .failed),
                WriteEffectItem(sourcePath: "/d", destinationPath: nil, status: .failed),
                WriteEffectItem(sourcePath: "/e", destinationPath: "/e", status: .completed),
            ])
    }

    private func moves(of result: WriteOperationOutcome) -> [PathMove] {
        ExplorerTabs.collectFollowedMoves(result.action, items: result.items)
    }

    @Test func followsWhatWasRenamedAndAnItemOfSeveralPutBackUnderAnotherName() {
        #expect(
            moves(of: result(.batchRename)) == [
                PathMove(from: "/a", to: "/b"), PathMove(from: "/c", to: "/c 2"),
            ])
    }

    @Test func followsOnlyWhatAMoveFinishedAFailedItemStayedWhereItWas() {
        #expect(moves(of: result(.moveTo)) == [PathMove(from: "/a", to: "/b")])
    }

    // The filter of the write progress the tabs follow: only a finished
    // operation that gave items new paths moves the tabs.
    @Test func followsTheMovesOfAFinishedRenameMoveOrCutPasteOnly() {
        func moves(_ status: WriteOperationStatus, _ result: WriteOperationOutcome?) -> [PathMove] {
            ExplorerTabs.followedMoves(WriteOperationProgress(status: status, result: result))
        }
        let moved = [PathMove(from: "/a", to: "/b")]
        for status: WriteOperationStatus in [.queued, .running, .awaitingResolution] {
            #expect(moves(status, result(.rename)).isEmpty)
        }
        #expect(moves(.completed, nil).isEmpty)
        for action: WriteOperationAction in [.rename, .moveTo, .undo, .redo] {
            #expect(moves(.completed, result(action)) == moved)
        }
        // A paste moves items only when they were cut; a copy, a trash or a new folder moves none.
        #expect(moves(.completed, result(.paste, mode: .cut)) == moved)
        #expect(moves(.completed, result(.paste, mode: .copy)).isEmpty)
        #expect(moves(.completed, result(.copyTo)).isEmpty)
        #expect(moves(.completed, result(.trash)).isEmpty)
        #expect(moves(.completed, result(.newFolder)).isEmpty)
        // What partly worked, or stopped, still moved what it finished.
        for status: WriteOperationStatus in [.partial, .cancelled, .failed] {
            #expect(moves(status, result(.moveTo)) == moved)
        }
    }

    // MARK: leaveUnmountedDisks

    private func onDisk(_ currentPath: String, _ history: [String], root: String = "/Volumes/Backup") -> TabSnapshot {
        TabSnapshot(
            currentPath: currentPath, historyPaths: history, historyIndex: history.count - 1, treeRootPath: root,
            selectedTreeItemID: "location:/Volumes/Backup", leftPaneSubview: .favorites, view: TabViewState())
    }

    @Test func sendsATabOnAnUnmountedDiskHomeKeepingItsHistoryElsewhere() {
        let left = ExplorerTabs.leaveUnmountedDisks(
            onDisk("/Volumes/Backup/Photos", ["/Users/demo/Desktop", "/Volumes/Backup/Photos"]),
            unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")

        #expect(left.currentPath == "/Users/demo")
        #expect(left.historyPaths == ["/Users/demo/Desktop", "/Users/demo"])
        #expect(left.historyIndex == 1)
        #expect(left.treeRootPath == "/Users/demo")
        #expect(left.selectedTreeItemID == "fs:/Users/demo")
        #expect(left.leftPaneSubview == .tree)
        #expect(left.view == nil)
    }

    // The tree alone was rooted on the disk, the pane showing a folder elsewhere: the tab stays where it is, with
    // what it had on screen, and its tree starts again at Home.
    @Test func aTabWhoseTreeAloneWasOnTheDiskKeepsItsFolder() {
        let tab = onDisk("/Users/demo/Documents", ["/Volumes/Backup/Photos", "/Users/demo/Documents"])
        let left = ExplorerTabs.leaveUnmountedDisks(tab, unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")

        #expect(left.currentPath == "/Users/demo/Documents")
        #expect(left.historyPaths == tab.historyPaths)
        #expect(left.view != nil)
        #expect(left.treeRootPath == "/Users/demo")
        #expect(left.selectedTreeItemID == "fs:/Users/demo/Documents")
        #expect(left.leftPaneSubview == .tree)
    }

    @Test func leavesATabOnAnotherDiskOrOnAFolderNamedAlikeAsItIs() {
        let onArchive = onDisk("/Volumes/Archive/2025", ["/Volumes/Archive/2025"], root: "/Volumes/Archive")
        #expect(
            ExplorerTabs.leaveUnmountedDisks(onArchive, unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")
                == onArchive)
        let onBackup2 = onDisk("/Volumes/Backup 2", ["/Volumes/Backup 2"], root: "/Volumes/Backup 2")
        #expect(
            ExplorerTabs.leaveUnmountedDisks(onBackup2, unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")
                == onBackup2)
    }

    @Test func followsTheDeepestMoveThatHoldsAPath() {
        // "/P" moved to "/Q", and "/P/A" inside it to "/Q/B": the deepest move decides.
        let moves = [PathMove(from: "/P", to: "/Q"), PathMove(from: "/P/A", to: "/Q/B")]
        #expect(ExplorerTabs.followMovedPath("/P/A", moves) == "/Q/B")
        #expect(ExplorerTabs.followMovedPath("/P/A/x", moves) == "/Q/B/x")
        #expect(ExplorerTabs.followMovedPath("/P/C", moves) == "/Q/C")
        #expect(ExplorerTabs.followMovedPath("/Elsewhere", moves) == "/Elsewhere")
    }

    // MARK: Two panes

    private func secondPane(_ path: String, _ history: [String]) -> PaneSnapshot {
        PaneSnapshot(
            pane: OpenPanePreference(
                path: path, viewMode: .icons, searchViewMode: .details, sortBy: .modified, sortDirection: .desc,
                includeHidden: true, foldersFirst: false),
            historyPaths: history, historyIndex: history.count - 1)
    }

    @Test func followsARenamedFolderInTheSecondPaneAndItsHistory() {
        var tab = snapshot("/Users/demo/Documents")
        tab.secondPane = secondPane("/Users/demo/Projects/app", ["/Users/demo/Projects", "/Users/demo/Projects/app"])

        let followed = ExplorerTabs.followMovedItems(
            tab, [PathMove(from: "/Users/demo/Projects", to: "/Users/demo/Work")])

        #expect(followed.secondPane?.pane.path == "/Users/demo/Work/app")
        #expect(followed.secondPane?.historyPaths == ["/Users/demo/Work", "/Users/demo/Work/app"])
        // The first pane stays where it is, with what it had on screen.
        #expect(followed.currentPath == "/Users/demo/Documents")
        #expect(followed.view != nil)
    }

    @Test func sendsOnlyThePaneOnAnUnmountedDiskHome() {
        var tab = snapshot("/Users/demo/Documents")
        tab.secondPane = secondPane("/Volumes/Backup/Photos", ["/Users/demo/Desktop", "/Volumes/Backup/Photos"])

        let left = ExplorerTabs.leaveUnmountedDisks(tab, unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")

        #expect(left.secondPane?.pane.path == "/Users/demo")
        #expect(left.secondPane?.historyPaths == ["/Users/demo/Desktop", "/Users/demo"])
        #expect(left.secondPane?.historyIndex == 1)
        #expect(left.currentPath == "/Users/demo/Documents")
        #expect(left.historyPaths == tab.historyPaths)
        #expect(left.treeRootPath == "/Users/demo")
        #expect(left.selectedTreeItemID == tab.selectedTreeItemID)
        #expect(left.view != nil)

        // The first pane on the disk, the second one elsewhere and active: the tree stays with the second.
        var other = onDisk("/Volumes/Backup/Photos", ["/Volumes/Backup/Photos"], root: "/Users/demo")
        other.secondPane = secondPane("/Users/demo/Documents", ["/Users/demo/Documents"])
        other.activePane = 1
        other.selectedTreeItemID = "fs:/Users/demo/Documents"
        let stayed = ExplorerTabs.leaveUnmountedDisks(other, unmounted: ["/Volumes/Backup"], homePath: "/Users/demo")
        #expect(stayed.currentPath == "/Users/demo")
        #expect(stayed.secondPane == other.secondPane)
        #expect(stayed.selectedTreeItemID == "fs:/Users/demo/Documents")
        #expect(stayed.leftPaneSubview == other.leftPaneSubview)
    }

    @Test func aNewTabHasOnePaneOnTheActivePanesFolderShownAsThatPaneShowsIt() {
        var tab = snapshot("/Users/demo/Documents")
        tab.secondPane = secondPane("/Users/demo/Projects", ["/Users/demo", "/Users/demo/Projects"])
        tab.paneSplit = 0.7

        let fromFirst = ExplorerTabs.newTab(from: tab)
        #expect(fromFirst.secondPane == nil)
        #expect(fromFirst.paneSplit == nil)
        #expect(fromFirst.currentPath == "/Users/demo/Documents")
        #expect(fromFirst.sortBy == tab.sortBy)

        tab.activePane = 1
        let fromSecond = ExplorerTabs.newTab(from: tab)
        #expect(fromSecond.secondPane == nil)
        #expect(fromSecond.activePane == 0)
        #expect(fromSecond.currentPath == "/Users/demo/Projects")
        #expect(fromSecond.historyPaths == ["/Users/demo/Projects"])
        #expect(fromSecond.viewMode == .icons)
        #expect(fromSecond.sortBy == .modified)
        #expect(fromSecond.sortDirection == .desc)
        #expect(fromSecond.includeHidden)
        #expect(!fromSecond.foldersFirst)
    }

    // A new tab started from a tab's second pane groups as that pane does.
    @Test func aNewTabFromTheSecondPaneGroupsAsItDoes() {
        var snapshot = TabSnapshot(
            currentPath: "/a", historyPaths: ["/a"], historyIndex: 0, treeRootPath: "/", focusedPane: .content)
        snapshot.groupBy = .size
        snapshot.secondPane = PaneSnapshot(
            pane: OpenPanePreference(
                path: "/b", viewMode: .icons, searchViewMode: .list, sortBy: .name, sortDirection: .asc,
                includeHidden: false, foldersFirst: true, groupBy: .kind, searchGroupBy: .folder, groupReversed: true),
            historyPaths: ["/b"], historyIndex: 0)
        #expect(ExplorerTabs.newTab(from: snapshot).groupBy == .size)
        snapshot.activePane = 1
        let new = ExplorerTabs.newTab(from: snapshot)
        #expect(new.groupBy == .kind && new.searchGroupBy == .folder && new.groupReversed)
    }
}
