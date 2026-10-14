// Port of the Replace cases of packages/core/src/fs/copyPasteUndoLog.realfs.test.ts (its other cases are in
// Execution/UndoRecordingTests.swift): what a Replace records for Undo
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
    // T-271c5c8b F-342
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
    // T-b2b14d9c F-342
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

    // T-a1ed3e3b
    @Test func cantBeUndoneWhenAllAMergeDidWasReplaceAnItemInTheFolder() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Folder"], into: dst, policy: mergeAndReplace,
                fileSystem: NativePaste.withTrash(trash))

            #expect(Disk.read(dst + "/Folder/a.txt") == "new")
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // T-41d67e83 F-343
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
    // T-36ef50f8 F-342
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

    // T-ca0ca81f
    @Test func cantBeUndoneWhenAllAMergeOnItsOwnDiskDidWasReplaceAnItem() async throws {
        try await withFolders { src, dst, trash in
            try Disk.write(src + "/Folder/a.txt", "new")
            try Disk.write(dst + "/Folder/a.txt", "old")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/Folder"], into: dst, policy: mergeAndReplace,
                fileSystem: NativePaste.withTrash(trash))

            #expect(Disk.read(dst + "/Folder/a.txt") == "new")
            #expect(try undoLog(run.result) == .notUndoable(reason: .merge))
        }
    }

    // T-17121de6
    @Test(.tags(.diskImage), .diskImages)
    func leavesUndoAsItWasWhenAReplaceCouldntCopyTheNewItem() async throws {
        try await withFolders { src, _, trash in
            try await DiskImage.withVolume(.apfs) { volume in
                try Disk.write(src + "/a.txt", "new")
                try Disk.write(volume.path + "/a.txt", "old")
                let fileSystem = TestFileSystem(NativePaste.withTrash(trash))
                fileSystem.copyFileImpl = { _, _, _, _ in
                    throw NativeError(message: "EIO: i/o error", code: "EIO")
                }

                let run = try await runPaste(
                    mode: .cut, sources: [src + "/a.txt"], into: volume.path, policy: NativePaste.replaceAll,
                    fileSystem: fileSystem)

                #expect(run.result?.status == .failed)
                #expect(Disk.read(volume.path + "/a.txt") == "old")
                #expect(Disk.list(trash) == [])
                #expect(try undoLog(run.result) == .undoable(units: []))
            }
        }
    }

    // T-4492a990
    @Test(.tags(.diskImage), .diskImages)
    func cantBeUndoneOnceAReplacePutTheNewItemInPlace() async throws {
        try await withFolders { src, _, _ in
            try await DiskImage.withVolume(.apfs) { volume in
                try Disk.write(src + "/a.txt", "new")
                try Disk.write(volume.path + "/a.txt", "old")
                // The disk's own Trash: an item can't be renamed into a folder on another disk.
                let volumeTrash = volume.path + "/.Trash"
                try Disk.makeDirectories(volumeTrash)

                let run = try await runPaste(
                    mode: .cut, sources: [src + "/a.txt"], into: volume.path, policy: NativePaste.replaceAll,
                    fileSystem: NativePaste.withTrash(volumeTrash))

                #expect(Disk.read(volume.path + "/a.txt") == "new")
                #expect(try undoLog(run.result) == .notUndoable(reason: .otherDiskMove))
            }
        }
    }
}
