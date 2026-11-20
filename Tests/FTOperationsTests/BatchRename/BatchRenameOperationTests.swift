import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

// Renaming several items through the write coordinator: what it checks before starting, what it reports, and what
// happens on a real disk.

private let nobodyHome = "/Users/nobody-batch-rename"

/// Holds the disk threads that wait on it until it is opened; it stays open.
private final class RenameGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var waitingCount = 0

    func wait() {
        condition.lock()
        waitingCount += 1
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    var someoneWaits: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waitingCount > 0
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private func request(
    _ root: String, _ pairs: [(String, String)], onConflict: BatchRenameOnConflict = .number,
    numberSeparator: String = " "
) -> BatchRenameRequest {
    BatchRenameRequest(
        items: pairs.map { .init(sourcePath: "\(root)/\($0.0)", destinationName: $0.1, isFolder: false) },
        onConflict: onConflict, numberSeparator: numberSeparator)
}

/// A request for files at these paths, each with its new name.
private func paths(_ pairs: [(String, String)]) -> BatchRenameRequest {
    BatchRenameRequest(items: pairs.map { .init(sourcePath: $0.0, destinationName: $0.1, isFolder: false) })
}

private let severalDisks = "These items are on more than one disk. Rename them one disk at a time."

/// The disk itself, except that the folder `other` is said to be on another disk than it is.
private func realDisk(sayingIsOnAnotherDisk other: String) -> TestLocalFileSystem {
    let disk = NativeWriteFileSystem()
    return TestLocalFileSystem(
        lstat: { try disk.lstat($0) },
        stat: { path in
            var stats = try disk.stat(path)
            if path == other { stats.dev = (stats.dev ?? 0) + 1 }
            return stats
        }, mkdir: { try disk.mkdir($0) }, rename: { try disk.rename($0, $1) },
        renameExclusive: { try disk.renameExclusive($0, $1) }, rm: { try disk.rm($0, recursive: $1, force: $2) },
        trash: { inTrash($0) }, readdir: { try disk.readdir($0) }, realpath: { try disk.realpath($0) },
        getFlags: { try disk.getFlags($0) })
}

private func write(_ path: String, _ text: String) throws {
    try text.write(toFile: path, atomically: false, encoding: .utf8)
}

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func makeFolder(_ root: TemporaryDirectory, _ files: [(String, String)]) throws -> String {
    for (name, contents) in files {
        try write(root.appending(name).path, contents)
    }
    return root.path
}

private func names(_ folder: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder).sorted(by: utf16Less)
}

private func visibleNames(_ folder: String) throws -> [String] {
    try names(folder).filter { !$0.hasPrefix(".") }
}

/// Whether the temporary folders' disk ignores case, as a Mac's startup disk does unless set up otherwise.
private let tmpIgnoresCase: Bool = {
    guard let folder = try? TemporaryDirectory(prefix: "filetrail-case") else { return true }
    defer { folder.remove() }
    try? write(folder.appending("a").path, "")
    return FileManager.default.fileExists(atPath: folder.appending("A").path)
}()

@MainActor
private func rename(
    _ root: String, _ pairs: [(String, String)], onConflict: BatchRenameOnConflict = .number,
    fileSystem: TestLocalFileSystem = .real()
) async throws -> (end: WriteOperationEvent, window: TestWindow) {
    let coordinator = WriteCoordinator.local(fileSystem, homePath: nobodyHome)
    let window = TestWindow()
    let handle = try await coordinator.batchRename(request(root, pairs, onConflict: onConflict), window: window)
    let end = try await Coordinators.end(of: handle.operationId, in: window)
    await coordinator.shutDown(maxWaitMs: 0)
    return (end, window)
}

