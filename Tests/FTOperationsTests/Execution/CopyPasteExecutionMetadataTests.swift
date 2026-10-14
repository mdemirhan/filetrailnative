// Port of "native copyFile and utimes" (packages/core/src/fs/copyPasteExecution.test.ts), but for the case that
// Replaces (P3-04's)
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

    // T-0d08aafa F-278
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
    // T-dc2a3197 F-453
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

    // T-3226a0ea F-452
    @Test func copyFilePreservesModeAndMtime() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5, mode: 0o755, mtimeMs: 9999)),
            ("/target", .directory()),
        ])
        fileSystem.enableUtimes()
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "native-preserve-1")

        #expect(fileSystem.readNode("/target/a.txt")?.mode == 0o755)
        #expect(fileSystem.readNode("/target/a.txt")?.mtimeMs == 9999)
    }

    // T-ebe86603 F-278 F-452
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

    // T-47e2728a F-453
    @Test func copyFileErrorPropagatesAndFailsTheOperation() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError("EACCES", "EACCES: permission denied") }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/a.txt"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "native-error-1")

        #expect(events.last?.result?.status == .failed)
        #expect(events.last?.result?.error == "You don't have permission to access this item.")
    }

    // T-0d97ceb3 F-271 F-452
    @Test func utimesCalledForDirectoriesAfterMkdirAndChmod() async throws {
        let fileSystem = folderWithAFile()
        fileSystem.enableUtimes()
        let calls = Recorded<[String]>()
        fileSystem.utimesImpl = { path, _, mtimeMs in calls.append([path, String(mtimeMs)]) }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-dir-1")

        #expect(calls.all.contains(["/target/dir", "5555.0"]))
    }

    // T-408edc5c F-452
    @Test func utimesNotCalledWhenAbsent() async throws {
        let fileSystem = folderWithAFile()
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-absent-1")

        #expect(fileSystem.readNode("/target/dir")?.kind == .directory)
    }

    // T-b12350e8 F-452
    @Test func utimesENOTSUPSilentlyIgnored() async throws {
        let fileSystem = folderWithAFile()
        fileSystem.enableUtimes()
        fileSystem.utimesImpl = { _, _, _ in throw codedError("ENOTSUP") }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-enotsup-1")

        #expect(fileSystem.readNode("/target/dir")?.kind == .directory)
    }

    // T-0cd81aa5 F-452
    @Test func utimesEOPNOTSUPPSilentlyIgnored() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/link", .symlink("actual.txt", mtimeMs: 7777)),
            ("/target", .directory()),
        ])
        fileSystem.enableUtimes()
        fileSystem.utimesImpl = { _, _, _ in throw codedError("EOPNOTSUPP") }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/link"], into: "/target")

        await execute(fileSystem, operation, operationId: "utimes-eopnotsupp-1")

        #expect(fileSystem.readNode("/target/link")?.kind == .symlink)
    }

    // T-a81e8d81 F-271 F-452
    @Test func doesntFailAFolderWhoseDateCantBeSet() async throws {
        let fileSystem = folderWithAFile()
        fileSystem.enableUtimes()
        fileSystem.utimesImpl = { _, _, _ in throw codedError("EPERM") }
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target")

        let events = await execute(fileSystem, operation, operationId: "utimes-eperm-1")

        // The folder and its items were written; only its date couldn't be set, which, as for a file, isn't a
        // failure (some network volumes refuse it).
        #expect(events.last?.result?.status == .completed)
        #expect(events.last?.result?.error == nil)
        #expect(fileSystem.exists("/target/dir/a.txt"))
    }

    // T-13e91ab9 F-461
    @Test func copyFileAndCutInlineSourceDeletionStillWorks() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.txt", .file(size: 5)), ("/target", .directory()),
        ])
        let operation = try createResolvedOperation(fileSystem, mode: .cut, sources: ["/source/a.txt"], into: "/target")

        await execute(fileSystem, operation, operationId: "native-cut-1")

        #expect(!fileSystem.exists("/source/a.txt"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // T-8258e572 F-283
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

    // T-855f8824 F-274 F-450
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

    // T-0a7fbe02 F-452
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
