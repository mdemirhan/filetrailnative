// What a paste records for Undo, one unit per item picked, with the steps it really took, or why it can't be undone
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

/// Adds an access rule to the item, as `chmod +a` does.
func addAccessRule(_ path: String, _ rule: String) throws {
    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", rule, path]
    try chmod.run()
    chmod.waitUntilExit()
    #expect(chmod.terminationStatus == 0)
}

/// The merge a unit is, as its only step; nil (and said) when it isn't one.
private func merged(_ unit: [UndoStep]?) -> UndoStep.Merged? {
    guard let unit, unit.count == 1, case .merged(let merged) = unit[0] else {
        Issue.record("Not a unit of one merged step: \(String(describing: unit))")
        return nil
    }
    return merged
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

    @Test func recordsADuplicateUnderTheNameItWasGiven() async throws {
        try await withTemporaryDirectory { root in
            let (src, _, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")

            let run = try await runPaste(mode: .copy, sources: [src + "/a.txt"], into: src)

            let units = try steps(try undoLog(run.result))
            #expect(units.map { $0.map(createdPath) } == [[src + "/a copy.txt"]])
        }
    }

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
                    throw codedError(.errno(EIO), "EIO: i/o error")
                }
                try native.copyFile(from, to, stop: stop, onProgress: progress)
            }

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst, fileSystem: fileSystem)

            #expect(run.result?.status == .partial)
            #expect(try steps(try undoLog(run.result)).map { $0.map(createdPath) } == [[dst + "/Folder"]])
        }
    }

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

    // Each item copied into the folder already there is a unit of its own, inside one step for the folder: the item
    // picked is still one.
    @Test func recordsEachItemCopiedIntoAFolderMergedIntoOneAlreadyThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/new.txt", "new")
            try Disk.write(src + "/Folder/Inside/deep.txt", "deep")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(dst + "/Folder") == ["Inside", "new.txt", "old.txt"])
            let units = try steps(try undoLog(run.result))
            #expect(units.count == 1)
            guard let merge = merged(units.first) else { return }
            #expect(merge.from == src + "/Folder")
            #expect(merge.to == dst + "/Folder")
            #expect(merge.removed == nil && merge.made == nil)
            // A folder that wasn't there is copied whole: one unit, as for any copied folder.
            var made: [String: ItemId?] = [:]
            for unit in merge.units {
                #expect(unit.steps.count == 1)
                if case .created(let path, let id, _)? = unit.steps.first { made[path] = id }
            }
            let expected: [String: ItemId?] = [
                dst + "/Folder/Inside": idOf(dst + "/Folder/Inside"),
                dst + "/Folder/new.txt": idOf(dst + "/Folder/new.txt"),
            ]
            #expect(made == expected)
        }
    }

    @Test func recordsALinkThatIsAllAMergeAdded() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.makeDirectories(src + "/Folder")
            try Disk.symlink("/nowhere", src + "/Folder/link")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            #expect(try PosixFileSystem().readlink(dst + "/Folder/link") == "/nowhere")
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.units.map { $0.steps.map(createdPath) } == [[dst + "/Folder/link"]])
        }
    }

    // A folder inside, also there already, is merged too: a merge in the merge, its items each a unit of their own.
    @Test func recordsAFolderMergedInsideAMergedFolderAsAMergeOfItsOwn() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/Sub/a.txt", "a")
            try Disk.write(src + "/Folder/Sub/b.txt", "b")
            try Disk.write(dst + "/Folder/Sub/old.txt", "old")

            let run = try await runPaste(mode: .copy, sources: [src + "/Folder"], into: dst)

            let outer = merged(try steps(try undoLog(run.result)).first)
            #expect(outer?.units.count == 1)
            let inner = merged(outer?.units.first?.steps)
            #expect(inner?.from == src + "/Folder/Sub")
            #expect(inner?.to == dst + "/Folder/Sub")
            #expect(
                inner?.units.map { $0.steps.map(createdPath) } == [
                    [dst + "/Folder/Sub/a.txt"], [dst + "/Folder/Sub/b.txt"],
                ])
        }
    }

    @Test func recordsAnItemKeptBesideTheOneThereInsideAMergedFolder() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Folder"], into: dst,
                policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip))

            #expect(Disk.read(dst + "/Folder/a copy.txt") == "new")
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.units.map { $0.steps.map(createdPath) } == [[dst + "/Folder/a copy.txt"]])
        }
    }

    // What was copied into it before the stop can be undone.
    @Test func recordsWhatAMergeCopiedBeforeItWasStopped() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "a")
            try Disk.write(src + "/Folder/b.txt", "b")
            try Disk.write(dst + "/Folder/old.txt", "old")
            let signal = StopSignal()

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Folder"], into: dst, signal: signal,
                onEvent: { event in
                    if event.status == .running && event.completedItemCount == 1 {
                        signal.stop()
                    }
                })

            #expect(run.result?.status == .cancelled || run.result?.status == .partial)
            #expect(Disk.list(dst + "/Folder") == ["a.txt", "old.txt"])
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.units.map { $0.steps.map(createdPath) } == [[dst + "/Folder/a.txt"]])
        }
    }

    // Nothing was changed, so Undo must still undo what came before.
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

    // Each item is moved on its own, from the folder that is then removed: what Undo makes again for them.
    @Test func recordsEachItemAMergingMoveTookAndTheFolderItRemoved() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/new.txt", "new")
            try Disk.write(dst + "/Folder/old.txt", "old")
            let (fileId, folderId, srcId) = (idOf(src + "/Folder/new.txt"), idOf(src + "/Folder"), idOf(src))
            let folderDate = mtimeMs(src + "/Folder")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(dst + "/Folder") == ["new.txt", "old.txt"])
            #expect(!Disk.exists(src + "/Folder"))
            let units = try steps(try undoLog(run.result))
            #expect(units.count == 1)
            guard let merge = merged(units.first) else { return }
            #expect(merge.from == src + "/Folder")
            #expect(merge.to == dst + "/Folder")
            #expect(
                merge.units == [
                    UndoUnit(steps: [
                        .moved(
                            .init(
                                from: src + "/Folder/new.txt", to: dst + "/Folder/new.txt", id: fileId, itemKind: .file,
                                parentId: folderId))
                    ])
                ])
            #expect(merge.removed?.path == src + "/Folder")
            #expect(merge.removed?.id == folderId)
            #expect(merge.removed?.parentId == srcId)
            #expect(merge.removed?.attributes.mode == 0o755)
            #expect(merge.removed?.attributes.flags == 0)
            // The date it had before its items were taken out.
            #expect(merge.removed?.attributes.mtimeMs == folderDate)
            #expect(merge.made == nil)
        }
    }

    @Test func recordsAnEmptyFolderMergedIntoAnotherAndRemoved() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.makeDirectories(src + "/Folder")
            try Disk.makeDirectories(dst + "/Folder")
            let folderId = idOf(src + "/Folder")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(src) == [])
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.units == [])
            #expect(merge?.removed?.id == folderId)
        }
    }

    // Its tags, its Hidden flag, its mode and its access rules are kept for Undo to give back.
    @Test func keepsWhatTheRemovedFolderHad() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "a")
            try Disk.makeDirectories(dst + "/Folder")
            let tags = Data([1, 2, 3])
            try NativeFS.setExtendedAttribute(src + "/Folder", "com.apple.metadata:_kMDItemUserTags", tags)
            #expect(chflags(src + "/Folder", UInt32(UF_HIDDEN)) == 0)
            Disk.chmod(src + "/Folder", 0o750)
            try addAccessRule(src + "/Folder", "everyone allow list")
            let acl = try NativeFS.getAcl(src + "/Folder")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(!Disk.exists(src + "/Folder"))
            let attributes = merged(try steps(try undoLog(run.result)).first)?.removed?.attributes
            #expect(attributes?.extendedAttributes?["com.apple.metadata:_kMDItemUserTags"] == tags)
            #expect(attributes?.flags == UInt32(UF_HIDDEN))
            #expect(attributes?.mode == 0o750)
            #expect(acl != nil && attributes?.acl == acl)
        }
    }

    // A folder an item was left in stays where it was: nothing to make again.
    @Test func recordsNoRemovedFolderWhenAMergingMoveLeftAnItemInIt() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(src + "/Folder/b.txt", "b")
            try Disk.write(dst + "/Folder/a.txt", "old")
            let fileId = idOf(src + "/Folder/b.txt")

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(Disk.list(src + "/Folder") == ["a.txt"])
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.removed == nil)
            #expect(
                merge?.units.map(\.steps) == [
                    [
                        .moved(
                            .init(
                                from: src + "/Folder/b.txt", to: dst + "/Folder/b.txt", id: fileId, itemKind: .file,
                                parentId: idOf(src + "/Folder")))
                    ]
                ])
        }
    }

    // The item left in it went away meanwhile: the folder is removed after all, and recorded for Undo to make again.
    @Test func recordsTheFolderRemovedWhenTheItemLeftInItWentAway() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(src + "/Folder/b.txt", "b")
            try Disk.write(dst + "/Folder/a.txt", "old")
            let folderId = idOf(src + "/Folder")
            let fileSystem = TestFileSystem()
            fileSystem.rmdirImpl = { path in
                if path == src + "/Folder" { unlink(src + "/Folder/a.txt") }
                try NativeWriteFileSystem().rmdir(path)
            }

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst, fileSystem: fileSystem)

            #expect(!Disk.exists(src + "/Folder"))
            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(merge?.removed?.id == folderId)
            #expect(merge?.units.count == 1)
        }
    }

    @Test func recordsAFolderMergedInsideAMergingMoveWithTheFolderItRemoved() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/Sub/a.txt", "a")
            try Disk.write(dst + "/Folder/Sub/old.txt", "old")
            let (subId, folderId) = (idOf(src + "/Folder/Sub"), idOf(src + "/Folder"))

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            #expect(!Disk.exists(src + "/Folder"))
            let outer = merged(try steps(try undoLog(run.result)).first)
            #expect(outer?.removed?.id == folderId)
            let inner = merged(outer?.units.first?.steps)
            #expect(inner?.removed?.path == src + "/Folder/Sub")
            #expect(inner?.removed?.id == subId)
            // Known by the folder it was in, which is made again first.
            #expect(inner?.removed?.parentId == folderId)
            #expect(inner?.units.count == 1)
        }
    }

    // Moved into the merged folder whole, a folder that wasn't there is one step, as a moved folder always is.
    @Test func recordsAFolderMovedWholeIntoAMergedFolderAsOneStep() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/New/a.txt", "a")
            try Disk.makeDirectories(dst + "/Folder")
            let (newId, folderId) = (idOf(src + "/Folder/New"), idOf(src + "/Folder"))

            let run = try await runPaste(mode: .cut, sources: [src + "/Folder"], into: dst)

            let merge = merged(try steps(try undoLog(run.result)).first)
            #expect(
                merge?.units.map(\.steps) == [
                    [
                        .moved(
                            .init(
                                from: src + "/Folder/New", to: dst + "/Folder/New", id: newId, itemKind: .directory,
                                parentId: folderId))
                    ]
                ])
        }
    }

    // On another disk the items are copied and their originals deleted: that still can't be undone.
    @Test func cantBeUndoneWhenAMergingMoveWentToAnotherDisk() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/new.txt", "new")
            try Disk.write(dst + "/Folder/old.txt", "old")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/Folder"], into: dst, fileSystem: NativePaste.asOnAnotherDisk(src))

            #expect(Disk.list(dst + "/Folder") == ["new.txt", "old.txt"])
            #expect(try undoLog(run.result) == .notUndoable(reason: .otherDiskMove))
        }
    }

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

    // The source seems to be on a disk of its own (another device number, EXDEV out of it): the engine tells
    // disks apart by device number alone.
    @Test func cantBeUndoneWhenItWentToAnotherDisk() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst, fileSystem: NativePaste.asOnAnotherDisk(src))

            #expect(Disk.read(dst + "/a.txt") == "a")
            #expect(try undoLog(run.result) == .notUndoable(reason: .otherDiskMove))
        }
    }
}

