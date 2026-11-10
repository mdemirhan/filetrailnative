import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// The review and resolution of a paste on the disk itself (thresholds 100 items, 10,000 bytes).
func realOperation(
    _ fileSystem: any WriteServiceFileSystem, mode: CopyPasteMode, sources: [String], into destination: String,
    policy: CopyPastePolicy = addMissing
) throws -> (report: CopyPasteAnalysisReport, resolvedNodes: [ResolvedCopyPasteNode]) {
    let report = try buildCopyPasteAnalysisReport(
        analysisId: "analysis-realfs",
        request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
        fileSystem: fileSystem,
        thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 10000))
    return (report, try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem))
}

/// The date of an item, in milliseconds.
func mtimeMs(_ path: String) -> Double? {
    Disk.lstat(path)?.mtimeMs
}

/// `utimes(path, date, date)`.
func setDate(_ path: String, _ milliseconds: Double) throws {
    try NativeFS.utimes(path, atimeMs: milliseconds, mtimeMs: milliseconds)
}

struct CopyPasteExecutionRealFSTests {
    @Test func cutMovesFileSourceGoneDestinationPresentWithCorrectContent() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/hello.txt", "hello world")
            try Disk.makeDirectories(destination)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: [source + "/hello.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-cut-1")

            #expect(!Disk.exists(source + "/hello.txt"))
            #expect(Disk.read(destination + "/hello.txt") == "hello world")
        }
    }

    @Test func midCancelCutLeavesACleanPartitionOnTheRealFilesystem() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]
            for name in names {
                try Disk.write(source + "/" + name, "content of \(name)")
            }
            try Disk.makeDirectories(destination)
            let signal = StopSignal()
            let copies = OSAllocatedUnfairLock(initialState: 0)
            // As to another disk, so the copy and delete path is taken.
            let fileSystem = NativePaste.asOnAnotherDisk(source)
            let native = NativeWriteFileSystem()
            fileSystem.copyFileImpl = { from, to, stop, progress in
                try stop?.throwIfStopped()
                let count = copies.withLock { value in
                    value += 1
                    return value
                }
                try native.copyFile(from, to, stop: stop, onProgress: progress)
                if count == 3 {
                    signal.stop()
                }
            }
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: names.map { source + "/" + $0 }, into: destination)

            await execute(fileSystem, operation, operationId: "realfs-cut-cancel-1", signal: signal)

            // The first three are at the destination only, the rest at the source only.
            for name in names.prefix(3) {
                #expect(!Disk.exists(source + "/" + name))
                #expect(Disk.exists(destination + "/" + name))
            }
            for name in names.dropFirst(3) {
                #expect(Disk.exists(source + "/" + name))
                #expect(!Disk.exists(destination + "/" + name))
            }
        }
    }

    @Test func aFailedCopyWhoseMessageSaysAbortedIsNotTakenForAStop() async throws {
        try await withTemporaryDirectory { root in
            // The error names the source's path, which holds "Aborted".
            let (source, destination) = (root.path + "/Aborted Takes", root.path + "/dst")
            try Disk.write(source + "/a.txt", "unreadable")
            try Disk.write(source + "/b.txt", "readable")
            try Disk.makeDirectories(destination)
            #expect(chmod(source + "/a.txt", 0) == 0)
            defer { _ = chmod(source + "/a.txt", 0o644) }
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(
                fileSystem, mode: .copy, sources: [source + "/a.txt", source + "/b.txt"], into: destination)

            let events = await execute(fileSystem, operation, operationId: "realfs-aborted-name-1")

            let result = try #require(events.last?.result)
            #expect(events.last?.status != .cancelled)
            #expect(result.items.map(\.status) == [.failed, .completed])
            #expect(result.items.first?.error == "You don't have permission to access this item.")
            #expect(Disk.read(destination + "/b.txt") == "readable")
        }
    }

    @Test func cutPreservesSourceWhenExternallyModifiedDuringCopy() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/data.txt", "original")
            try Disk.makeDirectories(destination)
            // As to another disk, so the copy and delete path is taken.
            let fileSystem = NativePaste.asOnAnotherDisk(source)
            let native = NativeWriteFileSystem()
            fileSystem.copyFileImpl = { from, to, stop, progress in
                try native.copyFile(from, to, stop: stop, onProgress: progress)
                // The source changes once it is copied.
                try Disk.write(from, "modified after copy")
            }
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: [source + "/data.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-cut-preserve-1")

            #expect(Disk.read(source + "/data.txt") == "modified after copy")
            #expect(Disk.read(destination + "/data.txt") == "original")
        }
    }

    @Test func renameWithinTheSameTmpdirPreservesInode() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/data.txt", "rename test content")
            try Disk.makeDirectories(destination)
            let originalIno = Disk.lstat(source + "/data.txt")?.ino
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: [source + "/data.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-rename-1")

            #expect(!Disk.exists(source + "/data.txt"))
            #expect(Disk.read(destination + "/data.txt") == "rename test content")
            // The same inode: renamed, not copied.
            #expect(Disk.lstat(destination + "/data.txt")?.ino == originalIno)
        }
    }

    @Test func renamePreservesMtimeOnTheRealFilesystem() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/timed.txt", "mtime test")
            try Disk.makeDirectories(destination)
            // 2020-06-15T10:30:00.000Z
            let target = 1_592_217_000_000.0
            try setDate(source + "/timed.txt", target)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: [source + "/timed.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-rename-mtime-1")

            #expect(!Disk.exists(source + "/timed.txt"))
            #expect(abs((mtimeMs(destination + "/timed.txt") ?? 0) - target) < 1000)
        }
    }

    @Test func copyPreservesMtimeForDirectoriesViaUtimes() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/subdir/child.txt", "hello")
            try Disk.makeDirectories(destination)
            // 2019-03-20T08:00:00.000Z
            let target = 1_553_068_800_000.0
            try setDate(source + "/subdir", target)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .copy, sources: [source + "/subdir"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-utimes-dir-1")

            #expect(Disk.exists(destination + "/subdir"))
            #expect(abs((mtimeMs(destination + "/subdir") ?? 0) - target) < 1000)
        }
    }

    @Test func copyPreservesMtimeForSymlinksViaUtimes() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/target.txt", "target content")
            try Disk.makeDirectories(destination)
            try Disk.symlink(source + "/target.txt", source + "/link")
            // 2018-01-01T00:00:00.000Z, on the link itself (what it points to keeps today's date).
            let target = 1_514_764_800_000.0
            var times = [timespec(tv_sec: 1_514_764_800, tv_nsec: 0), timespec(tv_sec: 1_514_764_800, tv_nsec: 0)]
            try #require(utimensat(AT_FDCWD, source + "/link", &times, AT_SYMLINK_NOFOLLOW) == 0)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .copy, sources: [source + "/link"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-utimes-symlink-1")

            #expect(Disk.lstat(destination + "/link")?.type == .symlink)
            #expect(abs((mtimeMs(destination + "/link") ?? 0) - target) < 1000)
        }
    }

    @Test func renameAndInlineCutNoCopySourceMovedAtomically() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/atom.txt", "atomic move")
            try Disk.makeDirectories(destination)
            let originalIno = Disk.lstat(source + "/atom.txt")?.ino
            let copied = Flag()
            let fileSystem = TestFileSystem()
            fileSystem.copyFileImpl = { _, _, _, _ in copied.set() }
            let operation = try realOperation(
                fileSystem, mode: .cut, sources: [source + "/atom.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-integration-rename-cut")

            #expect(!copied.isSet)
            #expect(!Disk.exists(source + "/atom.txt"))
            #expect(Disk.lstat(destination + "/atom.txt")?.ino == originalIno)
        }
    }

    @Test func copyModeWithUtimesSourcePreservedDestinationHasContent() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/keep.txt", "keep me")
            try Disk.makeDirectories(destination)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(
                fileSystem, mode: .copy, sources: [source + "/keep.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-integration-copy-utimes")

            #expect(Disk.exists(source + "/keep.txt"))
            #expect(Disk.read(destination + "/keep.txt") == "keep me")
        }
    }
}