@MainActor
@Suite struct BatchRenameOperationTests {
    @Test func renamesThemReportingEachAndWhereItWent() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("IMG_1.jpg", "one"), ("IMG_2.jpg", "two"), ("notes.txt", "n")])
            let (end, window) = try await rename(root, [("IMG_1.jpg", "Lisbon 1.jpg"), ("IMG_2.jpg", "Lisbon 2.jpg")])
            #expect(try visibleNames(root) == ["Lisbon 1.jpg", "Lisbon 2.jpg", "notes.txt"])
            #expect(try read("\(root)/Lisbon 2.jpg") == "two")
            #expect(end.action == .batchRename)
            #expect(end.status == .completed)
            #expect(end.completedItemCount == 2)
            #expect(end.totalItemCount == 2)
            #expect(end.result?.action == .batchRename)
            #expect(end.result?.targetPath == root)
            #expect(end.result?.error == nil)
            #expect(end.result?.summary.completedItemCount == 2)
            #expect(end.result?.summary.failedItemCount == 0)
            #expect(end.result?.summary.topLevelItemCount == 2)
            #expect(end.result?.items.map(\.destinationPath) == ["\(root)/Lisbon 1.jpg", "\(root)/Lisbon 2.jpg"])
            // Queued at once; the progress in between is sent at most every 100 ms, so a quick rename may finish
            // before any is.
            #expect(window.progress.first?.status == .queued)
            #expect(window.progress.first?.action == .batchRename)
        }
    }

    @Test func swapsNamesAndPassesThemAroundACycleKeepingEachFilesContents() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a", "A"), ("b", "B"), ("c", "C")])
            let (end, _) = try await rename(root, [("a", "b"), ("b", "c"), ("c", "a")])
            #expect(end.status == .completed)
            #expect(try names(root) == ["a", "b", "c"])
            #expect(try ["a", "b", "c"].map { try read("\(root)/\($0)") } == ["C", "A", "B"])
        }
    }

    @Test func renamesAFolderAndItemsInsideItTogetherAsSearchResultsCanAsk() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = directory.path
            try FileManager.default.createDirectory(atPath: "\(root)/day/inner", withIntermediateDirectories: true)
            try write("\(root)/day/x.jpg", "X")
            try write("\(root)/day/inner/z.jpg", "Z")
            let (end, _) = try await rename(
                root, [("day", "Lisbon"), ("day/x.jpg", "Lisbon 1.jpg"), ("day/inner/z.jpg", "Lisbon 2.jpg")])
            #expect(end.status == .completed)
            #expect(try visibleNames(root) == ["Lisbon"])
            #expect(try read("\(root)/Lisbon/Lisbon 1.jpg") == "X")
            #expect(try read("\(root)/Lisbon/inner/Lisbon 2.jpg") == "Z")
            #expect(
                end.result?.items.map(\.destinationPath) == [
                    "\(root)/Lisbon", "\(root)/Lisbon/Lisbon 1.jpg", "\(root)/Lisbon/inner/Lisbon 2.jpg",
                ])
        }
    }

    // Items found by a search are in several folders; on one disk they are renamed together.
    @Test func renamesItemsInSeveralFoldersOfOneDisk() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = directory.path
            for folder in ["one", "two", "two/deep"] {
                try FileManager.default.createDirectory(atPath: "\(root)/\(folder)", withIntermediateDirectories: true)
                try write("\(root)/\(folder)/a.jpg", folder)
                try write("\(root)/\(folder)/b.jpg", "b")
            }
            // Two of them swap names, which moves one aside.
            let (end, _) = try await rename(
                root,
                [
                    ("one/a.jpg", "b.jpg"), ("one/b.jpg", "a.jpg"), ("two/a.jpg", "Lisbon 2.jpg"),
                    ("two/deep/a.jpg", "Lisbon 3.jpg"),
                ])
            #expect(end.status == .completed)
            #expect(end.completedItemCount == 4)
            #expect(end.result?.targetPath == nil)
            #expect(try read("\(root)/one/b.jpg") == "one")
            #expect(try names("\(root)/one") == ["a.jpg", "b.jpg"])
            #expect(try read("\(root)/two/Lisbon 2.jpg") == "two")
            #expect(try read("\(root)/two/deep/Lisbon 3.jpg") == "two/deep")
        }
    }

    // On a disk that minds case, "Notes.txt" is simply another name: a test below covers it.
    @Test(.enabled(if: tmpIgnoresCase))
    func changesOnlyTheCaseOfNamesAndHowAnAccentedLetterIsWritten() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let decomposed = "cafe\u{301}.txt"
            let composed = "caf\u{E9}.txt"
            let root = try makeFolder(directory, [("notes.txt", "n"), (decomposed, "c")])
            let (end, _) = try await rename(root, [("notes.txt", "Notes.txt"), (decomposed, composed)])
            #expect(end.status == .completed)
            // Spelled exactly as asked: APFS keeps the form a name is written in.
            #expect(
                try names(root).map { Array($0.unicodeScalars) } == [
                    Array("Notes.txt".unicodeScalars), Array(composed.unicodeScalars),
                ])
            #expect(try read("\(root)/\(composed)") == "c")
        }
    }

    @Test func finishesASwapUnderWayWhenTheAppQuitsLeavingNothingUnderAHiddenName() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a", "A"), ("b", "B")])
            let gate = RenameGate()
            let fileSystem = TestLocalFileSystem.real()
            let disk = NativeWriteFileSystem()
            let heldOnce = RenameOnceFlag()
            // The first rename to a new name waits, with both items under hidden names.
            fileSystem.renameExclusiveImpl = { from, to in
                if !to.contains(".filetrail-rename-") && heldOnce.setOnce() {
                    gate.wait()
                }
                try disk.renameExclusive(from, to)
            }
            let coordinator = WriteCoordinator.local(fileSystem, homePath: nobodyHome)
            let window = TestWindow()
            let handle = try await coordinator.batchRename(request(root, [("a", "b"), ("b", "a")]), window: window)
            _ = try await Coordinators.waitFor { gate.someoneWaits ? true : nil }
            let quitting = Task { await coordinator.shutDown() }
            gate.open()
            await quitting.value
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.result?.items.map(\.status) == [.completed, .completed])
            #expect(try names(root) == ["a", "b"])
            #expect(try read("\(root)/a") == "B")
        }
    }

    @Test func handlesANameTakenSinceTheSheetCheckedItAsTheSettingSays() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let numbered = directory.appending("numbered").path
            let skipped = directory.appending("skipped").path
            let held = directory.appending("held").path
            for folder in [numbered, skipped, held] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
                try write("\(folder)/a.txt", "a")
                try write("\(folder)/taken.txt", "t")
            }
            let first = try await rename(numbered, [("a.txt", "taken.txt")])
            #expect(first.end.result?.items.first?.destinationPath == "\(numbered)/taken 2.txt")
            #expect(try read("\(numbered)/taken.txt") == "t")

            let second = try await rename(skipped, [("a.txt", "taken.txt")], onConflict: .skip)
            #expect(second.end.result?.items.first?.status == .skipped)
            #expect(try visibleNames(skipped) == ["a.txt", "taken.txt"])

            let third = try await rename(held, [("a.txt", "taken.txt")], onConflict: .block)
            #expect(third.end.status == .failed)
            #expect(third.end.result?.error == "An item named “taken.txt” already exists.")
        }
    }

    @Test func goesOnPastALockedItemAndSaysItIsLocked() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("locked.txt", "l"), ("free.txt", "f")])
            #expect(chflags("\(root)/locked.txt", UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags("\(root)/locked.txt", 0) }
            let (end, _) = try await rename(root, [("locked.txt", "a.txt"), ("free.txt", "b.txt")])
            #expect(end.status == .partial)
            #expect(end.result?.items.map(\.status) == [.failed, .completed])
            #expect(
                end.result?.items.first?.error
                    == "“locked.txt” is locked. Unlock it in Finder's Get Info and try again.")
            #expect(try visibleNames(root) == ["b.txt", "locked.txt"])
        }
    }

    @Test func failsWhatCantBeRenamedInAFolderThatCantBeWrittenTo() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let folder = directory.appending("read-only").path
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try write("\(folder)/a.txt", "a")
            #expect(chmod(folder, 0o555) == 0)
            defer { chmod(folder, 0o755) }
            let (end, _) = try await rename(folder, [("a.txt", "b.txt")])
            #expect(end.status == .failed)
            #expect(end.result?.items.first?.error == "You don't have permission to access this item.")
            #expect(try names(folder) == ["a.txt"])
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func swapsTwoItemsWhoseNamesDifferOnlyInCaseOnADiskThatMindsCase() async throws {
        try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
            let root = volume.path
            try write("\(root)/a", "lower")
            try write("\(root)/A", "upper")
            let (end, _) = try await rename(root, [("a", "A"), ("A", "a")])
            #expect(end.status == .completed)
            #expect(try read("\(root)/A") == "lower")
            #expect(try read("\(root)/a") == "upper")
            #expect(try visibleNames(root) == ["A", "a"])
        }
    }

    @Test(.tags(.diskImage), .diskImages)
    func numbersANameAnotherLinkToTheSameFileHasOnADiskThatMindsCase() async throws {
        try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
            let root = volume.path
            try write("\(root)/h", "one file")
            #expect(link("\(root)/h", "\(root)/H") == 0)
            let (end, _) = try await rename(root, [("h", "H")])
            #expect(end.status == .completed)
            // "H" is the same file under another name, not "h" itself: it is kept.
            #expect(try visibleNames(root) == ["H", "H 2"])
        }
    }

    @Test(.tags(.diskImage), .diskImages, arguments: [DiskImage.Kind.fat32, .exfat])
    func swapsChainsAndChangesCase(on kind: DiskImage.Kind) async throws {
        try await DiskImage.withSharedVolume(kind) { volume in
            let root = volume.path
            for (name, contents) in [
                ("a.txt", "A"), ("b.txt", "B"), ("notes.txt", "N"), ("1.txt", "1"), ("2.txt", "2"),
            ] {
                try write("\(root)/\(name)", contents)
            }
            let (end, _) = try await rename(
                root,
                [
                    ("a.txt", "b.txt"), ("b.txt", "a.txt"), ("notes.txt", "Notes.txt"), ("1.txt", "2.txt"),
                    ("2.txt", "3.txt"),
                ]
            )
            #expect(end.status == .completed)
            #expect(try read("\(root)/a.txt") == "B")
            #expect(try read("\(root)/b.txt") == "A")
            #expect(try read("\(root)/3.txt") == "2")
            #expect(try visibleNames(root) == ["2.txt", "3.txt", "Notes.txt", "a.txt", "b.txt"])
            #expect(try !names(root).contains { $0.contains("filetrail") })
        }
    }
}

