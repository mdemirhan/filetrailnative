import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

private typealias Files = NativeTestFiles

struct NativeCopyFileErrorTests {
    private func withFiles(_ body: (TemporaryDirectory) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "native-fs-copy") { root in
            try Files.write(root.appending("a.txt").path, "new")
            try Files.write(root.appending("b.txt").path, "existing")
            try body(root)
        }
    }

    @Test func neverWritesOverAnExistingDestination() throws {
        try withFiles { root in
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path)
            }
            #expect(error?.code == "EEXIST" && error?.syscall == "copyfile")
            #expect(Files.read(root.appending("b.txt").path) == Array("existing".utf8))
        }
    }

    @Test func namesTheErrnoAndKeepsLongPathsWholeInTheMessage() throws {
        try withFiles { root in
            let longDestination =
                root.path + "/missing-folder/" + String(repeating: "x", count: 200) + "/"
                + String(repeating: "y", count: 200)
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyFile(root.appending("a.txt").path, longDestination)
            }
            #expect(error?.code == "ENOENT" && error?.dest == longDestination)
            #expect(error?.message.contains(longDestination) == true)
            #expect(
                error?.message
                    == "ENOENT: No such file or directory, copyfile '\(root.appending("a.txt").path)' -> '\(longDestination)'"
            )
        }
    }

    @Test func reportsErrnosThatUsedToBeUnknownByName() throws {
        try withFiles { root in
            // A file used as a folder in the destination path.
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path + "/c.txt")
            }
            #expect(error?.code == "ENOTDIR")
        }
    }
}

struct NativeCopyMetadataTests {
    @Test func putsAFoldersTagsModeAndDateOnAnExistingFolderWithoutCopyingItsItems() throws {
        try withTemporaryDirectory(prefix: "native-fs-metadata") { root in
            let source = root.appending("source").path
            let destination = root.appending("destination").path
            try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
            try Files.write(source + "/inside.txt", "x")
            #expect(Files.setXattr(source, "com.apple.metadata:_kMDItemUserTags", "(\"Red\n6\")") == 0)
            let date = 1_577_934_245.0  // 2020-01-02T03:04:05Z
            try NativeFS.utimes(source, atimeMs: date * 1000, mtimeMs: date * 1000)
            try NativeFS.chmod(source, 0o555)

            try NativeFS.copyMetadata(source, destination)

            #expect(Files.xattrNames(destination).contains("com.apple.metadata:_kMDItemUserTags"))
            let stats = try PosixFileSystem().stat(destination)
            #expect(stats.mode & 0o777 == 0o555)
            #expect(stats.mtimeMs == date * 1000)
            #expect(try PosixFileSystem().readdir(destination).isEmpty)
        }
    }

    @Test func marksTheCopyOfAFolderInQuarantineToRunInPlaceAndLeavesOthersOutOfQuarantine() throws {
        try withTemporaryDirectory(prefix: "native-fs-metadata") { root in
            let quarantine = "com.apple.quarantine"
            let source = root.appending("Foo.app").path
            let inPlace = root.appending("in-place").path
            let plain = root.appending("plain").path
            let notQuarantined = root.appending("not-quarantined").path
            for path in [source, inPlace, plain, notQuarantined] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            }
            try NativeFS.copyMetadataToRunInPlace(source, notQuarantined)
            #expect(!Files.xattrNames(notQuarantined).contains(quarantine))

            #expect(Files.setXattr(source, quarantine, "0083;00000000;Safari;") == 0)
            try NativeFS.copyMetadataToRunInPlace(source, inPlace)
            try NativeFS.copyMetadata(source, plain)

            func flags(_ path: String) -> UInt32? {
                var value = [UInt8](repeating: 0, count: 128)
                guard getxattr(path, quarantine, &value, value.count, 0, 0) >= 4 else { return nil }
                return UInt32(String(decoding: value.prefix(4), as: UTF8.self), radix: 16)
            }
            // QTN_FLAG_DO_NOT_TRANSLOCATE.
            #expect(flags(inPlace).map { $0 & 0x100 != 0 } == true)
            #expect(flags(plain).map { $0 & 0x100 == 0 } == true)
        }
    }

    @Test func namesTheErrnoWhenTheSourceIsMissing() throws {
        try withTemporaryDirectory(prefix: "native-fs-metadata") { root in
            try FileManager.default.createDirectory(
                at: root.appending("destination"), withIntermediateDirectories: false)
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyMetadata(root.appending("missing").path, root.appending("destination").path)
            }
            #expect(error?.code == "ENOENT")
        }
    }
}

