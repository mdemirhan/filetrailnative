// Port of apps/desktop/src/main/bootstrap/undoExecution.test.ts: Undo and Redo on a real disk, through the write
// coordinator as the app runs them: each operation's round trip, chains, and what happens when things changed in
// between.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoExecutionTests {
    private func items(_ end: WriteOperationEvent) -> [WriteOperationItem] { end.result?.items ?? [] }

    // MARK: Round trips

    // T-ea9b354f F-550
    @Test func renamesBackAndAgainOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.rename("\(root)/a.txt", "b.txt")
            let after = t.snapshot()
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(t.snapshot() == after)
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-3c41e3ea F-550
    @Test func renamesBackANameThatDiffersOnlyInCase() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/notes.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.rename("\(root)/notes.txt", "Notes.txt")
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            await t.shutDown()
        }
    }

    // T-981c0a07 F-550
    @Test func movesANewFolderToTheTrashAndPutsItBackOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.newFolder(root, "New")
            let after = t.snapshot()
            try await t.undo()
            #expect(t.snapshot() == before)
            #expect(t.inTrash() == ["1-New"])
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            #expect(t.inTrash() == [])
            await t.shutDown()
        }
    }

    // T-aa24d610 F-550
    @Test func putsItemsBackFromTheTrashAndMovesThemThereAgainOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.mkdir("\(root)/Folder")
            try UndoDisk.write("\(root)/Folder/inside.txt", "inside")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.trash("\(root)/a.txt", "\(root)/Folder")
            #expect(t.history.menu().undo == "Move to Trash of 2 Items")
            let undone = try await t.undo()
            #expect(t.snapshot() == before)
            #expect(t.inTrash() == [])
            // A put back reads as a move out of the Trash.
            #expect(
                items(undone).contains {
                    $0.sourcePath == "\(trashDir)/1-a.txt" && $0.destinationPath == "\(root)/a.txt"
                        && $0.status == .completed
                })
            try await t.undo(.redo)
            #expect(!UndoDisk.exists("\(root)/a.txt"))
            #expect(t.inTrash().count == 2)
            try await t.undo()
            #expect(t.snapshot() == before)
            await t.shutDown()
        }
    }

    // T-88dc2daa F-392 F-550
    @Test func renamesABatchBackSwapsAndAFolderWithItemsInItIncluded() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            try UndoDisk.mkdir("\(root)/F")
            try UndoDisk.write("\(root)/F/c.txt", "c")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.batchRename([
                ("\(root)/a.txt", "b.txt", false), ("\(root)/b.txt", "a.txt", false), ("\(root)/F", "G", true),
                ("\(root)/F/c.txt", "d.txt", false),
            ])
            let after = t.snapshot()
            #expect(try UndoDisk.read("\(root)/G/d.txt") == "c")
            try await t.undo()
            #expect(t.snapshot() == before)
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    // T-e1df851a F-550
    @Test func movesCopiesToTheTrashAndPutsThemBackOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            try UndoDisk.mkdir("\(root)/src/Folder")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.paste(.copy, ["\(root)/src/a.txt", "\(root)/src/Folder"], into: "\(root)/dst")
            let after = t.snapshot()
            #expect(t.history.menu().undo == "Copy of 2 Items")
            try await t.undo()
            #expect(t.snapshot() == before)
            #expect(t.inTrash() == ["1-Folder", "2-a.txt"])
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    // T-f6ece398 F-550
    @Test func movesMovedItemsBack() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.paste(.cut, ["\(root)/src/a.txt"], into: "\(root)/dst")
            let after = t.snapshot()
            try await t.undo()
            #expect(t.snapshot() == before)
            try await t.undo(.redo)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    // T-2ffebec7 F-550
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func takesBackAReplaceTheNewItemAwayTheOldOneBackInItsPlace(mode: CopyPasteMode) async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.write("\(root)/src/a.txt", "new")
            try UndoDisk.write("\(root)/dst/a.txt", "old")
            let pasteTrash = "\(root)/paste-trash"
            try UndoDisk.mkdir(pasteTrash)
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot().filter { !$0.hasPrefix("paste-trash") }
            try await t.paste(
                mode, ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(pasteTrash))
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "new")
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot().filter { !$0.hasPrefix("paste-trash") } == before)
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "old")
            #expect(UndoDisk.names(pasteTrash) == [])
            // And done again.
            try await t.undo(.redo)
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "new")
            #expect(UndoDisk.exists("\(root)/src/a.txt") == (mode == .copy))
            await t.shutDown()
        }
    }

    // T-558c08ab F-550
    @Test func doesntAskAboutANewFolderAnItemWasMovedIntoAndBackOutOf() async throws {
        // A folder's date changes with every item in or out, so it must not count as a change.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.newFolder(root, "F")
            try await t.paste(.cut, ["\(root)/a.txt"], into: "\(root)/F")
            try await t.undo()
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            await t.shutDown()
        }
    }

    // T-d5da06b6 F-550
    @Test func doesntAskAboutANewFolderFinderWroteItsViewSettingsInto() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.newFolder(root, "F")
            try UndoDisk.write("\(root)/F/.DS_Store", "Finder")
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/F"))
            await t.shutDown()
        }
    }

    // T-8a92a9bd F-550
    @Test func undoesAChainOfOperationsOneByOneBackToTheStart() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.rename("\(root)/a.txt", "b.txt")
            try await t.newFolder(root, "F")
            try await t.paste(.cut, ["\(root)/b.txt"], into: "\(root)/F")
            try await t.trash("\(root)/F")
            for _ in 0..<4 {
                #expect(try await t.undo().status == .completed)
            }
            #expect(t.snapshot() == before)
            #expect(t.history.menu().undo == nil)
            await t.shutDown()
        }
    }

    // MARK: Changes made outside the app

    // T-2ba9b3c0 F-551
    @Test func skipsAnItemThatIsGoneSaysSoAndForgetsTheOperation() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            try UndoDisk.remove("\(root)/b.txt")
            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(items(undone).first?.error == "“b.txt” is no longer in “\(NodePath.basename(root))”.")
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-6314cb7d F-551
    @Test func asksWhenAnOldNameIsTakenThenPutsTheItemBackWithANumber() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/a.txt", "\(root)/b.txt")
            try UndoDisk.write("\(root)/a.txt", "someone else's")
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken == ["a.txt"])
            #expect(prepared.changed.isEmpty)
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(root)/a.txt") == "someone else's")
            #expect(try UndoDisk.read("\(root)/a 2.txt") == "a")
            #expect(try UndoDisk.read("\(root)/b.txt") == "b")
            // Redo moves the very item back to the Trash, under whatever name it has now.
            try await t.undo(.redo)
            #expect(!UndoDisk.exists("\(root)/a 2.txt"))
            await t.shutDown()
        }
    }

    // T-1273e179 F-551
    @Test func putsAnItemBackWithANumberInAFolderWhoseNameIsTaken() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/F")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/F")
            try UndoDisk.mkdir("\(root)/F")
            try await t.undo()
            #expect(UndoDisk.isDirectory("\(root)/F 2"))
            await t.shutDown()
        }
    }

    // T-3c68e7d4 F-551
    @Test func asksBeforeMovingACopyThatChangedToTheTrashSayingItIsADuplicate() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/src/a.txt"], into: "\(root)/src", action: .duplicate)
            try UndoDisk.write("\(root)/src/a copy.txt", "edited since")
            let prepared = try await t.prepare()
            #expect(prepared.action == .duplicate)
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed == [UndoQuestion.ChangedItem(name: "a copy.txt", putBack: false, replaced: false)])
            try await t.undo()
            #expect(!UndoDisk.exists("\(root)/src/a copy.txt"))
            // The edits went to the Trash with it, and come back with Redo.
            try await t.undo(.redo)
            #expect(try UndoDisk.read("\(root)/src/a copy.txt") == "edited since")
            await t.shutDown()
        }
    }

    // T-260d2dc9 F-551
    @Test func movesACopiedFolderSomethingWasAddedToTheTrashOnceAgreed() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src/Folder")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/src/Folder"], into: "\(root)/src", action: .duplicate)
            // An item added right inside the copied folder.
            try UndoDisk.write("\(root)/src/Folder copy/added.txt", "added")
            #expect(
                try await t.prepare().changed
                    == [UndoQuestion.ChangedItem(name: "Folder copy", putBack: false, replaced: false)])
            try await t.undo()
            #expect(!UndoDisk.exists("\(root)/src/Folder copy"))
            #expect(t.inTrash() == ["1-Folder copy"])
            await t.shutDown()
        }
    }

    // T-a3b8a2ae F-551
    @Test func neverMovesAnotherItemThatTookACopysNameToTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/src/a.txt"], into: "\(root)/src", action: .duplicate)
            try UndoDisk.remove("\(root)/src/a copy.txt")
            try UndoDisk.mkdir("\(root)/src/a copy.txt")
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(items(undone).first?.error == "The “a copy.txt” in “src” is another item now.")
            #expect(UndoDisk.exists("\(root)/src/a copy.txt"))
            #expect(t.inTrash() == [])
            await t.shutDown()
        }
    }

    // T-3ed5ef1f F-551
    @Test func stillRenamesBackAFileAnAppSavedUnderANewId() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            // Saved the way many apps save: a new file takes the old one's place.
            try UndoDisk.write("\(root)/b.tmp", "saved")
            try UndoDisk.move("\(root)/b.tmp", "\(root)/b.txt")
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(root)/a.txt") == "saved")
            await t.shutDown()
        }
    }

    // T-f809c560 F-551
    @Test func doesntMoveAnItemBackIntoAFolderThatIsGoneOrWasReplaced() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(root)/src/a.txt"], into: "\(root)/dst")
            try UndoDisk.remove("\(root)/src")
            let gone = try await t.undo()
            #expect(items(gone).map(\.status) == [.skipped])
            #expect(items(gone).first?.error == "Its folder “src” no longer exists.")
            try await t.paste(.cut, ["\(root)/dst/a.txt"], into: root)
            try UndoDisk.remove("\(root)/dst")
            try UndoDisk.mkdir("\(root)/dst")
            let replaced = try await t.undo()
            #expect(items(replaced).map(\.status) == [.skipped])
            #expect(items(replaced).first?.error == "Its folder “dst” was replaced by another folder.")
            #expect(UndoDisk.exists("\(root)/a.txt"))
            await t.shutDown()
        }
    }

    // T-41c11e28 F-551
    @Test func skipsAnItemEmptiedFromTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/a.txt")
            try UndoDisk.remove("\(trashDir)/1-a.txt")
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(items(undone).first?.error == "“a.txt” isn't in the Trash any more.")
            await t.shutDown()
        }
    }

    private func pasteReplacing(_ t: UndoTest, _ root: String, mode: CopyPasteMode = .copy) async throws -> String {
        try UndoDisk.mkdir("\(root)/src")
        try UndoDisk.mkdir("\(root)/dst")
        try UndoDisk.write("\(root)/src/a.txt", "new")
        try UndoDisk.write("\(root)/dst/a.txt", "old")
        let pasteTrash = "\(root)/paste-trash"
        try UndoDisk.mkdir(pasteTrash)
        try await t.paste(
            mode, ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
            fileSystem: NativePaste.withTrash(pasteTrash))
        return pasteTrash
    }

    // T-3092bca3 F-551
    @Test func putsAReplacedItemBackEvenWhenTheNewOneIsGoneAlready() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await pasteReplacing(t, root)
            try UndoDisk.remove("\(root)/dst/a.txt")
            try await t.undo()
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "old")
            await t.shutDown()
        }
    }

    // T-ec616fcd F-551
    @Test func leavesAReplacedItemInTheTrashWhileTheNewOneCantBeMovedAway() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            let pasteTrash = try await pasteReplacing(t, root)
            // Another item takes the new one's place before Undo.
            try UndoDisk.remove("\(root)/dst/a.txt")
            try UndoDisk.mkdir("\(root)/dst/a.txt")
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken.isEmpty)
            #expect(prepared.changed.isEmpty)
            let undone = try await t.undo()
            #expect(UndoDisk.isDirectory("\(root)/dst/a.txt"))
            #expect(UndoDisk.names(pasteTrash) == ["1-a.txt"])
            #expect(items(undone).map(\.status) == [.skipped, .skipped])
            #expect(
                items(undone).last?.error
                    == "“a.txt” was left in the Trash, because the item in its place couldn't be moved away.")
            await t.shutDown()
        }
    }

    // MARK: Running an Undo

    // T-738ac153 F-246 F-552
    @Test func hasNothingToUndoOrRedoAtFirst() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            let prepared = try await t.prepare()
            let redo = try await t.prepare(.redo)
            #expect(
                prepared
                    == UndoPrepared(ticket: nil, refusal: .nothing, label: nil, action: nil, nameTaken: [], changed: [])
            )
            #expect(redo.refusal == .nothing)
            await t.shutDown()
        }
    }

    // T-81d56946 F-386 F-552
    // T-c2f18eb0
    @Test func isRefusedWhileAnotherOperationHoldsTheWriteSlot() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            let held = HeldCall()
            let coordinator = t.coordinator
            DispatchQueue.global().async { _ = coordinator.runWriteAlone { held.hold() } }
            _ = try await Coordinators.waitFor { held.hasBegun ? true : nil }
            let busy = try await t.prepare()
            #expect(busy.ticket == nil)
            #expect(busy.refusal == .busy)
            held.release()
            _ = try await Coordinators.waitFor { coordinator.slotHolder == nil ? true : nil }
            #expect(try await t.prepare().ticket != nil)
            await t.shutDown()
        }
    }

    // T-8c6c71d1 F-386 F-395 F-552
    @Test func saysItCantUndoAfterAnOperationThatCantBeUndone() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(trashDir)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.finish(t.coordinator.deleteImmediately(paths: ["\(trashDir)/a.txt"], window: t.window))
            let prepared = try await t.prepare()
            #expect(prepared.ticket == nil)
            #expect(prepared.refusal == .cantUndo)
            #expect(try await t.prepare(.redo).refusal == .nothing)
            await t.shutDown()
        }
    }

    // T-4fd4220c F-388 F-552
    @Test func refusesToStartFromAQuestionAskedBeforeTheHistoryChanged() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            let prepared = try await t.prepare()
            try await t.newFolder(root, "F")
            let changed = WriteCoordinatorError("Something changed since Undo was chosen. Choose it again.")
            await #expect(throws: changed) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            await #expect(throws: changed) {
                try await t.coordinator.startUndo(ticket: "sideways:1:1", window: t.window)
            }
            await t.shutDown()
        }
    }

    // T-c4a50a12 F-389 F-552
    @Test func stopsBetweenItemsWhenToldToAndGoesOnFromThereNextTime() async throws {
        try await withUndoFolder { root, trashDir in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try UndoDisk.write("\(root)/\(name)", name)
            }
            let held = HeldCall()
            let renames = Counter()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if renames.next() == 1 { held.hold() }
                    try UndoDisk.move(from, to)
                }
            }
            let before = t.snapshot()
            try await t.trash("\(root)/a.txt", "\(root)/b.txt", "\(root)/c.txt")
            let prepared = try await t.prepare()
            let handle = try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            _ = try await Coordinators.waitFor { held.hasBegun ? true : nil }
            t.coordinator.cancel(handle.operationId, window: t.window)
            held.release()
            let stopped = try await t.finish(handle)
            #expect(stopped.status == .partial)
            #expect(stopped.result?.error == "Stopped after 1 item was undone.")
            #expect(UndoDisk.exists("\(root)/c.txt"))
            #expect(!UndoDisk.exists("\(root)/a.txt"))
            #expect(t.history.menu().undo == "Move to Trash of 2 Items")
            #expect(t.history.menu().redo == "Move to Trash of “c.txt”")
            try await t.undo()
            #expect(t.snapshot() == before)
            await t.shutDown()
        }
    }

    // T-f81310a1 F-552
    @Test func reportsAnItemItCouldntMoveBackAndLeavesItWhereItIs() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            let failing = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { _, _ in throw codedError("EACCES", "EACCES: permission denied") }
            }
            failing.history.record(
                FinishedWrite(
                    action: .write(.rename), log: .undoable(units: t.history.top(.undo)?.units ?? []), items: []))
            let undone = try await failing.undo()
            #expect(undone.status == .failed)
            #expect(items(undone).map(\.status) == [.failed])
            #expect(items(undone).first?.error?.contains("permission") == true)
            #expect(UndoDisk.exists("\(root)/b.txt"))
            await t.shutDown()
            await failing.shutDown()
        }
    }

    // T-9cd8ffff F-249 F-552
    @Test func neverDeletesACopyWhoseDiskTurnsOutToHaveNoTrash() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw noTrashError() }
            }
            try await t.paste(.copy, ["\(root)/src/a.txt"], into: "\(root)/src", action: .duplicate)
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(
                items(undone).first?.error
                    == "“a copy.txt” couldn't be moved to the Trash because its disk has no Trash.")
            #expect(UndoDisk.exists("\(root)/src/a copy.txt"))
            await t.shutDown()
        }
    }

    // MARK: The rarer paths

    // T-5a36a5ce F-390 F-553
    @Test func numbersTheNameWhenAnotherItemTakesItJustAsTheItemGoesBack() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let raced = Counter()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    // Another app takes the name between the check and the move, once.
                    if to == "\(root)/a.txt", raced.next() == 1 {
                        try UndoDisk.write(to, "someone else's")
                        throw codedError("EEXIST", "EEXIST: file exists")
                    }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.trash("\(root)/a.txt")
            try await t.undo()
            #expect(try UndoDisk.read("\(root)/a.txt") == "someone else's")
            #expect(try UndoDisk.read("\(root)/a 2.txt") == "a")
            await t.shutDown()
        }
    }

    // T-f5bec5b1 F-553
    @Test func leavesTheItemWhereItIsWhenEveryNameItTriesIsTakenJustThen() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if to.hasPrefix("\(root)/a") {
                        try UndoDisk.write(to, "someone else's")
                        throw codedError("EEXIST", "EEXIST: file exists")
                    }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.trash("\(root)/a.txt")
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(
                items(undone).first?.error == "An item named “a 3.txt” is already in “\(NodePath.basename(root))”.")
            #expect(t.inTrash() == ["1-a.txt"])
            await t.shutDown()
        }
    }

    // T-f4e8a0a5 F-553
    @Test func reportsACopyTheTrashRefusedAndLeavesIt() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.write("\(root)/src/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw codedError("EPERM", "EPERM: operation not permitted") }
            }
            try await t.paste(.copy, ["\(root)/src/a.txt"], into: "\(root)/src", action: .duplicate)
            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(items(undone).map(\.status) == [.failed])
            #expect(items(undone).first?.error == "You don't have permission to access this item.")
            #expect(UndoDisk.exists("\(root)/src/a copy.txt"))
            await t.shutDown()
        }
    }

    // T-23726158 F-384 F-392 F-553
    @Test func renamesBackEveryItemOfABatchNumberingOneWhoseOldNameIsTaken() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.batchRename([("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt")])
            try UndoDisk.write("\(root)/a.txt", "someone else's")
            #expect(try await t.prepare().nameTaken == ["a.txt"])
            let undone = try await t.undo()
            #expect(undone.status == .completed)
            #expect(try UndoDisk.read("\(root)/b.txt") == "b")
            #expect(try UndoDisk.read("\(root)/a 2.txt") == "a")
            #expect(try UndoDisk.read("\(root)/a.txt") == "someone else's")
            await t.shutDown()
        }
    }

    // T-9197521e F-553
    @Test func doesNothingToABatchNoneOfWhoseItemsAreWhereTheyWere() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.batchRename([("\(root)/a.txt", "x.txt")])
            try UndoDisk.remove("\(root)/x.txt")
            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-191836d7 F-389 F-553
    @Test func stopsABatchPartWayWhenToldToAndGoesOnFromThereNextTime() async throws {
        try await withUndoFolder { root, trashDir in
            for name in ["a", "b", "c"] {
                try UndoDisk.write("\(root)/\(name).txt", name)
            }
            let before = UndoDisk.snapshot(root, skipping: trashDir)
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.batchRename([
                ("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt"), ("\(root)/c.txt", "z.txt"),
            ])
            let renames = Counter()
            let stop = StopButton()
            let stopping = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    let count = renames.next()
                    try UndoDisk.move(from, to)
                    if count == 1 { stop.press() }
                }
            }
            stop.test = stopping
            stopping.history.record(
                FinishedWrite(
                    action: .write(.batchRename), log: .undoable(units: t.history.top(.undo)?.units ?? []),
                    items: []))
            let stopped = try await stopping.undo()
            #expect(stopped.status == .partial)
            #expect(renames.count == 1)
            #expect(
                stopping.history.menu() == UndoMenuLabels(undo: "Rename of 2 Items", redo: "Rename", cantUndo: false))
            try await stopping.undo()
            #expect(t.snapshot() == before)
            await t.shutDown()
            await stopping.shutDown()
        }
    }

    // T-1ff54593 F-553
    @Test(arguments: [
        (CopyPasteMode.copy, "“a.txt” was left in the Trash"),
        (CopyPasteMode.cut, "“a.txt” was left as it is, because the step before it couldn't be redone."),
    ])
    func doesntRedoAReplacesSecondStepWhenItsFirstCantBe(mode: CopyPasteMode, message: String) async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await pasteReplacing(t, root, mode: mode)
            try await t.undo()
            // The old item, back in its place, is replaced by another one before Redo.
            try UndoDisk.remove("\(root)/dst/a.txt")
            try UndoDisk.mkdir("\(root)/dst/a.txt")
            let redone = try await t.undo(.redo)
            #expect(items(redone).map(\.status) == [.skipped, .skipped])
            #expect(items(redone).first?.error == "The “a.txt” in “dst” is another item now.")
            #expect(items(redone).last?.error?.contains(message) == true)
            await t.shutDown()
        }
    }

    // T-218c67d5 F-389 F-553
    @Test func doesntMoveALaterStepsItemToTheTrashOnceAnEarlierOneCouldntBeUndone() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/made.txt", "made")
            try UndoDisk.write("\(root)/b.txt", "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            let made = try PosixFileSystem().lstat("\(root)/made.txt")
            let moved = try PosixFileSystem().lstat("\(root)/b.txt")
            t.history.record(
                FinishedWrite(
                    action: .write(.paste),
                    log: .undoable(units: [
                        UndoUnit(steps: [
                            .created(path: "\(root)/made.txt", id: itemIdOf(made), stamp: nil),
                            .moved(
                                UndoStep.Moved(
                                    from: "\(root)/a.txt", to: "\(root)/b.txt",
                                    // Another item than the one moved: a file where a folder was.
                                    id: ItemId(dev: moved.dev ?? 0, ino: (moved.ino ?? 0) + 1_000_000),
                                    itemKind: .directory, parentId: nil)),
                        ])
                    ]), items: []))
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped, .skipped])
            #expect(
                items(undone).last?.error
                    == "“made.txt” was left as it is, because the step before it couldn't be undone.")
            #expect(UndoDisk.exists("\(root)/made.txt"))
            await t.shutDown()
        }
    }
}

/// A count the disk threads of a test go up, one call at a time.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The count after this call (1 for the first).
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}
