// The look at what an Undo would ask: the time a slow disk gets, looks given up on, Stop, and the names a numbered
// item may take
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoLooksTests {
    private static let notAnswered = WriteCoordinatorError(
        "A disk didn't answer while Undo looked at its items. Choose Undo again once it does.")

    // A rename of many items is one step: the disk gets the time for each of its items, not for all of them.
    @Test func looksAtAllOfALargeBatchOnASlowDiskThatAnswersEveryRead() async throws {
        try await withUndoFolder { root, trashDir in
            let names = (0..<40).map { "f\($0).txt" }
            for name in names { try UndoDisk.write("\(root)/\(name)", "x") }
            let t = UndoTest(root: root, trashDir: trashDir, undoCheckWithinMs: 400)
            try await t.batchRename(names.map { ("\(root)/\($0)", "r-\($0)") })
            // Every look takes 20 ms, and answers: well over 400 ms for all of them.
            t.fileSystem.lstatImpl = { [base = t.fileSystem.base] path in
                usleep(20_000)
                return try base.lstat(path)
            }
            let prepared = try await t.prepare()
            #expect(prepared.ticket != nil)
            #expect(prepared.nameTaken.isEmpty)
            t.fileSystem.lstatImpl = nil
            #expect(try await t.undo().status == .completed)
            let back = names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            #expect(UndoDisk.names(root).filter { $0 != ".Trash" } == back)
            await t.shutDown()
        }
    }

    // Each look given up on keeps its threads until its disk answers: past a few of them, ⌘Z is refused at once and
    // reads nothing, and works again once the disk has answered.
    @Test func startsNoMoreLooksOnTopOfThoseADiskNeverAnswered() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let hanging = UndoFlag()
            let gate = DiskGate()
            defer { gate.open() }
            let looks = OSAllocatedUnfairLock(initialState: 0)
            let t = UndoTest(
                root: root, trashDir: trashDir,
                configure: { fileSystem in
                    let base = fileSystem.base
                    fileSystem.lstatImpl = { path in
                        if hanging.isSet && path.hasSuffix("b.txt") {
                            looks.withLock { $0 += 1 }
                            gate.wait()
                        }
                        return try base.lstat(path)
                    }
                }, undoCheckWithinMs: 50)
            try await t.rename("\(root)/a.txt", "b.txt")
            hanging.set(true)
            for _ in 0..<StuckLooks.atMost {
                await #expect(throws: Self.notAnswered) { try await t.prepare() }
            }
            #expect(looks.withLock { $0 } == StuckLooks.atMost)
            await #expect(throws: Self.notAnswered) { try await t.prepare() }
            #expect(looks.withLock { $0 } == StuckLooks.atMost)
            // The disk answers again.
            hanging.set(false)
            gate.open()
            while t.coordinator.undo.stuckLooks.tooMany {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.exists("\(root)/a.txt"))
            await t.shutDown()
        }
    }

    // A look that was given up on may still come back with something: it is never taken for an answer.
    @Test func countsALookGivenUpOnUntilItReturnsAndNeverTakesWhatItGives() async {
        let stuck = StuckLooks()
        let gate = DiskGate()
        let returned = DiskGate()
        let answer = await WriteCoordinator.answerWithin(30, stuck: stuck) { _ in
            gate.wait()
            returned.open()
            return 1
        }
        #expect(answer == nil)
        gate.open()
        returned.wait()
        // Counted until its thread is through.
        for _ in 0..<1_000 where stuck.count != 0 { usleep(1_000) }
        #expect(stuck.count == 0)
    }

    // Stop on the card that is up while an Undo is looked at: the look ends at once, and nothing is undone.
    @Test func stopEndsTheLookAtOnceAndUndoesNothing() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let hanging = UndoFlag()
            let gate = DiskGate()
            defer { gate.open() }
            let t = UndoTest(
                root: root, trashDir: trashDir,
                configure: { fileSystem in
                    let base = fileSystem.base
                    fileSystem.lstatImpl = { path in
                        if hanging.isSet && path.hasSuffix("b.txt") { gate.wait() }
                        return try base.lstat(path)
                    }
                })
            try await t.rename("\(root)/a.txt", "b.txt")
            hanging.set(true)
            let signal = StopSignal()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { signal.stop() }
            let started = Date()
            let stopped = try await t.coordinator.prepareUndo(.undo, stop: signal)
            #expect(stopped.ticket == nil)
            #expect(stopped.refusal == .nothing)
            // Long before the 10 s a disk gets.
            #expect(Date().timeIntervalSince(started) < 5)
            #expect(UndoDisk.exists("\(root)/b.txt"))
            // Stopped before it began: the same.
            let before = try await t.coordinator.prepareUndo(.undo, stop: signal)
            #expect(before.ticket == nil)
            hanging.set(false)
            #expect(try await t.undo().status == .completed)
            await t.shutDown()
        }
    }

    // An item put back with a number never takes the name another item of the same Undo goes back to.
    @Test func leavesTheNameOfAnotherItemOfTheUndoToThatItem() async throws {
        for order in [["a 2.txt", "a.txt"], ["a.txt", "a 2.txt"]] {
            try await withUndoFolder { root, trashDir in
                try UndoDisk.write("\(root)/a.txt", "one")
                try UndoDisk.write("\(root)/a 2.txt", "two")
                let t = UndoTest(root: root, trashDir: trashDir)
                _ = try await t.finish(t.coordinator.trash(paths: order.map { "\(root)/\($0)" }, window: t.window))
                try UndoDisk.write("\(root)/a.txt", "someone else's")
                let prepared = try await t.prepare()
                #expect(prepared.nameTaken == ["a.txt"])
                let end = try await t.finish(t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window))
                #expect(end.status == .completed)
                func contents() -> [String: String] {
                    var all: [String: String] = [:]
                    for name in UndoDisk.names(root) where name != ".Trash" {
                        all[name] = try? UndoDisk.read("\(root)/\(name)")
                    }
                    return all
                }
                let back = ["a.txt": "someone else's", "a 2.txt": "two", "a 3.txt": "one"]
                #expect(contents() == back)
                // And both ways again.
                #expect(try await t.undo(.redo).status == .completed)
                #expect(contents() == ["a.txt": "someone else's"])
                #expect(try await t.undo().status == .completed)
                #expect(contents() == back)
                await t.shutDown()
            }
        }
    }

    // A Redo that can't start any more is told as a Redo, also when its ticket is no longer known.
    @Test func namesARedoThatTheHistoryMovedOnFromAsARedo() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/c.txt", "c")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            try await t.undo()
            let prepared = try await t.prepare(.redo)
            // Another operation leaves nothing to redo.
            try await t.rename("\(root)/c.txt", "d.txt")
            let changed = WriteCoordinatorError("Something changed since Redo was chosen. Choose it again.")
            await #expect(throws: changed) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            // Started once already: the ticket is gone, and still says which command it was.
            await #expect(throws: changed) {
                try await t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window)
            }
            #expect(UndoDisk.exists("\(root)/a.txt"))
            await t.shutDown()
        }
    }

    // What a look asked is kept only until it is started, or its question is cancelled.
    @Test func letsGoOfWhatALookAskedOnceItIsStartedOrCancelled() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(root)/a.txt", "b.txt")
            let cancelled = try await t.prepare()
            #expect(t.coordinator.undo.asked.count == 1)
            t.coordinator.forgetUndo(ticket: cancelled.ticket ?? "")
            #expect(t.coordinator.undo.asked.isEmpty)
            let prepared = try await t.prepare()
            let end = try await t.finish(t.coordinator.startUndo(ticket: prepared.ticket ?? "", window: t.window))
            #expect(end.status == .completed)
            #expect(t.coordinator.undo.asked.isEmpty)
            await t.shutDown()
        }
    }
}

