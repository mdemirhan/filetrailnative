// What each kind of write does to search results: what it removed, renamed and put somewhere, and whether it acted on them
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

private let home = "/Users/demo"
private let root = "/Users/demo/Project"

private func item(
    _ from: String?, _ to: String?, _ status: CopyPasteItemResult.Status = .completed
) -> WriteOperationItem {
    WriteOperationItem(sourcePath: from, destinationPath: to, status: status)
}

private func write(
    _ action: WriteOperationAction, _ items: [WriteOperationItem], mode: CopyPasteMode? = nil, target: String? = nil,
    replaced: [String]? = nil
) -> SearchAfterWrite {
    let started = Date(timeIntervalSince1970: 0)
    let result = WriteOperationResult(
        operationId: "op", action: action, mode: mode, status: .completed, targetPath: target, startedAt: started,
        finishedAt: started,
        summary: CopyPasteOperationSummary(
            topLevelItemCount: items.count, totalItemCount: items.count,
            completedItemCount: items.filter { $0.status == .completed }.count, failedItemCount: 0,
            skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
        items: items, replacedPaths: replaced, error: nil)
    return SearchAfterWrite(result, homePath: home)
}

private func keys(_ paths: [String]) -> Set<ExactPath> { Set(paths.map(ExactPath.init)) }

@Suite struct SearchAfterWriteTests {
    private let a = root + "/a.txt"
    private let docs = root + "/Docs"
    private let outside = "/Users/demo/Elsewhere"
    private let trash = home + "/.Trash"

    // MARK: Taken away

    // Moved to the Trash: removed, and nothing arrived anywhere a search finds.
    @Test func movedToTheTrashIsRemoved() {
        let effect = write(.trash, [item(a, trash + "/a.txt"), item(docs, trash + "/Docs")])
        #expect(effect.removed == [a, docs])
        #expect(effect.renamed.isEmpty)
        #expect(effect.arrived.isEmpty)
        #expect(!effect.addsInside(root))
        #expect(!effect.addsInside(home))
    }

    // Deleted immediately: removed.
    @Test func deletedIsRemoved() {
        let effect = write(.deleteImmediately, [item(a, nil)])
        #expect(effect.removed == [a])
        #expect(effect.arrived.isEmpty)
    }

    // Moved into another folder outside the search: removed, arrived outside it.
    @Test func movedOutIsRemoved() {
        let effect = write(.moveTo, [item(a, outside + "/a.txt")], target: outside)
        #expect(effect.removed == [a])
        #expect(effect.renamed.isEmpty)
        #expect(effect.arrived == [outside + "/a.txt"])
        #expect(!effect.addsInside(root))
    }

    // Moved into a folder inside the search: removed from where it was, and the search may find it where it went.
    @Test func movedIntoAFolderInsideIsRemovedAndAdded() {
        let effect = write(.moveTo, [item(a, docs + "/a.txt")], target: docs)
        #expect(effect.removed == [a])
        #expect(effect.addsInside(root))
    }

    // A paste of what was cut moves it; a paste of what was copied doesn't.
    @Test func aPasteOfACutMovesAndOfACopyDoesnt() {
        let cut = write(.paste, [item(a, outside + "/a.txt")], mode: .cut, target: outside)
        #expect(cut.removed == [a])
        let copied = write(.paste, [item(a, outside + "/a.txt")], mode: .copy, target: outside)
        #expect(copied.removed.isEmpty)
        #expect(copied.arrived == [outside + "/a.txt"])
    }

    // MARK: Renamed

    // Renamed in its own folder: renamed, nothing removed or added.
    @Test func renamedInPlace() {
        let effect = write(.rename, [item(a, root + "/b.txt")])
        #expect(effect.renamed == [SearchResultRename(from: a, to: root + "/b.txt")])
        #expect(effect.removed.isEmpty)
        #expect(effect.arrived.isEmpty)
        #expect(!effect.addsInside(root))
    }

    // A batch rename renames each item.
    @Test func aBatchRenameRenamesEach() {
        let effect = write(.batchRename, [item(a, root + "/1.txt"), item(root + "/b.txt", root + "/2.txt")])
        #expect(effect.renamed.map(\.to) == [root + "/1.txt", root + "/2.txt"])
        #expect(!effect.addsInside(root))
    }

    // An Undo that renames back renames; one that moves back into the search's folder adds inside it; one that moved
    // an item to the Trash removes it.
    @Test func undoRenamesMovesAndRemoves() {
        let renamedBack = write(.undo, [item(root + "/b.txt", a)])
        #expect(renamedBack.renamed == [SearchResultRename(from: root + "/b.txt", to: a)])
        #expect(!renamedBack.addsInside(root))
        let movedBack = write(.undo, [item(outside + "/a.txt", a)])
        #expect(movedBack.removed == [outside + "/a.txt"])
        #expect(movedBack.addsInside(root))
        let putBack = write(.undo, [item(trash + "/a.txt", a)])
        #expect(putBack.addsInside(root))
        let madeUndone = write(.undo, [item(docs, nil)])
        #expect(madeUndone.removed == [docs])
    }

    // MARK: Added

    // Copied, duplicated, made: nothing removed, added where it went.
    @Test func copiesAndNewItemsAreAdded() {
        for action in [WriteOperationAction.copyTo, .duplicate, .newFolder, .pasteAsFile, .compress, .extract] {
            let effect = write(action, [item(a, docs + "/a copy.txt")], target: docs)
            #expect(effect.removed.isEmpty, "\(action)")
            #expect(effect.renamed.isEmpty, "\(action)")
            #expect(effect.addsInside(root), "\(action)")
            #expect(!effect.addsInside(outside), "\(action)")
        }
    }

    // A Replace's item keeps its result: another item is at its path.
    @Test func aReplacedItemKeepsItsResult() {
        let effect = write(.copyTo, [item(outside + "/a.txt", a)], target: root, replaced: [a])
        #expect(effect.removed.isEmpty)
        #expect(effect.addsInside(root))
    }

    // MARK: Partly done

    // Only what was done counts: an item that failed or was skipped is neither removed nor added.
    @Test func onlyWhatWasDoneCounts() {
        let effect = write(
            .moveTo,
            [item(a, docs + "/a.txt", .failed), item(root + "/b.txt", docs + "/b.txt", .skipped)], target: docs)
        #expect(effect.removed.isEmpty)
        #expect(effect.arrived.isEmpty)
        #expect(!effect.addsInside(root))
        let trashed = write(.trash, [item(a, trash + "/a.txt", .failed)])
        #expect(trashed.removed.isEmpty)
    }

    // MARK: Acting on the results

    // A write acts on results when one of its items is a result, or it put items into a folder found; not when it
    // only touched something else inside the search's folder.
    @Test func actsOnResultsByItsItemsOrWhereItWent() {
        let results = keys([a, docs])
        #expect(write(.trash, [item(a, trash + "/a.txt")]).actsOn(results))
        #expect(write(.rename, [item(a, root + "/b.txt")]).actsOn(results))
        #expect(write(.copyTo, [item(outside + "/x.txt", docs + "/x.txt")], target: docs).actsOn(results))
        #expect(write(.moveTo, [item(outside + "/x.txt", docs + "/x.txt")]).actsOn(results))
        #expect(!write(.trash, [item(root + "/other.txt", trash + "/other.txt")]).actsOn(results))
        #expect(!write(.copyTo, [item(outside + "/x.txt", root + "/x.txt")], target: root).actsOn(results))
        let intoInner = write(.copyTo, [item(outside + "/x.txt", docs + "/Inner/x.txt")], target: docs + "/Inner")
        #expect(!intoInner.actsOn(results))
        #expect(!write(.trash, [item(a, trash + "/a.txt")]).actsOn([]))
    }

    // What another app took away from a drag out of the results is removed, and acts on them.
    @Test func whatWasDraggedAwayIsRemoved() {
        let effect = SearchAfterWrite(draggedAway: [a])
        #expect(effect.removed == [a])
        #expect(effect.actsOn(keys([a])))
        #expect(!effect.actsOn(keys([docs])))
        #expect(!effect.addsInside(root))
    }
}
