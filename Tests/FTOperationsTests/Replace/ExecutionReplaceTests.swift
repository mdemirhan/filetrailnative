// Port of the Replace cases of packages/core/src/fs/copyPasteExecution.test.ts (on the mock disk) and of
// copyPasteExecution.realfs.test.ts (its others are in Execution/)
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// `recordRmCalls`: each removal (its path, and whether it was recursive), taking away the item and what is in it.
private func recordRmCalls(_ fileSystem: MockWriteServiceFileSystem) -> Locked<[[String]]> {
    let calls = Locked<[[String]]>([])
    fileSystem.rmImpl = { path, recursive, _ in
        calls.mutate { $0.append([path, String(recursive)]) }
        try fileSystem.removeDirectly(path, recursive: true, force: true)
    }
    return calls
}

private let overwriteFiles = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
private let overwriteFilesAndMismatches = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .overwrite)
private let overwriteFilesAndFolders = CopyPastePolicy(file: .overwrite, directory: .overwrite, mismatch: .skip)

private func node(_ fileSystem: MockWriteServiceFileSystem, _ path: String) throws -> MockWriteServiceFileSystem.Node {
    try #require(fileSystem.readNode(path), "Nothing at \(path)")
}

struct ExecutionReplaceTests {
    // T-dc9ef314 F-342
    @Test func overwritesConflictingFilesWhenTheResolvedActionRequiresIt() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5, mode: 0o755)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 2, mode: 0o644)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/file.txt"], into: "/target", policy: overwriteFiles)

        await execute(fileSystem, operation, policy: overwriteFiles)

        let file = try node(fileSystem, "/target/file.txt")
        #expect(file.kind == .file)
        #expect(file.size == 5)
        #expect(file.mode == 0o755)
    }

    // T-b6120d61 F-343
    @Test func treatsADestinationThatVanishesWhileBeingDeletedPermanentlyAsAlreadyRemoved() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 2)),
        ])
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/file.txt"], into: "/target", policy: overwriteFiles)
        let removedOnce = Locked(false)
        fileSystem.rmImpl = { path, recursive, force in
            if path == "/target/file.txt" && !removedOnce.value {
                removedOnce.mutate { $0 = true }
                fileSystem.deleteNode("/target/file.txt")
                if force {
                    return
                }
                throw MockWriteServiceFileSystem.error("ENOENT", path)
            }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }

        await execute(
            fileSystem, operation, operationId: "copy-op-enoent", policy: overwriteFiles,
            // No Trash here: the person agreed to delete the existing item permanently.
            requestResolution: { .immediate($0.reason == .trashUnavailable ? .overwrite : nil) })

        let file = try node(fileSystem, "/target/file.txt")
        #expect(file.kind == .file)
        #expect(file.size == 5)
    }

    // T-ac6200ce
    @Test func mergesExistingFoldersAndAppliesNestedFileActions() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/new.txt", .file(size: 1)),
            ("/source/Folder/shared.txt", .file(size: 8, mode: 0o755)), ("/target", .directory()),
            ("/target/Folder", .directory()), ("/target/Folder/shared.txt", .file(size: 2, mode: 0o644)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Folder"], into: "/target", policy: overwriteFiles)

        await execute(fileSystem, operation, policy: overwriteFiles)

        #expect(fileSystem.readNode("/target/Folder/new.txt")?.size == 1)
        #expect(fileSystem.readNode("/target/Folder/shared.txt")?.size == 8)
        #expect(fileSystem.readNode("/target/Folder/shared.txt")?.mode == 0o755)
    }

    // T-c924e277 F-342
    @Test func replacesConflictingFoldersAndDeletesDestinationOnlyNestedItems() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()),
            ("/source/Folder/shared.txt", .file(size: 8, mode: 0o755)), ("/target", .directory()),
            ("/target/Folder", .directory()), ("/target/Folder/shared.txt", .file(size: 2, mode: 0o644)),
            ("/target/Folder/destination-only.txt", .file(size: 3, mode: 0o600)),
            ("/target/Folder/nested", .directory()),
            ("/target/Folder/nested/left-behind.txt", .file(size: 1, mode: 0o600)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Folder"], into: "/target", policy: overwriteFilesAndFolders)

        await execute(fileSystem, operation, policy: overwriteFilesAndFolders)

        #expect(fileSystem.readNode("/target/Folder/shared.txt")?.size == 8)
        #expect(fileSystem.readNode("/target/Folder/shared.txt")?.mode == 0o755)
        #expect(!fileSystem.exists("/target/Folder/destination-only.txt"))
        #expect(!fileSystem.exists("/target/Folder/nested/left-behind.txt"))
    }

    // T-23f2ab89
    @Test func doesNotPromptForNestedDescendantConflictsUnderAReplacedFolder() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/nested", .directory()),
            ("/source/Folder/nested/deep.txt", .file(size: 8, mode: 0o755)), ("/target", .directory()),
            ("/target/Folder", .directory()), ("/target/Folder/nested", .directory()),
            ("/target/Folder/nested/deep.txt", .file(size: 2, mode: 0o644)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Folder"], into: "/target", policy: overwriteFilesAndFolders)
        let recorder = PasteRecorder()

        await execute(
            fileSystem, operation, policy: overwriteFilesAndFolders, recorder: recorder,
            requestResolution: { _ in .immediate(.overwrite) })

        #expect(recorder.conflicts.isEmpty)
        #expect(fileSystem.readNode("/target/Folder/nested/deep.txt")?.size == 8)
        #expect(fileSystem.readNode("/target/Folder/nested/deep.txt")?.mode == 0o755)
    }

    // T-aa23acf2
    @Test func overwritesAConflictingFileWithASourceDirectoryWhenMismatchPolicyRequestsOverwrite() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Photos", .directory()), ("/source/Photos/a.jpg", .file(size: 3)),
            ("/target", .directory()), ("/target/Photos", .file(size: 9)),
        ])
        fileSystem.enableTrash()
        let policy = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .overwrite)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Photos"], into: "/target", policy: policy)

        await execute(fileSystem, operation, policy: policy)

        #expect(fileSystem.readNode("/target/Photos")?.kind == .directory)
        #expect(fileSystem.readNode("/target/Photos/a.jpg")?.size == 3)
    }

    // T-71769d45 F-339
    @Test func pausesForRuntimeDestinationConflictsAndResumesWithTheChosenResolution() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/file.txt"], into: "/target")
        fileSystem.addFile("/target/file.txt", .file(size: 99))
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, recorder: recorder, requestResolution: { _ in .immediate(.overwrite) })

        #expect(recorder.conflicts.map(\.reason) == [.destinationCreated])
        #expect(events.contains { $0.status == .awaitingResolution })
        #expect(fileSystem.readNode("/target/file.txt")?.size == 5)
    }

    // MARK: Per-file cut flow

    // T-c889312f
    @Test func cutWithRuntimeConflictResolvedAsOverwriteDeletesSourceInline() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")
        fileSystem.addFile("/target/a.txt", .file(size: 2))

        await execute(
            fileSystem, operation, operationId: "cut-runtime-overwrite-1",
            requestResolution: { _ in .immediate(.overwrite) })

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(try node(fileSystem, "/target/a.txt").size == 5)
    }

    // MARK: Same-filesystem rename

    // T-192af090 F-342 F-463
    @Test func renameWithOverwriteMovesTheItemInAndTheReplacedOneToTheTrash() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 10)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target", policy: overwriteFilesAndMismatches)

        await execute(fileSystem, operation, operationId: "rename-overwrite-1", policy: overwriteFilesAndMismatches)

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(try node(fileSystem, "/target/a.txt").size == 10)
        #expect(fileSystem.trashed == ["/target/a.txt"])
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-ee6a7a32 F-342 F-463
    @Test func renameOfDirectoryWithOverwriteActionMovesTheReplacedDirectoryToTheTrash() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 3)),
            ("/target", .directory()), ("/target/dir", .directory()), ("/target/dir/old.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target", policy: NativePaste.replaceAll)

        await execute(fileSystem, operation, operationId: "rename-dir-overwrite-1", policy: NativePaste.replaceAll)

        #expect(!fileSystem.exists("/source/dir"))
        #expect(try node(fileSystem, "/target/dir/a.txt").size == 3)
        // old.txt gone because the folder was replaced, not merged.
        #expect(!fileSystem.exists("/target/dir/old.txt"))
        #expect(fileSystem.trashed == ["/target/dir"])
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-8cf7f825 F-343 F-463
    @Test func renameOverwriteWithoutATrashDeletesTheExistingItemOnlyWhenThePersonAgrees() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 10)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        let rmCalls = recordRmCalls(fileSystem)
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target", policy: overwriteFilesAndMismatches)
        let recorder = PasteRecorder()

        await execute(
            fileSystem, operation, operationId: "rename-overwrite-no-trash-1", policy: overwriteFilesAndMismatches,
            recorder: recorder, requestResolution: { _ in .immediate(.overwrite) })

        #expect(recorder.conflicts.map(\.reason) == [.trashUnavailable])
        #expect(rmCalls.value == [["/target/a.txt", "false"]])
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(try node(fileSystem, "/target/a.txt").size == 10)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-03dcc5bc F-343 F-345 F-463
    @Test func renameOverwriteWithoutATrashPutsEverythingBackWhenThePersonSkips() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 3)),
            ("/target", .directory()), ("/target/dir", .directory()), ("/target/dir/old.txt", .file(size: 1)),
        ])
        let rmCalls = recordRmCalls(fileSystem)
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target", policy: NativePaste.replaceAll)

        let events = await execute(
            fileSystem, operation, operationId: "rename-overwrite-no-trash-skip-1", policy: NativePaste.replaceAll,
            requestResolution: { _ in .immediate(.skip) })

        #expect(rmCalls.value.isEmpty)
        #expect(try node(fileSystem, "/source/dir/a.txt").size == 3)
        #expect(try node(fileSystem, "/target/dir/old.txt").size == 1)
        #expect(!fileSystem.exists("/target/dir/a.txt"))
        #expect(fileSystem.temporaryLeftovers() == [])
        let item = events.last?.result?.items.first
        #expect(item?.status == .skipped)
        #expect(item?.skipReason == .runtimeConflictResolution)
    }

    // T-342e6072 F-463
    @Test func renameOverwriteOfADirectoryByAFile() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/item", .file(size: 6)), ("/target", .directory()),
            ("/target/item", .directory()), ("/target/item/old.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/item"], into: "/target", policy: NativePaste.replaceAll)

        await execute(
            fileSystem, operation, operationId: "rename-overwrite-file-over-dir-1", policy: NativePaste.replaceAll)

        #expect(fileSystem.trashed == ["/target/item"])
        #expect(!fileSystem.exists("/source/item"))
        #expect(try node(fileSystem, "/target/item").kind == .file)
        #expect(try node(fileSystem, "/target/item").size == 6)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-5cb81f6b F-463
    @Test func renameOverwriteOfAFileByADirectory() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/item", .directory()), ("/source/item/a.txt", .file(size: 4)),
            ("/target", .directory()), ("/target/item", .file(size: 9)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/item"], into: "/target", policy: NativePaste.replaceAll)

        await execute(
            fileSystem, operation, operationId: "rename-overwrite-dir-over-file-1", policy: NativePaste.replaceAll)

        #expect(fileSystem.trashed == ["/target/item"])
        #expect(!fileSystem.exists("/source/item"))
        #expect(try node(fileSystem, "/target/item").kind == .directory)
        #expect(try node(fileSystem, "/target/item/a.txt").size == 4)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-de750b08 F-340
    @Test func renameWithRuntimeConflictResolvedAsOverwriteUsesRename() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let copyFileCalled = Locked(false)
        fileSystem.copyFileImpl = { _, _, _, _ in copyFileCalled.mutate { $0 = true } }
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")
        // Made after the review: a question while the paste runs.
        fileSystem.addFile("/target/a.txt", .file(size: 99))

        await execute(
            fileSystem, operation, operationId: "rename-runtime-overwrite-1",
            requestResolution: { _ in .immediate(.overwrite) })

        #expect(!copyFileCalled.value)
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(try node(fileSystem, "/target/a.txt").size == 5)
    }

    // MARK: Native copyFile

    // T-8c371eee F-342
    @Test func copyFileWithOverwriteDestinationMovedToTheTrashThenReplaced() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 10)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        fileSystem.enableTrash()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: overwriteFilesAndMismatches)

        await execute(fileSystem, operation, operationId: "native-overwrite-1", policy: overwriteFilesAndMismatches)

        #expect(try node(fileSystem, "/target/a.txt").size == 10)
        #expect(fileSystem.trashed == ["/target/a.txt"])
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // MARK: The Replace journal

    // T-b53285ff F-345 F-523
    @Test func clearsAReplaceFromTheJournalWhenItsStagedCopyFailsAndIsUndone() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 9)),
        ])
        fileSystem.enableTrash()
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError("EIO") }
        let journal = ReplaceHistoryJournal()
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: NativePaste.replaceAll)

        let events = await execute(
            fileSystem, operation, operationId: "op-metadata", policy: NativePaste.replaceAll, writeJournal: journal)

        #expect(events.last?.result?.status == .failed)
        #expect(journal.history.count == 1)
        #expect(journal.live.isEmpty)
        #expect(try node(fileSystem, "/target/a.txt").size == 9)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-68d8d731 F-345 F-523
    @Test func clearsAMovedReplaceFromTheJournalWhenTheMoveToTheHiddenNameFails() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 9)),
        ])
        fileSystem.enableTrash()
        fileSystem.renameImpl = { _, _ in throw codedError("EACCES") }
        let journal = ReplaceHistoryJournal()
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target", policy: NativePaste.replaceAll)

        let events = await execute(
            fileSystem, operation, operationId: "op-metadata", policy: NativePaste.replaceAll, writeJournal: journal)

        #expect(events.last?.result?.status == .failed)
        #expect(journal.history.map(\.moved) == [true])
        #expect(journal.live.isEmpty)
        #expect(fileSystem.readNode("/source/a.txt") != nil)
        #expect(try node(fileSystem, "/target/a.txt").size == 9)
    }
}