/// A move to another disk, when nothing was changed. The source seems to be on a disk of its own (another device
/// number, EXDEV out of it), so the move copies and then removes, as one to a real other disk does.
struct OtherDiskUndoRecordingTests {
    @Test func leavesUndoAsItWasWhenTheItemCantBeRead() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, trash) = try folders(root)
            try Disk.write(src + "/a.txt", "a")
            let fileSystem = TestFileSystem(NativePaste.withTrash(trash))
            fileSystem.copyFileImpl = { _, _, _, _ in throw codedError(.errno(EACCES), "EACCES: permission denied") }

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst,
                fileSystem: NativePaste.asOnAnotherDisk(src, fileSystem))

            #expect(run.result?.status == .failed)
            #expect(!Disk.list(dst).contains("a.txt"))
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }

    @Test func leavesUndoAsItWasWhenStoppedBeforeAnythingWasWritten() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/a.txt", "a")
            let signal = StopSignal()
            let fileSystem = TestFileSystem()
            fileSystem.copyFileImpl = { _, _, _, _ in
                signal.stop()
                throw StopError()
            }

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst,
                fileSystem: NativePaste.asOnAnotherDisk(src, fileSystem), signal: signal)

            #expect(run.result?.status == .cancelled)
            #expect(Disk.read(src + "/a.txt") == "a")
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }

    // The folder was being built under a hidden name on the other disk: stopped, it goes, and nothing was changed,
    // so Undo is left as it was.
    @Test func changesNothingWhenStoppedJustAfterMakingTheFolderThere() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, _) = try folders(root)
            try Disk.write(src + "/Folder/a.txt", "a")
            let signal = StopSignal()
            let native = NativeWriteFileSystem()
            let fileSystem = TestFileSystem(native)
            fileSystem.mkdirImpl = { path in
                try native.mkdir(path)
                if path.hasPrefix(dst + "/") {
                    signal.stop()
                }
            }

            let run = try await runPaste(
                mode: .cut, sources: [src + "/Folder"], into: dst,
                fileSystem: NativePaste.asOnAnotherDisk(src, fileSystem), signal: signal)

            #expect(run.result?.status == .cancelled)
            #expect(Disk.read(src + "/Folder/a.txt") == "a")
            #expect(Disk.list(dst).filter { $0.contains("Folder") } == [])
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }
}
