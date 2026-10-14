// Ports apps/desktop/src/renderer/lib/explorerTabs.test.ts
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

@Suite struct ExplorerTabsTests {
    private let tabs = ["a", "b", "c"]

    // T-e787702a F-068 B-VIEW-144
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

    // T-c703a3b8 F-673
    @Test func handsAClosedTabsPlaceToTheTabOnItsRightOrItsLeftWhenItWasLast() {
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "a") == "b")
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "b") == "c")
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "c") == "b")
        #expect(ExplorerTabs.tabAfterClose(["a"], closing: "a") == nil)
        #expect(ExplorerTabs.tabAfterClose(tabs, closing: "missing") == nil)
    }

    // T-e479ad17 F-675
    @Test func stepsToTheNextAndPreviousTabWrappingAround() {
        #expect(ExplorerTabs.adjacentTab(tabs, active: "a", .next) == "b")
        #expect(ExplorerTabs.adjacentTab(tabs, active: "c", .next) == "a")
        #expect(ExplorerTabs.adjacentTab(tabs, active: "a", .previous) == "c")
        #expect(ExplorerTabs.adjacentTab(["a"], active: "a", .next) == nil)
    }

    // T-2404af85 F-834
    @Test func stopsASavedTreeFromWaitingForAnswersThatWentToAnotherTab() {
        let node = TabTreeNode(path: "/a", expanded: true, loaded: true)
        let settled = ["/a": node]
        #expect(ExplorerTabs.settleTreeNodes(settled) == settled)
        var loading = node
        loading.path = "/b"
        loading.loading = true
        let nodes = ExplorerTabs.settleTreeNodes(["/a": node, "/b": loading])
        #expect(nodes["/b"]?.loading == false)
        #expect(nodes["/a"] == node)
    }

    // T-b0759acc F-834
    @Test func movesATabAlongTheRowWithoutDisturbingTheOrderOfTheOthers() {
        func ids(_ list: [String]) -> String { list.joined() }
        #expect(ids(ExplorerTabs.moveTab(tabs, "a", to: 2)) == "bca")
        #expect(ids(ExplorerTabs.moveTab(tabs, "c", to: 0)) == "cab")
        #expect(ids(ExplorerTabs.moveTab(tabs, "b", to: 1)) == "abc")
        #expect(ids(ExplorerTabs.moveTab(tabs, "a", to: 9)) == "bca")
        #expect(ids(ExplorerTabs.moveTab(tabs, "missing", to: 0)) == "abc")
    }

    // T-6d407a9e F-674
    @Test func keepsAClosedTabsFolderAndViewNotItsHistoryOrWhatItHadOnScreen() {
        var view = TabViewState()
        view.selectedPaths = ["/Users/demo/work/a"]
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

    // MARK: A search running in a background tab

    private func result(_ name: String) -> SearchResultItem {
        SearchResultItem(
            path: "/Users/demo/\(name)", name: name, fileExtension: "txt", kind: .file, isHidden: false,
            parentPath: "/Users/demo", relativeParentPath: ".")
    }

    private var session: TabSearchSession {
        var session = TabSearchSession()
        session.results = [result("a.txt")]
        session.cursor = 1
        session.status = .running
        session.jobID = "job-1"
        return session
    }

    private func update(_ items: [SearchResultItem], done: Bool) -> TabSearchUpdate {
        TabSearchUpdate(
            jobID: "job-1", status: done ? .complete : .running, items: items, nextCursor: 1 + items.count, done: done,
            truncated: false, error: nil)
    }

    // T-4240a387 F-834
    @Test func addsWhatWasFoundSinceAndKeepsAskingWhileTheSearchRuns() {
        let next = ExplorerTabs.applyBackgroundSearchUpdate(session, update([result("b.txt")], done: false))
        #expect(next.results.map(\.name) == ["a.txt", "b.txt"])
        #expect(next.cursor == 2)
        #expect(next.status == .running)
        #expect(next.jobID == "job-1")
    }

    // T-1403402d F-834
    @Test func letsGoOfASearchThatHasFinished() {
        let next = ExplorerTabs.applyBackgroundSearchUpdate(session, update([result("b.txt")], done: true))
        #expect(next.status == .complete)
        #expect(next.jobID == nil)
        #expect(next.elapsedMilliseconds == nil)
        #expect(next.results.count == 2)
    }

    // T-56d3adf6 F-834
    @Test func leavesOutResultsThatWereKeptFromTheSearchBefore() {
        var kept = session
        kept.keptResultPaths = ["/Users/demo/a.txt"]
        let next = ExplorerTabs.applyBackgroundSearchUpdate(
            kept, update([result("a.txt"), result("b.txt")], done: false))
        #expect(next.results.map(\.name) == ["a.txt", "b.txt"])
    }

    // T-ad557b96 F-834
    @Test func marksTheSearchToRunAgainWhenItsLastAnswerWasThrownAway() {
        var inFlight = session
        inFlight.pollInFlight = true
        let next = ExplorerTabs.applyBackgroundSearchUpdate(inFlight, update([], done: true))
        #expect(next.jobID == nil)
        #expect(next.status == .cancelled)
        #expect(next.interrupted)
        // An answer that still carries results shows that nothing was lost.
        let running = ExplorerTabs.applyBackgroundSearchUpdate(inFlight, update([], done: false))
        #expect(running.jobID == "job-1")
        #expect(!running.pollInFlight)
        #expect(!running.interrupted)
    }

    // T-84234a52 F-068 B-VIEW-144
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

    // T-654ba719 F-673
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

    // T-7f43e078 F-676
    @Test func followsARenamedOrMovedFolderAndFoldersInsideIt() {
        let moves = [PathMove(from: "/Users/demo/Projects", to: "/Users/demo/Work")]

        let followed = ExplorerTabs.followMovedItems(snapshot("/Users/demo/Projects/app"), moves)

        #expect(followed.currentPath == "/Users/demo/Work/app")
        #expect(followed.historyPaths == ["/Users/demo", "/Users/demo/Work/app"])
        #expect(followed.selectedTreeItemID == "fs:/Users/demo/Work/app")
        // Its listing is read again at the new place.
        #expect(followed.view == nil)
    }

    // T-1fff82ea F-676
    @Test func leavesATabOnAnotherFolderAsItIs() {
        let tab = snapshot("/Users/demo/Projects2")
        #expect(
            ExplorerTabs.followMovedItems(tab, [PathMove(from: "/Users/demo/Projects", to: "/Users/demo/Work")]) == tab)
    }

    // MARK: collectFollowedMoves (explorerAppUtils.test.ts)

    private func result(_ action: String, mode: CopyPasteMode? = nil) -> WriteOperationOutcome {
        WriteOperationOutcome(
            action: action, mode: mode,
            items: [
                WriteEffectItem(sourcePath: "/a", destinationPath: "/b", status: "completed"),
                WriteEffectItem(sourcePath: "/c", destinationPath: "/c 2", status: "failed"),
                WriteEffectItem(sourcePath: "/d", destinationPath: nil, status: "failed"),
                WriteEffectItem(sourcePath: "/e", destinationPath: "/e", status: "completed"),
            ])
    }

    // T-b0dde00f
    @Test func followsWhatWasRenamedAndAnItemOfSeveralPutBackUnderAnotherName() {
        #expect(
            ExplorerTabs.collectFollowedMoves(result("batch_rename")) == [
                PathMove(from: "/a", to: "/b"), PathMove(from: "/c", to: "/c 2"),
            ])
    }

    // T-52ae9489
    @Test func followsOnlyWhatAMoveFinishedAFailedItemStayedWhereItWas() {
        #expect(ExplorerTabs.collectFollowedMoves(result("move_to")) == [PathMove(from: "/a", to: "/b")])
    }

    // The filter of the original's `onWriteOperationProgress` listener (useExplorerTabs.ts): only a finished
    // operation that gave items new paths moves the tabs.
    // F-676 B-VIEW-172
    @Test func followsTheMovesOfAFinishedRenameMoveOrCutPasteOnly() {
        func moves(_ status: String, _ result: WriteOperationOutcome?) -> [PathMove] {
            ExplorerTabs.followedMoves(WriteOperationProgress(status: status, result: result))
        }
        let moved = [PathMove(from: "/a", to: "/b")]
        for status in ["queued", "running", "awaiting_resolution"] {
            #expect(moves(status, result("rename")).isEmpty)
        }
        #expect(moves("completed", nil).isEmpty)
        for action in ["rename", "move_to", "undo", "redo"] {
            #expect(moves("completed", result(action)) == moved)
        }
        // A paste moves items only when they were cut; a copy, a trash or a new folder moves none.
        #expect(moves("completed", result("paste", mode: .cut)) == moved)
        #expect(moves("completed", result("paste", mode: .copy)).isEmpty)
        #expect(moves("completed", result("copy_to")).isEmpty)
        #expect(moves("completed", result("trash")).isEmpty)
        #expect(moves("completed", result("new_folder")).isEmpty)
        // What partly worked, or stopped, still moved what it finished.
        for status in ["partial", "cancelled", "failed"] {
            #expect(moves(status, result("move_to")) == moved)
        }
    }

    // MARK: leaveUnmountedDisks

    private func onDisk(_ currentPath: String, _ history: [String], root: String = "/Volumes/Backup") -> TabSnapshot {
        TabSnapshot(
            currentPath: currentPath, historyPaths: history, historyIndex: history.count - 1, treeRootPath: root,
            selectedTreeItemID: "location:/Volumes/Backup", leftPaneSubview: .favorites, view: TabViewState())
    }

    // T-29bd3543 F-676
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

    // T-594eb68d F-676
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

    // T-7174190f F-676
    @Test func followsTheDeepestMoveThatHoldsAPath() {
        // "/P" moved to "/Q", and "/P/A" inside it to "/Q/B": the deepest move decides.
        let moves = [PathMove(from: "/P", to: "/Q"), PathMove(from: "/P/A", to: "/Q/B")]
        #expect(ExplorerTabs.followMovedPath("/P/A", moves) == "/Q/B")
        #expect(ExplorerTabs.followMovedPath("/P/A/x", moves) == "/Q/B/x")
        #expect(ExplorerTabs.followMovedPath("/P/C", moves) == "/Q/C")
        #expect(ExplorerTabs.followMovedPath("/Elsewhere", moves) == "/Elsewhere")
    }
}
