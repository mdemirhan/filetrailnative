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
                searchRunning: running)
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

    @Test func keepsAClosedTabsFolderAndViewNotItsHistoryOrWhatItHadOnScreen() {
        var view = TabViewState()
        view.contentSelection = .single("/Users/demo/work/a")
        view.listFilterQuery = "a"
        view.contentScroll.y = 40
        let snapshot = TabSnapshot(
            currentPath: "/Users/demo/work", historyPaths: ["/Users/demo", "/Users/demo/work"], historyIndex: 1,
            viewMode: .details, searchViewMode: .icons, sortBy: .size, sortDirection: .desc,
            treeRootPath: "/Users/demo", focusedPane: .tree, favoritesExpanded: false, view: view)

        var expected = snapshot
        expected.historyPaths = ["/Users/demo/work"]
        expected.historyIndex = 0
        expected.view = nil
        #expect(ExplorerTabs.reopenable(snapshot) == expected)
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
        let labels = ExplorerTabs.disambiguate([
            tab("src", "/Users/demo/filetrail/src"),
            tab("src", "/Users/demo/codetrail/src"),
            tab("Documents", "/Users/demo/Documents"),
            // Two tabs on the same folder are the same place.
            tab("Downloads", "/Users/demo/Downloads"),
            tab("Downloads", "/Users/demo/Downloads"),
            tab("“src” in demo", "/Users/demo", .search),
        ]).map(\.label)
        #expect(
            labels == [
                "src — filetrail", "src — codetrail", "Documents", "Downloads", "Downloads", "“src” in demo",
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

    @Test func followsWhatWasRenamedAndAnItemOfSeveralPutBackUnderAnotherName() {
        #expect(
            ExplorerTabs.collectFollowedMoves(result(.batchRename)) == [
                PathMove(from: "/a", to: "/b"), PathMove(from: "/c", to: "/c 2"),
            ])
    }

    @Test func followsOnlyWhatAMoveFinishedAFailedItemStayedWhereItWas() {
        #expect(ExplorerTabs.collectFollowedMoves(result(.moveTo)) == [PathMove(from: "/a", to: "/b")])
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
}
