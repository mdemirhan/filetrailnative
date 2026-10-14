// Port of the edge cases and cut cleanups of packages/core/src/fs/copyPasteExecution.test.ts ("copyPasteExecution"),
// on the mock disk
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct CopyPasteExecutionEdgeTests {
    // The step where a changed destination is answered with Replace is P3-04's: it is left out here.
    // T-706c8576 F-269 F-271 F-278 F-324
    @Test func handlesSourceDeletionRuntimeDirectoryMergesPartialCancellationAndChmodEdgeCases() async throws {
        let deletedSource = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let deletedOperation = try createResolvedOperation(
            deletedSource, sources: ["/source/file.txt"], into: "/target")
        try deletedSource.rm("/source/file.txt", recursive: false, force: false)
        let deletedRecorder = PasteRecorder()

        let deletedEvents = await execute(
            deletedSource, deletedOperation, recorder: deletedRecorder, requestResolution: { _ in .immediate(.skip) })

        #expect(deletedRecorder.conflicts.map(\.reason) == [.sourceDeleted])
        #expect(deletedEvents.last?.status == .partial)

        let mergeAtRuntime = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        let mergeOperation = try createResolvedOperation(mergeAtRuntime, sources: ["/source/Folder"], into: "/target")
        mergeAtRuntime.addDirectory("/target/Folder")
        let mergeRecorder = PasteRecorder()

        await execute(
            mergeAtRuntime, mergeOperation, operationId: "copy-op-3", recorder: mergeRecorder,
            requestResolution: { _ in .immediate(.merge) })

        #expect(mergeRecorder.conflicts.map(\.conflictClass) == [.directoryConflict])
        #expect(mergeAtRuntime.exists("/target/Folder/file.txt"))

        let partialCancel = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/one.txt", .file(size: 1)), ("/source/two.txt", .file(size: 2)),
            ("/target", .directory()),
        ])
        partialCancel.copyFileImpl = { source, destination, stop, _ in
            if source.hasSuffix("two.txt") {
                waitUntilStopped(stop)
                try stop?.throwIfStopped()
            }
            partialCancel.addFile(destination, .file(size: source.hasSuffix("two.txt") ? 2 : 1))
        }
        let partialOperation = try createResolvedOperation(
            partialCancel, sources: ["/source/one.txt", "/source/two.txt"], into: "/target")
        let signal = StopSignal()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { signal.stop() }

        let partialEvents = await execute(partialCancel, partialOperation, operationId: "copy-op-4", signal: signal)

        #expect(partialEvents.last?.status == .partial)

        let chmodIgnored = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        chmodIgnored.chmodImpl = { _, _ in throw codedError("EOPNOTSUPP", "unsupported") }
        let ignoredOperation = try createResolvedOperation(chmodIgnored, sources: ["/source/file.txt"], into: "/target")

        await execute(chmodIgnored, ignoredOperation, operationId: "copy-op-5")

        #expect(chmodIgnored.exists("/target/file.txt"))

        let chmodFailure = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        chmodFailure.chmodImpl = { _, _ in throw codedError("EPERM", "chmod denied") }
        let failureOperation = try createResolvedOperation(chmodFailure, sources: ["/source/file.txt"], into: "/target")

        let failureEvents = await execute(chmodFailure, failureOperation, operationId: "copy-op-6")

        // The file was copied; a volume that refuses its mode doesn't make the copy a failure.
        #expect(failureEvents.last?.status == .completed)
        #expect(failureEvents.last?.result?.error == nil)
        #expect(chmodFailure.exists("/target/file.txt"))
    }

    // T-eb95d949 F-466
    @Test func removesSourceDirectoriesAfterSuccessfulCutCopiesAndSupportsFilesystemsWithoutChmod() async throws {
        let cutDirectory = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        let cutOperation = try createResolvedOperation(
            cutDirectory, mode: .cut, sources: ["/source/Folder"], into: "/target")

        await execute(cutDirectory, cutOperation)

        #expect(!cutDirectory.exists("/source/Folder"))
        #expect(cutDirectory.exists("/target/Folder/file.txt"))

        let base = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let noChmod = TestFileSystem(base)
        noChmod.chmod = nil
        let noChmodOperation = try createResolvedOperation(base, sources: ["/source/file.txt"], into: "/target")

        await execute(noChmod, noChmodOperation, operationId: "copy-op-2")

        #expect(base.exists("/target/file.txt"))
    }

    // T-637bb845 F-466
    @Test func movesDirectoriesWithHiddenFilesAndHiddenFoldersDuringCut() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/.env", .file(size: 7)),
            ("/source/Folder/.config", .directory()), ("/source/Folder/.config/settings.json", .file(size: 11)),
            ("/source/Folder/visible.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let policy = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/Folder"], into: "/target", policy: policy)

        await execute(fileSystem, operation, operationId: "cut-op-hidden-1", policy: policy)

        #expect(fileSystem.exists("/target/Folder/.env"))
        #expect(fileSystem.exists("/target/Folder/.config"))
        #expect(fileSystem.exists("/target/Folder/.config/settings.json"))
        #expect(fileSystem.exists("/target/Folder/visible.txt"))
        #expect(!fileSystem.exists("/source/Folder"))
    }

    // T-7f71a8fd F-466
    @Test func removesEmptiedCutSourceFoldersWhenChildDeletionsOnlyChangeParentMtime() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/file.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        fileSystem.rmImpl = { path, recursive, force in
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
            if path == "/source/Folder/file.txt" {
                fileSystem.mutateNode("/source/Folder") { _ in }
            }
        }
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/Folder"], into: "/target")

        await execute(fileSystem, operation, operationId: "copy-op-3")

        #expect(!fileSystem.exists("/source/Folder"))
        #expect(fileSystem.exists("/target/Folder/file.txt"))
    }

    // T-125afc8b F-285
    @Test func preservesCutSourceDirectoriesWhenTheSourceFolderChangesBeforeCleanup() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/Folder", .directory()),
            ("/source/Folder/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 5))
            if source.hasSuffix("file.txt") {
                fileSystem.mutateNode("/source/Folder") { $0.mode = 0o700 }
            }
        }
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/Folder"], into: "/target")

        await execute(fileSystem, operation)

        #expect(fileSystem.exists("/source/Folder"))
        #expect(fileSystem.exists("/target/Folder/file.txt"))
    }
}
