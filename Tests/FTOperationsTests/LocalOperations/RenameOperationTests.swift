// Port of the "renaming on a real disk" and "locked items" describes of
// apps/desktop/src/main/bootstrap/writeOperations.test.ts
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

    // F-302 T-64bdda6c
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

    // F-301 T-1e716faa
    @Test func changesOnlyTheCaseOfANameOnADiskThatIgnoresCase() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-rename-case") { root in
            try write(root.appending("notes.txt").path, "notes")
            // This disk minds case; "notes.txt" and "Notes.txt" are different names there, and the test below
            // covers that.
            guard FileManager.default.fileExists(atPath: root.appending("NOTES.TXT").path) else { return }
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: root.appending("notes.txt").path, destinationName: "Notes.txt", window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Notes.txt"])
            #expect(try read(root.appending("Notes.txt").path) == "notes")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // F-301 T-8a9072dc
    @Test func changesOnlyHowAnAccentedLetterIsEncodedOnADiskThatIgnoresThat() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-rename-nfc") { root in
            let decomposed = "cafe\u{301}.txt"
            let composed = "caf\u{E9}.txt"
            try write(root.path + "/" + decomposed, "menu")
            guard Darwin.access(root.path + "/" + composed, F_OK) == 0 else { return }
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.rename(
                sourcePath: root.path + "/" + decomposed, destinationName: composed, window: window)
            let end = await window.ended("write-op-1")

            #expect(end.status == .completed)
            let listed = try PosixFileSystem().readdir(root.path)
            #expect(listed.count == 1)
            #expect(listed.first.map { Array($0.unicodeScalars) } == Array(composed.unicodeScalars))
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // On a disk that minds case, "Notes.txt" next to "notes.txt" is another file.
    // F-302 T-9f913ecf
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

    // F-301 F-302 T-00189ff5
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
    // F-301 T-fef51c5b
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

    // F-301 T-bf53ad2b
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
    // F-301 T-974f57fe
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

    // F-297 F-300 T-5a782d53
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

    // F-302 T-3ff4b570
    @Test func explainsARenameThatFailsWhileRunningInPlainWords() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in
            guard path == "/Users/demo/source.txt" else { throw errorWithCode("ENOENT", "ENOENT") }
            return Stats.file()
        }
        fileSystem.renameExclusiveImpl = { _, _ in
            throw errorWithCode("EACCES: permission denied, rename '/Users/demo/source.txt'", "EACCES")
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        try await coordinator.rename(
            sourcePath: "/Users/demo/source.txt", destinationName: "renamed.txt", window: window)
        let end = await window.ended("write-op-1")

        #expect(end.result?.error == "You don't have permission to access this item.")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // What goes wrong while a finished rename is reported (keeping it for Undo, telling the other windows, the
    // window going away) never turns it into a failure, and the slot is free again.
    // F-302 T-2b819be4
    @Test func doesntReportAFinishedRenameAsFailedWhenReportingItGoesWrong() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in
            guard path == "/Users/demo/source.txt" else { throw OperationError("missing") }
            return Stats.file()
        }
        let logs = LogRecorder()
        var bothLogged: CheckedContinuation<Void, Never>?
        let coordinator = WriteCoordinator.local(
            fileSystem,
            options: WriteCoordinatorOptions(
                recordUndo: { _ in throw OperationError("unexpected shape") },
                broadcastProgress: { event, _ in
                    if event.status == .completed { throw OperationError("unexpected shape") }
                },
                logError: { message, error in
                    logs.log(message, error)
                    if logs.messages.count >= 2 {
                        bothLogged?.resume()
                        bothLogged = nil
                    }
                }))
        let window = TestWindow()

        try await coordinator.rename(
            sourcePath: "/Users/demo/source.txt", destinationName: "renamed.txt", window: window)
        if logs.messages.count < 2 { await withCheckedContinuation { bothLogged = $0 } }

        #expect(fileSystem.calls.renameExclusive.count == 1)
        #expect(!window.statuses.contains(.failed))
        // The write slot is free again all the same.
        #expect(
            try await coordinator.createFolder(parentDirectoryPath: "/Users/demo", folderName: "Next", window: window)
                == WriteOperationHandle(operationId: "write-op-2", status: .queued))
        await coordinator.shutDown()
    }

    // MARK: Locked items

    private func chflags(_ path: String, _ flags: UInt32) {
        #expect(Darwin.lchflags(path, flags) == 0)
    }

    // F-302 T-ec5348d1
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

    // F-296 T-3e6c5d4f
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
