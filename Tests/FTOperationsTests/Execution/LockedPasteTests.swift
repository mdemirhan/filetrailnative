// Port of the moving and stopping cases of packages/core/src/fs/copyPasteLocked.realfs.test.ts (its Replace and
// recovery cases are P3-04's): locked items (Finder's "Locked", the uchg flag) and stopping a copy part way through a
// file, on the real disk with the native copy
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// What a test made on a disk, not the disk's own hidden folders (.fseventsd, .Trashes).
private func made(_ folder: String) -> [String] {
    Disk.list(folder).filter { !$0.hasPrefix(".") }
}

struct LockedPasteTests {
    // T-f2cc6a9a F-259 F-474
    @Test func saysALockedFileIsLockedWhenItCantBeMoved() async throws {
        try await withTemporaryDirectory { root in
            let (src, dst) = (root.path + "/src", root.path + "/dst")
            try Disk.write(src + "/f.txt", "content")
            try Disk.makeDirectories(dst)
            Disk.lock(src + "/f.txt")

            let run = try await runPaste(mode: .cut, sources: [src + "/f.txt"], into: dst)

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}f.txt\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.list(src) == ["f.txt"])
            #expect(Disk.list(dst) == [])
        }
    }

    /// A source folder that seems to be on a disk of its own (another device number, EXDEV out of it), and a
    /// destination beside it: a move between them copies and then removes the originals, as one to a real other
    /// disk does. The engine tells disks apart by device number alone.
    private func withOtherDisk(
        _ body: (_ src: String, _ disk: String, _ fileSystem: TestFileSystem) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { root in
            let (src, disk) = (root.path + "/src", root.path + "/disk")
            try Disk.makeDirectories(src)
            try Disk.makeDirectories(disk)
            try await body(src, disk, NativePaste.asOnAnotherDisk(src))
        }
    }

    // Across disks a move copies, then removes the original. A locked original can't be removed, so nothing is
    // copied: it would end up in both places.
    // T-936b31e5 F-263 F-474
    @Test func doesntCopyALockedFolderToAnotherDiskItCantThenRemove() async throws {
        try await withOtherDisk { src, disk, fileSystem in
            try Disk.write(src + "/Vault/a.txt", "a")
            Disk.lock(src + "/Vault")

            let run = try await runPaste(mode: .cut, sources: [src + "/Vault"], into: disk, fileSystem: fileSystem)

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}Vault\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.list(src + "/Vault") == ["a.txt"])
            #expect(made(disk) == [])
        }
    }

    // Every file used to be copied, then each reported "copied, but the original couldn't be removed": everything
    // in both places after copying all of it.
    // T-1317a353 F-263 F-335 F-474
    @Test func copiesNothingOutOfAReadOnlyFolderAndSaysWhy() async throws {
        try await withOtherDisk { src, disk, fileSystem in
            let docs = src + "/Docs"
            try Disk.write(docs + "/a.txt", "a")
            try Disk.write(docs + "/b.txt", "b")
            Disk.chmod(docs, 0o555)
            defer { Disk.chmod(docs, 0o755) }

            let run = try await runPaste(mode: .cut, sources: [docs], into: disk, fileSystem: fileSystem)

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}Docs\u{201D} wasn't moved, because you don't have permission to remove what is inside it."
            )
            #expect(made(disk) == [])
            #expect(Disk.list(docs) == ["a.txt", "b.txt"])
        }
    }

    // T-335016cf F-263 F-335 F-474
    @Test func doesntMoveAFileOutOfAFolderThatCantBeChanged() async throws {
        try await withOtherDisk { src, disk, fileSystem in
            let docs = src + "/Docs"
            try Disk.write(docs + "/a.txt", "a")
            Disk.chmod(docs, 0o555)
            defer { Disk.chmod(docs, 0o755) }

            let run = try await runPaste(mode: .cut, sources: [docs + "/a.txt"], into: disk, fileSystem: fileSystem)

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}a.txt\u{201D} wasn't moved, because you don't have permission to remove it from \u{201C}Docs\u{201D}."
            )
            #expect(made(disk) == [])
        }
    }

    // Across disks a copy can't be a clone, so a large file takes long enough to stop. On a busy machine the copy
    // may finish before the stop is seen; that run proves nothing, so it is tried again.
    // T-97d6fd58 F-257 F-274
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func stopsALargeCopyAtOnceAndLeavesNothingHalfWritten() async throws {
        try await withTemporaryDirectory { root in
            try await DiskImage.withSharedVolume(.apfs) { volume in
                let source = root.path + "/src/big.bin"
                try Disk.makeDirectories(root.path + "/src")
                try NativeTestFiles.makeFile(source, megabytes: 150)
                let destination = volume.path + "/big.bin"
                var status: CopyPasteOperationStatus? = .completed
                for _ in 0..<3 where status == .completed {
                    try? FileManager.default.removeItem(atPath: destination)
                    let signal = StopSignal()
                    let run = try await runPaste(
                        mode: .copy, sources: [source], into: volume.path, signal: signal,
                        beforeExecute: {
                            // Stop once the file has begun to be written (under a hidden name until it is whole),
                            // not after a fixed time a fast disk can beat.
                            DispatchQueue.global().async {
                                while !signal.isStopped {
                                    if Disk.list(volume.path).contains(where: { $0.hasPrefix(".big.bin.") }) {
                                        signal.stop()
                                    }
                                    usleep(500)
                                }
                            }
                        })
                    signal.stop()
                    status = run.result?.status
                }
                try #require(status != .completed, "each copy finished before the stop could be seen")
                #expect(status == .cancelled)
                // Neither the file nor the hidden one it was being written as is left.
                #expect(Disk.list(volume.path).filter { !$0.hasPrefix(".") || $0.hasPrefix(".big.bin.") } == [])
            }
        }
    }
}
