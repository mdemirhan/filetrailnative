// What a Replace records for Undo
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// Folders merged, and files inside them replaced.
private let mergeAndReplace = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)

private func idOf(_ path: String) -> ItemId? {
    Disk.lstat(path).flatMap { stats in stats.dev.flatMap { dev in stats.ino.map { ItemId(dev: dev, ino: $0) } } }
}

private func undoLog(_ result: CopyPasteOperationResult?) throws -> UndoLog {
    try #require(result?.undoLog, "The paste recorded nothing for Undo.")
}

private func steps(_ log: UndoLog) -> [[UndoStep]] {
    guard case .undoable(let units) = log else {
        Issue.record("The paste can't be undone: \(log)")
        return []
    }
    return units.map(\.steps)
}

private func withFolders(_ body: (_ src: String, _ dst: String, _ trash: String) async throws -> Void) async throws {
    try await withTemporaryDirectory { root in
        let (src, dst, trash) = (root.path + "/src", root.path + "/dst", root.path + "/Trash")
        for folder in [src, dst, trash] {
            try Disk.makeDirectories(folder)
        }
        try await body(src, dst, trash)
    }
}

struct CopyUndoReplaceTests {
    @Test func recordsTheOldItemsPlaceInTheTrashThenTheNewItemForAReplace() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")
            let oldId = idOf(dst + "/a.txt")
            let dstId = idOf(dst)

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            let unit = try #require(steps(try undoLog(run.result)).first)
            #expect(unit.count == 2)
            #expect(
                unit.first
                    == .trashed(
                        from: dst + "/a.txt", trashPath: trash + "/1-a.txt", id: oldId, parentId: dstId, stamp: nil))
            if case .created(let path, let id, _)? = unit.last {
                #expect(path == dst + "/a.txt")
                #expect(id == idOf(dst + "/a.txt"))
            } else {
                Issue.record("Not a created step: \(String(describing: unit.last))")
            }
            #expect(Disk.read(trash + "/1-a.txt") == "old")
            // Nothing about the hidden name the new item was built under.
            #expect(!"\(unit)".contains(".filetrail"))
        }
    }

    // The Trash's size, and the sizes of what holds it, stayed as they were.
    @Test func saysWhereInTheTrashTheItemsAReplaceMovedOutOfTheWayWent() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(src + "/b.txt", "b")
            try Disk.write(dst + "/a.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt", src + "/b.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            #expect(run.result?.trashedPaths == [trash + "/1-a.txt"])
        }
    }

    // As a Replace of an item picked: the old item's trip to the Trash, then the new item, one unit.
    @Test func recordsAReplaceInsideAMergedFolderAsAUnitOfItsOwn() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")
            let oldId = idOf(dst + "/Folder/a.txt")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Folder"], into: dst, policy: mergeAndReplace,
                fileSystem: NativePaste.withTrash(trash))

            #expect(Disk.read(dst + "/Folder/a.txt") == "new")
            let units = steps(try undoLog(run.result))
            guard units.count == 1, units[0].count == 1, case .merged(let merge) = units[0][0] else {
                Issue.record("Not one merged step: \(units)")
                return
            }
            #expect(merge.units.count == 1)
            let unit = merge.units.first?.steps ?? []
            #expect(unit.count == 2)
            if case .trashed(let from, let trashPath, let id, _, _)? = unit.first {
                #expect(from == dst + "/Folder/a.txt")
                #expect(trashPath == trash + "/1-a.txt")
                #expect(id == oldId)
            } else {
                Issue.record("Not a trashed step: \(String(describing: unit.first))")
            }
            if case .created(let path, let id, _)? = unit.last {
                #expect(path == dst + "/Folder/a.txt")
                #expect(id == idOf(dst + "/Folder/a.txt"))
            } else {
                Issue.record("Not a created step: \(String(describing: unit.last))")
            }
        }
    }

    @Test func cantBeUndoneOnceAReplaceDeletesTheOldItemForGood() async throws {
        try await withFolders { src, dst, _ in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: { _ in throw noTrashHere() }),
                // Asked whether to delete it for good, the person says yes.
                resolve: { _ in .overwrite })

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(Disk.read(dst + "/a.txt") == "new")
            #expect(try undoLog(run.result) == .notUndoable(reason: .deletedForGood))
        }
    }
}

