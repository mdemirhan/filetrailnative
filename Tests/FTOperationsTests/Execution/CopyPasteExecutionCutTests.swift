// Port of "per-file cut flow" (packages/core/src/fs/copyPasteExecution.test.ts): the items are on another disk
// (dev 2), so a move copies each, then removes its original
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

struct CopyPasteExecutionCutTests {
    /// Copies as the mock does, with the source's size.
    private func copyingSize(_ fileSystem: MockWriteServiceFileSystem)
        -> (String, String, StopSignal?, (@Sendable (Int64) -> Void)?) throws -> Void
    {
        { source, destination, stop, _ in
            try stop?.throwIfStopped()
            fileSystem.addFile(destination, .file(size: fileSystem.readNode(source)?.size ?? 0))
        }
    }

    /// Removes as the mock does, but `path` fails with EPERM.
    private func failingRemoval(_ fileSystem: MockWriteServiceFileSystem, _ failing: String)
        -> (String, Bool, Bool) throws -> Void
    {
        { path, recursive, force in
            if path == failing {
                throw NativeError(message: "EPERM", code: "EPERM", path: path)
            }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
    }

    // T-da4e0088 F-461
    @Test func deletesSourceFileImmediatelyAfterSuccessfulCopy() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 3)), ("/source/b.txt", .file(size: 4)),
            ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt", "/source/b.txt"], into: "/target")
        let sourceExistedDuringSecondCopy = OSAllocatedUnfairLock(initialState: [Bool]())
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, progress in
            if source == "/source/b.txt" {
                let exists = fileSystem.exists("/source/a.txt")
                sourceExistedDuringSecondCopy.withLock { $0.append(exists) }
            }
            try copy(source, destination, stop, progress)
        }

        await execute(fileSystem, operation, operationId: "cut-inline-1")

        #expect(sourceExistedDuringSecondCopy.withLock { $0 } == [false])
        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(!fileSystem.exists("/source/b.txt"))
        #expect(fileSystem.exists("/target/a.txt"))
        #expect(fileSystem.exists("/target/b.txt"))
    }

    // T-7128aaad F-461
    @Test func deletesSourceSymlinkImmediatelyAfterSuccessfulCopy() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/link", .symlink("actual.txt")), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/link"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-symlink-1")

        #expect(!fileSystem.exists("/source/link"))
        #expect(fileSystem.readNode("/target/link")?.kind == .symlink)
        #expect(fileSystem.readNode("/target/link")?.target == "actual.txt")
    }

    // T-fff0c98c F-257 F-262
    @Test func stoppedPartWayThroughAFolderLeavesEveryOriginalAndNothingCopied() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/source/dir/b.txt", .file(size: 2)), ("/source/dir/c.txt", .file(size: 3)), ("/target", .directory()),
        ])
        let signal = StopSignal()
        let copyCount = OSAllocatedUnfairLock(initialState: 0)
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, progress in
            try copy(source, destination, stop, progress)
            let count = copyCount.withLock { value in
                value += 1
                return value
            }
            if count == 2 {
                signal.stop()
            }
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-cancel-1", signal: signal)

        // The folder was built under a hidden name, which went with the stop.
        #expect(try fileSystem.readdir("/target") == [])
        for name in ["a.txt", "b.txt", "c.txt"] {
            #expect(fileSystem.exists("/source/dir/\(name)"))
        }
    }

    // T-e684da1c F-279
    @Test func preservesSourceFileWhenSourceMutatedAfterCopy() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 5))
            fileSystem.mutateNode(source) { $0.size = 99 }
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-mutated-1")

        #expect(fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/source/a.txt")?.size == 99)
        #expect(fileSystem.exists("/target/a.txt"))
    }

    // T-b974155f F-461
    @Test func preservesSourceFileWhenSourceDeletedExternallyAfterCopy() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 5))
            fileSystem.deleteNode(source)
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-external-delete-1")

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.exists("/target/a.txt"))
    }

    // T-2d3a3dc0 F-284 F-461
    @Test func removesEmptySourceDirectoryAfterAllChildrenDeleted() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/source/dir/b.txt", .file(size: 2)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-rmdir-1")

        #expect(!fileSystem.exists("/source/dir"))
        #expect(fileSystem.exists("/source"))
        #expect(fileSystem.exists("/target/dir/a.txt"))
        #expect(fileSystem.exists("/target/dir/b.txt"))
    }

    // T-b5739b37 F-284 F-461
    @Test func preservesNonEmptySourceDirectoryWhenSomeChildrenSkipped() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/source/dir/b.txt", .file(size: 2)), ("/target", .directory()), ("/target/dir", .directory()),
            ("/target/dir/b.txt", .file(size: 3)),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-partial-skip-1")

        #expect(fileSystem.exists("/source/dir"))
        #expect(fileSystem.exists("/source/dir/b.txt"))
        #expect(!fileSystem.exists("/source/dir/a.txt"))
        #expect(fileSystem.exists("/target/dir/a.txt"))
    }

    // T-4072637e F-285
    @Test func preservesSourceDirectoryWhenDirectoryModeChangedExternally() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory(mode: 0o755)),
            ("/source/dir/a.txt", .file(size: 1)), ("/target", .directory()),
        ])
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, progress in
            try copy(source, destination, stop, progress)
            fileSystem.mutateNode("/source/dir") { $0.mode = 0o700 }
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-dir-changed-1")

        #expect(fileSystem.exists("/source/dir"))
        #expect(!fileSystem.exists("/source/dir/a.txt"))
        #expect(fileSystem.exists("/target/dir/a.txt"))
    }

    // T-e85b5090 F-284
    @Test func emptySourceDirectoryRmFailureReportsItemAsFailed() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/target", .directory()),
        ])
        fileSystem.rmdirImpl = { path in throw NativeError(message: "EPERM", code: "EPERM", path: path) }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "cut-rmdir-fail-1")

        // Partial: the folder failed (its original couldn't be removed).
        #expect(events.last?.status == .partial)
        let first = events.last?.result?.items.first
        #expect(first?.status == .failed)
        #expect(first?.error?.contains("the original folder couldn't be removed") == true)
        // Its items were moved.
        #expect(fileSystem.exists("/target/dir/a.txt"))
        #expect(!fileSystem.exists("/source/dir/a.txt"))
        // The emptied original stays (rmdir failed).
        #expect(fileSystem.exists("/source/dir"))
    }

    // T-446f7a30 F-461
    @Test func inlineDeletionRmFailureReportsItemAsFailedButContinuesOperation() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 1)), ("/source/b.txt", .file(size: 2)),
            ("/target", .directory()),
        ])
        fileSystem.rmImpl = failingRemoval(fileSystem, "/source/a.txt")
        let operation = try createResolvedOperation(
            fileSystem, mode: .cut, sources: ["/source/a.txt", "/source/b.txt"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "cut-rm-fail-1")

        // Partial: a.txt failed (its original stayed), b.txt was moved.
        #expect(events.last?.status == .partial)
        let items = events.last?.result?.items ?? []
        #expect(items.first?.status == .failed)
        #expect(items.first?.error?.contains("the original couldn't be removed") == true)
        #expect(items.dropFirst().first?.status == .completed)
        #expect(fileSystem.exists("/target/a.txt"))
        #expect(fileSystem.exists("/target/b.txt"))
        #expect(fileSystem.exists("/source/a.txt"))
        #expect(!fileSystem.exists("/source/b.txt"))
    }

    // T-41ba71f5 F-284
    @Test func handlesNestedDirectoryCutWithMixedActions() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/new.txt", .file(size: 1)),
            ("/source/dir/conflict.txt", .file(size: 5)), ("/target", .directory()), ("/target/dir", .directory()),
            ("/target/dir/conflict.txt", .file(size: 3)),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-mixed-1")

        // new.txt moved; conflict.txt skipped (its original kept); so the folder stays.
        #expect(!fileSystem.exists("/source/dir/new.txt"))
        #expect(fileSystem.exists("/target/dir/new.txt"))
        #expect(fileSystem.exists("/source/dir/conflict.txt"))
        #expect(fileSystem.readNode("/target/dir/conflict.txt")?.size == 3)
        #expect(fileSystem.exists("/source/dir"))
    }

    // T-2e830d91 F-461
    @Test func sourceRmCalledOnlyOncePerFileNoRedundantCleanupPass() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let removals = OSAllocatedUnfairLock(initialState: [String]())
        fileSystem.rmImpl = { path, recursive, force in
            removals.withLock { $0.append(path) }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "cut-no-double-rm-1")

        #expect(removals.withLock { $0 }.filter { $0 == "/source/a.txt" }.count == 1)
    }

    // T-7bb1f9cf F-461
    @Test func cutWithRuntimeConflictResolvedAsSkipPreservesSource() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")
        fileSystem.addFile("/target/a.txt", .file(size: 2))

        await execute(
            fileSystem, operation, operationId: "cut-runtime-skip-1", requestResolution: { _ in .immediate(.skip) })

        #expect(fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 2)
    }

    // T-9257a90b F-284
    @Test func nestedChildFileDeletionFailurePropagatesToParentDirectoryStatus() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/source/dir/b.txt", .file(size: 2)), ("/target", .directory()),
        ])
        fileSystem.rmImpl = failingRemoval(fileSystem, "/source/dir/a.txt")
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "nested-child-fail-1")

        // The folder failed, as an item in it did.
        #expect(events.last?.status == .partial)
        #expect(events.last?.result?.items.first?.status == .failed)
        #expect(fileSystem.exists("/source/dir/a.txt"))
        #expect(!fileSystem.exists("/source/dir/b.txt"))
        #expect(fileSystem.exists("/target/dir/a.txt"))
        #expect(fileSystem.exists("/target/dir/b.txt"))
    }

    // T-4391a680 F-279
    @Test func mutatedSourceFileReportsAsFailedNotCompleted() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 5))
            fileSystem.mutateNode(source) { $0.size = 99 }
        }
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "cut-mutated-status-1")

        // Its original was kept (changed after the copy), and nothing else was pasted: the paste failed.
        #expect(events.last?.status == .failed)
        let first = events.last?.result?.items.first
        #expect(first?.status == .failed)
        #expect(first?.error?.contains("so the original was kept") == true)
        #expect(fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.exists("/target/a.txt"))
    }
}