struct ExecutionReplaceRealFSTests {
    // T-4dbcade3 F-342 F-463 F-413
    @Test func renameOverwriteMovesTheFileIntoPlaceAndTheOldOneToTheTrash() async throws {
        try await withTemporaryDirectory { root in
            let (srcDir, dstDir, trashDir) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            try Disk.write(srcDir + "/data.txt", "new content")
            try Disk.write(dstDir + "/data.txt", "old content")
            try Disk.makeDirectories(trashDir)
            let originalIno = Disk.lstat(srcDir + "/data.txt")?.ino
            // Nothing is deleted permanently: the replaced file goes to the Trash.
            let rmPaths = Locked<[String]>([])
            let fileSystem = TestFileSystem(NativeWriteFileSystem(trash: trashInto(trashDir)))
            fileSystem.rmImpl = { path, recursive, force in
                rmPaths.mutate { $0.append(path) }
                try NativeWriteFileSystem().rm(path, recursive: recursive, force: force)
            }
            let report = try buildCopyPasteAnalysisReport(
                analysisId: "analysis-realfs",
                request: CopyPasteAnalysisRequest(
                    mode: .cut, sourcePaths: [srcDir + "/data.txt"], destinationDirectoryPath: dstDir),
                fileSystem: fileSystem,
                thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 10000))
            let resolvedNodes = try resolveAnalysisWithPolicy(
                report: report, policy: overwriteFilesAndMismatches, fileSystem: fileSystem)

            await execute(
                fileSystem, (report, resolvedNodes), operationId: "realfs-rename-overwrite-1",
                policy: overwriteFilesAndMismatches)

            #expect(rmPaths.value == [])
            #expect(!Disk.exists(srcDir + "/data.txt"))
            #expect(Disk.read(dstDir + "/data.txt") == "new content")
            #expect(Disk.read(trashDir + "/data.txt") == "old content")
            #expect(Disk.list(dstDir) == ["data.txt"])
            // Same inode as the source = moved by rename, not copied.
            #expect(Disk.lstat(dstDir + "/data.txt")?.ino == originalIno)
        }
    }
}
