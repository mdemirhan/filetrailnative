// Port of packages/core/src/fs/copyPasteUndoLog.realfs.test.ts, but for the cases that Replace (P3-04's): what a
// paste records for Undo, one unit per item picked, with the steps it really took, or why it can't be undone
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// What copying a file costs in lstat calls, one of them the look for Undo once it is made.
private let lstatsPerCopiedFile = 7

private func idOf(_ path: String) -> ItemId? {
    Disk.lstat(path).flatMap { stats in stats.dev.flatMap { dev in stats.ino.map { ItemId(dev: dev, ino: $0) } } }
}

private func undoLog(_ result: CopyPasteOperationResult?) throws -> UndoLog {
    try #require(result?.undoLog, "The paste recorded nothing for Undo.")
}

private func steps(_ log: UndoLog) throws -> [[UndoStep]] {
    guard case .undoable(let units) = log else {
        Issue.record("The paste can't be undone: \(log)")
        return []
    }
    return units.map(\.steps)
}

/// The path of a `created` step, or nil.
private func createdPath(_ step: UndoStep?) -> String? {
    if case .created(let path, _, _)? = step { return path }
    return nil
}

/// Counts the lstat and stat calls a paste makes, from `reset()` on.
private final class CountingFileSystem: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (lstat: 0, stat: 0))
    let fileSystem: TestFileSystem

    init() {
        let base = NativeWriteFileSystem()
        let fileSystem = TestFileSystem(base)
        self.fileSystem = fileSystem
        let counts = counts
        fileSystem.lstatImpl = { path in
            counts.withLock { $0.lstat += 1 }
            return try base.lstat(path)
        }
        fileSystem.statImpl = { path in
            counts.withLock { $0.stat += 1 }
            return try base.stat(path)
        }
    }

    func reset() { counts.withLock { $0 = (0, 0) } }
    var lstats: Int { counts.withLock { $0.lstat } }
    var stats: Int { counts.withLock { $0.stat } }
}

private func folders(_ root: TemporaryDirectory) throws -> (src: String, dst: String, trash: String) {
    let folders = (root.path + "/src", root.path + "/dst", root.path + "/Trash")
    for folder in [folders.0, folders.1, folders.2] {
        try Disk.makeDirectories(folder)
    }
    return folders
}

struct CopyUndoRecordingTests {
    // T-f94ca69b F-447
    @Test func recordsEachItemItMadeNotWhatIsInsideACopiedFolder() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")
            try Disk.write(src + "/Folder/inside.txt", "inside")

            let run = try await runPaste(mode: .copy, sources: [src + "/a.txt", src + "/Folder"], into: dst)