@Suite
struct NativeCopyStopFlagTests {
    private func withSource(_ body: (TemporaryDirectory) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try Files.write(root.appending("a.txt").path, "content")
            try body(root)
        }
    }

    @Test func copiesNormallyWhileTheFlagIsClear() throws {
        try withSource { root in
            try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path, control: CopyControl())
            #expect(Files.read(root.appending("b.txt").path) == Array("content".utf8))
        }
    }

    @Test func doesntStartACopyWhoseFlagIsAlreadySet() throws {
        try withSource { root in
            let control = CopyControl()
            control.stop()
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path, control: control)
            }
            #expect(error?.code == "ECANCELED")
            #expect(!Files.exists(root.appending("b.txt").path))
        }
    }

    // Across volumes the copy can't be a clone, so a large file takes long enough to stop. The stop lands as the
    // destination appears, while copyfile is still copying extended attributes: a stop seen there once left an
    // empty file behind.
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func stopsPartWayThroughALargeFileAndLeavesNoPartialFile() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let source = root.appending("big.bin").path
                try Files.makeFile(source, megabytes: 150)
                let destination = volume.path + "/big.bin"
                let control = CopyControl()
                let copy = Background { try NativeFS.copyFile(source, destination, control: control) }
                try Files.waitUntil { Files.exists(destination) }
                control.stop()
                let error = #expect(throws: NativeError.self) { try copy.wait() }
                #expect(error?.code == "ECANCELED")
                #expect(!Files.exists(destination))
            }
        }
    }

    // A copy that isn't a clone counts the bytes copied so far, so a large file can show its progress.
    @Test(.tags(.diskImage), .diskImages)
    func countsTheBytesCopiedAfterTheFlag() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withSharedVolume(.apfs) { volume in
                let source = root.appending("big.bin").path
                try Files.makeFile(source, megabytes: 20)
                let control = CopyControl()
                try NativeFS.copyFile(source, volume.path + "/big.bin", control: control)
                #expect(control.copiedBytes == 20 * 1024 * 1024)
            }
        }
    }

    // copyfile asks the status callback what to do when a write fails; answering "continue" there retried the
    // write forever, so a full disk hung the copy. The disk is full before the copy starts, so its first write
    // fails; the source is still larger than the whole disk (34 MB onto 32 MB), so it can't fit whatever APFS
    // gives back after the fill.
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func failsWithENOSPCOnAFullDiskInsteadOfRetryingTheWriteForever() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfsSmall) { volume in
                let source = root.appending("big.bin").path
                try Files.makeFile(source, megabytes: Files.totalBytes(volume.path) / (1024 * 1024) + 2)
                try Files.fillDisk(volume.path)
                let destination = volume.path + "/big.bin"
                let started = Date()
                let error = #expect(throws: NativeError.self) {
                    try NativeFS.copyFile(source, destination, control: CopyControl())
                }
                #expect(error?.code == "ENOSPC")
                #expect(Date().timeIntervalSince(started) < 10)
                #expect(!Files.exists(destination))
            }
        }
    }

    // copyfile goes on as if a resource fork that couldn't be written had been copied, unless the callback quits:
    // the copy then succeeded without it, and a move removed the original. A full disk makes the write fail; the
    // file's own data is empty, so nothing else does.
    @Test(.tags(.diskImage), .diskImages)
    func failsWithTheWritesErrnoWhenTheResourceForkCantBeWritten() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfsSmall) { volume in
                try Files.fillDisk(volume.path)
                let source = root.appending("old.rsrc").path
                try Files.write(source, "")
                // Over 1 MB, which copyfile copies through the fork's own file, in chunks; and larger than the whole
                // disk, so it can't fit whatever APFS keeps back on a full disk or gives back after the fill. A fork
                // of the free space plus 2 MB, measured after the fill, once fitted in a full CI run.
                let forkSize = Files.totalBytes(volume.path) + 2 * 1024 * 1024
                try Files.write(source + "/..namedfork/rsrc", [UInt8](repeating: 7, count: forkSize))

                let destination = volume.path + "/old.rsrc"
                let error = #expect(throws: NativeError.self) {
                    try NativeFS.copyFile(source, destination, control: CopyControl())
                }
                #expect(
                    error?.code == "ENOSPC" && error?.syscall == "copyfile",
                    "copied \(Files.size(destination + "/..namedfork/rsrc")) of \(forkSize) bytes of the fork")
            }
        }
    }

    // A fork under 1 MB is copied like any other extended attribute, in one write, so a failed write there reaches
    // the callback's extended-attribute branch, which skipped it. On a FAT disk the fork goes in the "._" file
    // beside the copy, in the disk's clusters: once they are full the copy can still be made (an empty file takes
    // none) but its fork can't. Older macOS says a full FAT disk is EIO rather than ENOSPC: the copy fails with
    // whichever the disk says.
    @Test(.tags(.diskImage), .diskImages)
    func failsWithTheWritesErrnoWhenASmallResourceForkCantBeWritten() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.fat32Small) { volume in
                let fullCode = try Files.fillDisk(volume.path, fullCodes: ["ENOSPC", "EIO"])
                let source = root.appending("small.rsrc").path
                try Files.write(source, "")
                let fork = [UInt8](repeating: 7, count: 512 * 1024)
                try Files.write(source + "/..namedfork/rsrc", fork)
                let destination = volume.path + "/small.rsrc"

                let error = #expect(throws: NativeError.self) {
                    try NativeFS.copyFile(source, destination, control: CopyControl())
                }
                #expect(error?.code == fullCode && error?.syscall == "copyfile")
                // The copy got as far as the fork: it left the file it made, for the caller to remove, without the
                // whole fork.
                #expect(Files.exists(destination))
                #expect(Files.read(destination + "/..namedfork/rsrc") != fork)
            }
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func keepsASparseFileSparseSoItFitsOnADiskSmallerThanItsLength() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withSharedVolume(.apfs) { volume in
                let source = root.appending("sparse.img").path
                try Files.write(source, "start")
                #expect(truncate(source, 1024 * 1024 * 1024) == 0)
                let destination = volume.path + "/sparse.img"
                try NativeFS.copyFile(source, destination, control: CopyControl())
                #expect(try PosixFileSystem().stat(destination).size == 1024 * 1024 * 1024)
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: destination))
                defer { try? handle.close() }
                #expect(try handle.read(upToCount: 5) == Data("start".utf8))
            }
        }
    }
}
