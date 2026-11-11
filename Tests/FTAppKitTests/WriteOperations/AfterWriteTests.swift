import FTFoundation
import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

private func result(
    _ action: WriteOperationAction, _ items: [WriteOperationItem], targetPath: String? = nil,
    mode: FTOperations.CopyPasteMode? = nil
) -> WriteOperationResult {
    WriteOperationResult(
        operationId: "op-1", action: action, mode: mode, status: .completed, targetPath: targetPath,
        startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
        summary: CopyPasteOperationSummary(
            topLevelItemCount: 1, totalItemCount: items.count, completedItemCount: items.count, failedItemCount: 0,
            skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
        items: items, error: nil)
}

private func item(
    _ sourcePath: String?, _ destinationPath: String?, _ status: CopyPasteItemResult.Status = .completed
) -> WriteOperationItem {
    WriteOperationItem(sourcePath: sourcePath, destinationPath: destinationPath, status: status)
}

@Suite struct AfterWriteTests {
    // What a write made is selected, unless results are showing, the person picked
    // something else meanwhile, or it landed in another folder than the one on screen.
    @Test func whatAWriteMadeIsSelectedOnlyInTheFolderOnScreenWithNothingElsePicked() {
        let pasted = result(
            .paste,
            [
                item("/Users/demo/a.txt", "/Users/demo/Folder/a.txt"),
                item("/Users/demo/b.txt", "/Users/demo/Folder/b.txt"),
                item("/Users/demo/c.txt", "/Users/demo/Folder/c.txt", .failed),
            ], targetPath: "/Users/demo/Folder")
        func selection(in folder: String = "/Users/demo/Folder", searching: Bool = false, changed: Bool = false)
            -> [String]?
        {
            AfterWrite.selection(pasted, currentPath: folder, isSearching: searching, selectionChanged: changed)
        }
        #expect(selection() == ["/Users/demo/Folder/a.txt", "/Users/demo/Folder/b.txt"])
        #expect(selection(searching: true) == nil)
        #expect(selection(changed: true) == nil)
        #expect(selection(in: "/Users/demo") == nil)
        #expect(
            AfterWrite.selection(
                result(.paste, [item("/Users/demo/a.txt", nil, .failed)], targetPath: "/Users/demo/Folder"),
                currentPath: "/Users/demo/Folder", isSearching: false, selectionChanged: false) == nil)
    }

    private let renamed = result(.rename, [item("/Users/demo/tmp/old-name", "/Users/demo/tmp/new-name")])

    @Test func remapsTheRefreshedPathAfterARenameInsideTheCurrentFolder() {
        #expect(AfterWrite.refreshPath(renamed, currentPath: "/Users/demo/tmp/old-name") == "/Users/demo/tmp/new-name")
        #expect(
            AfterWrite.refreshPath(renamed, currentPath: "/Users/demo/tmp/old-name/child/grandchild")
                == "/Users/demo/tmp/new-name/child/grandchild")
    }

    @Test func fallsBackToTheParentPathAfterTrashingTheSelectedTreeFolder() {
        let trashed = result(.trash, [item("/Users/demo/tmp/old-name", nil)])

        #expect(AfterWrite.refreshPath(trashed, currentPath: "/Users/demo/tmp/old-name") == "/Users/demo/tmp")
        #expect(
            AfterWrite.treeSelectionPath(trashed, selectedTreePath: "/Users/demo/tmp/old-name/child")
                == "/Users/demo/tmp")
    }

    @Test func followsAFolderMovedByCutAndPasteOrADragButNotOneCopied() {
        func pasted(_ mode: FTOperations.CopyPasteMode) -> WriteOperationResult {
            result(
                .paste, [item("/Users/demo/Folder", "/Users/demo/Other/Folder")], targetPath: "/Users/demo/Other",
                mode: mode)
        }

        #expect(
            AfterWrite.refreshPath(pasted(.cut), currentPath: "/Users/demo/Folder/Inner")
                == "/Users/demo/Other/Folder/Inner")
        #expect(
            AfterWrite.treeSelectionPath(pasted(.cut), selectedTreePath: "/Users/demo/Folder")
                == "/Users/demo/Other/Folder")
        #expect(
            AfterWrite.refreshPath(pasted(.copy), currentPath: "/Users/demo/Folder/Inner") == "/Users/demo/Folder/Inner"
        )
        #expect(AfterWrite.treeSelectionPath(pasted(.copy), selectedTreePath: "/Users/demo/Folder") == nil)
    }

    @Test func tellsWhatAWriteTookOutOfItsFolderTrashedDeletedOrMovedElsewhereNotRenamed() {
        func left(
            _ action: WriteOperationAction, _ from: String, _ to: String?, mode: FTOperations.CopyPasteMode? = nil
        )
            -> [String]
        {
            AfterWrite.pathsLeftByWrite(result(action, [item(from, to)], mode: mode))
        }

        #expect(left(.trash, "/a/x", nil) == ["/a/x"])
        #expect(left(.deleteImmediately, "/a/x", nil) == ["/a/x"])
        #expect(left(.moveTo, "/a/x", "/b/x") == ["/a/x"])
        #expect(left(.paste, "/a/x", "/b/x", mode: .cut) == ["/a/x"])
        // A rename stays in its folder, and a copy leaves the original where it was.
        #expect(left(.rename, "/a/x", "/a/y") == [])
        #expect(left(.paste, "/a/x", "/b/x", mode: .copy) == [])
    }

    @Test func remapsTreeSelectionAfterARenameWhenTheSelectedNodeIsInsideTheRenamedFolder() {
        #expect(
            AfterWrite.treeSelectionPath(renamed, selectedTreePath: "/Users/demo/tmp/old-name/child")
                == "/Users/demo/tmp/new-name/child")
    }

    @Test func remapsTreeSelectionAfterARenameWhenTheRenamedFolderItselfIsSelected() {
        #expect(
            AfterWrite.treeSelectionPath(renamed, selectedTreePath: "/Users/demo/tmp/old-name")
                == "/Users/demo/tmp/new-name")
    }

    @Test func reloadsImpactedDestinationBranchesAsWellAsTheirParentsForACompletedSubtreeMove() {
        let moved = result(
            .moveTo,
            [
                item("/Users/demo/source-folder", "/Users/demo/target/source-folder"),
                item("/Users/demo/source-folder/child.txt", "/Users/demo/target/source-folder/child.txt"),
                item(
                    "/Users/demo/source-folder/nested/deep.txt", "/Users/demo/target/source-folder/nested/deep.txt"),
            ])

        #expect(
            AfterWrite.treeReloadPaths(moved) == [
                "/Users/demo", "/Users/demo/target", "/Users/demo/target/source-folder",
            ])
    }
}