            let units = try steps(try undoLog(run.result))
            #expect(units.count == 2)
            guard case .created(let filePath, let fileId, let fileStamp)? = units.first?.first,
                case .created(let folderPath, let folderId, let folderStamp)? = units.last?.first
            else {
                Issue.record("not two created steps: \(units)")
                return
            }
            #expect(units.map(\.count) == [1, 1])
            #expect(filePath == dst + "/a.txt")
            #expect(fileId == idOf(dst + "/a.txt"))
            #expect(fileStamp?.kind == .file && fileStamp?.size == 1 && fileStamp?.entryCount == nil)
            #expect(folderPath == dst + "/Folder")
            #expect(folderId == idOf(dst + "/Folder"))
            #expect(folderStamp?.kind == .directory && folderStamp?.size == nil && folderStamp?.entryCount == 1)
            // Taken once the folder was complete, its date included.
            #expect(folderStamp?.mtimeMs == mtimeMs(dst + "/Folder"))
        }
    }

    // A file's id is read along with how it looks once it is copied.
    // T-eb8aa002 F-447
    @Test func looksAtEachFileItMadeOnceForUndo() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            func lstats(_ count: Int, into: String) async throws -> Int {
                let names = (0..<count).map { "copy \(count)-\($0).txt" }
                for name in names {
                    try Disk.write(src + "/" + name, "a")
                }
                let counting = CountingFileSystem()
                let run = try await runPaste(
                    mode: .copy, sources: names.map { src + "/" + $0 }, into: into, fileSystem: counting.fileSystem,
                    beforeExecute: { counting.reset() })
                #expect(try steps(try undoLog(run.result)).count == count)
                return counting.lstats
            }
            try Disk.makeDirectories(dst + "/two")
            try Disk.makeDirectories(dst + "/five")
            let two = try await lstats(2, into: dst + "/two")
            let five = try await lstats(5, into: dst + "/five")

            #expect((five - two) / 3 == lstatsPerCopiedFile)
            #expect((five - two) % 3 == 0)
        }
    }

    // T-9a853576 F-447
    @Test func recordsADuplicateUnderTheNameItWasGiven() async throws {
        try await withTemporaryDirectory { root in
            let (src, _, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")

            let run = try await runPaste(mode: .copy, sources: [src + "/a.txt"], into: src)

            let units = try steps(try undoLog(run.result))
            #expect(units.map { $0.map(createdPath) } == [[src + "/a copy.txt"]])
        }
    }

    // T-2fe30a89 F-447
    @Test func recordsNothingForAnItemSkippedAsAlreadyThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(src + "/b.txt", "b")
            try Disk.write(dst + "/a.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/a.txt", src + "/b.txt"], into: dst)

            let units = try steps(try undoLog(run.result))
            #expect(units.map { $0.map(createdPath) } == [[dst + "/b.txt"]])
        }
    }

    // T-612d57eb F-447
    @Test func recordsAFolderWhoseCopyFailedPartWaySinceTheFolderIsThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "a")
            try Disk.write(src + "/Folder/b.txt", "b")
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let native = NativeWriteFileSystem()
            let fileSystem = TestFileSystem(native)
            fileSystem.copyFileImpl = { from, to, stop, progress in
                let call = calls.withLock { value in
                    value += 1
                    return value
                }
                if call == 2 {
                    throw codedError("EIO", "EIO: i/o error")
                }
                try native.copyFile(from, to, stop: stop, onProgress: progress)
            }

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst, fileSystem: fileSystem)

            #expect(run.result?.status == .partial)
            #expect(try steps(try undoLog(run.result)).map { $0.map(createdPath) } == [[dst + "/Folder"]])
        }
    }

    // T-6b2fab99 F-257 F-447
    @Test func recordsOnlyWhatWasDoneBeforeAStop() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")
            try Disk.write(src + "/b.txt", "b")
            let signal = StopSignal()

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt", src + "/b.txt"], into: dst, signal: signal,
                onEvent: { event in
                    if event.status == .running && event.completedItemCount == 1 {
                        signal.stop()
                    }
                })

            #expect(run.result?.status == .partial)
            #expect(Disk.list(dst) == ["a.txt"])
            #expect(try steps(try undoLog(run.result)).map { $0.map(createdPath) } == [[dst + "/a.txt"]])
        }
    }

    // T-cbb7658c F-448
    @Test func cantBeUndoneOnceAFolderIsMergedIntoOneAlreadyThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/new.txt", "new")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(dst + "/Folder") == ["new.txt", "old.txt"])
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // T-f2580505 F-448
    @Test func cantBeUndoneWhenAllAMergeDidWasAddALink() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.makeDirectories(src + "/Folder")
            try Disk.symlink("/nowhere", src + "/Folder/link")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            #expect(try PosixFileSystem().readlink(dst + "/Folder/link") == "/nowhere")
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // Nothing was changed, so Undo must still undo what came before.
    // T-dc09a208 F-448
    @Test func leavesUndoAsItWasWhenAMergeFindsEveryItemAlreadyThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            #expect(Disk.read(dst + "/Folder/a.txt") == "old")
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }
}

struct MoveUndoRecordingTests {
    // T-2ec40398 F-283
    @Test func recordsWhereEachItemCameFromOnItsDiskAndTheFolderItWasIn() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")
            try Disk.makeDirectories(src + "/Folder")
            let (fileId, folderId, srcId) = (idOf(src + "/a.txt"), idOf(src + "/Folder"), idOf(src))

            let run = try await runPaste(mode: .cut, sources: [src + "/a.txt", src + "/Folder"], into: dst)