struct MoveUndoReplaceTests {
    @Test func recordsTheOldItemsPlaceInTheTrashThenTheMoveForAReplace() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")
            let movedId = idOf(src + "/a.txt")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            let units = steps(try undoLog(run.result))
            #expect(units.count == 1)
            let unit = units.first ?? []
            #expect(unit.count == 2)
            if case .trashed(let from, _, _, _, _)? = unit.first {
                #expect(from == dst + "/a.txt")
            } else {
                Issue.record("Not a trashed step: \(String(describing: unit.first))")
            }
            if case .moved(let moved)? = unit.last {
                #expect(moved.from == src + "/a.txt")
                #expect(moved.to == dst + "/a.txt")
                #expect(moved.id == movedId)
            } else {
                Issue.record("Not a moved step: \(String(describing: unit.last))")
            }
        }
    }

    @Test func recordsAReplaceInsideAMergingMoveAsAUnitOfItsOwn() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")
            let (movedId, folderId) = (idOf(src + "/Folder/a.txt"), idOf(src + "/Folder"))

            let run = try await runPaste(
                mode: .cut, sources: [src + "/Folder"], into: dst, policy: mergeAndReplace,
                fileSystem: NativePaste.withTrash(trash))

            #expect(Disk.read(dst + "/Folder/a.txt") == "new")
            #expect(!Disk.exists(src + "/Folder"))
            let units = steps(try undoLog(run.result))
            guard units.count == 1, units[0].count == 1, case .merged(let merge) = units[0][0] else {
                Issue.record("Not one merged step: \(units)")
                return
            }
            #expect(merge.removed?.id == folderId)
            let unit = merge.units.first?.steps ?? []
            #expect(unit.count == 2)
            if case .trashed(let from, _, _, _, _)? = unit.first {
                #expect(from == dst + "/Folder/a.txt")
            } else {
                Issue.record("Not a trashed step: \(String(describing: unit.first))")
            }
            if case .moved(let moved)? = unit.last {
                #expect(moved.from == src + "/Folder/a.txt")
                #expect(moved.to == dst + "/Folder/a.txt")
                #expect(moved.id == movedId)
                #expect(moved.parentId == folderId)
            } else {
                Issue.record("Not a moved step: \(String(describing: unit.last))")
            }
        }
    }

    // The source seems to be on a disk of its own (another device number, EXDEV out of it), so the move copies and
    // then removes, as one to a real other disk does.
    @Test func leavesUndoAsItWasWhenAReplaceCouldntCopyTheNewItem() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")
            let fileSystem = TestFileSystem(NativePaste.withTrash(trash))
            fileSystem.copyFileImpl = { _, _, _, _ in
                throw NativeError(message: "EIO: i/o error", code: .errno(EIO))
            }

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.asOnAnotherDisk(src, fileSystem))

            #expect(run.result?.status == .failed)
            #expect(Disk.read(dst + "/a.txt") == "old")
            #expect(Disk.list(trash) == [])
            #expect(try undoLog(run.result) == .undoable(units: []))
        }
    }

    // The source seems to be on a disk of its own, as above. The Trash the replaced item goes to is on the disk it
    // is on, as a real disk's own Trash is.
    @Test func cantBeUndoneOnceAReplacePutTheNewItemInPlace() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.asOnAnotherDisk(src, NativePaste.withTrash(trash)))

            #expect(Disk.read(dst + "/a.txt") == "new")
            #expect(try undoLog(run.result) == .notUndoable(reason: .otherDiskMove))
        }
    }
}