// A window other than the one that ran an operation is sent only the items it needs of the result
// (itemsForOtherWindows). What it does with them must come out as with all of them: the folder sizes it forgets and
// the folders its tabs follow.
@Suite struct OtherWindowsWriteResultTests {
    private func tab(at path: String) -> TabSnapshot {
        TabSnapshot(
            currentPath: path, historyPaths: [path], historyIndex: 0, treeRootPath: path,
            selectedTreeItemID: "fs:\(path)")
    }

    private func moves(_ result: WriteOperationResult) -> [PathMove] {
        ExplorerTabs.collectFollowedMoves(result.action, items: result.items)
    }

    // Every path the items name, the folders above them, and a few inside them.
    private func probes(_ full: WriteOperationResult) -> [String] {
        var probes: Set<String> = ["/", "/Users", "/elsewhere/x"]
        for path in full.changedPaths {
            let scalars = Array(path.unicodeScalars)
            for index in 1...scalars.count where index == scalars.count || scalars[index] == "/" {
                probes.insert(String(String.UnicodeScalarView(scalars[..<index])))
            }
            probes.insert("\(path)/inside")
            probes.insert("\(path)/inside/deeper")
            probes.insert("\(path) 2")
        }
        return probes.sorted()
    }

    @discardableResult
    private func expectSameForOtherWindows(_ full: WriteOperationResult) -> WriteOperationResult {
        var compact = full
        compact.items = full.itemsForOtherWindows
        let fullChanges = ChangeMatcher(changedPaths: full.changedPaths)
        let compactChanges = ChangeMatcher(changedPaths: compact.changedPaths)
        let fullMoves = moves(full)
        let compactMoves = moves(compact)
        for probe in probes(full) {
            // Folder sizes: forgotten at or inside a change, measured again around one.
            #expect(compactChanges.holdsChange(probe) == fullChanges.holdsChange(probe), "\(probe)")
            #expect(compactChanges.isAtOrInsideChange(probe) == fullChanges.isAtOrInsideChange(probe), "\(probe)")
            // Tabs: where a tab showing the probe goes.
            #expect(
                ExplorerTabs.followMovedItems(tab(at: probe), compactMoves)
                    == ExplorerTabs.followMovedItems(tab(at: probe), fullMoves), "\(probe)")
        }
        return compact
    }

    @Test func leavesOutAllButOneItemInEachFolderInsideAPastedFolder() {
        func inFolder(_ path: String, _ status: CopyPasteItemResult.Status = .completed) -> WriteOperationItem {
            item("/Users/me/Folder\(path)", "/Users/me/b/Folder\(path)", status)
        }
        let compact = expectSameForOtherWindows(
            result(
                .paste,
                [inFolder("")] + ["a", "b", "c"].map { inFolder("/\($0).txt") } + [
                    inFolder("/Inner/d.txt", .failed), inFolder("/Inner/e.txt"),
                    item("/Users/me/f.txt", "/Users/me/b/f.txt"),
                ], targetPath: "/Users/me/b"))
        #expect(
            compact.items.map(\.sourcePath) == [
                "/Users/me/Folder", "/Users/me/Folder/a.txt", "/Users/me/Folder/Inner/d.txt", "/Users/me/f.txt",
            ])
    }

    @Test func keepsWhatMovedInsideAFolderWhoseOwnMoveFailed() {
        let compact = expectSameForOtherWindows(
            result(
                .moveTo,
                [
                    item("/Users/me/Folder", "/Volumes/Disk/Folder", .failed),
                    item("/Users/me/Folder/a.txt", "/Volumes/Disk/Folder/a.txt"),
                    item("/Users/me/Folder/Inner", "/Volumes/Disk/Folder/Inner"),
                    item("/Users/me/Folder/Inner/b.txt", "/Volumes/Disk/Folder/Inner/b.txt"),
                    item("/Users/me/Folder/Inner/c.txt", "/Volumes/Disk/Folder/Inner/c.txt"),
                ]))
        #expect(
            compact.items.map(\.sourcePath) == [
                "/Users/me/Folder", "/Users/me/Folder/a.txt", "/Users/me/Folder/Inner", "/Users/me/Folder/Inner/b.txt",
            ])
    }

    @Test func keepsARenamedItemPutBackUnderAnotherName() {
        expectSameForOtherWindows(
            result(
                .batchRename,
                [
                    item("/Users/me/a", "/Users/me/b"), item("/Users/me/b", "/Users/me/b 2", .failed),
                    item("/Users/me/a/x", "/Users/me/b/x", .failed),
                ]))
    }

    @Test func keepsEveryItemATrashOrAnUndoMovedOnItsOwn() {
        expectSameForOtherWindows(
            result(.trash, [item("/Users/me/a", nil), item("/Users/me/a/b", nil), item("/Users/me/c", nil, .failed)]))
        expectSameForOtherWindows(
            result(
                .undo,
                [
                    item("/Users/me/b/Folder", "/Users/me/Folder"), item("/Users/me/copy.txt", nil),
                    item("/Users/me/Folder/x", "/Users/me/x", .skipped),
                ]))
    }

    // Paths drawn from a few names, so that items fall inside one another in every way.
    @Test func doesAsAllTheItemsWouldForAnyOperation() {
        // In doubles, as JavaScript multiplies them.
        var seed = 7.0
        func random(_ count: Int) -> Int {
            seed = (seed * 1_103_515_245 + 12_345).truncatingRemainder(dividingBy: 2_147_483_648)
            return Int(seed.truncatingRemainder(dividingBy: Double(count)))
        }
        let names = ["a", "b", "a b", "c"]
        func randomPath() -> String {
            var path = "/u"
            var depth = random(4)
            while depth >= 0 {
                path += "/\(names[random(names.count)])"
                depth -= 1
            }
            return path
        }
        let actions: [WriteOperationAction] = [.paste, .moveTo, .rename, .batchRename, .undo]
        let statuses: [CopyPasteItemResult.Status] = [.completed, .failed, .skipped, .cancelled]
        for _ in 0..<300 {
            let count = 1 + random(8)
            var items: [WriteOperationItem] = []
            for _ in 0..<count {
                let source = random(10) == 0 ? nil : randomPath()
                let destination = random(6) == 0 ? nil : randomPath()
                items.append(item(source, destination, statuses[random(statuses.count)]))
            }
            let action = actions[random(actions.count)]
            expectSameForOtherWindows(result(action, items, targetPath: random(2) == 0 ? randomPath() : nil))
        }
    }

    // A Trash or a move of 20,000 items from one folder ends without holding up the window: what is read again and
    // what left the folder take time in proportion to the paths, not to their square.
    @Test func whatAWriteOfManyItemsLeavesBehindIsWorkedOutQuickly() {
        let count = 20_000
        let trashed = result(
            .trash, (0..<count).map { item("/Users/demo/Big/file-\($0)", "/Users/demo/.Trash/file-\($0)") })
        let moved = result(
            .paste, (0..<count).map { item("/Users/demo/Big/file-\($0)", "/Users/demo/Other/file-\($0)") },
            targetPath: "/Users/demo/Other", mode: .cut)

        let (outcome, seconds) = CPUTime.measureThread {
            (
                AfterWrite.treeReloadPaths(trashed), AfterWrite.pathsLeftByWrite(trashed),
                AfterWrite.treeReloadPaths(moved), AfterWrite.pathsLeftByWrite(moved)
            )
        }

        #expect(outcome.0.count == count + 2)
        #expect(outcome.1.count == count)
        #expect(outcome.2.count == count + 2)
        #expect(outcome.3.count == count)
        #expect(seconds < 2, "took \(seconds) s of CPU time")
    }
}