            #expect(
                try steps(try undoLog(run.result)) == [
                    [
                        .moved(
                            .init(
                                from: src + "/a.txt", to: dst + "/a.txt", id: fileId, itemKind: .file, parentId: srcId))
                    ],
                    [
                        .moved(
                            .init(
                                from: src + "/Folder", to: dst + "/Folder", id: folderId, itemKind: .directory,
                                parentId: srcId))
                    ],
                ])
        }
    }

    // A move on one disk keeps the item's id: it isn't looked at again where it went, and the folder the items came
    // from is looked at once for all of them.
    // T-25d0e5b0 F-283
    @Test func looksAtEachMovedItemTwiceAndAtTheFolderItWasInOnce() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            func calls(_ count: Int, into: String) async throws -> (lstats: Int, stats: Int) {
                let names = (0..<count).map { "move \(count)-\($0).txt" }
                for name in names {
                    try Disk.write(src + "/" + name, "a")
                }
                let counting = CountingFileSystem()
                let run = try await runPaste(
                    mode: .cut, sources: names.map { src + "/" + $0 }, into: into, fileSystem: counting.fileSystem,
                    beforeExecute: { counting.reset() })
                #expect(try steps(try undoLog(run.result)).count == count)
                return (counting.lstats, counting.stats)
            }
            try Disk.makeDirectories(dst + "/two")
            try Disk.makeDirectories(dst + "/five")
            let two = try await calls(2, into: dst + "/two")
            let five = try await calls(5, into: dst + "/five")

            #expect(five.lstats - two.lstats == 3 * 2)
            #expect(five.stats == two.stats)
        }
    }

    // T-02179678 F-283
    @Test func recordsAMovedItemThatIsNeitherAFileAFolderNorALinkAsSuch() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            #expect(mkfifo(src + "/pipe", 0o644) == 0)
            let pipeId = idOf(src + "/pipe")

            let run = try await runPaste(mode: .cut, sources: [src + "/pipe"], into: dst)

            let units = try steps(try undoLog(run.result))
            guard case .moved(let moved)? = units.first?.first else {
                Issue.record("no moved step: \(units)")
                return
            }
            #expect(units.map(\.count) == [1])
            #expect(moved.id == pipeId)
            #expect(moved.itemKind == .other)
        }
    }

    // T-ffceccbe F-448
    @Test func cantBeUndoneOnceAFolderIsMergedOnItsOwnDiskAsAMerge() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/new.txt", "new")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(dst + "/Folder") == ["new.txt", "old.txt"])
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // T-efaf4179 F-448
    @Test func cantBeUndoneOnceAnEmptyFolderMergedIntoAnotherIsRemoved() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.makeDirectories(src + "/Folder")
            try Disk.makeDirectories(dst + "/Folder")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(src) == [])
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // T-1786aaec F-448
    @Test func leavesUndoAsItWasWhenAMergingMoveFindsEveryItemAlreadyThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.read(src + "/Folder/a.txt") == "new")
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }

    // T-b03f7dc5 F-467
    @Test(.tags(.diskImage), .diskImages)
    func cantBeUndoneWhenItWentToAnotherDisk() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let (src, _, _) = try folders(root)
                try Disk.write(src + "/a.txt", "a")

                let run = try await runPaste(mode: .cut, sources: [src + "/a.txt"], into: volume.path)

                #expect(Disk.read(volume.path + "/a.txt") == "a")
                #expect(try undoLog(run.result) == .notUndoable(reason: .otherDiskMove))
            }
        }
    }
}

/// A move to another disk, when nothing was changed.
struct OtherDiskUndoRecordingTests {
    // T-8e3b55e9 F-467
    @Test(.tags(.diskImage), .diskImages)
    func leavesUndoAsItWasWhenTheItemCantBeRead() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let (src, _, trash) = try folders(root)
                try Disk.write(src + "/a.txt", "a")
                let fileSystem = TestFileSystem(NativePaste.withTrash(trash))
                fileSystem.copyFileImpl = { _, _, _, _ in throw codedError("EACCES", "EACCES: permission denied") }

                let run = try await runPaste(mode: .cut, sources: [src + "/a.txt"], into: volume.path, fileSystem: fileSystem)

                #expect(run.result?.status == .failed)
                #expect(!Disk.list(volume.path).contains("a.txt"))
                #expect(try undoLog(run.result) == .undoable(units: []))
            }
        }
    }

    // T-9b6dc618 F-257 F-467
    @Test(.tags(.diskImage), .diskImages)
    func leavesUndoAsItWasWhenStoppedBeforeAnythingWasWritten() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let (src, _, _) = try folders(root)
                try Disk.write(src + "/a.txt", "a")
                let signal = StopSignal()
                let fileSystem = TestFileSystem()
                fileSystem.copyFileImpl = { _, _, _, _ in
                    signal.stop()
                    throw StopError()
                }

                let run = try await runPaste(
                    mode: .cut, sources: [src + "/a.txt"], into: volume.path, fileSystem: fileSystem, signal: signal)

                #expect(run.result?.status == .cancelled)
                #expect(Disk.read(src + "/a.txt") == "a")
                #expect(try undoLog(run.result) == .undoable(units: []))
            }
        }
    }

    // The folder was being built under a hidden name on the other disk: stopped, it goes, and nothing was changed,
    // so Undo is left as it was.
    // T-9b055e08 F-257 F-262
    @Test(.tags(.diskImage), .diskImages)
    func changesNothingWhenStoppedJustAfterMakingTheFolderThere() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let (src, _, _) = try folders(root)
                try Disk.write(src + "/Folder/a.txt", "a")
                let signal = StopSignal()
                let native = NativeWriteFileSystem()
                let fileSystem = TestFileSystem(native)
                fileSystem.mkdirImpl = { path in
                    try native.mkdir(path)
                    if path.hasPrefix(volume.path) {
                        signal.stop()
                    }
                }

                let run = try await runPaste(
                    mode: .cut, sources: [src + "/Folder"], into: volume.path, fileSystem: fileSystem, signal: signal)

                #expect(run.result?.status == .cancelled)
                #expect(Disk.read(src + "/Folder/a.txt") == "a")
                #expect(Disk.list(volume.path).filter { $0.contains("Folder") } == [])
                #expect(try undoLog(run.result) == .undoable(units: []))
            }
        }
    }
}
