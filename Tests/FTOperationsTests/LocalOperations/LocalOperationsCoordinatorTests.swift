// Port of the local-operation rows of the createWriteOperationCoordinator and "quitting during an operation" describes
// of apps/desktop/src/main/bootstrap/writeOperations.test.ts, and of the "deleting immediately what a disk without a
// Trash couldn't take" describe of writeOperations.windows.test.ts: rename, New Folder, Trash and Delete Immediately
// through the coordinator's write slot
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.localOperationHang) struct LocalOperationsCoordinatorTests {
    // F-243 F-302 T-ba2f0985
    @Test func renamesALocalItemAndEmitsProgress() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in
            guard path == "/Users/demo/source.txt" else { throw OperationError("missing") }
            return Stats.file()
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        let handle = try await coordinator.rename(
            sourcePath: "/Users/demo/source.txt", destinationName: "renamed.txt", window: window)
        #expect(handle == WriteOperationHandle(operationId: "write-op-1", status: .queued))
        let end = await window.ended("write-op-1")

        #expect(
            fileSystem.calls.renameExclusive.map { [$0.0, $0.1] } == [
                ["/Users/demo/source.txt", "/Users/demo/renamed.txt"]
            ])
        #expect(fileSystem.calls.rename.isEmpty)
        #expect(end.action == .rename)
        #expect(end.status == .completed)
        #expect(end.completedItemCount == 1)
        #expect(end.currentDestinationPath == "/Users/demo/renamed.txt")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-243 F-297 F-299 T-e868310c
    @Test func createsAFolderOnlyWhenTheParentExistsAndTheTargetIsUnused() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        let handle = try await coordinator.createFolder(
            parentDirectoryPath: "/Users/demo", folderName: "Projects", window: window)
        #expect(handle == WriteOperationHandle(operationId: "write-op-1", status: .queued))
        let end = await window.ended("write-op-1")

        #expect(fileSystem.calls.stat.contains("/Users/demo"))
        #expect(fileSystem.calls.mkdir == ["/Users/demo/Projects"])
        #expect(end.action == .newFolder)
        #expect(end.status == .completed)
        #expect(end.currentDestinationPath == "/Users/demo/Projects")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-243 F-291 F-294 T-7ce082ce
    @Test func movesItemsToTheTrashGoingOnPastAnItemThatCantBeMoved() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { path in
            // What TrashItem reports on a disk that may have no Trash.
            if path.hasSuffix("b.txt") { throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode) }
            return inTrash(path)
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()

        let handle = try await coordinator.trash(
            paths: ["/Users/demo/a.txt", "/Users/demo/b.txt", "/Users/demo/c.txt"], window: window)
        #expect(handle == WriteOperationHandle(operationId: "write-op-1", status: .queued))
        let end = await window.ended("write-op-1")

        // c.txt still goes to the Trash after b.txt failed.
        #expect(fileSystem.calls.trash == ["/Users/demo/a.txt", "/Users/demo/b.txt", "/Users/demo/c.txt"])
        #expect(end.action == .trash)
        #expect(end.status == .partial)
        #expect(end.completedItemCount == 2)
        #expect(end.result?.error == "“b.txt” couldn’t be moved to the Trash because its disk has no Trash.")
        #expect(end.result?.items.map(\.sourcePath) == ["/Users/demo/a.txt", "/Users/demo/b.txt", "/Users/demo/c.txt"])
        #expect(end.result?.items.map(\.status) == [.completed, .failed, .completed])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-291 F-292 T-6e5d5f21
    @Test func takesWhatWentToTheTrashOffMeasuredFoldersAndForgetsThoseItCantTell() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.itemSizeImpl = { path in
            if path.hasSuffix("b.bin") { throw errorWithCode("denied", "EACCES") }
            return path == "/Users/demo"
                ? ItemSize(kind: .folder, sizeBytes: 0, diskBytes: 0, dev: 16)
                : ItemSize(kind: .file, sizeBytes: 200, diskBytes: 400, dev: 16)
        }
        var forgotten: [(changed: [String], removed: [RemovedItem])] = []
        let coordinator = WriteCoordinator.local(
            fileSystem, homePath: "/Users/demo",
            options: WriteCoordinatorOptions(
                caches: WriteCaches(forget: { changed, removed in forgotten.append((changed, removed)) })))
        let window = TestWindow()

        try await coordinator.trash(paths: ["/Users/demo/Project/a.bin", "/Users/demo/Music/b.bin"], window: window)
        _ = await window.ended("write-op-1")

        // Read just before it went, so the size known for Project is still exact; what b.bin added to Music
        // couldn't be read, so Music is measured again when asked for (FolderSizeAdjust, ported with P2-03).
        #expect(forgotten.count == 1)
        #expect(
            forgotten.first?.removed == [
                RemovedItem(
                    path: "/Users/demo/Project/a.bin",
                    item: ItemSize(kind: .file, sizeBytes: 200, diskBytes: 400, dev: 16), intoHomeTrash: true),
                RemovedItem(path: "/Users/demo/Music/b.bin", item: nil, intoHomeTrash: nil),
            ])
        // What was removed is taken off, not forgotten as a changed path.
        #expect(forgotten.first?.changed == [])
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-296 T-f293d4ee
    @Test func deleteImmediatelyReportsPartialCompletionWhileContinuingAfterFailedItems() async throws {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.rmImpl = { path, _, _ in
            if path.hasSuffix("b.txt") { throw OperationError("delete denied") }
        }
        let coordinator = WriteCoordinator.local(fileSystem, homePath: "/Users/demo")
        let window = TestWindow()

        let handle = try await coordinator.deleteImmediately(
            paths: ["/Users/demo/.Trash/a.txt", "/Users/demo/.Trash/b.txt", "/Users/demo/.Trash/c.txt"],
            window: window)
        #expect(handle == WriteOperationHandle(operationId: "write-op-1", status: .queued))
        let end = await window.ended("write-op-1")

        #expect(fileSystem.calls.rm.count == 3)
        #expect(end.action == .deleteImmediately)
        #expect(end.status == .partial)
        #expect(end.completedItemCount == 2)
        #expect(end.result?.error == "delete denied")
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-290 F-295 F-300 T-a63d0d99
    @Test func rejectsProtectedTopLevelTrashMutationsBeforeQueuingLocalWrites() async throws {
        let coordinator = WriteCoordinator.local(.stub())
        let trashPath = NodePath.join(NSHomeDirectory(), ".Trash")

        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.rename(sourcePath: trashPath, destinationName: "Renamed Trash", window: TestWindow())
        }
        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.trash(paths: [trashPath], window: TestWindow())
        }
        await #expect(throws: WriteCoordinatorError(WriteGuards.trashFolderRefusal)) {
            try await coordinator.deleteImmediately(paths: [trashPath], window: TestWindow())
        }
        #expect(coordinator.activeOperation == nil)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // F-291 F-293 F-363 T-88f70b42
    @Test func countsEveryItemAStoppedTrashNeverReached() async throws {
        let held = HeldCall()
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.trashImpl = { path in
            if path.hasSuffix("a.txt") { held.hold() }
            return inTrash(path)
        }
        let coordinator = WriteCoordinator.local(fileSystem)
        let window = TestWindow()
        let paths = ["a", "b", "c", "d", "e"].map { "/Users/demo/\($0).txt" }

        try await coordinator.trash(paths: paths, window: window)
        await held.begun()
        #expect(coordinator.cancel("write-op-1", window: window))
        held.release()
        let end = await window.ended("write-op-1")

        #expect(end.result?.status == .partial)
        #expect(end.result?.error == "Stopped after 1 item was moved to the Trash.")
        #expect(end.result?.summary.completedItemCount == 1)
        #expect(end.result?.summary.cancelledItemCount == 4)
        #expect(end.result?.summary.topLevelItemCount == 5)
        await coordinator.shutDown(maxWaitMs: 0)
    }

    // MARK: Several windows

    /// The disk of the no-Trash window cases: one id per path, and /Volumes/Share without a Trash.
    private func noTrashDisk() -> TestLocalFileSystem {
        let fileSystem = TestLocalFileSystem.stub()
        fileSystem.lstatImpl = { path in Stats.file(dev: 1, ino: UInt64(path.utf8.count)) }
        fileSystem.trashImpl = { path in
            if path.hasPrefix("/Volumes/Share/") { throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode) }
            return "/Users/demo/.Trash/\(NodePath.basename(path))"
        }
        return fileSystem
    }

    private func trashEnd(
        _ coordinator: WriteCoordinator, _ window: TestWindow, _ path: String
    ) async throws -> WriteOperationEvent {
        let handle = try await coordinator.trash(paths: [path], window: window)
        return await window.ended(handle.operationId)
    }

    // F-295 T-7f27af07
    @Test func deletingWhatHadNoTrashIsUpToTheWindowThatWasToldWhateverAnotherSendsToTheTrash() async throws {
        let fileSystem = noTrashDisk()
        let coordinator = WriteCoordinator.local(fileSystem, homePath: "/Users/demo")
        let first = TestWindow()
        let second = TestWindow()

        #expect(try await trashEnd(coordinator, first, "/Volumes/Share/a.txt").result?.items.first?.noTrash == true)
        // While the first window asks whether to delete it, the second one moves something to the Trash.
        #expect(try await trashEnd(coordinator, second, "/Users/demo/b.txt").status == .completed)

        // Only the window that was told may delete it.
        await #expect(throws: (any Error).self) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/a.txt"], window: second)
        }
        let handle = try await coordinator.deleteImmediately(paths: ["/Volumes/Share/a.txt"], window: first)
        #expect(await first.ended(handle.operationId).status == .completed)
        #expect(fileSystem.calls.rm.map(\.0) == ["/Volumes/Share/a.txt"])
        #expect(fileSystem.calls.rm.first.map { $0.1 && $0.2 } == true)
        // Once deleted, it is let go of: another item there now is a different matter.
        let refusal = await #expect(throws: WriteCoordinatorError.self) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/a.txt"], window: first)
        }
        #expect(refusal?.message.contains("isn't in the Trash") == true)
        await coordinator.shutDown()
    }

    // The window that moved items to the Trash closes while it runs: the window a Trash is handed to never asks
    // about deleting its items (it wasn't the one asked to trash them), and can't delete them unasked.
    // F-295 T-3299f715
    @Test func deletingWhatHadNoTrashStaysWithTheWindowThatAskedNotOneATrashIsHandedTo() async throws {
        let held = HeldCall()
        let fileSystem = noTrashDisk()
        fileSystem.trashImpl = { path in
            if path.hasSuffix("b.txt") { held.hold() }
            throw errorWithCode("no Trash", CopyPasteErrors.noTrashErrorCode)
        }
        let first = TestWindow()
        let second = TestWindow()
        let coordinator = WriteCoordinator.local(
            fileSystem, homePath: "/Users/demo", options: WriteCoordinatorOptions(successorOf: { _ in second }))

        let handle = try await coordinator.trash(
            paths: ["/Volumes/Share/a.txt", "/Volumes/Share/b.txt"], window: first)
        await held.begun()
        first.isClosed = true
        coordinator.windowClosed(first)
        held.release()
        let end = await second.ended(handle.operationId)
        #expect(end.result?.items.map(\.noTrash) == [true, true])

        let refusal = await #expect(throws: WriteCoordinatorError.self) {
            try await coordinator.deleteImmediately(
                paths: ["/Volumes/Share/a.txt", "/Volumes/Share/b.txt"], window: second)
        }
        #expect(refusal?.message == "“a.txt” isn't in the Trash, so it can't be deleted immediately.")
        #expect(fileSystem.calls.rm.isEmpty)
        await coordinator.shutDown()
    }

    // A native window has no page to load again: what it was asked about goes when it closes.
    // F-295 T-9fbaceb4
    @Test func whatHadNoTrashIsLetGoOfWhenItsWindowCloses() async throws {
        let coordinator = WriteCoordinator.local(noTrashDisk(), homePath: "/Users/demo")
        let window = TestWindow()

        // Twice: each Trash keeps only what it found.
        _ = try await trashEnd(coordinator, window, "/Volumes/Share/a.txt")
        _ = try await trashEnd(coordinator, window, "/Volumes/Share/a.txt")
        coordinator.windowClosed(window)

        let refusal = await #expect(throws: WriteCoordinatorError.self) {
            try await coordinator.deleteImmediately(paths: ["/Volumes/Share/a.txt"], window: window)
        }
        #expect(refusal?.message.contains("isn't in the Trash") == true)
        #expect(coordinator.itemsWithoutTrash.isEmpty)
        await coordinator.shutDown()
    }
}
