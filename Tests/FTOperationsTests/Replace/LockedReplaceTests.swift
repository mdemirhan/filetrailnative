// Port of the Replace cases of packages/core/src/fs/copyPasteLocked.realfs.test.ts ("Replace with locked items",
// "moving to another disk with Replace"), on the real disk with the native copy
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct LockedReplaceTests {
    private func isLockedOnDisk(_ path: String) -> Bool {
        Disk.flags(path) & UInt32(UF_IMMUTABLE) != 0
    }

    private func withPlaces(_ body: (_ src: String, _ dst: String, _ trash: String) async throws -> Void)
        async throws
    {
        try await withTemporaryDirectory { root in
            let (src, dst, trash) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            for folder in [src, dst, trash] {
                try Disk.makeDirectories(folder)
            }
            try await body(src, dst, trash)
        }
    }

    // T-1ae04534 F-510 F-505
    @Test func replacesAnItemWithALockedFileAndTheNewFileStaysLocked() async throws {
        try await withPlaces { src, dst, trash in
            try Disk.write(src + "/f.txt", "new")
            Disk.lock(src + "/f.txt")
            try Disk.write(dst + "/f.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/f.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            #expect(run.result?.status == .completed)
            #expect(Disk.read(dst + "/f.txt") == "new")
            #expect(isLockedOnDisk(dst + "/f.txt"))
            #expect(Disk.list(dst) == ["f.txt"])
            #expect(Disk.list(trash) == ["1-f.txt"])
        }
    }

    // T-4fa90b14 F-510
    @Test func replacesAFolderWithALockedFolderAndEverythingInIt() async throws {
        try await withPlaces { src, dst, trash in
            try Disk.write(src + "/Vault/a.txt", "a")
            Disk.lock(src + "/Vault")
            try Disk.write(dst + "/Vault/old.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Vault"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            #expect(run.result?.status == .completed)
            #expect(Disk.list(dst + "/Vault") == ["a.txt"])
            #expect(isLockedOnDisk(dst + "/Vault"))
            #expect(Disk.list(dst) == ["Vault"])
        }
    }

    // T-bbaefeb3 F-510 F-338
    @Test func refusesToReplaceALockedItemBeforeAnythingChanges() async throws {
        try await withPlaces { src, dst, trash in
            try Disk.write(src + "/f.txt", "new")
            try Disk.write(dst + "/f.txt", "old")
            Disk.lock(dst + "/f.txt")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/f.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash))

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}f.txt\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.read(dst + "/f.txt") == "old")
            #expect(Disk.list(dst) == ["f.txt"])
            #expect(Disk.list(trash) == [])
        }
    }

    // The Replace stages a plain copy and removes the originals only after the swap: a locked original used to be
    // found out then, after the old item had gone to the Trash. The source seems to be on a disk of its own
    // (another device number, EXDEV out of it), so the move copies and then removes, as one to a real other disk.
    // T-d236f420 F-475 F-510
    @Test func refusesALockedFileBeforeAnythingIsReplaced() async throws {
        try await withPlaces { src, disk, otherTrash in
            try Disk.write(src + "/f.txt", "new")
            Disk.lock(src + "/f.txt")
            try Disk.write(disk + "/f.txt", "old")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/f.txt"], into: disk, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.asOnAnotherDisk(src, NativePaste.withTrash(otherTrash)))

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}f.txt\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.read(disk + "/f.txt") == "old")
            #expect(Disk.list(otherTrash) == [])
            #expect(Disk.list(src) == ["f.txt"])
        }
    }

    // T-751f9048 F-475 F-510
    @Test func refusesAFolderHoldingALockedItemBeforeAnythingIsReplaced() async throws {
        try await withPlaces { src, disk, otherTrash in
            try Disk.write(src + "/Docs/keep.txt", "keep")
            Disk.lock(src + "/Docs/keep.txt")
            try Disk.write(disk + "/Docs/old.txt", "old")

            let run = try await runPaste(
                mode: .cut, sources: [src + "/Docs"], into: disk, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.asOnAnotherDisk(src, NativePaste.withTrash(otherTrash)))

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}keep.txt\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.list(disk + "/Docs") == ["old.txt"])
            #expect(Disk.list(otherTrash) == [])
        }
    }
}
