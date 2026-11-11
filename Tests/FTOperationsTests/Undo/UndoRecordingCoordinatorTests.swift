// What each operation tells the history for Undo, and when: before the next operation can start, so the history keeps
// them in order.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// What the coordinator told the history (`finished`).
@MainActor
final class FinishedWrites {
    var all: [FinishedWrite] = []
    var logs: [UndoLog] { all.map(\.log) }
}

@MainActor
@Suite(.serialized)
struct UndoRecordingCoordinatorTests {
    private func idOf(_ path: String) throws -> ItemId? {
        itemIdOf(try PosixFileSystem().lstat(path))
    }

    /// `setUp`: a coordinator on the disk, with a folder Trash, whose history is a list.
    private func setUp(
        _ root: String, _ trashDir: String, writeService: any CoordinatorWriteService = StubWriteService(),
        configure: (UndoTestFileSystem) -> Void = { _ in }, diskHasTrash: (@Sendable (String) throws -> Bool)? = nil
    ) -> (coordinator: WriteCoordinator, finished: FinishedWrites, window: TestWindow) {
        let finished = FinishedWrites()
        let fileSystem = UndoTestFileSystem(trashDir: trashDir)
        configure(fileSystem)
        let coordinator = WriteCoordinator(
            writeService: writeService, fileSystem: fileSystem,
            options: WriteCoordinatorOptions(
                homePath: root, recordUndo: { finished.all.append($0) }, diskHasTrash: diskHasTrash))
        return (coordinator, finished, TestWindow())
    }

    private func end(_ handle: WriteOperationHandle, _ window: TestWindow) async throws -> WriteOperationEvent {
        try await Coordinators.end(of: handle.operationId, in: window)
    }

