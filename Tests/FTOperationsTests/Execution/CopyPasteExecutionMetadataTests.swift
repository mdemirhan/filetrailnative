import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

/// Calls a test records, from any thread.
final class Recorded<Call: Sendable>: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Call]())
    func append(_ call: Call) { state.withLock { $0.append(call) } }
    var all: [Call] { state.withLock { $0 } }
}

struct CopyPasteExecutionMetadataTests {
    private func folderWithAFile(mtimeMs: Double = 5555) -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory(mtimeMs: mtimeMs)),
            ("/source/dir/a.txt", .file(size: 3)), ("/target", .directory()),
        ])
    }

    @Test func leavesTheModeCopyFileCopied() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5, mode: 0o755)), ("/target", .directory()),
        ])
        let chmods = Recorded<String>()
        fileSystem.chmodImpl = { path, _ in chmods.append(path) }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "native-copy-1")

        // The native copy carried the mode, so it isn't set again (that would fail on a locked file).
        #expect(chmods.all == [])
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // A large file shows its progress as it is copied, counted once when it is done.
    @Test func reportsTheBytesOfTheFileBeingCopiedAsTheyAreWritten() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 100)), ("/source/b.bin", .file(size: 1000)),
            ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { source, destination, _, onProgress in
            if source == "/source/b.bin" {
                onProgress?(400)
            }
            fileSystem.addFile(destination, .file(size: fileSystem.readNode(source)?.size ?? 0))
        }
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt", "/source/b.bin"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "native-copy-progress")

        let copying = events.first { $0.completedByteCount == 500 }
        #expect(copying?.currentSourcePath == "/source/b.bin")
        #expect(copying?.completedItemCount == 1)
        #expect(events.map(\.completedByteCount) == [0, 100, 500, 1100, 1100])
    }

    // On the disk itself, with nothing to set the mode or the date again afterwards: the copy carries them.
    @Test func copyFilePreservesModeAndMtime() async throws {
        try await withTemporaryDirectory { root in
            let (source, destination) = (root.path + "/src", root.path + "/dst")
            try Disk.write(source + "/a.txt", "hello")
            Disk.chmod(source + "/a.txt", 0o755)
            // 2021-02-03T04:05:06.000Z
            let date = 1_612_325_106_000.0
            try setDate(source + "/a.txt", date)
            try Disk.makeDirectories(destination)
            let fileSystem = TestFileSystem()
            fileSystem.chmodImpl = { _, _ in }
            fileSystem.utimesImpl = { _, _, _ in }
            let operation = try createResolvedOperation(fileSystem, sources: [source + "/a.txt"], into: destination)

            await execute(fileSystem, operation, operationId: "native-preserve-1")

            #expect((Disk.lstat(destination + "/a.txt")?.mode ?? 0) & 0o777 == 0o755)
            #expect(abs((mtimeMs(destination + "/a.txt") ?? 0) - date) < 1000)
        }
    }

    @Test func nativeCopyFilePathReappliesModeAndMtimeEvenWhenTheCopyDropsMetadata() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5, mode: 0o755, mtimeMs: 9999)),
            ("/target", .directory()),
        ])
        fileSystem.enableUtimes()
        // A copy that carries the contents but not the metadata.
        fileSystem.copyFileImpl = { source, destination, _, _ in
            fileSystem.addFile(destination, .file(size: fileSystem.readNode(source)?.size ?? 0))
        }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "native-preserve-2")

        #expect(fileSystem.readNode("/target/a.txt")?.mode == 0o755)
        #expect(fileSystem.readNode("/target/a.txt")?.mtimeMs == 9999)
    }

    @Test func copyFileErrorPropagatesAndFailsTheOperation() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError(.errno(EACCES), "EACCES: permission denied") }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "native-error-1")

        #expect(events.last?.result?.status == .failed)
        #expect(events.last?.result?.error == "You don't have permission to access this item.")
    }

    @Test func utimesENOTSUPSilentlyIgnored() async throws {
        let fileSystem = folderWithAFile()
        fileSystem.enableUtimes()
        fileSystem.utimesImpl = { _, _, _ in throw codedError(.errno(ENOTSUP)) }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-enotsup-1")

        #expect(fileSystem.readNode("/target/dir")?.kind == .directory)
    }

    // A paste lets any date that can't be set go; the disk's "not supported" is told apart where the date is set.
    @Test func utimesEOPNOTSUPPSilentlyIgnored() throws {
        var tried: [String] = []
        try FolderMetadata.preserveTimestamps("/target/dir", 7777) { path, _, _ in
            tried.append(path)
            throw codedError(.errno(EOPNOTSUPP))
        }
        #expect(tried == ["/target/dir"])
    }

    @Test func doesntFailAFolderWhoseDateCantBeSet() async throws {
        let fileSystem = folderWithAFile()
        fileSystem.enableUtimes()
        fileSystem.utimesImpl = { _, _, _ in throw codedError(.errno(EPERM)) }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "utimes-eperm-1")

        // The folder and its items were written; only its date couldn't be set, which, as for a file, isn't a
        // failure (some network volumes refuse it).
        #expect(events.last?.result?.status == .completed)
        #expect(events.last?.result?.error == nil)
        #expect(fileSystem.exists("/target/dir/a.txt"))
    }

    @Test func copyFileAndCutInlineSourceDeletionStillWorks() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "native-cut-1")

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    @Test func copyFileAndRenameRenameTakesPriorityForSameDevCut() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let copied = Flag()
        fileSystem.copyFileImpl = { _, _, _, _ in copied.set() }
        let originalIno = fileSystem.readNode("/source/a.txt")?.ino
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "rename-vs-native-1")

        #expect(!copied.isSet)
        #expect(fileSystem.readNode("/target/a.txt")?.ino == originalIno)
    }

    @Test func copyFileWithKeepBothUsesTheAlternateDestinationPath() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 8)), ("/target", .directory()),
            ("/target/a.txt", .file(size: 2)),
        ])
        let destinations = Recorded<String>()
        fileSystem.copyFileImpl = { source, destination, _, _ in
            destinations.append(destination)
            fileSystem.addFile(destination, .file(size: fileSystem.readNode(source)?.size ?? 0))
        }
        let policy = CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .keepBoth)
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: policy)

        await execute(fileSystem, operation, operationId: "native-keepboth-1", policy: policy)

        // Written under a hidden name next to it, then given its name.
        #expect(destinations.all.count == 1)
        #expect(
            destinations.all.allSatisfy {
                $0.wholeMatch(of: /\/target\/\.a copy\.txt\.filetrail-[0-9a-f]{8}/) != nil
            })
        #expect(fileSystem.readNode("/target/a.txt")?.size == 2)
        #expect(fileSystem.readNode("/target/a copy.txt")?.size == 8)
    }

    @Test func utimesUsesSourceMtimeMsForBothAtimeAndMtimeParameters() async throws {
        let fileSystem = folderWithAFile(mtimeMs: 1_234_567_890)
        fileSystem.enableUtimes()
        let calls = Recorded<[String]>()
        fileSystem.utimesImpl = { path, atimeMs, mtimeMs in calls.append([path, String(atimeMs), String(mtimeMs)]) }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-args-1")

        let call = try #require(calls.all.first { $0.first == "/target/dir" })
        #expect(call == ["/target/dir", "1234567890.0", "1234567890.0"])
    }
}
