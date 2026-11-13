// A Replace on a disk without a Trash deletes the old item for good only as counted when it was agreed to
import Darwin
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

struct DeleteForGoodTests {
    private func withPlaces(_ body: (_ src: String, _ dst: String) async throws -> Void) async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = (root.path + "/src", root.path + "/dst")
            for folder in [src, dst] {
                try Disk.makeDirectories(folder)
            }
            try await body(src, dst)
        }
    }

    private func noTrash() -> TestFileSystem {
        let fileSystem = TestFileSystem(NativeWriteFileSystem())
        fileSystem.trashImpl = { _ in throw noTrashHere() }
        return fileSystem
    }

    // A folder that turned up after the review, so the review didn't count it, and that can't be looked through
    // now: it isn't deleted for good, and nothing replaces it.
    @Test func aFolderThatCantBeCountedIsntDeletedForGood() async throws {
        try await withPlaces { src, dst in
            try Disk.write(src + "/F/a.txt", "new")
            defer { Darwin.chmod(dst + "/F/closed", 0o755) }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll, fileSystem: noTrash(),
                beforeExecute: {
                    try Disk.write(dst + "/F/closed/kept.txt", "someone's")
                    try Disk.write(dst + "/F/old.txt", "old")
                    Darwin.chmod(dst + "/F/closed", 0)
                },
                resolve: { _ in .overwrite })

            let item = run.result?.items.first { $0.sourcePath == src + "/F" }
            #expect(item?.status == .failed)
            #expect(
                item?.error
                    == "\u{201C}F\u{201D} couldn't be looked through, so it wasn't deleted for good and nothing was replaced."
            )
            Darwin.chmod(dst + "/F/closed", 0o755)
            #expect(Disk.list(dst) == ["F"])
            #expect(Disk.list(dst + "/F") == ["closed", "old.txt"])
            #expect(Disk.read(dst + "/F/closed/kept.txt") == "someone's")
        }
    }

    // A delete for good that fails part way: the item is named as replaced (some of it is gone), nothing is put
    // in its place, and nothing is left under a hidden name.
    @Test func aDeleteForGoodThatFailsPartWayLeavesNoHiddenCopy() async throws {
        try await withPlaces { src, dst in
            try Disk.write(src + "/F/a.txt", "new")
            try Disk.write(dst + "/F/one.txt", "one")
            try Disk.write(dst + "/F/two.txt", "two")
            let fileSystem = noTrash()
            fileSystem.rmImpl = { path, recursive, force in
                guard path == dst + "/F" else {
                    return try NativeWriteFileSystem().rm(path, recursive: recursive, force: force)
                }
                try NativeWriteFileSystem().rm(path + "/one.txt", recursive: false, force: false)
                throw NativeError.errno(EIO, syscall: "rm", path: path + "/two.txt")
            }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: fileSystem, resolve: { _ in .overwrite })

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            let item = run.result?.items.first { $0.sourcePath == src + "/F" }
            #expect(item?.status == .failed)
            #expect(run.result?.replacedPaths == [dst + "/F"])
            #expect(Disk.list(dst) == ["F"])
            #expect(Disk.list(dst + "/F") == ["two.txt"])
            #expect(Disk.read(src + "/F/a.txt") == "new")
        }
    }
}
