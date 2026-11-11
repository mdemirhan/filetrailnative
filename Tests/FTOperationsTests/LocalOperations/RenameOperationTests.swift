import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct RenameOperationTests {
    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    private func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test func refusesToReplaceAnItemThatTookTheNewNameAfterItWasChecked() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-rename-race") { root in
            let source = root.appending("a.txt").path
            let destination = root.appending("b.txt").path
            try write(source, "renamed item")
            // Something else creates b.txt between the check and the rename itself.
            let fileSystem = TestLocalFileSystem.real()
            let disk = NativeWriteFileSystem()
            fileSystem.renameImpl = { from, to in
                try "someone else's file".write(toFile: destination, atomically: false, encoding: .utf8)
                try disk.rename(from, to)
            }
            fileSystem.renameExclusiveImpl = { from, to in
                try "someone else's file".write(toFile: destination, atomically: false, encoding: .utf8)
                try disk.renameExclusive(from, to)
            }
            let coordinator = WriteCoordinator.local(fileSystem)
            let window = TestWindow()

            try await coordinator.rename(sourcePath: source, destinationName: "b.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .failed)
            #expect(end.result?.error == "An item named “b.txt” already exists.")
            #expect(try read(destination) == "someone else's file")
            #expect(try read(source) == "renamed item")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func changesOnlyTheCaseOfANameOnADiskThatIgnoresCase() async throws {
        try await DiskImage.withSharedVolume(.apfs) { volume in
            try write(volume.path + "/notes.txt", "notes")
            // This disk ignores case: "NOTES.TXT" is the same name.
            try #require(FileManager.default.fileExists(atPath: volume.path + "/NOTES.TXT"))
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: volume.path + "/notes.txt", destinationName: "Notes.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            #expect(try FileManager.default.contentsOfDirectory(atPath: volume.path) == ["Notes.txt"])
            #expect(try read(volume.path + "/Notes.txt") == "notes")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func changesOnlyHowAnAccentedLetterIsEncodedOnADiskThatIgnoresThat() async throws {
        try await DiskImage.withSharedVolume(.apfs) { volume in
            let decomposed = "cafe\u{301}.txt"
            let composed = "caf\u{E9}.txt"
            try write(volume.path + "/" + decomposed, "menu")
            // This disk ignores how the letter is encoded: both spellings are one name.
            try #require(Darwin.access(volume.path + "/" + composed, F_OK) == 0)
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: volume.path + "/" + decomposed, destinationName: composed, window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            let listed = try PosixFileSystem().readdir(volume.path)
            #expect(listed.count == 1)
            #expect(listed.first.map { Array($0.unicodeScalars) } == Array(composed.unicodeScalars))
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // On a disk that minds case, "Notes.txt" next to "notes.txt" is another file.
    @Test func stillRefusesANameTakenByADifferentItemThatDiffersOnlyInCase() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in Stats.file(dev: 1, ino: path.hasSuffix("notes.txt") ? 10 : 11) }
        let coordinator = WriteCoordinator.local(fileSystem)

        await #expect(throws: WriteCoordinatorError("An item named “Notes.txt” already exists.")) {
            try await coordinator.rename(
                sourcePath: "/Users/demo/notes.txt", destinationName: "Notes.txt", window: TestWindow())
        }
        #expect(fileSystem.calls.rename.isEmpty)
        #expect(fileSystem.calls.renameExclusive.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func refusesANameHeldByAHardLinkToTheSameFile() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-rename-link") { root in
            try write(root.appending("a.txt").path, "shared")
            #expect(link(root.appending("a.txt").path, root.appending("b.txt").path) == 0)
            let coordinator = WriteCoordinator.local(.real())

            await #expect(throws: WriteCoordinatorError("An item named “b.txt” already exists.")) {
                try await coordinator.rename(
                    sourcePath: root.appending("a.txt").path, destinationName: "b.txt", window: TestWindow())
            }
            #expect(try names(root.path) == ["a.txt", "b.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // Two hard links to one file whose names differ only in case can exist on a disk that minds case; renaming one
    // onto the other would do nothing, yet report success.
    @Test(.tags(.diskImage), .diskImages)
    func refusesANameHeldByAHardLinkThatDiffersOnlyInCaseOnADiskThatMindsCase() async throws {
        try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
            let coordinator = WriteCoordinator.local(.real())
            try write(volume.path + "/h.txt", "shared")
            #expect(link(volume.path + "/h.txt", volume.path + "/H.txt") == 0)

            await #expect(throws: WriteCoordinatorError("An item named “H.txt” already exists.")) {
                try await coordinator.rename(
                    sourcePath: volume.path + "/h.txt", destinationName: "H.txt", window: TestWindow())
            }
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func changesOnlyTheCaseOfANameOnADiskThatMindsCase() async throws {
        try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
            let coordinator = WriteCoordinator.local(.real())
            try write(volume.path + "/notes.txt", "notes")
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: volume.path + "/notes.txt", destinationName: "Notes.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            #expect(try names(volume.path) == ["Notes.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // FAT and exFAT give empty files ids too large to compare: an empty file must still be recognized as itself when
    // only the case of its name changes.
    @Test(.tags(.diskImage), .diskImages)
    func changesOnlyTheCaseOfAnEmptyFilesNameOnAFAT32Disk() async throws {
        try await DiskImage.withSharedVolume(.fat32) { volume in
            let coordinator = WriteCoordinator.local(.real())
            try write(volume.path + "/empty.txt", "")
            try write(volume.path + "/other.txt", "")
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: volume.path + "/empty.txt", destinationName: "Empty.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            #expect(try names(volume.path) == ["Empty.txt", "other.txt"])
            // Another empty file isn't mistaken for the item itself.
            await #expect(throws: WriteCoordinatorError("An item named “other.txt” already exists.")) {
                try await coordinator.rename(
                    sourcePath: volume.path + "/Empty.txt", destinationName: "other.txt", window: TestWindow())
            }
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test func saysPlainlyThatAnItemIsGoneInsteadOfPassingOnTheSystemsError() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-rename-gone") { root in
            let coordinator = WriteCoordinator.local(.real())

            await #expect(throws: WriteCoordinatorError("“gone.txt” no longer exists.")) {
                try await coordinator.rename(
                    sourcePath: root.appending("gone.txt").path, destinationName: "b.txt", window: TestWindow())
            }
            await #expect(throws: WriteCoordinatorError("“Missing” no longer exists.")) {
                try await coordinator.createFolder(
                    parentDirectoryPath: root.appending("Missing").path, folderName: "New", window: TestWindow())
            }
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test func explainsARenameThatFailsWhileRunningInPlainWords() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in
            guard path == "/Users/demo/source.txt" else { throw errorWithCode("ENOENT", .errno(ENOENT)) }
            return Stats.file()
        }
        fileSystem.renameExclusiveImpl = { _, _ in
            throw errorWithCode("EACCES: permission denied, rename '/Users/demo/source.txt'", .errno(EACCES))
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        try await coordinator.rename(
            sourcePath: "/Users/demo/source.txt", destinationName: "renamed.txt", window: window)
        let end = await window.ended("write-op-1")

        #expect(end.result?.error == "You don't have permission to access this item.")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    @Test func saysALockedItemIsLockedWhenItCantBeRenamed() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-locked-ops") { root in
            try write(root.appending("notes.txt").path, "notes")
            chflags(root.appending("notes.txt").path, UInt32(UF_IMMUTABLE))
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: root.appending("notes.txt").path, destinationName: "renamed.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.result?.error == "“notes.txt” is locked. Unlock it in Finder's Get Info and try again.")
            #expect(try names(root.path) == ["notes.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test func namesTheLockedItemInsideAFolderThatCouldntBeDeleted() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-locked-ops") { root in
            let trash = root.appending(".Trash").path
            try FileManager.default.createDirectory(atPath: trash + "/Folder", withIntermediateDirectories: true)
            try write(trash + "/Folder/keep.txt", "keep")
            chflags(trash + "/Folder/keep.txt", UInt32(UF_IMMUTABLE))
            let coordinator = WriteCoordinator.local(.real(), homePath: root.path)
            let window = TestWindow()

            try await coordinator.deleteImmediately(paths: [trash + "/Folder"], window: window)
            let end = await window.ended("write-op-1")

            #expect(
                end.result?.items.first?.error == "“keep.txt” is locked. Unlock it in Finder's Get Info and try again.")
            #expect(try read(trash + "/Folder/keep.txt") == "keep")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }
}
