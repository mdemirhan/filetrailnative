// Port of apps/desktop/src/main/bootstrap/undoExecution.failures.test.ts: what an Undo leaves to do: a step whose write
// failed stays on the Undo list to be tried again, a stopped Undo goes on from where it stopped, and what changed
// outside the app is dropped. Redo only ever does again what Undo really did.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoFailuresTests {
    private func items(_ end: WriteOperationEvent) -> [WriteOperationItem] { end.result?.items ?? [] }

    private func permissionDenied() -> OperationError { codedError("EACCES", "EACCES: permission denied") }

    private func snapshot(_ t: UndoTest) -> [String] {
        t.snapshot().filter { !$0.hasPrefix("paste-trash") }
    }

    // T-6f8df3a6 F-379 F-554
    @Test func keepsTheOperationOnTheUndoListAndUndoesItOnceItCanBeRead() async throws {
        // A folder that can't be read for a moment (no permission, a share that doesn't answer) hides whether the
        // item is there: it isn't taken for gone.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let unreadable = UndoFlag()
            let denied = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.lstatImpl = { path in
                    if unreadable.isSet && path == "\(root)/b.txt" { throw denied }
                    return try base.lstat(path)
                }
            }
            try await t.rename("\(root)/a.txt", "b.txt")
            let entry = t.history.top(.undo)
            unreadable.set(true)
            let failed = try await t.undo()
            #expect(failed.status == .failed)
            #expect(
                items(failed).first?.error
                    == "“b.txt” couldn't be checked: You don't have permission to access this item.")
            #expect(t.history.top(.undo) == entry)
            unreadable.set(false)
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names(root) == [".Trash", "a.txt"])
            await t.shutDown()
        }
    }

    // T-d3086208 F-554
    @Test func keepsTheOperationOnTopOfTheUndoListToBeTriedAgain() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let denied = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if denied.isSet { throw error }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.rename("\(root)/a.txt", "b.txt")
            let entry = t.history.top(.undo)
            denied.set(true)
            let failed = try await t.undo()
            #expect(failed.status == .failed)
            #expect(t.history.top(.undo) == entry)
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
            denied.set(false)
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(root)/a.txt") == "a")
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
            await t.shutDown()
        }
    }

    // T-3a9ef84f F-554
    @Test func keepsOnlyTheItemsWhoseWriteFailedTheRestGoToRedo() async throws {
        try await withUndoFolder { root, trashDir in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try UndoDisk.write("\(root)/\(name)", name)
            }
            let denied = UndoFlag(true)
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if denied.isSet && to == "\(root)/b.txt" { throw error }
                    try UndoDisk.move(from, to)
                }
            }
            let before = snapshot(t)
            try await t.trash("\(root)/a.txt", "\(root)/b.txt", "\(root)/c.txt")
            let partly = try await t.undo()
            #expect(partly.status == .partial)
            #expect(items(partly).map(\.status) == [.completed, .failed, .completed])
            #expect(
                t.history.menu()
                    == UndoMenuLabels(
                        undo: "Move to Trash of “b.txt”", redo: "Move to Trash of 2 Items", cantUndo: false))
            denied.set(false)
            try await t.undo()
            #expect(snapshot(t) == before)
            #expect(t.history.menu().undo == nil)
            await t.shutDown()
        }
    }

    // T-230db385 F-554
    @Test func keepsTheStepsOfAReplaceAfterOneThatFailedAndGoesOnFromThere() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.mkdir("\(root)/paste-trash")
            try UndoDisk.write("\(root)/src/a.txt", "new")
            try UndoDisk.write("\(root)/dst/a.txt", "old")
            let denied = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    // Putting the old item back from the Trash fails, once.
                    if to == "\(root)/dst/a.txt", denied.take() { throw error }
                    try UndoDisk.move(from, to)
                }
            }
            let before = snapshot(t)
            try await t.paste(
                .cut, ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash("\(root)/paste-trash"))
            denied.set(true)
            #expect(try await t.undo().status == .partial)
            #expect(try UndoDisk.read("\(root)/src/a.txt") == "new")
            #expect(!UndoDisk.exists("\(root)/dst/a.txt"))
            // Still a move: what is left of it is only the old item's trip to the Trash.
            #expect(
                t.history.menu() == UndoMenuLabels(undo: "Move of “a.txt”", redo: "Move of “a.txt”", cantUndo: false))
            try await t.undo()
            #expect(snapshot(t) == before)
            await t.shutDown()
        }
    }

    // T-47bc83e5 F-392 F-554
    @Test func keepsTheItemsOfABatchWhoseRenameBackFailed() async throws {
        try await withUndoFolder { root, trashDir in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try UndoDisk.write("\(root)/\(name)", name)
            }
            let denied = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if denied.isSet && to == "\(root)/b.txt" { throw error }
                    try UndoDisk.move(from, to)
                }
            }
            let before = snapshot(t)
            try await t.batchRename([
                ("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt"), ("\(root)/c.txt", "z.txt"),
            ])
            denied.set(true)
            #expect(try await t.undo().status == .partial)
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename", redo: "Rename of 2 Items", cantUndo: false))
            denied.set(false)
            try await t.undo()
            #expect(snapshot(t) == before)
            await t.shutDown()
        }
    }

    // T-94c29349 F-392 F-554
    @Test func swapsTwoNamesBackInTwoTriesWhenOneItemFailedTheFirstTime() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let failOnce = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    // The item now named "a.txt" can't be moved aside, once.
                    if from == "\(root)/a.txt", failOnce.take() { throw error }
                    try base.renameExclusive(from, to)
                }
            }
            let before = snapshot(t)
            try await t.batchRename([("\(root)/a.txt", "b.txt"), ("\(root)/b.txt", "a.txt")])
            let after = snapshot(t)
            failOnce.set(true)
            let failed = try await t.undo()
            #expect(failed.status == .failed)
            // The other one took a number rather than wait: both are tried again from where they are.
            #expect(UndoDisk.exists("\(root)/a 2.txt"))
            #expect(!UndoDisk.exists("\(root)/b.txt"))
            #expect(items(failed).map(\.status) == [.failed, .failed])
            #expect(
                items(failed).map(\.error) == [
                    "“b.txt” is named “a 2.txt” for now, because “a.txt” couldn't be renamed out of its way.",
                    "You don't have permission to access this item.",
                ])
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename of 2 Items", redo: "Rename", cantUndo: false))
            #expect(try await t.undo().status == .completed)
            #expect(snapshot(t) == before)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename of 2 Items", cantUndo: false))
            try await t.undo(.redo)
            try await t.undo(.redo)
            #expect(snapshot(t) == after)
            await t.shutDown()
        }
    }

    // T-afc36e80 F-392 F-554
    @Test func recordsWhereAnItemThatWaitsUnderANumberWentForRedoAndUndo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let failing = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    // The item now named "a.txt" can't be moved aside.
                    if failing.isSet && from == "\(root)/a.txt" { throw error }
                    try base.renameExclusive(from, to)
                }
            }
            let before = snapshot(t)
            try await t.batchRename([("\(root)/a.txt", "b.txt"), ("\(root)/b.txt", "a.txt")])
            let after = snapshot(t)
            failing.set(true)
            let failed = try await t.undo()
            #expect(items(failed).map(\.status) == [.failed, .failed])
            #expect(items(failed).map(\.destinationPath) == ["\(root)/a 2.txt", nil])
            // Moved, so on Redo; not back yet, so still to undo.
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename of 2 Items", redo: "Rename", cantUndo: false))
            // Redo first: it goes back where it was. Undo then takes it to the number again, and does both; Redo,
            // each try in turn.
            failing.set(false)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(snapshot(t) == after)
            try await t.undo()
            try await t.undo()
            #expect(snapshot(t) == before)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename of 2 Items", cantUndo: false))
            try await t.undo(.redo)
            try await t.undo(.redo)
            #expect(snapshot(t) == after)
            #expect(t.history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-dc3d68ab F-392 F-554
    @Test func saysWhereTheItemsInsideAFolderThatWaitsUnderANumberAre() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/A")
            try UndoDisk.write("\(root)/A/in.txt", "in")
            try UndoDisk.mkdir("\(root)/B")
            let failing = UndoFlag()
            let error = permissionDenied()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    if failing.isSet && from == "\(root)/A" { throw error }
                    try base.renameExclusive(from, to)
                }
            }
            let before = snapshot(t)
            try await t.batchRename([
                ("\(root)/A/in.txt", "out.txt", false), ("\(root)/A", "B", true), ("\(root)/B", "A", true),
            ])
            failing.set(true)
            #expect(try await t.undo().status == .partial)
            // The item inside, which nothing held, is renamed back, in the folder that waits.
            #expect(UndoDisk.names("\(root)/A") == [])
            #expect(UndoDisk.names("\(root)/A 2") == ["in.txt"])
            failing.set(false)
            try await t.undo()
            #expect(snapshot(t) == before)
            await t.shutDown()
        }
    }

    // T-5da8a730 F-393 F-554
    @Test func letsGoOfACopyOnADiskWithoutATrashWhichWouldFailEachTimeAndSaysWhy() async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw noTrashError() }
            }
            try await t.newFolder(root, "F")
            let undone = try await t.undo()
            let reason = "“F” couldn't be moved to the Trash because its disk has no Trash."
            #expect(undone.status == .failed)
            #expect(undone.result?.error == reason)
            #expect(items(undone).map(\.status) == [.skipped])
            #expect(items(undone).first?.sourcePath == "\(root)/F")
            #expect(items(undone).first?.error == reason)
            #expect(UndoDisk.exists("\(root)/F"))
            // Not kept to be tried again: an older operation is next.
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-9ecb5aae F-393 F-554
    @Test func keepsACopyTheTrashRefusedWithoutSayingWhyOnADiskThatHasATrash() async throws {
        try await withUndoFolder { root, trashDir in
            let unsaid = codedError("ENOTRASH", "couldn't be moved")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw unsaid }
            }
            try await t.newFolder(root, "F")
            let kept = try await t.undo()
            #expect(items(kept).map(\.status) == [.failed])
            #expect(items(kept).first?.error == "couldn't be moved")
            #expect(t.history.menu().undo == "New Folder")
            await t.shutDown()

            // On a disk found to have none by the time of the Undo (a share mounted there since: a New Folder made on
            // one can't be undone at all), it is let go.
            let hasTrash = UndoFlag(true)
            let share = UndoTest(
                root: root, trashDir: trashDir, configure: { $0.trashImpl = { _ in throw unsaid } },
                diskHasTrash: { _ in hasTrash.isSet })
            try await share.newFolder(root, "G")
            hasTrash.set(false)
            let dropped = try await share.undo()
            #expect(items(dropped).map(\.status) == [.skipped])
            #expect(items(dropped).first?.error?.contains("no Trash") == true)
            #expect(share.history.menu().undo == nil)
            await share.shutDown()
        }
    }

    // T-589ac013 F-393 F-554
    @Test func classifiesEachErrorCode() {
        #expect(UndoExecution.classifyUndoWriteError("ENOENT") == .outsideChange)
        #expect(UndoExecution.classifyUndoWriteError("ENOTDIR") == .outsideChange)
        #expect(UndoExecution.classifyUndoWriteError("EEXIST") == .outsideChange)
        #expect(UndoExecution.classifyUndoWriteError("ENOTRASH") == .permanent)
        #expect(UndoExecution.classifyUndoWriteError("EROFS") == .permanent)
        #expect(UndoExecution.classifyUndoWriteError("EXDEV") == .permanent)
        #expect(UndoExecution.classifyUndoWriteError("EACCES") == .retry)
        #expect(UndoExecution.classifyUndoWriteError("EPERM") == .retry)
        #expect(UndoExecution.classifyUndoWriteError("EBUSY") == .retry)
        #expect(UndoExecution.classifyUndoWriteError(nil) == .retry)
    }

    nonisolated static let renameFailures: [(String, CopyPasteItemResult.Status, String, String?)] = [
        ("EACCES", .failed, "You don't have permission to access this item.", "Rename"),
        ("EROFS", .skipped, "“b.txt” is on a disk that can only be read.", nil),
        ("EXDEV", .skipped, "“b.txt” is on another disk now.", nil),
        ("ENOENT", .skipped, "“b.txt” is no longer in", nil),
        ("EEXIST", .skipped, "An item named “a", nil),
    ]

    // T-7dd74c4a F-393 F-554
    @Test(arguments: renameFailures)
    func renamingBackFailsWith(code: String, status: CopyPasteItemResult.Status, error: String, left: String?)
        async throws
    {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let denied = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if denied.isSet { throw codedError(code, "\(code): failed on purpose") }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.rename("\(root)/a.txt", "b.txt")
            denied.set(true)
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [status])
            #expect(items(undone).first?.error?.contains(error) == true)
            #expect(UndoDisk.exists("\(root)/b.txt"))
            #expect(t.history.menu().undo == left)
            await t.shutDown()
        }
    }

    // T-3dbe93f7 F-393 F-554
    @Test(
        arguments: [
            ("EACCES", CopyPasteItemResult.Status.failed, "New Folder"), ("ENOENT", .skipped, nil),
            ("EROFS", .skipped, nil),
        ] as [(String, CopyPasteItemResult.Status, String?)])
    func theTrashFailsWith(code: String, status: CopyPasteItemResult.Status, left: String?) async throws {
        try await withUndoFolder { root, trashDir in
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw codedError(code, "\(code): failed on purpose") }
            }
            try await t.newFolder(root, "F")
            #expect(items(try await t.undo()).map(\.status) == [status])
            #expect(t.history.menu().undo == left)
            await t.shutDown()
        }
    }

    // T-ea0980a4 F-393 F-554
    @Test(
        arguments: [("EACCES", CopyPasteItemResult.Status.failed), ("EROFS", .skipped)]
            as [(String, CopyPasteItemResult.Status)])
    func anItemOfABatchFailsWith(code: String, status: CopyPasteItemResult.Status) async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let denied = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if denied.isSet && from == "\(root)/x.txt" { throw codedError(code, "\(code): failed on purpose") }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.batchRename([("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt")])
            denied.set(true)
            let undone = try await t.undo()
            #expect(
                items(undone).map(\.status.rawValue).sorted()
                    == [CopyPasteItemResult.Status.completed.rawValue, status.rawValue].sorted())
            #expect(UndoDisk.exists("\(root)/x.txt"))
            // What failed for good is let go; what may work next time stays, with the item the batch did on Redo.
            #expect(
                t.history.menu()
                    == UndoMenuLabels(undo: status == .failed ? "Rename" : nil, redo: "Rename", cantUndo: false))
            await t.shutDown()
        }
    }

    // MARK: A stop as the last item of a batch is renamed back

    // T-5f254296 F-389 F-554
    @Test func stopsNothingAndLeavesNothingToUndo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let stopping = UndoFlag()
            let stop = StopButton()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    try base.renameExclusive(from, to)
                    if stopping.isSet && to == "\(root)/b.txt" { stop.press() }
                }
            }
            stop.test = t
            let before = snapshot(t)
            try await t.batchRename([("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt")])
            stopping.set(true)
            let undone = try await t.undo()
            #expect(undone.status == .completed)
            #expect(snapshot(t) == before)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename of 2 Items", cantUndo: false))
            await t.shutDown()
        }
    }

    // MARK: A batch rename another app got in the way of

    // T-f451fcc2 F-384 F-553
    @Test func renamesBackAnItemLeftUnderANumberedName() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    try base.renameExclusive(from, to)
                    // Once "a" has taken "b.txt", another app makes a new "a.txt": "b" can't take it, and its own old
                    // name is taken, so it is left as "b 2.txt".
                    if to == "\(root)/b.txt" { try UndoDisk.write("\(root)/a.txt", "outside") }
                }
            }
            let renamed = try await t.batchRename(
                BatchRenameRequest(
                    items: [
                        .init(sourcePath: "\(root)/a.txt", destinationName: "b.txt", isFolder: false),
                        .init(sourcePath: "\(root)/b.txt", destinationName: "a.txt", isFolder: false),
                    ], onConflict: .skip, numberSeparator: " "))
            #expect(items(renamed).map(\.status) == [.completed, .failed])
            #expect(items(renamed).map(\.destinationPath) == ["\(root)/b.txt", "\(root)/b 2.txt"])
            #expect(try await t.prepare().nameTaken == ["a.txt"])
            try await t.undo()
            #expect(try UndoDisk.read("\(root)/a.txt") == "outside")
            #expect(try UndoDisk.read("\(root)/a 2.txt") == "a")
            #expect(try UndoDisk.read("\(root)/b.txt") == "b")
            #expect(!UndoDisk.exists("\(root)/b 2.txt"))
            await t.shutDown()
        }
    }

    /// `stoppedHalfway`: a moving Replace undone up to the stop: the new item went back where it came from, the old
    /// item is still in the Trash.
    private func stoppedHalfway(_ root: String, _ trashDir: String) async throws -> (
        t: UndoTest, before: [String], after: [String]
    ) {
        try UndoDisk.mkdir("\(root)/src")
        try UndoDisk.mkdir("\(root)/dst")
        try UndoDisk.mkdir("\(root)/paste-trash")
        try UndoDisk.write("\(root)/src/a.txt", "new")
        try UndoDisk.write("\(root)/dst/a.txt", "old")
        let stopAfterNextMove = UndoFlag()
        let stop = StopButton()
        let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
            fileSystem.renameExclusiveImpl = { from, to in
                try UndoDisk.move(from, to)
                if stopAfterNextMove.take() { stop.press() }
            }
        }
        stop.test = t
        let before = snapshot(t)
        try await t.paste(
            .cut, ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
            fileSystem: NativePaste.withTrash("\(root)/paste-trash"))
        let after = snapshot(t)
        stopAfterNextMove.set(true)
        let stopped = try await t.undo()
        #expect(stopped.status == .partial)
        #expect(try UndoDisk.read("\(root)/src/a.txt") == "new")
        #expect(!UndoDisk.exists("\(root)/dst/a.txt"))
        #expect(t.history.menu() == UndoMenuLabels(undo: "Move of “a.txt”", redo: "Move of “a.txt”", cantUndo: false))
        return (t, before, after)
    }

    // T-44543bce F-554
    @Test func putsTheOldItemBackOnTheNextUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let (t, before, _) = try await stoppedHalfway(root, trashDir)
            #expect(try await t.undo().status == .completed)
            #expect(snapshot(t) == before)
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "old")
            #expect(UndoDisk.names("\(root)/paste-trash") == [])
            #expect(t.history.menu().undo == nil)
            await t.shutDown()
        }
    }

    // T-456f9e84 F-554
    @Test func bringsTheNewItemBackOnRedoWithTheRestStillToUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let (t, before, after) = try await stoppedHalfway(root, trashDir)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(snapshot(t) == after)
            #expect(t.history.menu() == UndoMenuLabels(undo: "Move of “a.txt”", redo: nil, cantUndo: false))
            try await t.undo()
            try await t.undo()
            #expect(snapshot(t) == before)
            #expect(t.history.menu().undo == nil)
            await t.shutDown()
        }
    }

    // MARK: The Trash not saying where an item went

    /// `silentTrash`: a Trash that takes the item and says nothing of where it put it.
    private func silentTrash(_ trashDir: String) -> @Sendable (String) throws -> String? {
        { path in
            try UndoDisk.move(path, "\(trashDir)/somewhere-\(UUID().uuidString)")
            return nil
        }
    }

    // T-8ff8503a F-370 F-554
    @Test func makesAMoveToTrashOneThatCantBeUndone() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let toTrash = UndoTestFileSystem.folderTrash(trashDir)
            let silent = silentTrash(trashDir)
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { path in try path.hasSuffix("b.txt") ? silent(path) : toTrash(path) }
            }
            #expect(try await t.trash("\(root)/a.txt", "\(root)/b.txt").status == .completed)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: true))
            await t.shutDown()
        }
    }

    // T-0589d02a F-370 F-554
    @Test func makesAPasteWhoseReplacePutTheOldItemThereOneThatCantBeUndone() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.write("\(root)/src/a.txt", "new")
            try UndoDisk.write("\(root)/dst/a.txt", "old")
            let run = try await runPaste(
                mode: .copy, sources: ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: silentTrash(trashDir)))
            #expect(run.result?.status == .completed)
            #expect(run.result?.undoLog == .notUndoable(reason: .trashLocationUnknown))
        }
    }

    // T-11cd3b00 F-554
    @Test func countsAnUndosTripToTheTrashAsDoneWithNothingToRedo() async throws {
        try await withUndoFolder { root, trashDir in
            let silent = silentTrash(trashDir)
            let t = UndoTest(root: root, trashDir: trashDir) { $0.trashImpl = silent }
            try await t.newFolder(root, "F")
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/F"))
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // T-e3f31ede F-554
    @Test func leavesNothingToRedoOfAReplaceWhoseNewItemWentThere() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.mkdir("\(root)/paste-trash")
            try UndoDisk.write("\(root)/src/a.txt", "new")
            try UndoDisk.write("\(root)/dst/a.txt", "old")
            let toTrash = UndoTestFileSystem.folderTrash(trashDir)
            let silent = silentTrash(trashDir)
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                // The new item goes to the Trash without it saying where; the old one comes back.
                fileSystem.trashImpl = { path in try path == "\(root)/dst/a.txt" ? silent(path) : toTrash(path) }
            }
            try await t.paste(
                .copy, ["\(root)/src/a.txt"], into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash("\(root)/paste-trash"))
            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(root)/dst/a.txt") == "old")
            // Redo could only move the old item to the Trash again, with nothing in its place.
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // MARK: An item that can't be checked, with nothing else read

    private func unreadableDisk(_ trashDir: String, _ error: OperationError) -> UndoTestFileSystem {
        let fileSystem = UndoTestFileSystem(trashDir: trashDir)
        fileSystem.lstatImpl = { _ in throw error }
        fileSystem.statImpl = { _ in throw error }
        return fileSystem
    }

    // T-47f55637 F-554
    @Test func keepsAWholeRenameOfSeveralToBeTriedAgain() {
        // Its items may swap names with each other: none of them is renamed until all can be checked, and the whole
        // batch stays to be tried again.
        let items = [
            BatchRenamedItem(from: "/D/a", to: "/D/b", id: ItemId(dev: 1, ino: 10), itemKind: .file),
            BatchRenamedItem(from: "/D/b", to: "/D/a", id: ItemId(dev: 1, ino: 11), itemKind: .file),
        ]
        let units = [UndoUnit(steps: [.batchRenamed(items: items)])]
        let run = UndoExecution.runUndo(
            units, UndoRunOptions(direction: .undo, fileSystem: unreadableDisk("/nowhere", permissionDenied())))
        #expect(run.items.map(\.status) == [.failed])
        #expect(run.items.first?.sourcePath == "/D/b")
        #expect(run.items.first?.error == "“b” couldn't be checked: You don't have permission to access this item.")
        #expect(run.leftover == units)
    }

    // T-d02a5c8e F-554
    @Test func keepsAnItemToMoveToTheTrashToBeTriedAgain() {
        let units = [UndoUnit(steps: [.created(path: "/D/a copy", id: ItemId(dev: 1, ino: 10), stamp: nil)])]
        let run = UndoExecution.runUndo(
            units, UndoRunOptions(direction: .undo, fileSystem: unreadableDisk("/nowhere", permissionDenied())))
        #expect(run.items.map(\.status) == [.failed])
        #expect(
            run.items.first?.error == "“a copy” couldn't be checked: You don't have permission to access this item.")
        #expect(run.leftover == units)
    }

    // T-efe7f3fe F-554
    @Test func reportsEachOfVeryManyItemsMoreThanACallCanTakeAtOnce() {
        let count = 130_000
        let items = (0..<count).map {
            BatchRenamedItem(
                from: "/D/a\($0)", to: "/D/b\($0)", id: ItemId(dev: 1, ino: UInt64($0 + 10)), itemKind: .file)
        }
        let run = UndoExecution.runUndo(
            [UndoUnit(steps: [.batchRenamed(items: items)])],
            UndoRunOptions(direction: .undo, fileSystem: unreadableDisk("/nowhere", codedError("ENOENT"))))
        #expect(run.items.count == count)
        #expect(run.items.first?.status == .skipped)
    }

    // MARK: An Undo's progress

    // T-5acda2d3 F-554
    @Test func countsWhatItHasDoneOutOfAllItHasToDoStepsAndBatchItemsAlike() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(root)/src")
            try UndoDisk.mkdir("\(root)/dst")
            try UndoDisk.mkdir("\(root)/paste-trash")
            let names = ["a.txt", "b.txt", "c.txt"]
            for name in names {
                try UndoDisk.write("\(root)/src/\(name)", name)
                try UndoDisk.write("\(root)/dst/\(name)", "old")
            }
            let t = UndoTest(root: root, trashDir: trashDir)
            // Three Replaces: six steps.
            try await t.paste(
                .copy, names.map { "\(root)/src/\($0)" }, into: "\(root)/dst", policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash("\(root)/paste-trash"))
            try await t.undo()
            // A batch of three: one step, three items.
            try await t.batchRename(names.map { ("\(root)/dst/\($0)", "x \($0)") })
            try await t.undo()
            let undoEvents = t.events.filter { $0.action == .undo }
            var totals: [Int] = []
            for event in undoEvents where event.totalItemCount > 0 && !totals.contains(event.totalItemCount) {
                totals.append(event.totalItemCount)
            }
            #expect(totals == [6, 3])
            for event in undoEvents {
                #expect(event.completedItemCount <= event.totalItemCount)
            }
            let ends = undoEvents.filter { $0.status == .completed }
            #expect(ends.map(\.completedItemCount) == [6, 3])
            #expect(ends.map(\.totalItemCount) == [6, 3])
            await t.shutDown()
        }
    }

    // MARK: An item of a batch that goes away as it is renamed back

    // T-028d8b83 F-554
    @Test func isSkippedAsOneTheCheckFindsGoneAndNotKept() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            let removing = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    if removing.isSet && from == "\(root)/x.txt" { try UndoDisk.remove(from) }
                    try base.renameExclusive(from, to)
                }
            }
            try await t.batchRename([("\(root)/a.txt", "x.txt"), ("\(root)/b.txt", "y.txt")])
            removing.set(true)
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.skipped, .completed])
            #expect(items(undone).first?.error == "“x.txt” is no longer in “\(NodePath.basename(root))”.")
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
            await t.shutDown()
        }
    }

    // T-005f3bea F-554
    @Test func doesAgainOnlyWhatUndoReallyDid() async throws {
        try await withUndoFolder { root, trashDir in
            for name in ["a.txt", "b.txt", "c.txt"] {
                try UndoDisk.write("\(root)/\(name)", name)
            }
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/a.txt", "\(root)/b.txt", "\(root)/c.txt")
            // Renamed in the Trash, outside the app.
            try UndoDisk.move("\(trashDir)/2-b.txt", "\(trashDir)/renamed.txt")
            let undone = try await t.undo()
            #expect(undone.status == .partial)
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Move to Trash of 2 Items", cantUndo: false))
            let redone = try await t.undo(.redo)
            #expect(redone.status == .completed)
            #expect(items(redone).map(\.sourcePath) == ["\(root)/a.txt", "\(root)/c.txt"])
            #expect(UndoDisk.names(trashDir) == ["4-a.txt", "5-c.txt", "renamed.txt"])
            await t.shutDown()
        }
    }

    // T-e40e148f F-394 F-554
    @Test func keepsTheOperationOnTheUndoListWhenAnUndoStopsUnexpectedly() async throws {
        try await withUndoFolder { root, trashDir in
            let broken = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir)
            t.coordinator.undo.run = { units, options in
                if broken.isSet { throw OperationError("Disk gone.") }
                return UndoExecution.runUndo(units, options)
            }
            try await t.newFolder(root, "F")
            broken.set(true)
            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(undone.result?.error == "The Undo stopped unexpectedly: Disk gone.")
            #expect(t.history.menu() == UndoMenuLabels(undo: "New Folder", redo: nil, cantUndo: false))
            broken.set(false)
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/F"))
            await t.shutDown()
        }
    }
}

/// A switch the test and the disk threads share.
final class UndoFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) {
        self.value = value
    }

    var isSet: Bool { lock.withLock { value } }

    func set(_ newValue: Bool) {
        lock.withLock { value = newValue }
    }

    /// Whether it was set, turning it off.
    func take() -> Bool {
        lock.withLock {
            defer { value = false }
            return value
        }
    }
}

/// Stop pressed from a disk thread, once the test it belongs to is made.
final class StopButton: @unchecked Sendable {
    nonisolated(unsafe) weak var test: UndoTest?

    func press() {
        test?.pressStop()
    }
}
