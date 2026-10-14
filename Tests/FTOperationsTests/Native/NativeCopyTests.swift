// Port of the nativeCopyFile and nativeCopyMetadata cases of packages/native-fs/src/native-fs.test.ts
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

    // T-239cae6f F-348 F-404
    @Test func neverWritesOverAnExistingDestination() throws {
        try withFiles { root in
            let error = #expect(throws: NativeError.self) {
                try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path)
            }
            #expect(error?.code == "EEXIST" && error?.syscall == "copyfile")
            #expect(Files.read(root.appending("b.txt").path) == Array("existing".utf8))
        }
    }

    // T-6a49d862 F-409
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

    // T-90a9d326 F-409
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
    // T-97075e26 F-405 F-412
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

    // T-eee4b3f2
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

    // applyDirectoryMetadata: on a move the folder keeps the date it had before its items went out; when copyfile
    // fails, the mode and date alone are carried over and a move keeps its original.
    // F-405
    @Test func fallsBackToTheModeAndDateWhenTheMetadataCantBeCopied() throws {
        var calls: [String] = []
        let refused = NativeError.errno(ENOTSUP, syscall: "copyfile", path: "/s", dest: "/d")
        try FolderMetadata.apply(
            source: "/s", destination: "/d", sourceMode: 0o40755, sourceMtimeMs: 1500, moving: true,
            onNotCopied: { calls.append("not copied") },
            copyMetadata: { _, _ in throw refused }, chmod: { calls.append("chmod \($0) \(String($1, radix: 8))") },
            utimes: { calls.append("utimes \($0) \($1) \($2)") })
        #expect(calls == ["not copied", "chmod /d 40755", "utimes /d 1500.0 1500.0"])

        calls = []
        try FolderMetadata.apply(
            source: "/s", destination: "/d", sourceMode: 0o755, sourceMtimeMs: 1500, moving: false,
            onNotCopied: { calls.append("not copied") },
            copyMetadata: { _, _ in throw refused }, chmod: { _, _ in throw refused },
            utimes: { _, _, _ in calls.append("u") })
        #expect(calls == ["u"])

        calls = []
        try FolderMetadata.apply(
            source: "/s", destination: "/d", sourceMode: 0o755, sourceMtimeMs: 1500, moving: true,
            onNotCopied: { calls.append("not copied") },
            copyMetadata: { _, _ in calls.append("copy") }, chmod: { _, _ in calls.append("chmod") },
            utimes: { _, _, _ in
                calls.append("utimes")
                throw NativeError.errno(EPERM, syscall: "utime", path: "/d")
            })
        #expect(calls == ["copy", "utimes"])

        #expect(throws: NativeError.self) {
            try FolderMetadata.apply(
                source: "/s", destination: "/d", sourceMode: 0o755, sourceMtimeMs: nil, moving: false,
                onNotCopied: {}, copyMetadata: { _, _ in throw refused },
                chmod: { _, _ in throw NativeError.errno(EPERM, syscall: "chmod", path: "/d") }, utimes: { _, _, _ in })
        }
    }
}

@Suite(.serialized)
struct NativeCopyStopFlagTests {
    private func withSource(_ body: (TemporaryDirectory) throws -> Void) throws {
        try withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try Files.write(root.appending("a.txt").path, "content")
            try body(root)
        }
    }

    // T-5e050894 F-410
    @Test func copiesNormallyWhileTheFlagIsClear() throws {
        try withSource { root in
            try NativeFS.copyFile(root.appending("a.txt").path, root.appending("b.txt").path, control: CopyControl())
            #expect(Files.read(root.appending("b.txt").path) == Array("content".utf8))
        }
    }

    // T-5a6dbafe F-361 F-410
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

    // N/A T-0c9bb001 the stop flag is a typed CopyControl: there is no other kind of flag to refuse.

    // Across volumes the copy can't be a clone, so a large file takes long enough to stop. The stop lands as the
    // destination appears, while copyfile is still copying extended attributes: a stop seen there once left an
    // empty file behind.
    // T-19343d44 F-361 F-410
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
    // T-4197f701 F-410
    @Test(.tags(.diskImage), .diskImages)
    func countsTheBytesCopiedAfterTheFlag() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let source = root.appending("big.bin").path
                try Files.makeFile(source, megabytes: 20)
                let control = CopyControl()
                try NativeFS.copyFile(source, volume.path + "/big.bin", control: control)
                #expect(control.copiedBytes == 20 * 1024 * 1024)
            }
        }
    }

    // copyfile asks the status callback what to do when a write fails; answering "continue" there retried the
    // write forever, so a full disk hung the copy.
    // T-26424164 F-404
    @Test(.tags(.diskImage), .diskImages, .enabled(if: LargeFileTests.enabled))
    func failsWithENOSPCOnAFullDiskInsteadOfRetryingTheWriteForever() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                let source = root.appending("big.bin").path
                try Files.makeFile(source, megabytes: 80)
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
    // T-0c2e0a1d F-364 F-411
    @Test(.tags(.diskImage), .diskImages)
    func failsWithTheWritesErrnoWhenTheResourceForkCantBeWritten() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfs) { volume in
                try Files.fillDisk(volume.path)
                let source = root.appending("old.rsrc").path
                try Files.write(source, "")
                // Over 1 MB, which copyfile copies through the fork's own file, in chunks; and more than the space
                // APFS keeps back on a full disk, which a fork can still take (about 6 MB of a 256 MB disk, where
                // the original's 20 MB disk kept less than its 2 MB fork).
                let forkSize = max(2 * 1024 * 1024, Files.freeBytes(volume.path) + 2 * 1024 * 1024)
                try Files.write(source + "/..namedfork/rsrc", [UInt8](repeating: 7, count: forkSize))

                let error = #expect(throws: NativeError.self) {
                    try NativeFS.copyFile(source, volume.path + "/old.rsrc", control: CopyControl())
                }
                #expect(error?.code == "ENOSPC" && error?.syscall == "copyfile")
            }
        }
    }

    // A fork under 1 MB is copied like any other extended attribute, in one write, so a failed write there reaches
    // the callback's extended-attribute branch, which skipped it. On a FAT disk the fork goes in the "._" file
    // beside the copy, in the disk's clusters: once they are full the copy can still be made (an empty file takes
    // none) but its fork can't. Older macOS says a full FAT disk is EIO rather than ENOSPC: the copy fails with
    // whichever the disk says.
    // T-1c84056e F-364 F-411
    @Test(.tags(.diskImage), .diskImages)
    func failsWithTheWritesErrnoWhenASmallResourceForkCantBeWritten() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.fat32) { volume in
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

    // T-c9970c51 F-404
    @Test(.tags(.diskImage), .diskImages)
    func keepsASparseFileSparseSoItFitsOnADiskSmallerThanItsLength() async throws {
        try await withTemporaryDirectory(prefix: "native-fs-stop") { root in
            try await DiskImage.withVolume(.apfs) { volume in
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
