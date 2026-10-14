// Port of "same-filesystem rename optimization" (packages/core/src/fs/copyPasteExecution.test.ts), but for the cases
// that Replace (P3-04's)
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// Whether a call happened, from any thread.
final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}

/// A copy as the mock does it, with the source's size, noting that it happened.
func copyingSize(_ fileSystem: MockWriteServiceFileSystem, _ called: Flag? = nil)
    -> (String, String, StopSignal?, (@Sendable (Int64) -> Void)?) throws -> Void
{
    { source, destination, stop, _ in
        try stop?.throwIfStopped()
        called?.set()
        fileSystem.addFile(destination, .file(size: fileSystem.readNode(source)?.size ?? 0))
    }
}

struct CopyPasteExecutionRenameTests {
    // T-a2db2911 F-283 F-462
    @Test func usesRenameForSameDevCutFile() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = { _, _, _, _ in copied.set() }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-file-1")

        #expect(!copied.isSet)
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-62a90ca4 F-283 F-462
    @Test func usesRenameForSameDevCutSymlink() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/link", .symlink("actual.txt")), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/link"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-symlink-1")

        #expect(!fileSystem.exists("/source/link"))
        #expect(fileSystem.readNode("/target/link")?.kind == .symlink)
        #expect(fileSystem.readNode("/target/link")?.target == "actual.txt")
    }

    // T-09b8c7ae F-283 F-462
    @Test func usesRenameForSameDevCutDirectoryMovingTheWholeSubtreeAtOnce() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 3)),
            ("/source/dir/sub", .directory()), ("/source/dir/sub/b.txt", .file(size: 7)), ("/target", .directory()),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = { _, _, _, _ in copied.set() }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-dir-1")

        #expect(!copied.isSet)
        #expect(!fileSystem.exists("/source/dir"))
        #expect(!fileSystem.exists("/source/dir/a.txt"))
        #expect(!fileSystem.exists("/source/dir/sub/b.txt"))
        #expect(fileSystem.readNode("/target/dir")?.kind == .directory)
        #expect(fileSystem.readNode("/target/dir/a.txt")?.size == 3)
        #expect(fileSystem.readNode("/target/dir/sub/b.txt")?.size == 7)
    }

    // T-cc2feb3b F-462
    @Test func fallsBackToCopyAndDeleteForCrossDevCut() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 1)), ("/source/a.txt", .file(size: 5, dev: 1)),
            ("/target", .directory(dev: 2)),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = copyingSize(fileSystem, copied)
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-cross-dev-1")

        #expect(copied.isSet)
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-69474f3e F-466
    @Test func treatsExternallyRemovedSourceDirectoriesAsAlreadyCleanedUpInCutMode() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 5)),
            ("/target", .directory()),
        ])
        fileSystem.rmImpl = { path, _, _ in
            if path == "/source/dir/a.txt" {
                fileSystem.deleteNode("/source/dir/a.txt")
                fileSystem.deleteNode("/source/dir")
                return
            }
            if !fileSystem.deleteNode(path) {
                throw MockWriteServiceFileSystem.error("ENOENT", path)
            }
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "cut-source-dir-already-gone-1")

        #expect(events.last?.status == .completed)
        #expect(!fileSystem.exists("/source/dir"))
        #expect(fileSystem.readNode("/target/dir/a.txt")?.size == 5)
    }

    /// Another disk: renames out of /source fail; a file put in place at /target doesn't.
    private func renamesOutOfSourceFail(_ fileSystem: MockWriteServiceFileSystem) {
        fileSystem.renameImpl = { from, to in
            if from.hasPrefix("/source/") {
                throw NativeError(message: "EXDEV", code: "EXDEV", path: "/source/a.txt")
            }
            try fileSystem.renameDirectly(from, to)
        }
    }

    // T-ff15a058 F-283 F-462
    @Test func fallsBackToCopyAndDeleteOnEXDEVError() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        renamesOutOfSourceFail(fileSystem)
        let copied = Flag()
        fileSystem.copyFileImpl = copyingSize(fileSystem, copied)
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-exdev-1")

        #expect(copied.isSet)
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-690f0044 F-283 F-462
    @Test func reportsNonEXDEVRenameErrorsAsOperationFailures() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.renameImpl = { _, _ in throw NativeError(message: "EPERM", code: "EPERM", path: "/source/a.txt") }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "rename-eperm-1")

        #expect(events.last?.status == .failed)
        #expect(events.last?.result?.error == "You don't have permission to access this item.")
        #expect(fileSystem.exists("/source/a.txt"))
        #expect(!fileSystem.exists("/target/a.txt"))
    }

    // T-e6eab4e1 F-462
    @Test func doesNotUseRenameForCopyModeOnlyCut() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = copyingSize(fileSystem, copied)
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-copy-mode-1")

        #expect(copied.isSet)
        #expect(fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-1fd60fb6 F-462
    @Test func mergesDirectoriesInsteadOfRenamingWhenActionIsMerge() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 3)),
            ("/source/dir/b.txt", .file(size: 4)), ("/target", .directory()), ("/target/dir", .directory()),
            ("/target/dir/existing.txt", .file(size: 9)),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-merge-1")

        // existing.txt kept (a merge, not a Replace); the items moved one by one.
        #expect(fileSystem.readNode("/target/dir/existing.txt")?.size == 9)
        #expect(!fileSystem.exists("/source/dir/a.txt"))
        #expect(!fileSystem.exists("/source/dir/b.txt"))
        #expect(fileSystem.readNode("/target/dir/a.txt")?.size == 3)
        #expect(fileSystem.readNode("/target/dir/b.txt")?.size == 4)
    }

    // T-347d1040 F-462
    @Test func renameWithKeepBothUsesAlternateDestinationName() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 8)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        let policy = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target", policy: policy)

        await execute(fileSystem, operation, operationId: "rename-keepboth-1", policy: policy)

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 2)
        #expect(fileSystem.readNode("/target/a copy.txt")?.size == 8)
    }

    // T-49ec9582 F-283 F-462
    @Test func renamePreservesInode() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5, mode: 0o755)), ("/target", .directory()),
        ])
        let original = try #require(fileSystem.readNode("/source/a.txt"))
        let (originalIno, originalMtimeMs) = (original.ino, original.mtimeMs)
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-preserve-1")

        let moved = fileSystem.readNode("/target/a.txt")
        #expect(moved?.ino == originalIno)
        #expect(moved?.mode == 0o755)
        #expect(moved?.mtimeMs == originalMtimeMs)
    }

    // T-49147656 F-465
    @Test func mixedDevBatchRenamesSomeItemsAndCopiesAndDeletesOthers() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source1", .directory(dev: 1)), ("/source1/a.txt", .file(size: 3, dev: 1)),
            ("/source2", .directory(dev: 2)), ("/source2/b.txt", .file(size: 7, dev: 2)),
            ("/target", .directory(dev: 1)),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = copyingSize(fileSystem, copied)
        let originalInoA = fileSystem.readNode("/source1/a.txt")?.ino
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source1/a.txt", "/source2/b.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-mixed-dev-1")

        // a.txt renamed (same disk), keeping its inode; b.txt copied, then removed (another disk).
        #expect(fileSystem.readNode("/target/a.txt")?.ino == originalInoA)
        #expect(!fileSystem.exists("/source1/a.txt"))
        #expect(copied.isSet)
        #expect(!fileSystem.exists("/source2/b.txt"))
        #expect(fileSystem.readNode("/target/b.txt")?.size == 7)
    }

    // T-61a311d1 F-462
    @Test func exdevFallbackStillPerformsInlineSourceDeletion() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        renamesOutOfSourceFail(fileSystem)
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-exdev-inline-1")

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-ffc2a129 F-260
    @Test func renameOverwriteSkipsPreDeleteWhenTheDestinationVanishedBeforeExecution() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 10)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        let removals = OSAllocatedUnfairLock(initialState: [String]())
        fileSystem.rmImpl = { path, recursive, force in
            removals.withLock { $0.append(path) }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
        let policy = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .overwrite)
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target", policy: policy)
        // The destination goes between the review and the paste.
        fileSystem.deleteNode("/target/a.txt")

        await execute(fileSystem, operation, operationId: "rename-overwrite-vanished-1", policy: policy)

        #expect(removals.withLock { $0 } == [])
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 10)
    }

    // T-4486c341 F-257 F-464
    @Test func cancellationBetweenRenameOperations() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 3)), ("/source/b.txt", .file(size: 4)),
            ("/source/c.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let signal = StopSignal()
        let renames = OSAllocatedUnfairLock(initialState: 0)
        fileSystem.renameImpl = { oldPath, newPath in
            let count = renames.withLock { value in
                value += 1
                return value
            }
            let size = fileSystem.readNode(oldPath)?.size ?? 0
            fileSystem.deleteNode(oldPath)
            fileSystem.addFile(newPath, .file(size: size))
            if count == 1 {
                signal.stop()
            }
        }
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt", "/source/b.txt", "/source/c.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-cancel-1", signal: signal)

        #expect(fileSystem.exists("/target/a.txt"))
        #expect(fileSystem.exists("/source/b.txt"))
        #expect(fileSystem.exists("/source/c.txt"))
    }

    // T-57bc373d F-462
    @Test func renameWithRuntimeConflictResolvedAsSkipPreservesSource() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")
        // Made after the review: a question.
        fileSystem.addFile("/target/a.txt", .file(size: 99))

        await execute(
            fileSystem, operation, operationId: "rename-runtime-skip-1", requestResolution: { _ in .immediate(.skip) })

        #expect(fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 99)
    }

    // T-8769504f F-325 F-464
    @Test func classifiesARuntimeCreatedDestinationDirectoryForAFileAsATypeMismatch() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")
        fileSystem.addDirectory("/target/a.txt")
        let recorder = PasteRecorder()

        let events = await execute(
            fileSystem, operation, operationId: "runtime-created-type-mismatch-1", recorder: recorder,
            requestResolution: { _ in .immediate(.skip) })

        #expect(recorder.conflicts.map(\.reason) == [.destinationCreated])
        #expect(recorder.conflicts.map(\.conflictClass) == [.typeMismatch])
        #expect(events.contains { $0.status == .awaitingResolution })
        #expect(events.last?.status == .partial)
    }

    // T-fe3bbf2d F-325
    @Test(arguments: [RuntimeConflictReason.destinationDeleted, .destinationChanged])
    func promptsWhenAnOverwriteDestinationChangesAfterAnalysis(reason: RuntimeConflictReason) async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 99)),
        ])
        let policy = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .overwrite)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: policy)
        if reason == .destinationDeleted {
            fileSystem.deleteNode("/target/a.txt")
        } else {
            fileSystem.mutateNode("/target/a.txt") { _ in }
        }
        let recorder = PasteRecorder()

        await execute(
            fileSystem, operation, operationId: "runtime-\(reason.rawValue)-1", policy: policy, recorder: recorder,
            requestResolution: { _ in .immediate(.skip) })

        // A destination gone is no question: it is written as a new item. One changed is asked about.
        #expect(fileSystem.exists("/source/a.txt"))
        if reason == .destinationChanged {
            #expect(recorder.conflicts.map(\.reason) == [reason])
        }
    }

    // T-71dfe8b1 F-281 F-464
    @Test func countsAFolderRenamedWholeAsOneItemOfASizeNotKnown() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 100)),
            ("/source/dir/b.txt", .file(size: 200)), ("/source/dir/sub", .directory()),
            ("/source/dir/sub/c.txt", .file(size: 300)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "rename-byte-progress-1")

        // What is inside it wasn't read.
        let summary = events.last?.result?.summary
        #expect(summary?.completedItemCount == 1)
        #expect(summary?.totalBytes == nil)
        #expect(fileSystem.exists("/target/dir/sub/c.txt"))
    }
}
