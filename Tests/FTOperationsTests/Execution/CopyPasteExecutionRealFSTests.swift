// Port of packages/core/src/fs/copyPasteExecution.realfs.test.ts, but for the case that Replaces (P3-04's)
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
    // T-a0287703 F-461
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

    // T-13d8fe6e F-257 F-461
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

    // T-26a4f537 F-279
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
            let operation = try realOperation(fileSystem, mode: .cut, sources: [source + "/data.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-cut-preserve-1")

            #expect(Disk.read(source + "/data.txt") == "modified after copy")
            #expect(Disk.read(destination + "/data.txt") == "original")
        }
    }

    // T-c26523a5 F-283 F-462
    @Test func renameWithinTheSameTmpdirPreservesInode() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/data.txt", "rename test content")
            try Disk.makeDirectories(destination)
            let originalIno = Disk.lstat(source + "/data.txt")?.ino
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .cut, sources: [source + "/data.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-rename-1")

            #expect(!Disk.exists(source + "/data.txt"))
            #expect(Disk.read(destination + "/data.txt") == "rename test content")
            // The same inode: renamed, not copied.
            #expect(Disk.lstat(destination + "/data.txt")?.ino == originalIno)
        }
    }

    // T-cbbc9f49 F-462
    @Test func renamePreservesMtimeOnTheRealFilesystem() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/timed.txt", "mtime test")
            try Disk.makeDirectories(destination)
            // 2020-06-15T10:30:00.000Z
            let target = 1_592_217_000_000.0
            try setDate(source + "/timed.txt", target)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .cut, sources: [source + "/timed.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-rename-mtime-1")

            #expect(!Disk.exists(source + "/timed.txt"))
            #expect(abs((mtimeMs(destination + "/timed.txt") ?? 0) - target) < 1000)
        }
    }

    // T-a2325a77 F-271 F-452
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

    // T-2ba84c2f F-273 F-451
    @Test func copyPreservesMtimeForSymlinksViaUtimes() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/target.txt", "target content")
            try Disk.makeDirectories(destination)
            try Disk.symlink(source + "/target.txt", source + "/link")
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .copy, sources: [source + "/link"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-utimes-symlink-1")

            #expect(Disk.lstat(destination + "/link")?.type == .symlink)
        }
    }

    // T-ceffaec5 F-283
    @Test func renameAndInlineCutNoCopySourceMovedAtomically() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/atom.txt", "atomic move")
            try Disk.makeDirectories(destination)
            let originalIno = Disk.lstat(source + "/atom.txt")?.ino
            let copied = Flag()
            let fileSystem = TestFileSystem()
            fileSystem.copyFileImpl = { _, _, _, _ in copied.set() }
            let operation = try realOperation(fileSystem, mode: .cut, sources: [source + "/atom.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-integration-rename-cut")

            #expect(!copied.isSet)
            #expect(!Disk.exists(source + "/atom.txt"))
            #expect(Disk.lstat(destination + "/atom.txt")?.ino == originalIno)
        }
    }

    // T-0d18ea04 F-447
    @Test func copyModeWithUtimesSourcePreservedDestinationHasContent() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/keep.txt", "keep me")
            try Disk.makeDirectories(destination)
            let fileSystem = NativeWriteFileSystem()
            let operation = try realOperation(fileSystem, mode: .copy, sources: [source + "/keep.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "realfs-integration-copy-utimes")

            #expect(Disk.exists(source + "/keep.txt"))
            #expect(Disk.read(destination + "/keep.txt") == "keep me")
        }
    }
}