    @Test func recordsARenameWithTheItemsIdAndTheFolderItIsIn() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let (coordinator, finished, window) = setUp(root, trashDir)
            _ = try await end(
                coordinator.rename(sourcePath: "\(root)/a.txt", destinationName: "b.txt", window: window), window)
            #expect(finished.all.count == 1)
            #expect(finished.all.first?.action == .write(.rename))
            #expect(
                finished.logs == [
                    .undoable(units: [
                        UndoUnit(steps: [
                            .moved(
                                UndoStep.Moved(
                                    from: "\(root)/a.txt", to: "\(root)/b.txt", id: try idOf("\(root)/b.txt"),
                                    itemKind: .file, parentId: try idOf(root)))
                        ])
                    ])
                ])
            #expect(finished.all.first?.items.map(\.status) == [.completed])
            await coordinator.shutDown()
        }
    }

    @Test func recordsNothingForARenameThatFailed() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.renameExclusiveImpl = { _, _ in throw codedError(.errno(EACCES), "EACCES: permission denied")
                }
            }
            let ended = try await end(
                coordinator.rename(sourcePath: "\(root)/a.txt", destinationName: "b.txt", window: window), window)
            #expect(ended.status == .failed)
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func recordsANewFolderWithHowItLookedWhenMade() async throws {
        try await withUndoFolder { root, trashDir in
            let (coordinator, finished, window) = setUp(root, trashDir)
            _ = try await end(
                coordinator.createFolder(parentDirectoryPath: root, folderName: "New", window: window), window)
            let folder = "\(root)/New"
            let stats = try PosixFileSystem().lstat(folder)
            guard case .undoable(let units) = finished.logs.first,
                case .created(let path, let id, let stamp) =
                    units.first?.steps.first, units.count == 1
            else {
                Issue.record("expected one made folder, got \(finished.logs)")
                return
            }
            #expect(path == folder)
            #expect(id == itemIdOf(stats))
            #expect(stamp?.kind == .directory)
            #expect(stamp?.size == nil)
            #expect(stamp?.mtimeMs == stats.mtimeMs)
            #expect(stamp?.entryCount == 0)
            #expect(stamp?.entryNames != nil)
            await coordinator.shutDown()
        }
    }

    @Test func cantUndoANewFolderMadeOnADiskWithoutATrash() async throws {
        try await withUndoFolder { root, trashDir in
            let asked = AskedPaths()
            let (coordinator, finished, window) = setUp(
                root, trashDir,
                diskHasTrash: { path in
                    asked.add(path)
                    return false
                })
            _ = try await end(
                coordinator.createFolder(parentDirectoryPath: root, folderName: "New", window: window), window)
            #expect(finished.logs == [.notUndoable(reason: .noTrash)])
            #expect(asked.paths == [root])
            await coordinator.shutDown()
        }
    }

    @Test func cantUndoANewFolderWhenWhetherItsDiskHasATrashCantBeTold() async throws {
        try await withUndoFolder { root, trashDir in
            let (coordinator, finished, window) = setUp(
                root, trashDir, diskHasTrash: { _ in throw OperationError("The mount table couldn't be read.") })
            let ended = try await end(
                coordinator.createFolder(parentDirectoryPath: root, folderName: "New", window: window), window)
            #expect(ended.status == .completed)
            #expect(finished.logs == [.notUndoable(reason: .noTrash)])
            await coordinator.shutDown()
        }
    }

    @Test func recordsTheItemsABatchRenameRenamedUnderTheirFinalNames() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.write("\(root)/b.txt", "b")
            try UndoDisk.write("\(root)/same.txt", "same")
            let (coordinator, finished, window) = setUp(root, trashDir)
            // A swap.
            _ = try await end(
                coordinator.batchRename(
                    BatchRenameRequest(
                        items: [
                            .init(sourcePath: "\(root)/a.txt", destinationName: "b.txt", isFolder: false),
                            .init(sourcePath: "\(root)/b.txt", destinationName: "a.txt", isFolder: false),
                        ], onConflict: .number, numberSeparator: " "), window: window), window)
            guard case .undoable(let units) = finished.logs.first, finished.logs.count == 1, units.count == 1,
                units[0].steps.count == 1, case .batchRenamed(let renamed) = units[0].steps[0]
            else {
                Issue.record("expected one batch rename, got \(finished.logs)")
                return
            }
            let expected = [
                BatchRenamedItem(
                    from: "\(root)/a.txt", to: "\(root)/b.txt", id: try idOf("\(root)/b.txt"), itemKind: .file),
                BatchRenamedItem(
                    from: "\(root)/b.txt", to: "\(root)/a.txt", id: try idOf("\(root)/a.txt"), itemKind: .file),
            ]
            // In any order.
            for item in expected {
                #expect(renamed.contains(item))
            }
            await coordinator.shutDown()
        }
    }

    @Test func recordsEachItemMovedToTheTrashOnItsOwnWithWhereItWent() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.mkdir("\(root)/Folder")
            let fileId = try idOf("\(root)/a.txt")
            let folderId = try idOf("\(root)/Folder")
            let (coordinator, finished, window) = setUp(root, trashDir)
            // One that was already gone: nothing to put back.
            _ = try await end(
                coordinator.trash(paths: ["\(root)/a.txt", "\(root)/gone.txt", "\(root)/Folder"], window: window),
                window)
            let parentId = try idOf(root)
            #expect(
                finished.logs == [
                    .undoable(units: [
                        UndoUnit(steps: [
                            .trashed(
                                from: "\(root)/a.txt", trashPath: "\(trashDir)/1-a.txt", id: fileId, parentId: parentId,
                                stamp: nil)
                        ]),
                        UndoUnit(steps: [
                            .trashed(
                                from: "\(root)/Folder", trashPath: "\(trashDir)/2-Folder", id: folderId,
                                parentId: parentId, stamp: nil)
                        ]),
                    ])
                ])
            await coordinator.shutDown()
        }
    }

    @Test func looksAtEachItemItMovesToTheTrashOnceAndAtTheirFolderOnceForUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let paths = ["a.txt", "b.txt", "c.txt"].map { "\(root)/\($0)" }
            for path in paths { try UndoDisk.write(path, "a") }
            let looks = AskedPaths()
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.lstatImpl = { path in
                    looks.add("lstat \(path)")
                    return try base.lstat(path)
                }
                fileSystem.statImpl = { path in
                    looks.add("stat \(path)")
                    return try base.stat(path)
                }
            }
            _ = try await end(coordinator.trash(paths: paths, window: window), window)
            // Each item once by the check that refuses system folders, and once to be moved.
            #expect(
                looks.paths.sorted() == (paths.flatMap { ["lstat \($0)", "lstat \($0)"] } + ["stat \(root)"]).sorted())
            let parentId = try idOf(root)
            guard case .undoable(let units) = finished.logs.first else {
                Issue.record("expected the Trash to be undoable")
                return
            }
            #expect(units.count == paths.count)
            #expect(
                units.allSatisfy { unit in
                    if case .trashed(_, _, _, let parent, _) = unit.steps.first { return parent == parentId }
                    return false
                })
            await coordinator.shutDown()
        }
    }

    @Test func recordsNothingWhenNothingCouldGoToTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw codedError(.errno(EPERM), "EPERM: operation not permitted") }
            }
            let ended = try await end(coordinator.trash(paths: ["\(root)/a.txt"], window: window), window)
            #expect(ended.status == .failed)
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func cantUndoDeleteImmediately() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(trashDir)/a.txt", "a")
            let (coordinator, finished, window) = setUp(root, trashDir)
            _ = try await end(coordinator.deleteImmediately(paths: ["\(trashDir)/a.txt"], window: window), window)
            #expect(finished.all.map(\.action) == [.write(.deleteImmediately)])
            #expect(finished.logs == [.notUndoable(reason: .deletedForGood)])
            await coordinator.shutDown()
        }
    }

    @Test func leavesTheHistoryAsItWasWhenDeleteImmediatelyDeletedNothing() async throws {
        // Nothing was deleted: the item had changed after the no-Trash question, and was refused just before
        // deleting. What can be undone stays undoable.
        try await withUndoFolder { root, trashDir in
            let path = "\(root)/share.txt"
            try UndoDisk.write(path, "asked about")
            let swapWhenMeasured = UndoFlag()
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw codedError(.noTrash, "no Trash") }
                // Measured just before deleting: something else is put in its place then.
                fileSystem.itemSizeImpl = { target in
                    let size = try NativeItemSize.of(target)
                    if target == path, swapWhenMeasured.take() {
                        try UndoDisk.move(path, "\(root)/moved.txt")
                        try UndoDisk.write(path, "never asked about")
                    }
                    return size
                }
            }
            _ = try await end(coordinator.trash(paths: [path], window: window), window)
            swapWhenMeasured.set(true)
            let terminal = try await end(coordinator.deleteImmediately(paths: [path], window: window), window)
            #expect(terminal.result?.items.first?.status == .failed)
            #expect(
                terminal.result?.items.first?.error
                    == "“share.txt” changed after you were asked about it, so it wasn't deleted.")
            #expect(try UndoDisk.read(path) == "never asked about")
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func leavesTheHistoryAsItWasWhenTheItemAskedAboutIsGone() async throws {
        // Gone already (moved away while the question was open): nothing is deleted, so what can be undone stays
        // undoable.
        try await withUndoFolder { root, trashDir in
            let path = "\(root)/share.txt"
            try UndoDisk.write(path, "asked about")
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.trashImpl = { _ in throw codedError(.noTrash, "no Trash") }
            }
            _ = try await end(coordinator.trash(paths: [path], window: window), window)
            try UndoDisk.move(path, "\(root)/moved.txt")
            let terminal = try await end(coordinator.deleteImmediately(paths: [path], window: window), window)
            #expect(terminal.status == .completed)
            #expect(try UndoDisk.read("\(root)/moved.txt") == "asked about")
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func leavesTheHistoryAsItWasWhenAFileCouldntBeDeletedAtAll() async throws {
        // A file the delete couldn't remove is still there, as it was: nothing went for good.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(trashDir)/a.txt", "a")
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.rmImpl = { _, _, _ in throw codedError(.errno(EACCES), "EACCES: permission denied") }
            }
            let ended = try await end(
                coordinator.deleteImmediately(paths: ["\(trashDir)/a.txt"], window: window), window)
            #expect(ended.status == .failed)
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func cantUndoAFolderWhoseDeleteFailedPartWay() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.mkdir("\(trashDir)/F")
            let (coordinator, finished, window) = setUp(root, trashDir) { fileSystem in
                fileSystem.rmImpl = { _, _, _ in throw codedError(.errno(EACCES), "EACCES: permission denied") }
            }
            _ = try await end(coordinator.deleteImmediately(paths: ["\(trashDir)/F"], window: window), window)
            #expect(finished.logs == [.notUndoable(reason: .deletedForGood)])
            await coordinator.shutDown()
        }
    }

    @Test func cantUndoEmptyTrashEvenOneThatFailedPartWay() async throws {
        try await withUndoFolder { root, trashDir in
            let (coordinator, finished, _) = setUp(root, trashDir)
            _ = await coordinator.emptyTrash { (false, "Finder stopped.") }
            #expect(
                finished.all
                    == [FinishedWrite(action: .emptyTrash, log: .notUndoable(reason: .deletedForGood), items: [])])
            await coordinator.shutDown()
        }
    }

    @Test(arguments: [
        "Not authorized to send Apple events to Finder. (-1743)",
        "execution error: Finder got an error: Not permitted. (-1744)",
        "execution error: Finder got an error: Application isn't running. (-600)",
    ])
    func keepsTheHistoryWhenFinderRefusedBeforeItBegan(error: String) async throws {
        try await withUndoFolder { root, trashDir in
            let (coordinator, finished, _) = setUp(root, trashDir)
            _ = await coordinator.emptyTrash { (false, error) }
            #expect(finished.all.isEmpty)
            await coordinator.shutDown()
        }
    }

    @Test func recordsAnOperationBeforeTheNextOneCanStart() async throws {
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            final class Box {
                weak var coordinator: WriteCoordinator?
                var finished: [FinishedWrite] = []
                var slotFreeWhenRecorded: Bool?
            }
            let box = Box()
            let coordinator = WriteCoordinator(
                writeService: StubWriteService(), fileSystem: UndoTestFileSystem(trashDir: trashDir),
                options: WriteCoordinatorOptions(
                    homePath: root,
                    recordUndo: { entry in
                        box.finished.append(entry)
                        box.slotFreeWhenRecorded = box.coordinator?.activeOperation == nil
                    }))
            box.coordinator = coordinator
            let window = TestWindow()
            _ = try await end(
                coordinator.rename(sourcePath: "\(root)/a.txt", destinationName: "b.txt", window: window), window)
            #expect(box.finished.count == 1)
            #expect(box.slotFreeWhenRecorded == false)
            await coordinator.shutDown()
        }
    }

    // MARK: What a paste records

    private static let copied = UndoLog.undoable(units: [
        UndoUnit(steps: [.created(path: "/Volumes/Share/a.txt", id: ItemId(dev: 9, ino: 1), stamp: nil)])
    ])

    /// A Copy To that ends with `undoLog`, through a write service whose events the test sends.
    private func paste(_ undoLog: UndoLog?, diskHasTrash: @escaping @Sendable (String) throws -> Bool = { _ in true })
        async throws -> [FinishedWrite]
    {
        var all: [FinishedWrite] = []
        try await withUndoFolder { root, trashDir in
            let service = StubWriteService()
            let (coordinator, finished, window) = setUp(
                root, trashDir, writeService: service, diskHasTrash: diskHasTrash)
            let report = try await Coordinators.analyze(coordinator, window, destination: "/Volumes/Share")
            try coordinator.startCopyPaste(
                CopyPasteStart(report: report, action: .copyTo, policy: Coordinators.skipMerge), window: window)
            service.emit(
                Coordinators.event(
                    .completed, completedItemCount: 1,
                    items: [
                        CopyPasteItemResult(
                            sourcePath: "/Users/demo/a.txt", destinationPath: "/Volumes/Share/a.txt",
                            sourceKind: .file, status: .completed, error: nil)
                    ], destination: "/Volumes/Share", undoLog: undoLog))
            await coordinator.shutDown()
            all = finished.all
        }
        return all
    }

    @Test func passesOnThePastesOwnLogWithTheActionThatStartedIt() async throws {
        let finished = try await paste(Self.copied)
        #expect(finished.count == 1)
        #expect(finished.first?.action == .write(.copyTo))
        #expect(finished.first?.log == Self.copied)
        #expect(finished.first?.items.map(\.destinationPath) == ["/Volumes/Share/a.txt"])
    }

    @Test func cantUndoCopiesMadeOnADiskWithoutATrash() async throws {
        let asked = AskedPaths()
        let finished = try await paste(Self.copied) { path in
            asked.add(path)
            return false
        }
        #expect(finished.map(\.log) == [.notUndoable(reason: .noTrash)])
        #expect(asked.paths == ["/Volumes/Share"])
    }

    @Test func asksWhetherADiskHasATrashOncePerFolderTheCopiesAreIn() async throws {
        // Each answer reads the mount table.
        func created(_ path: String, _ ino: UInt64) -> UndoUnit {
            UndoUnit(steps: [.created(path: path, id: ItemId(dev: 9, ino: ino), stamp: nil)])
        }
        let log = UndoLog.undoable(units: [
            created("/Volumes/Share/a.txt", 1), created("/Volumes/Share/b.txt", 2), created("/Volumes/Share/c.txt", 3),
            created("/Volumes/Other/d.txt", 4),
        ])
        let asked = AskedPaths()
        let finished = try await paste(log) { path in
            asked.add(path)
            return true
        }
        #expect(finished.map(\.log) == [log])
        #expect(asked.paths == ["/Volumes/Share", "/Volumes/Other"])
    }

    @Test func passesOnAPasteThatCantBeUndone() async throws {
        #expect(try await paste(.notUndoable(reason: .merge)).map(\.log) == [.notUndoable(reason: .merge)])
    }

    @Test func recordsNothingForAPasteThatDidNothing() async throws {
        #expect(try await paste(.undoable(units: [])).isEmpty)
        #expect(try await paste(nil).isEmpty)
    }

    @Test func leavesTheHistoryAsItWasAfterAPasteThatChangedNothing() async throws {
        // Add Missing where every item is there already: nothing is written, so what came before can still be undone.
        try await withUndoFolder { root, trashDir in
            try UndoDisk.write("\(root)/a.txt", "a")
            try UndoDisk.mkdir("\(root)/src/Folder")
            try UndoDisk.write("\(root)/src/Folder/x.txt", "new")
            try UndoDisk.mkdir("\(root)/dst/Folder")
            try UndoDisk.write("\(root)/dst/Folder/x.txt", "old")
            let history = UndoHistory()
            let fileSystem = UndoTestFileSystem(trashDir: trashDir)
            let coordinator = WriteCoordinator(
                writeService: WriteService(WriteServiceDependencies(fileSystem: NativeWriteFileSystem())),
                fileSystem: fileSystem,
                options: WriteCoordinatorOptions(
                    homePath: root, recordUndo: { history.record($0) }, undoHistory: history))
            let window = TestWindow()
            _ = try await end(
                coordinator.rename(sourcePath: "\(root)/a.txt", destinationName: "b.txt", window: window), window)
            let generation = history.generation
            let report = try await coordinator.analyze(
                CopyPasteAnalysisRequest(
                    mode: .copy, sourcePaths: ["\(root)/src/Folder"], destinationDirectoryPath: "\(root)/dst"),
                window: window, signal: StopSignal())
            let handle = try coordinator.startCopyPaste(
                CopyPasteStart(report: report, action: .paste, policy: Coordinators.skipMerge), window: window)
            #expect(try await Coordinators.end(of: handle.operationId, in: window).status == .partial)
            #expect(history.generation == generation)
            #expect(history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
            await coordinator.shutDown()
        }
    }
}

/// Paths a disk thread was asked about, in order.
final class AskedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ path: String) {
        lock.withLock { list.append(path) }
    }

    var paths: [String] { lock.withLock { list } }
}