/// A batch whose items have no ids (FAT, exFAT), on a disk that ignores case: both spellings of a name find the item.
struct UndoBatchWithoutIdsTests {
    private func item(_ from: String, _ to: String, _ ino: UInt64? = nil) -> BatchRenamedItem {
        BatchRenamedItem(from: from, to: to, id: ino.map { ItemId(dev: 1, ino: $0) }, itemKind: .file)
    }

    @Test func takesAnItemFoundUnderAnotherSpellingOfItsOwnNameForItself() {
        for ino in [nil, 10] as [UInt64?] {
            let disk = PlanDisk([
                "/Docs": .dir(ino: 1), "/Docs/b.txt": .file(ino: ino), "/Docs/B.txt": .file(ino: ino),
            ])
            let checks = UndoPlan.checkBatch(disk, [item("/Docs/b.txt", "/Docs/B.txt", ino)])
            #expect(checks.map(\.nameTaken) == [false])
            #expect(checks.allSatisfy { $0.refusal == nil })
        }
    }

    @Test func letsTwoItemsWithoutIdsSwapNamesSpelledOtherwise() {
        let disk = PlanDisk([
            "/Docs": .dir(ino: 1), "/Docs/a": .file(ino: nil), "/Docs/A": .file(ino: nil),
            "/Docs/b": .file(ino: nil), "/Docs/B": .file(ino: nil),
        ])
        let checks = UndoPlan.checkBatch(disk, [item("/Docs/a", "/Docs/B"), item("/Docs/b", "/Docs/A")])
        #expect(checks.map(\.nameTaken) == [false, false])
    }

    @Test func stillFindsANameTakenByAnotherItemWithoutAnId() {
        let disk = PlanDisk([
            "/Docs": .dir(ino: 1), "/Docs/b.txt": .file(ino: nil), "/Docs/c.txt": .file(ino: nil),
        ])
        let checks = UndoPlan.checkBatch(disk, [item("/Docs/b.txt", "/Docs/c.txt")])
        #expect(checks.map(\.nameTaken) == [true])
    }

    // A batch tells of each item looked at, and reads nothing more once its wait gave up.
    @Test func tellsOfEachItemLookedAtAndStopsOnceGivenUpOn() {
        let disk = PlanDisk([
            "/Docs": .dir(ino: 1), "/Docs/b": .file(ino: 10), "/Docs/d": .file(ino: 11),
        ])
        let items = [item("/Docs/b", "/Docs/a", 10), item("/Docs/d", "/Docs/c", 11)]
        let progress = AnswerProgress()
        let before = progress.lastAnswer
        usleep(2_000)
        #expect(UndoPlan.checkBatch(disk, items, progress: progress).count == 2)
        #expect(progress.lastAnswer > before)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        disk.onLstat = { _ in reads.withLock { $0 += 1 } }
        progress.abandon()
        #expect(UndoPlan.checkBatch(disk, items, progress: progress).isEmpty)
        #expect(reads.withLock { $0 } == 0)
    }
}
