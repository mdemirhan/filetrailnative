// Port of apps/desktop/src/main/bootstrap/undoExecution.start.test.ts and undoExecution.links.test.ts: starting an
// Undo against what was asked, and Undo through a folder opened by a link
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// A disk call that waits until the test opens the gate: every call meanwhile waits, and none once it is open.
final class DiskGate: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var waiting = 0
    private var isOpen = false

    init() {
        group.enter()
    }

    var hasWaiters: Bool { lock.withLock { waiting > 0 } }

    func wait() {
        lock.withLock { waiting += 1 }
        group.wait()
    }

    func open() {
        let first = lock.withLock { () -> Bool in
            defer { isOpen = true }
            return !isOpen
        }
        if first { group.leave() }
    }
}

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoStartTests {
    private func items(_ end: WriteOperationEvent) -> [WriteOperationItem] { end.result?.items ?? [] }

    // T-fdce3b36 F-388 F-558
    @Test func refusesWhenAnItemChangedWhileTheQuestionAboutAnotherWasOpen() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/x.txt", "x")
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.trash("\(root)/x.txt")
            let trashed = t.history.top(.undo)?.units ?? []
            try await t.paste(.copy, ["\(root)/a.txt"], into: root, action: .duplicate)
            let duplicated = t.history.top(.undo)?.units ?? []
            // One operation that put an item in the Trash and made a copy.
            t.history.record(
                FinishedWrite(action: .write(.paste), log: .undoable(units: trashed + duplicated), items: []))
            try UndoDisk.write("\(root)/x.txt", "someone else's")
            let prepared = try await t.prepare()
            #expect(prepared.nameTaken == ["x.txt"])
            #expect(prepared.changed.isEmpty)
            // While "x.txt" is asked about, the copy is edited.
            try UndoDisk.write("\(root)/a copy.txt", "edited")
            await #expect(
                throws: WriteCoordinatorError("“a copy.txt” was changed after Undo was chosen. Choose Undo again.")
            ) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            #expect(try UndoDisk.read("\(root)/a copy.txt") == "edited")
            #expect(t.coordinator.activeOperation == nil)
            // Chosen again, it asks about both, and goes ahead once both are agreed to.
            let again = try await t.prepare()
            #expect(again.nameTaken == ["x.txt"])
            #expect(again.changed == [UndoQuestion.ChangedItem(name: "a copy.txt", putBack: false, replaced: false)])
            #expect(try await t.undo().status == .completed)
            #expect(!UndoDisk.exists("\(root)/a copy.txt"))
            #expect(try UndoDisk.read("\(root)/x 2.txt") == "x")
            await t.shutDown()
        }
    }

    // T-086549ab F-388 F-558
    @Test func refusesWhenAnotherItemTookANameWhileUndoWasBeingChosen() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            let prepared = try await t.prepare()
            try UndoDisk.write("\(root)/a.txt", "someone else's")
            await #expect(
                throws: WriteCoordinatorError(
                    "Another item took the name “a.txt” after Undo was chosen. Choose Undo again.")
            ) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            #expect(try UndoDisk.read("\(root)/b.txt") == "a")
            await t.shutDown()
        }
    }

    // T-e913f17e F-386 F-558
    @Test func refusesAndFreesTheWriteSlotWhenADiskDoesntAnswerItsLastLook() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let hanging = UndoFlag()
            let gate = DiskGate()
            let t = UndoTest(
                root: root, trashDir: trashDir,
                configure: { fileSystem in
                    let base = fileSystem.base
                    fileSystem.lstatImpl = { path in
                        if hanging.isSet && path.hasSuffix("b.txt") { gate.wait() }
                        return try base.lstat(path)
                    }
                }, undoCheckWithinMs: 20)
            defer { gate.open() }
            try await t.rename("\(root)/a.txt", "b.txt")
            let prepared = try await t.prepare()
            hanging.set(true)
            await #expect(
                throws: WriteCoordinatorError(
                    "A disk didn't answer while Undo looked at its items. Choose Undo again once it does.")
            ) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            #expect(t.coordinator.activeOperation == nil)
            #expect(t.coordinator.slotHolder == nil)
            #expect(UndoDisk.exists("\(root)/b.txt"))
            hanging.set(false)
            #expect(try await t.undo().status == .completed)
            await t.shutDown()
        }
    }

    // T-dd6a69b0 F-391 F-558
    @Test func leavesACopyThatChangedOnceTheUndoStartedToBeAskedAboutNextTime() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/x.txt", "x")
            try UndoDisk.write("\(root)/y.txt", "y")
            try UndoDisk.mkdir("\(root)/D")
            let trash = UndoTestFileSystem.folderTrash(trashDir)
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.trashImpl = { path in
                    // As the first copy goes to the Trash, the other one is edited.
                    if path == "\(root)/D/y.txt" {
                        try UndoDisk.write("\(root)/D/x.txt", "edited")
                    }
                    return try trash(path)
                }
            }
            try await t.paste(.copy, ["\(root)/x.txt", "\(root)/y.txt"], into: "\(root)/D")
            let undone = try await t.undo()
            #expect(items(undone).map(\.status) == [.completed, .failed])
            #expect(
                items(undone).last?.error == "“x.txt” was changed after Undo was chosen, so it was left as it is.")
            #expect(try UndoDisk.read("\(root)/D/x.txt") == "edited")
            #expect(
                try await t.prepare().changed
                    == [UndoQuestion.ChangedItem(name: "x.txt", putBack: false, replaced: false)])
            await t.shutDown()
        }
    }

    // T-a4cbd868 F-388 F-558
    @Test func tellsApartTwoItemsOfOneNameInTwoFolders() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/x.txt", "x")
            try UndoDisk.mkdir("\(root)/A")
            try UndoDisk.mkdir("\(root)/B")
            let t = UndoTest(root: root, trashDir: trashDir)
            var copies: [UndoUnit] = []
            for folder in ["A", "B"] {
                let result = try await t.paste(.copy, ["\(root)/x.txt"], into: "\(root)/\(folder)")
                if case .undoable(let units) = result.undoLog { copies += units }
            }
            t.history.record(FinishedWrite(action: .write(.paste), log: .undoable(units: copies), items: []))
            try UndoDisk.write("\(root)/A/x.txt", "edited")
            let prepared = try await t.prepare()
            #expect(prepared.changed == [UndoQuestion.ChangedItem(name: "x.txt", putBack: false, replaced: false)])
            // While the copy in A is asked about, the one in B is edited too.
            try UndoDisk.write("\(root)/B/x.txt", "edited")
            await #expect(
                throws: WriteCoordinatorError("“x.txt” was changed after Undo was chosen. Choose Undo again.")
            ) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            #expect(UndoDisk.exists("\(root)/B/x.txt"))
            await t.shutDown()
        }
    }

    // T-c8ba2524 F-387 F-558
    @Test func startsEachWindowsUndoWithWhatThatWindowWasAsked() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/x.txt", "x")
            try UndoDisk.write("\(root)/y.txt", "y")
            try UndoDisk.mkdir("\(root)/D")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(root)/x.txt", "\(root)/y.txt"], into: "\(root)/D")
            try UndoDisk.write("\(root)/D/x.txt", "edited x")
            let first = try await t.prepare()
            #expect(first.changed.map(\.name) == ["x.txt"])
            // While the first window asks about "x.txt", "y.txt" is edited, and a second window looks at the same
            // Undo.
            try UndoDisk.write("\(root)/D/y.txt", "edited y")
            let second = try await t.prepare()
            #expect(second.changed.map(\.name) == ["y.txt", "x.txt"])
            // The first window's answer covers only "x.txt".
            await #expect(
                throws: WriteCoordinatorError("“y.txt” was changed after Undo was chosen. Choose Undo again.")
            ) {
                try await t.coordinator.startUndo(ticket: first.ticket ?? "", window: t.window)
            }
            #expect(try UndoDisk.read("\(root)/D/y.txt") == "edited y")
            let undone = try await t.finish(t.coordinator.startUndo(ticket: second.ticket ?? "", window: t.window))
            #expect(undone.status == .completed)
            #expect(!UndoDisk.exists("\(root)/D/y.txt"))
            await t.shutDown()
        }
    }

    // T-d4e51511 F-387 F-558
    @Test func startsOneUndoForTwoWindowsThatChoseItAtOnceAndRefusesTheOther() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let held = HeldCall()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { from, to in
                    if to == "\(root)/a.txt" { held.hold() }
                    try UndoDisk.move(from, to)
                }
            }
            try await t.rename("\(root)/a.txt", "b.txt")
            let otherWindow = TestWindow()
            let first = try await t.prepare()
            let second = try await t.coordinator.prepareUndo(.undo)
            #expect(second.ticket != first.ticket)
            let started = try await t.coordinator.startUndo(ticket: first.ticket ?? "", window: t.window)
            _ = try await Coordinators.waitFor { held.hasBegun ? true : nil }
            // While the first runs: busy.
            await #expect(throws: WriteCoordinatorError.busy) {
                try await t.coordinator.startUndo(ticket: second.ticket ?? "", window: otherWindow)
            }
            held.release()
            #expect(try await t.finish(started).status == .completed)
            // Once it has finished: the history has moved on.
            await #expect(
                throws: WriteCoordinatorError("Something changed since Undo was chosen. Choose it again.")
            ) {
                try await t.coordinator.startUndo(ticket: second.ticket ?? "", window: otherWindow)
            }
            #expect(try UndoDisk.read("\(root)/a.txt") == "a")
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
            await t.shutDown()
        }
    }

    // MARK: A folder opened through a link

    /// `real` (root/Data/Projects) and `link` (root/Projects, a link to it).
    private func linkedFolder(_ root: String) throws -> (real: String, link: String) {
        let real = "\(root)/Data/Projects"
        try UndoDisk.mkdir(real)
        let link = "\(root)/Projects"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        return (real, link)
    }

    // T-813536c7 F-555
    @Test func renamesBackThroughALinkAndAgainOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            let (real, link) = try linkedFolder(root)
            try UndoDisk.write("\(real)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.rename("\(link)/a.txt", "b.txt")
            let after = t.snapshot()
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }

    // T-aa64fc37 F-555
    @Test func putsBackFromTheTrashThroughALinkAndMovesToTheTrashAgainOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            let (real, link) = try linkedFolder(root)
            try UndoDisk.write("\(real)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.trash("\(link)/a.txt")
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.exists("\(real)/a.txt"))
            await t.shutDown()
        }
    }

    // T-9b0ce600 F-555
    @Test func movesACutItemBackOutOfAFolderReachedThroughALinkAndInAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let (real, link) = try linkedFolder(root)
            try UndoDisk.mkdir("\(real)/In")
            try UndoDisk.write("\(real)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            try await t.paste(.cut, ["\(link)/a.txt"], into: "\(link)/In")
            let after = t.snapshot()
            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            #expect(try await t.undo(.redo).status == .completed)
            #expect(t.snapshot() == after)
            await t.shutDown()
        }
    }
}
