// Port of the "moving to the Trash and deleting", "the Trash" and "New Folder and Trash, picked items and names"
// describes of apps/desktop/src/main/bootstrap/writeOperations.test.ts
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct TrashOperationTests {
    private let home = "/Users/demo"

    private func write(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: Moving to the Trash and deleting

    // F-291 F-417 T-bbdad287
    @Test func countsAnItemThatIsAlreadyGoneAsDoneAndNamesTheItemWhenTheTrashRefuses() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { path in
            if path.hasSuffix("locked.txt") { throw errorWithCode("EPERM: operation not permitted", "EPERM") }
            return inTrash(path)
        }
        fileSystem.lstatImpl = { path in
            if path.hasSuffix("gone.txt") { throw errorWithCode("ENOENT: no such file or directory", "ENOENT") }
            return Stats.file()
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        try await coordinator.trash(
            paths: ["/Users/demo/gone.txt", "/Users/demo/locked.txt", "/Users/demo/c.txt"], window: window)
        let end = await window.ended("write-op-1")

        #expect(fileSystem.calls.trash == ["/Users/demo/locked.txt", "/Users/demo/c.txt"])
        #expect(end.status == .partial)
        #expect(
            end.result?.items.map(\.sourcePath) == [
                "/Users/demo/gone.txt", "/Users/demo/locked.txt", "/Users/demo/c.txt",
            ]
        )
        #expect(end.result?.items.map(\.status) == [.completed, .failed, .completed])
        // A known system error keeps its own plain sentence.
        #expect(end.result?.items[1].error == "You don't have permission to access this item.")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-291 F-293 T-957c5285
    @Test func stopsMovingItemsToTheTrashWhenCancelled() async throws {
        let held = HeldCall()
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { path in
            if path.hasSuffix("a.txt") { held.hold() }
            return inTrash(path)
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        try await coordinator.trash(paths: ["/Users/demo/a.txt", "/Users/demo/b.txt"], window: window)
        await held.begun()
        coordinator.cancel("write-op-1", window: window)
        held.release()
        let end = await window.ended("write-op-1")

        #expect(fileSystem.calls.trash.count == 1)
        #expect(end.status == .partial)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-253 F-254 T-255b6063
    @Test func refusesToDeleteOrTrashTheDiskTheSystemFoldersAVolumeOrTheHomeFolder() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
        let refused = [
            "/", "/Users", "/users/", "/Volumes", "/Volumes/Backup", "/volumes/Backup/", "/System", "/Applications",
            "/Library", "/Users/demo", "/USERS/DEMO", "/Users/demo/Desktop", "/Users/demo/library",
            "/Users/demo/../../Library", "Documents/report.txt",
        ]

        for path in refused {
            await #expect(throws: (any Error).self, "\(path)") {
                try await coordinator.deleteImmediately(
                    paths: ["/Users/demo/.Trash/fine.txt", path], window: TestWindow())
            }
            await #expect(throws: (any Error).self, "\(path)") {
                try await coordinator.trash(paths: [path], window: TestWindow())
            }
        }
        await #expect(throws: WriteCoordinatorError("“Backup” can't be deleted.")) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Backup"], window: TestWindow())
        }
        #expect(fileSystem.calls.rm.isEmpty)
        #expect(fileSystem.calls.trash.isEmpty)

        // What is in that disk's Trash is fine.
        #expect(
            try await coordinator.deleteImmediately(
                paths: ["/Volumes/Backup/.Trashes/501/old.txt"], window: TestWindow())
                == WriteOperationHandle(operationId: "write-op-1", status: .queued))
        await coordinator.shutDown()
    }

    // F-295 T-dccdd6c7
    @Test func protectsTheTrashFolderHoweverItsNameIsWritten() async throws {
        let coordinator = WriteCoordinator.local(.stub())

        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.deleteImmediately(
                paths: [NodePath.join(NSHomeDirectory(), ".trash")], window: TestWindow())
        }
        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.trash(paths: [NodePath.join(NSHomeDirectory(), ".TRASH")], window: TestWindow())
        }
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // Delete Immediately deletes only what is in a Trash, never a Trash itself.
    // F-295 T-1848ceae
    @Test func protectsAnotherDisksTrashAndEachUsersTrashInIt() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem)

        for path in ["/Volumes/Backup/.Trashes", "/Volumes/Backup/.Trashes/501", "/volumes/backup/.TRASHES/501/"] {
            let refusal = WriteCoordinatorError(WriteGuards.trashFolderRefusal)
            await #expect(throws: refusal, "\(path)") {
                try await coordinator.deleteImmediately(paths: [path], window: TestWindow())
            }
            await #expect(throws: refusal, "\(path)") {
                try await coordinator.trash(paths: [path], window: TestWindow())
            }
            await #expect(throws: refusal, "\(path)") {
                try await coordinator.rename(sourcePath: path, destinationName: "Old", window: TestWindow())
            }
        }
        #expect(fileSystem.calls.rm.isEmpty)
        #expect(fileSystem.calls.trash.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-295 T-22afff39
    @Test func doesntDeleteAnotherDisksTrashThroughALinkInTheTrash() async throws {
        let homeTrash = NodePath.join(NSHomeDirectory(), ".Trash")
        let fileSystem = TestLocalFileSystem.stub()
        // A link in the Trash that leads to another disk's Trash.
        fileSystem.realpathImpl = { path in path == homeTrash + "/link" ? "/Volumes/Backup/.Trashes" : path }
        let coordinator = WriteCoordinator.local(fileSystem)

        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.deleteImmediately(paths: [homeTrash + "/link/501"], window: TestWindow())
        }
        #expect(fileSystem.calls.rm.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // The same folder can be reached by other paths: on macOS the home folder is also at
    // /System/Volumes/Data/Users/<name>. What is on disk is compared, not only the path.
    // F-254 F-255 T-20578928
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/System/Volumes/Data")))
    func refusesTheHomeFolderAndTheDisksHoweverTheyAreReached() async throws {
        let disk = NativeWriteFileSystem()
        let home = NSHomeDirectory()
        for path in [
            "/System/Volumes/Data\(home)", "/System/Volumes/Data\(home)/Documents", "/System/Volumes/Data/Applications",
            "/System/Volumes/Data",
        ] {
            let error = #expect(throws: WriteCoordinatorError.self, "\(path)") {
                try WriteGuards.assertNotSystemLocation([path], verb: "deleted", fileSystem: disk, homePath: home)
            }
            #expect(error?.message.contains("can't be deleted") == true, "\(path)")
        }
        // An ordinary folder is fine, however it is reached.
        try withTemporaryDirectory(prefix: "filetrail-guard") { folder in
            try WriteGuards.assertNotSystemLocation([folder.path], verb: "deleted", fileSystem: disk, homePath: home)
        }
    }

    // F-255 T-ecb01d2e
    @Test(.tags(.diskImage), .diskImages)
    func refusesADiskMountedSomewhereOtherThanVolumes() async throws {
        try await DiskImage.withVolume(.apfs, ownMountPoint: true) { volume in
            let error = #expect(throws: WriteCoordinatorError.self) {
                try WriteGuards.assertNotSystemLocation(
                    [volume.path], verb: "moved to the Trash", fileSystem: NativeWriteFileSystem(),
                    homePath: NSHomeDirectory())
            }
            #expect(error?.message.hasSuffix("is a disk, so it can't be moved to the Trash.") == true)
        }
    }

    // Moving to another disk copies, then deletes the originals: as final as deleting.
    // F-251 F-255 T-8f45ec8a
    @Test func refusesToMoveTheHomeFolderOrASystemFolderButCopiesIt() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(writeService: service, fileSystem: TestLocalFileSystem.stub())
        func request(_ mode: CopyPasteMode) -> CopyPasteAnalysisRequest {
            CopyPasteAnalysisRequest(
                mode: mode, sourcePaths: [NSHomeDirectory()], destinationDirectoryPath: "/Volumes/Backup")
        }

        let error = await #expect(throws: WriteCoordinatorError.self) {
            try await coordinator.startAnalysis(request(.cut), window: TestWindow())
        }
        #expect(error?.message.hasSuffix("can't be moved.") == true)
        #expect(service.calls.startCopyPasteAnalysis.isEmpty)
        #expect(
            try await coordinator.startAnalysis(request(.copy), window: TestWindow())
                == CopyPasteAnalysisStartHandle(analysisId: "analysis-1", status: .queued))
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // The home folder it is given, as for everything else it checks.
    // F-254 T-af2a8e72
    @Test func protectsTheFoldersOfTheHomeFolderItIsGiven() async throws {
        let service = StubWriteService()
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: fileSystem, options: WriteCoordinatorOptions(homePath: "/Users/someone"))
        let window = TestWindow()

        await #expect(throws: WriteCoordinatorError("“Desktop” can't be renamed.")) {
            try await coordinator.rename(
                sourcePath: "/Users/someone/Desktop", destinationName: "Old Desktop", window: window)
        }
        await #expect(throws: WriteCoordinatorError("“Documents” can't be moved to the Trash.")) {
            try await coordinator.trash(paths: ["/Users/someone/Documents"], window: window)
        }
        await #expect(throws: WriteCoordinatorError("“someone” can't be deleted.")) {
            try await coordinator.deleteImmediately(paths: ["/Users/someone"], window: window)
        }
        await #expect(throws: WriteCoordinatorError("“Pictures” can't be moved.")) {
            try await coordinator.startAnalysis(
                CopyPasteAnalysisRequest(
                    mode: .cut, sourcePaths: ["/Users/someone/Pictures"], destinationDirectoryPath: "/Volumes/Backup"),
                window: window)
        }
        #expect(service.calls.startCopyPasteAnalysis.isEmpty)
        #expect(fileSystem.calls.trash.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-254 F-300 T-15a38c04
    @Test func refusesToRenameTheHomeFoldersOwnFolders() async throws {
        let coordinator = WriteCoordinator.local(.stub())

        await #expect(throws: WriteCoordinatorError("“Desktop” can't be renamed.")) {
            try await coordinator.rename(
                sourcePath: NodePath.join(NSHomeDirectory(), "Desktop"), destinationName: "Old Desktop",
                window: TestWindow())
        }
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-296 T-52aeacf2
    // T-c8c37a58
    @Test func explainsAFailedDeleteInPlainWords() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.rmImpl = { _, _, _ in
            throw errorWithCode("EACCES: permission denied, rmdir '/Users/demo/a'", "EACCES")
        }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
        let window = TestWindow()

        try await coordinator.deleteImmediately(paths: ["/Users/demo/.Trash/a"], window: window)
        let end = await window.ended("write-op-1")

        #expect(end.status == .failed)
        #expect(end.result?.error == "You don't have permission to access this item.")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: The Trash

    // F-250 F-297 T-06050e82
    @Test func refusesToPasteMoveOrMakeAnythingInIt() async throws {
        let service = StubWriteService()
        let coordinator = WriteCoordinator(
            writeService: service, fileSystem: TestLocalFileSystem.stub(),
            options: WriteCoordinatorOptions(homePath: home))

        for destination in ["/Users/demo/.Trash", "/Users/demo/.Trash/Old", "/Volumes/USB/.Trashes/501"] {
            await #expect(throws: WriteCoordinatorError("Nothing can be pasted into the Trash."), "\(destination)") {
                try await coordinator.startAnalysis(
                    CopyPasteAnalysisRequest(
                        mode: .cut, sourcePaths: ["/Users/demo/a.txt"], destinationDirectoryPath: destination),
                    window: TestWindow())
            }
            await #expect(throws: WriteCoordinatorError("Nothing can be made in the Trash."), "\(destination)") {
                try await coordinator.createFolder(
                    parentDirectoryPath: destination, folderName: "New Folder", window: TestWindow())
            }
        }
        #expect(service.calls.startCopyPasteAnalysis.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-290 T-4822ea4c
    @Test func doesntMoveWhatIsAlreadyInItToTheTrashAgain() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)

        await #expect(throws: WriteCoordinatorError("“old.txt” is already in the Trash.")) {
            try await coordinator.trash(paths: ["/Users/demo/.Trash/old.txt"], window: TestWindow())
        }
        #expect(fileSystem.calls.trash.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-295 T-f6553345
    @Test func deletesForGoodOnlyWhatIsInATrash() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)

        for path in [
            "/Users/demo/Work/report.txt", "/Users/demo/.Trash/../Work/report.txt", "/Users/demo/.Trash2/report.txt",
            "/Volumes/USB/report.txt",
        ] {
            let error = await #expect(throws: WriteCoordinatorError.self, "\(path)") {
                try await coordinator.deleteImmediately(
                    paths: ["/Users/demo/.Trash/old.txt", path], window: TestWindow())
            }
            #expect(error?.message.hasSuffix("isn't in the Trash, so it can't be deleted immediately.") == true)
        }
        #expect(fileSystem.calls.rm.isEmpty)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-294 F-295 T-697480a5
    @Test func deletesForGoodWhatJustCouldntGoToTheTrashBecauseItsDiskHasNone() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { path in
            if path.hasPrefix("/Volumes/Share/") { throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode) }
            return inTrash(path)
        }
        // Each item with its own id, so the one asked about is told from any other.
        let ids = Locked<[String: UInt64]>([:])
        fileSystem.lstatImpl = { path in
            var ino: UInt64 = 0
            ids.mutate { ids in
                ino = ids[path] ?? UInt64(ids.count + 1)
                ids[path] = ino
            }
            return Stats.file(dev: 7, ino: ino)
        }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
        let window = TestWindow()

        try await coordinator.trash(paths: ["/Volumes/Share/a.txt", "/Users/demo/b.txt"], window: window)
        let end = await window.ended("write-op-1")
        #expect(end.result?.items.map(\.noTrash) == [true, false])
        #expect(end.result?.items.first?.status == .failed)
        #expect(
            end.result?.items.first?.error == "“a.txt” couldn’t be moved to the Trash because its disk has no Trash.")

        // Another item on that disk wasn't asked about, so it can't be deleted this way.
        let error = await #expect(throws: WriteCoordinatorError.self) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/other.txt"], window: TestWindow())
        }
        #expect(error?.message.contains("isn't in the Trash") == true)
        #expect(
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/a.txt"], window: window)
                == WriteOperationHandle(operationId: "write-op-2", status: .queued))
        _ = await window.ended("write-op-2")
        #expect(fileSystem.calls.rm.map(\.0) == ["/Volumes/Share/a.txt"])
        #expect(fileSystem.calls.rm.first.map { $0.1 && $0.2 } == true)
        await coordinator.shutDown()
    }

    // Move to Trash through the app's TrashItem: only what it marks as being on a disk with no Trash (ENOTSUP, or no
    // code on a disk taken to have none, never on the startup disk) is offered for deleting for good; a locked item
    // says so, and any other reason is the Trash's own.
    // F-408 F-571
    @Test func offersToDeleteOnlyWhatTheTrashItemMarksAsOnADiskWithNoTrash() async throws {
        let startupDev: Int64 = 16_777_231
        let devices: [String: Int64] = [
            home: startupDev, "/Users/demo/locked.txt": startupDev, "/Users/demo/busy.txt": startupDev,
            "/Users/demo/ok.txt": startupDev, "/Volumes/USB/a.txt": 50, "/Volumes/USB/full.txt": 50,
            "/Volumes/Share/b.txt": 60,
        ]
        let trashItem = TrashItem(
            trash: { path in
                switch NodePath.basename(path) {
                case "ok.txt": return inTrash(path)
                case "full.txt": throw NativeError(message: "The disk is full.", code: "ENOSPC")
                case "b.txt": throw NativeError(message: "“b.txt” couldn’t be moved to the trash.", cocoaCode: 512)
                default:
                    throw NativeError(
                        message: "“\(NodePath.basename(path))” couldn’t be moved to the trash.", code: "ENOTSUP",
                        cocoaCode: 3328)
                }
            },
            lstat: { path in
                guard let dev = devices[path] else { throw OperationError("ENOENT: \(path)", code: "ENOENT") }
                return WriteServiceStats(type: .file, dev: dev)
            },
            getFlags: { $0.hasSuffix("locked.txt") ? 0x2 : 0 }, homePath: home,
            diskHasTrash: { !$0.hasPrefix("/Volumes/Share/") })
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { try trashItem($0) }
        let ids = Locked<[String: UInt64]>([:])
        fileSystem.lstatImpl = { path in
            var ino: UInt64 = 0
            ids.mutate { ids in
                ino = ids[path] ?? UInt64(ids.count + 1)
                ids[path] = ino
            }
            return Stats.file(dev: devices[path] ?? 7, ino: ino)
        }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
        let window = TestWindow()
        let paths = [
            "/Users/demo/ok.txt", "/Users/demo/locked.txt", "/Users/demo/busy.txt", "/Volumes/USB/a.txt",
            "/Volumes/USB/full.txt", "/Volumes/Share/b.txt",
        ]

        try await coordinator.trash(paths: paths, window: window)
        let end = await window.ended("write-op-1")

        #expect(end.result?.items.map(\.status) == [.completed, .failed, .failed, .failed, .failed, .failed])
        #expect(end.result?.items.map(\.noTrash) == [false, false, false, true, false, true])
        #expect(
            end.result?.items[1].error == "“locked.txt” is locked. Unlock it in Finder's Get Info and try again.")
        #expect(end.result?.items[2].error == "“busy.txt” couldn’t be moved to the trash.")
        #expect(end.result?.items[3].error == "“a.txt” couldn’t be moved to the Trash because its disk has no Trash.")
        #expect(end.result?.items[5].error == "“b.txt” couldn’t be moved to the Trash because its disk has no Trash.")

        // What the Trash refused for a reason of its own can't be deleted for good this way.
        for path in ["/Users/demo/busy.txt", "/Volumes/USB/full.txt"] {
            let error = await #expect(throws: WriteCoordinatorError.self) {
                try await coordinator.deleteImmediately(paths: [path], window: window)
            }
            #expect(error?.message.hasSuffix("isn't in the Trash, so it can't be deleted immediately.") == true)
        }
        let noTrash = ["/Volumes/USB/a.txt", "/Volumes/Share/b.txt"]
        #expect(
            try await coordinator.deleteImmediately(paths: noTrash, window: window)
                == WriteOperationHandle(operationId: "write-op-2", status: .queued))
        _ = await window.ended("write-op-2")
        #expect(fileSystem.calls.rm.map(\.0) == noTrash)
        await coordinator.shutDown()
    }

    // While the question is open, another window (or another Mac on the share) puts a different item at that path:
    // confirming deletes nothing it wasn't asked about.
    // F-295 T-f704e86b
    @Test func doesntDeleteAnotherItemPutAtThePathWhileTheNoTrashQuestionWasOpen() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-no-trash-swap") { root in
            try write(root.appending("a.txt").path, "asked about")
            try write(root.appending("b.txt").path, "asked about too")
            let fileSystem = TestLocalFileSystem.real()
            fileSystem.trashImpl = { _ in throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode) }
            let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
            let window = TestWindow()
            try await coordinator.trash(
                paths: [root.appending("a.txt").path, root.appending("b.txt").path], window: window)
            _ = await window.ended("write-op-1")

            #expect(Darwin.rename(root.appending("a.txt").path, root.appending("moved.txt").path) == 0)
            try write(root.appending("a.txt").path, "never asked about")

            await #expect(
                throws: WriteCoordinatorError("“a.txt” changed after you were asked about it, so it wasn't deleted.")
            ) {
                try await coordinator.deleteImmediately(paths: [root.appending("a.txt").path], window: window)
            }
            #expect(try read(root.appending("a.txt").path) == "never asked about")

            // The item still there is deleted as asked.
            try await coordinator.deleteImmediately(paths: [root.appending("b.txt").path], window: window)
            _ = await window.ended("write-op-2")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["a.txt", "moved.txt"])
            await coordinator.shutDown()
        }
    }

    // On a disk without usable ids (some network volumes), a folder put in its place holding as many items isn't
    // taken for it: its date differs.
    // F-295 T-224b2971
    @Test func tellsAFolderWithoutAnIdFromAnotherOneHoldingAsManyItems() async throws {
        let looks = Locked<(mtimeMs: Double, entries: [String])>((1_000, ["a.txt"]))
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { _ in throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode) }
        fileSystem.lstatImpl = { _ in Stats.directory(mtimeMs: looks.value.mtimeMs) }
        fileSystem.readdirImpl = { _ in looks.value.entries }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: home)
        let window = TestWindow()
        try await coordinator.trash(paths: ["/Volumes/Share/Project"], window: window)
        _ = await window.ended("write-op-1")

        looks.mutate { $0 = (2_000, ["b.txt"]) }
        await #expect(
            throws: WriteCoordinatorError("“Project” changed after you were asked about it, so it wasn't deleted.")
        ) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/Project"], window: window)
        }

        looks.mutate { $0 = (1_000, ["a.txt"]) }
        try await coordinator.deleteImmediately(paths: ["/Volumes/Share/Project"], window: window)
        _ = await window.ended("write-op-2")
        #expect(fileSystem.calls.rm.map(\.0) == ["/Volumes/Share/Project"])
        await coordinator.shutDown()
    }

    // A symlink inside the Trash to a folder elsewhere: what is "in" it through the link is really outside the Trash.
    // F-295 T-b8ba37a4
    @Test func doesntDeleteThroughALinkInTheTrashThatLeadsOutOfIt() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-trash-link") { root in
            try FileManager.default.createDirectory(
                atPath: root.appending(".Trash").path, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                atPath: root.appending("Work").path, withIntermediateDirectories: false)
            try write(root.appending("Work/report.txt").path, "keep")
            #expect(symlink(root.appending("Work").path, root.appending(".Trash/link").path) == 0)
            let coordinator = WriteCoordinator.local(.real(), homePath: root.path)

            let error = await #expect(throws: WriteCoordinatorError.self) {
                try await coordinator.deleteImmediately(
                    paths: [root.appending(".Trash/link/report.txt").path], window: TestWindow())
            }
            #expect(error?.message.contains("isn't in the Trash") == true)
            #expect(try read(root.appending("Work/report.txt").path) == "keep")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // MARK: New Folder and Trash, picked items and names

    // The window suggests a free name from what it lists, which may be out of date.
    // F-243 F-297 T-d7664236
    @Test func takesTheNextFreeNameWhenTheOneSuggestedWasTakenMeanwhile() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-new-folder") { root in
            for name in ["New Folder", "New Folder 2", "Untitled 3"] {
                try FileManager.default.createDirectory(
                    atPath: root.appending(name).path, withIntermediateDirectories: false)
            }
            let coordinator = WriteCoordinator.local(.real())
            let window = TestWindow()

            try await coordinator.createFolder(
                parentDirectoryPath: root.path, folderName: "New Folder", nextFreeName: true, window: window)
            let made = await window.ended("write-op-1")
            #expect(made.result?.items.first?.destinationPath == root.appending("New Folder 3").path)

            try await coordinator.createFolder(
                parentDirectoryPath: root.path, folderName: "Untitled 3", nextFreeName: true, window: window)
            let second = await window.ended("write-op-2")
            #expect(second.result?.items.first?.destinationPath == root.appending("Untitled 4").path)

            // A name the person typed is never changed: it is refused.
            await #expect(throws: WriteCoordinatorError("An item named “New Folder” already exists.")) {
                try await coordinator.createFolder(
                    parentDirectoryPath: root.path, folderName: "New Folder", window: window)
            }
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // F-291 T-4151775f
    @Test func movesAFolderAndAnItemInsideItToTheTrashAsOneItem() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        try await coordinator.trash(
            paths: ["/Users/demo/F/child.txt", "/Users/demo/F", "/Users/demo/F"], window: window)
        let end = await window.ended("write-op-1")

        #expect(fileSystem.calls.trash == ["/Users/demo/F"])
        #expect(end.result?.summary.totalItemCount == 1)
        #expect(end.result?.summary.completedItemCount == 1)
        await coordinator.shutDown(maxWaitMs: 0)
    }
}
