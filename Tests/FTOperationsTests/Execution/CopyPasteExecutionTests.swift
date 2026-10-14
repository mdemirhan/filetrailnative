// Port of the first cases of packages/core/src/fs/copyPasteExecution.test.ts ("copyPasteExecution"), on the mock
// disk
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

let addMissing = CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip)

struct CopyPasteExecutionTests {
    // Add Missing leaves the files already there: progress runs to what is copied, not to the size of everything
    // picked.
    // T-9a1d4621 F-447
    @Test func countsOnlyWhatAnAddMissingMergeCopiesTowardTheBytesToGo() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F/a.txt", .file(size: 10)), ("/source/F/b.txt", .file(size: 20)),
            ("/target/F/a.txt", .file(size: 10)),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/F"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "op-add-missing")

        #expect(operation.report.summary.totalBytes == 30)
        #expect(events.map(\.totalBytes) == events.map { _ in 20 })
        let summary = events.last?.result?.summary
        #expect(summary?.completedByteCount == 20)
        #expect(summary?.totalBytes == 20)
    }

    // T-3d53c383 F-447
    @Test func copiesANewFileAndEmitsACompletedResult() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/file.txt"], into: "/target")

        let events = await execute(fileSystem, operation)

        #expect(fileSystem.exists("/target/file.txt"))
        #expect(events.last?.status == .completed)
        #expect(events.last?.result?.summary.completedItemCount == 1)
    }

    // T-e0613e7b F-448
    @Test func copiesDirectoriesWithHiddenFilesAndHiddenFolders() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/.env", .file(size: 7)),
            ("/source/Folder/.config", .directory()), ("/source/Folder/.config/settings.json", .file(size: 11)),
            ("/source/Folder/visible.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let policy = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Folder"], into: "/target", policy: policy)

        await execute(fileSystem, operation, operationId: "copy-op-hidden-1", policy: policy)

        #expect(fileSystem.exists("/target/Folder/.env"))
        #expect(fileSystem.exists("/target/Folder/.config"))
        #expect(fileSystem.exists("/target/Folder/.config/settings.json"))
        #expect(fileSystem.exists("/target/Folder/visible.txt"))
    }

    // T-1f1fa985 F-450
    @Test func keepsBothConflictingFilesWhenRequested() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/report.txt", .file(size: 7)), ("/target", .directory()),
            ("/target/report.txt", .file(size: 2)), ("/target/report copy.txt", .file(size: 2)),
        ])
        let policy = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/report.txt"], into: "/target", policy: policy)

        await execute(fileSystem, operation, policy: policy)

        #expect(fileSystem.exists("/target/report copy 2.txt"))
    }

    // T-dc4def7e F-450
    @Test func keepsBothConflictingDirectoriesByCreatingADuplicateDestinationAndCopyingChildrenIntoIt() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/a.txt", .file(size: 7)),
            ("/target", .directory()), ("/target/Folder", .directory()), ("/target/Folder copy", .directory()),
        ])
        let policy = CopyPastePolicy(file: .overwrite, directory: .keepBoth, mismatch: .skip)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/Folder"], into: "/target", policy: policy)

        await execute(fileSystem, operation, policy: policy)

        #expect(fileSystem.readNode("/target/Folder copy 2")?.kind == .directory)
        #expect(fileSystem.readNode("/target/Folder copy 2/a.txt")?.size == 7)
    }

    // T-ff86e124 F-273 F-451
    @Test func copiesSymlinksAsSymlinks() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/alias", .symlink("actual.txt")), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/alias"], into: "/target")

        await execute(fileSystem, operation)

        #expect(fileSystem.readNode("/target/alias")?.kind == .symlink)
        #expect(fileSystem.readNode("/target/alias")?.target == "actual.txt")
    }

    // T-e321bc6b F-257
    @Test func supportsCancellationDuringStreamCopy() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/slow.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { _, destination, stop, _ in
            waitUntilStopped(stop)
            try stop?.throwIfStopped()
            fileSystem.addFile(destination, .file(size: 5))
        }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/slow.txt"], into: "/target")
        let signal = StopSignal()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { signal.stop() }

        let events = await execute(fileSystem, operation, signal: signal)

        #expect(events.last?.status == .cancelled)
        #expect(!fileSystem.exists("/target/slow.txt"))
    }

    // T-df49b768 F-279 F-461
    @Test func removesSourceFilesAfterSuccessfulCutAndPreservesChangedSourcesDuringCleanup() async throws {
        let moved = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let moveOperation = try createResolvedOperation(
            moved, mode: .cut, sources: ["/source/file.txt"], into: "/target")

        await execute(moved, moveOperation, operationId: "cut-op-1")

        #expect(!moved.exists("/source/file.txt"))
        #expect(moved.exists("/target/file.txt"))

        // On another disk, so the file is copied and its original then removed.
        let changedSource = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        changedSource.copyFileImpl = { source, destination, _, _ in
            changedSource.addFile(destination, .file(size: 5))
            changedSource.mutateNode(source) { $0.size += 1 }
        }
        let changedOperation = try createResolvedOperation(
            changedSource, mode: .cut, sources: ["/source/file.txt"], into: "/target")

        await execute(changedSource, changedOperation, operationId: "cut-op-2")

        #expect(changedSource.exists("/source/file.txt"))
        #expect(changedSource.exists("/target/file.txt"))
    }

    // T-447a6911 F-280 F-455
    @Test func reportsSkippedItemsAsAPartialResultWhenTheResolvedTopLevelActionIsSkip() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 2)),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/file.txt"], into: "/target")

        let events = await execute(fileSystem, operation)

        #expect(events.last?.status == .partial)
        #expect(events.last?.result?.items.map(\.status) == [.skipped])
        #expect(events.last?.result?.items.map(\.skipReason) == [.plannedConflictPolicy])
    }

    // T-4981f124 F-257
    @Test func cancelsImmediatelyWhenTheSignalIsAlreadyAborted() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/file.txt"], into: "/target")
        let signal = StopSignal()
        signal.stop()

        let events = await execute(fileSystem, operation, signal: signal)

        #expect(events.last?.status == .cancelled)
    }

    // T-0290cd75 F-280 F-453 F-455
    @Test func reportsPartialAndFailedResultsWhenLaterOrFirstItemsFail() async throws {
        let partial = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/one.txt", .file(size: 1)), ("/source/two.txt", .file(size: 2)),
            ("/target", .directory()),
        ])
        partial.copyFileImpl = { source, destination, _, _ in
            if source.hasSuffix("two.txt") {
                throw OperationError("Disk full")
            }
            partial.addFile(destination, .file(size: 1))
        }
        let partialOperation = try createResolvedOperation(
            partial, sources: ["/source/one.txt", "/source/two.txt"], into: "/target")

        let partialEvents = await execute(partial, partialOperation)

        #expect(partialEvents.last?.status == .partial)
        #expect(partialEvents.last?.result?.error == "Disk full")

        let failed = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/one.txt", .file(size: 1)), ("/target", .directory()),
        ])
        failed.copyFileImpl = { _, _, _, _ in throw OperationError("Permission denied") }
        let failedOperation = try createResolvedOperation(failed, sources: ["/source/one.txt"], into: "/target")

        let failedEvents = await execute(failed, failedOperation, operationId: "copy-op-2")

        #expect(failedEvents.last?.status == .failed)
        #expect(failedEvents.last?.result?.error == "Permission denied")
    }

    // T-340e0d10 F-324
    @Test func failsWhenARuntimeConflictIsNotResolvedAndCanSkipAChangedSourceAfterPrompting() async throws {
        let unresolved = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let unresolvedOperation = try createResolvedOperation(
            unresolved, sources: ["/source/file.txt"], into: "/target")
        unresolved.addFile("/target/file.txt", .file(size: 2))

        let unresolvedEvents = await execute(unresolved, unresolvedOperation)

        #expect(unresolvedEvents.last?.status == .failed)
        #expect(unresolvedEvents.last?.result?.error == "Runtime conflict was not resolved.")

        let changedSource = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let changedOperation = try createResolvedOperation(
            changedSource, sources: ["/source/file.txt"], into: "/target")
        changedSource.mutateNode("/source/file.txt") { $0.size += 1 }
        let recorder = PasteRecorder()

        let changedEvents = await execute(
            changedSource, changedOperation, operationId: "copy-op-2", recorder: recorder,
            requestResolution: { _ in .immediate(.skip) })

        #expect(recorder.conflicts.map(\.reason) == [.sourceChanged])
        #expect(changedEvents.last?.status == .partial)
        #expect(changedEvents.last?.result?.items.map(\.status) == [.skipped])
        #expect(changedEvents.last?.result?.items.map(\.skipReason) == [.runtimeConflictResolution])
    }

    // T-2d44909c F-260 F-466
    @Test func handlesDestinationChangesForOverwriteConflictsWithoutRePromptingAndPreservesNonEmptyCutFolders()
        async throws
    {
        let changedDestination = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/file.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/file.txt", .file(size: 1)),
        ])
        let policy = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
        let changedOperation = try createResolvedOperation(
            changedDestination, sources: ["/source/file.txt"], into: "/target", policy: policy)
        try changedDestination.rm("/target/file.txt", recursive: false, force: false)
        let recorder = PasteRecorder()

        let changedEvents = await execute(changedDestination, changedOperation, policy: policy, recorder: recorder)

        #expect(changedDestination.exists("/target/file.txt"))
        #expect(recorder.conflicts.isEmpty)
        #expect(!changedEvents.contains { $0.status == .awaitingResolution })

        let cutFolder = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/Folder", .directory()), ("/source/Folder/file.txt", .file(size: 5)),
            ("/target", .directory()), ("/target/Folder", .directory()), ("/target/Folder/file.txt", .file(size: 1)),
        ])
        let cutOperation = try createResolvedOperation(
            cutFolder, mode: .cut, sources: ["/source/Folder"], into: "/target")

        await execute(cutFolder, cutOperation, operationId: "copy-op-2")

        #expect(cutFolder.exists("/source/Folder"))
        #expect(cutFolder.exists("/source/Folder/file.txt"))
    }
}
