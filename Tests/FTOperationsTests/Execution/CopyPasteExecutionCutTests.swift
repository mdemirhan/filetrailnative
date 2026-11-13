// The items are on another disk (dev 2), so a move copies each, then removes its original
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
                throw NativeError(message: "EPERM", code: .errno(EPERM), path: path)
            }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
    }

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

    @Test func emptySourceDirectoryRmFailureReportsItemAsFailed() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/target", .directory()),
        ])
        fileSystem.rmdirImpl = { path in throw NativeError(message: "EPERM", code: .errno(EPERM), path: path) }
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
        #expect(fileSystem.readNode("/source/a.txt")?.size == 99)
        #expect(fileSystem.exists("/target/a.txt"))
    }
}