@MainActor
@Suite struct BatchRenameChecksTests {
    private func refusal(_ payload: BatchRenameRequest, home: String = nobodyHome) async -> String {
        let coordinator = WriteCoordinator.local(.real(), homePath: home)
        defer { Task { await coordinator.shutDown(maxWaitMs: 0) } }
        do {
            try await coordinator.batchRename(payload, window: TestWindow())
            return "started"
        } catch {
            return errorMessage(error)
        }
    }

    @Test func leavesOutItemsThatWouldKeepTheirNameAndRefusesWhenNoneIsLeft() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a")])
            #expect(await refusal(request(root, [("a.txt", "a.txt")])) == "Nothing would be renamed.")
        }
    }

    @Test func refusesAnItemListedTwice() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a")])
            #expect(
                await refusal(request(root, [("a.txt", "b.txt"), ("a.txt", "c.txt")]))
                    == "“a.txt” is in the list twice.")
        }
    }

    @Test func refusesTheTrashTheStartupDisksFoldersAndTheHomeFolder() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-home") { directory in
            let home = directory.path
            try FileManager.default.createDirectory(atPath: "\(home)/.Trash", withIntermediateDirectories: false)
            try FileManager.default.createDirectory(atPath: "\(home)/Documents", withIntermediateDirectories: false)
            let one = { (path: String, name: String) in
                BatchRenameRequest(items: [.init(sourcePath: path, destinationName: name, isFolder: true)])
            }
            #expect(
                await refusal(one("\(home)/.Trash", "x"), home: home)
                    == "The Trash folder is a protected system directory and cannot be modified.")
            #expect(await refusal(one("\(home)/Documents", "x"), home: home) == "“Documents” can't be renamed.")
            #expect(await refusal(one("/Applications", "Apps")) == "“Applications” can't be renamed.")
        }
    }

    // A rename of several is of one disk. One over two is refused before anything is moved aside, written down for
    // recovery or kept for Undo.
    @Test func refusesItemsOnMoreThanOneDiskBeforeAnythingIsRenamedOrWrittenDown() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let here = directory.appending("here").path
            let there = directory.appending("there").path
            for folder in [here, there] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
                try write("\(folder)/a.txt", "a")
                try write("\(folder)/b.txt", "b")
            }
            let fileSystem = realDisk(sayingIsOnAnotherDisk: there)
            let journal = RenameJournal()
            var finished: [FinishedWrite] = []
            var options = WriteCoordinatorOptions()
            options.writeJournal = journal
            options.recordUndo = { finished.append($0) }
            let coordinator = WriteCoordinator.local(fileSystem, homePath: nobodyHome, options: options)
            let window = TestWindow()
            // The two of "here" swap names: started, that alone moves one aside and writes it down.
            let swap = [("\(here)/a.txt", "b.txt"), ("\(here)/b.txt", "a.txt")]
            do {
                let handle = try await coordinator.batchRename(
                    paths(swap + [("\(there)/a.txt", "c.txt")]), window: window)
                _ = try await Coordinators.end(of: handle.operationId, in: window)
                Issue.record("a rename over two disks started")
            } catch {
                #expect(errorMessage(error) == severalDisks)
            }
            #expect(coordinator.activeOperation == nil)
            #expect(fileSystem.calls.renameExclusive.isEmpty)
            #expect(fileSystem.calls.rename.isEmpty)
            #expect(journal.added.isEmpty)
            #expect(finished.isEmpty)
            #expect(window.progress.isEmpty)
            #expect(try names(here) == ["a.txt", "b.txt"])
            #expect(try read("\(here)/a.txt") == "a")
            #expect(try names(there) == ["a.txt", "b.txt"])

            // Each disk's items on their own are renamed, the write slot free again.
            let handle = try await coordinator.batchRename(paths(swap), window: window)
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.status == .completed)
            #expect(try read("\(here)/a.txt") == "b")
            #expect(finished.count == 1)
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // An item whose folder is gone has its own failure. Its disk can't be read, which refuses nothing.
    @Test func leavesAnItemWhoseFolderCantBeReadToFailOnItsOwn() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a")])
            let coordinator = WriteCoordinator.local(.real(), homePath: nobodyHome)
            let window = TestWindow()
            let handle = try await coordinator.batchRename(
                request(root, [("a.txt", "b.txt"), ("gone/x.txt", "y.txt")]), window: window)
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.result?.items.map(\.status) == [.completed, .failed])
            #expect(end.result?.items.last?.error == "“x.txt” no longer exists.")
            #expect(try visibleNames(root) == ["b.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // On two real disks. An item is on the disk its folder is on: one in a folder reached through a link is on the
    // disk the link leads to, and a link among the items is on the disk of the folder it is in.
    @Test(.tags(.diskImage), .diskImages)
    func refusesItemsOnTwoRealDisksJudgingEachByTheFolderItIsIn() async throws {
        try await DiskImage.withSharedVolume(.apfsCaseSensitive) { volume in
            try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
                let here = directory.path
                let there = volume.path
                try write("\(here)/a.txt", "a")
                try write("\(there)/b.txt", "b")
                try write("\(there)/c.txt", "c")
                #expect(symlink(there, "\(here)/link") == 0)
                #expect(
                    await refusal(paths([("\(here)/a.txt", "x.txt"), ("\(there)/b.txt", "y.txt")])) == severalDisks)
                #expect(
                    await refusal(paths([("\(here)/a.txt", "x.txt"), ("\(here)/link/b.txt", "y.txt")]))
                        == severalDisks)
                #expect(try visibleNames(here) == ["a.txt", "link"])
                #expect(try visibleNames(there) == ["b.txt", "c.txt"])

                let coordinator = WriteCoordinator.local(.real(), homePath: nobodyHome)
                let window = TestWindow()
                let throughLink = try await coordinator.batchRename(
                    paths([("\(here)/link/b.txt", "y.txt"), ("\(there)/c.txt", "z.txt")]), window: window)
                #expect(try await Coordinators.end(of: throughLink.operationId, in: window).status == .completed)
                #expect(try visibleNames(there) == ["y.txt", "z.txt"])
                let linkItself = try await coordinator.batchRename(
                    paths([("\(here)/a.txt", "x.txt"), ("\(here)/link", "link 2")]), window: window)
                #expect(try await Coordinators.end(of: linkItself.operationId, in: window).status == .completed)
                #expect(try visibleNames(here) == ["link 2", "x.txt"])
                await coordinator.shutDown(maxWaitMs: 0)
            }
        }
    }

    @Test func waitsForNoOtherWriteAndReportsTheKindOfChangeWhileItRuns() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a")])
            let gate = RenameGate()
            let fileSystem = TestLocalFileSystem.real()
            let disk = NativeWriteFileSystem()
            fileSystem.renameExclusiveImpl = { from, to in
                gate.wait()
                try disk.renameExclusive(from, to)
            }
            let coordinator = WriteCoordinator.local(fileSystem, homePath: nobodyHome)
            let window = TestWindow()
            defer { gate.open() }
            let handle = try await coordinator.batchRename(request(root, [("a.txt", "b.txt")]), window: window)
            // Its own kind, so quitting asks before stopping it.
            #expect(coordinator.activeOperation?.kind == .batchRename)
            await #expect(throws: (any Error).self) {
                try await coordinator.batchRename(request(root, [("a.txt", "c.txt")]), window: window)
            }
            do {
                try await coordinator.batchRename(request(root, [("a.txt", "c.txt")]), window: window)
            } catch {
                #expect(errorMessage(error) == "Another write operation is already running.")
            }
            gate.open()
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.status == .completed)
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test func stillEndsFailingEveryItemWhenSomethingUnexpectedGoesWrong() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("notes.txt", "n")])
            let coordinator = WriteCoordinator.local(.real(), homePath: nobodyHome)
            coordinator.batchRenameRunner = { _, _, _, _, _ in throw OperationError("Disk gone.") }
            let window = TestWindow()
            let handle = try await coordinator.batchRename(request(root, [("notes.txt", "Notes.txt")]), window: window)
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.status == .failed)
            #expect(end.result?.items.first?.status == .failed)
            #expect(end.result?.items.first?.error == "The rename stopped unexpectedly: Disk gone.")
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    @Test func stopsWhenAskedLeavingTheRestAsTheyWere() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a"), ("b.txt", "b"), ("c.txt", "c")])
            let gate = RenameGate()
            let fileSystem = TestLocalFileSystem.real()
            let disk = NativeWriteFileSystem()
            fileSystem.renameExclusiveImpl = { from, to in
                gate.wait()
                try disk.renameExclusive(from, to)
            }
            let coordinator = WriteCoordinator.local(fileSystem, homePath: nobodyHome)
            let window = TestWindow()
            defer { gate.open() }
            let handle = try await coordinator.batchRename(
                request(root, [("a.txt", "x.txt"), ("b.txt", "y.txt"), ("c.txt", "z.txt")]), window: window)
            // Stopped while the first item is being renamed (its rename starts at once).
            _ = try await Coordinators.waitFor { gate.someoneWaits ? true : nil }
            #expect(coordinator.cancel(handle.operationId, window: window))
            gate.open()
            let end = try await Coordinators.end(of: handle.operationId, in: window)
            #expect(end.status == .partial)
            #expect(end.result?.error == "Stopped after 1 item was renamed.")
            #expect(try visibleNames(root) == ["b.txt", "c.txt", "x.txt"])
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }

    // The undo record has the final names: a taken name numbered is undone from where it went.
    @Test func recordsWhereEachItemWentForUndo() async throws {
        try await withTemporaryDirectory(prefix: "filetrail-batch-rename") { directory in
            let root = try makeFolder(directory, [("a.txt", "a"), ("b.txt", "b"), ("taken.txt", "t")])
            var finished: [FinishedWrite] = []
            var options = WriteCoordinatorOptions()
            options.recordUndo = { finished.append($0) }
            let coordinator = WriteCoordinator.local(.real(), homePath: nobodyHome, options: options)
            let window = TestWindow()
            let handle = try await coordinator.batchRename(
                request(root, [("a.txt", "taken.txt"), ("b.txt", "b.txt")]), window: window)
            _ = try await Coordinators.end(of: handle.operationId, in: window)
            guard case .undoable(let units) = finished.first?.log,
                case .batchRenamed(let items) = units.first?.steps.first
            else {
                Issue.record("no batch rename recorded for Undo")
                return
            }
            #expect(items.map(\.from) == ["\(root)/a.txt"])
            #expect(items.map(\.to) == ["\(root)/taken 2.txt"])
            #expect(items.first?.itemKind == .file)
            await coordinator.shutDown(maxWaitMs: 0)
        }
    }
}

/// A flag set once, from any thread.
private final class RenameOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// True the first time only.
    func setOnce() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }
}
