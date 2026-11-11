// Races and failures in the middle of a paste that the plain paths don't reach (items appearing or changing while they
// are written, stops part way, and a Replace whose last step fails), on the mock disk, where each can be made to happen
// at an exact step
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// The Replace entries a paste writes down, by id, as the journal holds them now.
/// `refuseAdd` makes a write fail (before it is kept); `onAdd` is told of each Replace entry kept.
final class ReplaceEntriesJournal: WriteJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ReplaceJournalEntry] = [:]
    private var order: [String] = []
    var refuseAdd: (() -> (any Error)?)?
    var onAdd: ((ReplaceJournalEntry) -> Void)?

    func add(_ entry: WriteJournalEntry) throws {
        if let error = refuseAdd?() {
            throw error
        }
        guard case .replace(let replace) = entry else { return }
        lock.lock()
        if entries[replace.id] == nil {
            order.append(replace.id)
        }
        entries[replace.id] = replace
        lock.unlock()
        onAdd?(replace)
    }

    func remove(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    var live: [ReplaceJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { entries[$0] }
    }
}

/// A paste on the mock disk as the edge-case tests run one: questions answered by `resolve` ("skip" without it).
func edgePaste(
    _ fileSystem: any WriteServiceFileSystem, mode: CopyPasteMode = .copy, sources: [String],
    into destination: String = "/target", policy: CopyPastePolicy = NativePaste.keepExisting,
    signal: StopSignal = StopSignal(), writeJournal: (any WriteJournal)? = nil, beforeExecute: (() -> Void)? = nil,
    resolve: (@Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?)? = nil
) async throws -> (result: CopyPasteOperationResult, conflicts: [CopyPasteRuntimeConflict]) {
    let report = try buildCopyPasteAnalysisReport(
        analysisId: "analysis-edge",
        request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
        fileSystem: fileSystem,
        thresholds: CopyPasteThresholds(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
    let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem)
    beforeExecute?()
    let recorder = PasteRecorder()
    await executeCopyPasteFromAnalysis(
        CopyPasteRun(
            operationId: "op-edge", report: report, mode: mode, policy: policy, fileSystem: fileSystem,
            now: { Date(timeIntervalSince1970: 1_759_449_600) }, signal: signal, resolvedNodes: resolvedNodes,
            emit: { recorder.record($0) },
            requestResolution: { conflict in
                recorder.asked(conflict)
                return .immediate(resolve?(conflict) ?? .skip)
            }, writeJournal: writeJournal))
    let result = try #require(recorder.result, "The paste reported no result.")
    return (result, recorder.conflicts)
}

func itemFor(_ result: CopyPasteOperationResult, _ sourcePath: String) -> CopyPasteItemResult? {
    result.items.first { $0.sourcePath == sourcePath }
}

struct EdgeCasesTests {
    // MARK: Items that keep changing while they are pasted

    @Test func leavesAnItemThatChangesAfterEveryAnswerInsteadOfAskingForever() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/a.txt", .file(size: 1)), ("/target", .directory())])

        let (result, conflicts) = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"],
            beforeExecute: { fileSystem.mutateNode("/source/a.txt") { _ in } },
            resolve: { _ in
                // Changed again before the answer is used.
                fileSystem.mutateNode("/source/a.txt") { _ in }
                return .overwrite
            })

        #expect(conflicts.count == 5)
        #expect(itemFor(result, "/source/a.txt")?.status == .failed)
        #expect(itemFor(result, "/source/a.txt")?.error == "\u{201C}a.txt\u{201D} kept changing, so it was left.")
        #expect(!fileSystem.exists("/target/a.txt"))
    }

    @Test func givesUpOnANameThatIsTakenEveryTimeItIsWritten() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/a.txt", .file(size: 1)), ("/target", .directory())])
        fileSystem.copyFileImpl = { _, _, _, _ in throw codedError(.errno(EEXIST)) }

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/a.txt"])

        #expect(itemFor(result, "/source/a.txt")?.status == .failed)
        #expect(itemFor(result, "/source/a.txt")?.error == "An item with this name already exists.")
    }

    @Test func asksAboutAFolderThatTookItsNameWhileItWasBeingCopied() async throws {
        let fileSystem = MockWriteServiceFileSystem([("/source/Docs/a.txt", .file(size: 1)), ("/target", .directory())])
        fileSystem.copyFileImpl = { source, destination, stop, _ in
            fileSystem.copyFileImpl = nil
            // Another app makes a folder at the name while the copy is built under a hidden one.
            fileSystem.addDirectory("/target/Docs")
            try fileSystem.copyDirectly(source, destination, stop: stop)
        }

        let (result, conflicts) = try await edgePaste(
            fileSystem, sources: ["/source/Docs"], resolve: { _ in .skip })

        #expect(conflicts.map(\.reason) == [.destinationCreated])
        #expect(itemFor(result, "/source/Docs")?.status == .skipped)
        #expect(!fileSystem.exists("/target/Docs/a.txt"))
    }

    @Test func asksAboutAnItemThatAppearedWhereASymlinkWasBeingMade() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/link", .symlink("/elsewhere")), ("/target", .directory()),
        ])
        fileSystem.copyFileImpl = { _, path, _, _ in
            fileSystem.copyFileImpl = nil
            fileSystem.addFile(path, .file(size: 3))
            throw codedError(.errno(EEXIST))
        }

        let (result, conflicts) = try await edgePaste(
            fileSystem, sources: ["/source/link"], resolve: { _ in .keepBoth })

        #expect(conflicts.map(\.reason) == [.destinationCreated])
        #expect(itemFor(result, "/source/link")?.status == .completed)
        #expect(itemFor(result, "/source/link")?.destinationPath == "/target/link copy")
        #expect(fileSystem.readNode("/target/link")?.kind == .file)
    }

    @Test func asksBeforeMergingIntoAFolderThatBecameAFile() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target/Docs/old.txt", .file(size: 1)),
        ])

        let (result, conflicts) = try await edgePaste(
            fileSystem, sources: ["/source/Docs"],
            beforeExecute: {
                fileSystem.deleteNode("/target/Docs/old.txt")
                fileSystem.deleteNode("/target/Docs")
                fileSystem.addFile("/target/Docs", .file(size: 9))
            },
            resolve: { _ in .skip })

        #expect(conflicts.map(\.reason) == [.destinationChanged])
        #expect(conflicts.map(\.conflictClass) == [.typeMismatch])
        #expect(itemFor(result, "/source/Docs")?.status == .skipped)
        #expect(fileSystem.readNode("/target/Docs")?.kind == .file)
    }

    // MARK: Stopping part way

    @Test func stoppedInsideAFolderBeingCopiedLeavesNothingOfIt() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/source/Docs/b.txt", .file(size: 1)),
            ("/source/Docs/c.txt", .file(size: 1)), ("/target", .directory()),
        ])
        let signal = StopSignal()
        fileSystem.copyFileImpl = { source, destination, stop, _ in
            if source.hasSuffix("b.txt") {
                signal.stop()
                try stop?.throwIfStopped()
            }
            fileSystem.addFile(destination, .file(size: 1))
        }

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/Docs"], signal: signal)

        // It was built under a hidden name, which went with the stop.
        #expect(result.status == .cancelled)
        #expect(try fileSystem.readdir("/target") == [])
    }

    @Test func stoppedWhileBuildingAReplacementLeavesTheExistingItemAsItWas() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/source/Docs/b.txt", .file(size: 1)),
            ("/target/Docs/old.txt", .file(size: 7)),
        ])
        fileSystem.enableTrash()
        let signal = StopSignal()
        fileSystem.copyFileImpl = { source, destination, _, _ in
            if source.hasSuffix("b.txt") {
                signal.stop()
                throw StopError()
            }
            fileSystem.addFile(destination, .file(size: 1))
        }
        let journal = ReplaceEntriesJournal()

        let (result, _) = try await edgePaste(
            fileSystem, sources: ["/source/Docs"], policy: NativePaste.replaceAll, signal: signal,
            writeJournal: journal)

        #expect(result.status == .cancelled)
        #expect(fileSystem.readNode("/target/Docs/old.txt")?.size == 7)
        #expect(fileSystem.temporaryLeftovers() == [])
        #expect(fileSystem.trashed == [])
        #expect(journal.live.isEmpty)
    }

    // A folder moved to another disk found in place while its originals were removed, whose source can't be read at
    // the next start: whether the original is still there isn't known, so the record is kept and asked again.
    @Test func keepsTheRecordOfAMoveFoundInPlaceWhoseSourceCantBeRead() {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F/a.txt", .file(size: 1)), ("/target/F/a.txt", .file(size: 1)),
        ])
        fileSystem.lstatImpl = { path in
            if path == "/source/F" { throw MockWriteServiceFileSystem.error(EIO, path) }
            return try fileSystem.lstatDirectly(path)
        }
        let entry = ReplaceJournalEntry(
            id: "move-1", stagingPath: "/target/.F.filetrail-1", finalPath: "/target/F", sourcePath: "/source/F",
            moved: false, staged: true, movingCopy: true)

        let outcomes = recoverInterruptedReplaces([entry], fileSystem)

        #expect(outcomes.map(\.outcome) == [.unreachable(error: "A disk error occurred.")])
    }

    // MARK: A full disk

    // Every item after the first that found the disk full used to be tried, and failed, one by one.
    @Test func endsThePasteAtTheFirstItemThatFindsTheDiskFull() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 1)), ("/source/b.txt", .file(size: 1)), ("/source/c.txt", .file(size: 1)),
            ("/target", .directory()),
        ])
        let attempts = Locked(0)
        fileSystem.copyFileImpl = { _, destination, _, _ in
            attempts.mutate { $0 += 1 }
            throw MockWriteServiceFileSystem.error(ENOSPC, destination)
        }

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/a.txt", "/source/b.txt", "/source/c.txt"])

        #expect(attempts.value == 1)
        #expect(result.status == .failed)
        #expect(result.error == "There isn't enough free space on the destination disk.")
        #expect(result.items.map(\.status) == [.failed, .cancelled, .cancelled])
        #expect(itemFor(result, "/source/a.txt")?.error == "There isn't enough free space on the destination disk.")
        #expect(itemFor(result, "/source/c.txt")?.error == "Not started because the destination disk is full.")
        #expect(try fileSystem.readdir("/target") == [])
    }

    // A folder being copied when the disk filled up used to be put in place with what fitted, and the items after it
    // were tried too.
    @Test func leavesNothingOfAFolderBeingCopiedWhenTheDiskFillsUpAndStartsNothingAfterIt() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/source/Docs/b.txt", .file(size: 1)),
            ("/source/Docs/c.txt", .file(size: 1)), ("/source/z.txt", .file(size: 1)), ("/target", .directory()),
        ])
        let attempts = Locked(0)
        fileSystem.copyFileImpl = { source, destination, stop, _ in
            attempts.mutate { $0 += 1 }
            if attempts.value >= 2 {
                throw MockWriteServiceFileSystem.error(ENOSPC, destination)
            }
            try fileSystem.copyDirectly(source, destination, stop: stop)
        }

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/Docs", "/source/z.txt"])

        #expect(attempts.value == 2)
        #expect(result.status == .failed)
        #expect(result.items.map(\.sourcePath) == ["/source/Docs", "/source/z.txt"])
        #expect(result.items.map(\.status) == [.failed, .cancelled])
        #expect(itemFor(result, "/source/Docs")?.error == "There isn't enough free space on the destination disk.")
        #expect(itemFor(result, "/source/z.txt")?.error == "Not started because the destination disk is full.")
        #expect(try fileSystem.readdir("/target") == [])
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // MARK: The last step of a Replace

    private func replaceSetup() -> MockWriteServiceFileSystem {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 2)), ("/target/a.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()
        return fileSystem
    }

    @Test func asksAgainWhenSomethingTookTheNameInTheMomentTheOldItemWasGone() async throws {
        let fileSystem = replaceSetup()
        let sneaked = Locked(false)
        fileSystem.renameImpl = { from, to in
            if to == "/target/a.txt" && !sneaked.value {
                sneaked.mutate { $0 = true }
                fileSystem.addFile("/target/a.txt", .file(size: 5))
                throw codedError(.errno(EEXIST))
            }
            try fileSystem.renameDirectly(from, to)
        }

        let (result, conflicts) = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll, resolve: { _ in .keepBoth })

        #expect(conflicts.map(\.reason) == [.destinationChanged])
        #expect(itemFor(result, "/source/a.txt")?.status == .completed)
        #expect(itemFor(result, "/source/a.txt")?.destinationPath == "/target/a copy.txt")
        #expect(fileSystem.readNode("/target/a.txt")?.size == 5)
    }

    // The copy made for a Replace that is then asked again was counted as done: it goes away, and is counted once,
    // as what the answer makes.
    @Test func countsAReplaceThatIsAskedAgainOnce() async throws {
        let fileSystem = replaceSetup()
        let sneaked = Locked(false)
        fileSystem.renameImpl = { from, to in
            if to == "/target/a.txt" && !sneaked.value {
                sneaked.mutate { $0 = true }
                fileSystem.addFile("/target/a.txt", .file(size: 5))
                throw codedError(.errno(EEXIST))
            }
            try fileSystem.renameDirectly(from, to)
        }
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.txt"], into: "/target", policy: NativePaste.replaceAll)

        let events = await execute(
            fileSystem, operation, policy: NativePaste.replaceAll, requestResolution: { _ in .immediate(.keepBoth) })

        let last = try #require(events.last)
        #expect(last.status == .completed)
        #expect(events.allSatisfy { $0.completedItemCount <= $0.totalItemCount })
        #expect(events.allSatisfy { $0.totalBytes == nil || $0.completedByteCount <= $0.totalBytes! })
        #expect(last.completedItemCount == last.totalItemCount)
    }

    @Test func leavesTheNewItemToTheNextStartWhenNoNameCanBeGivenToIt() async throws {
        let fileSystem = replaceSetup()
        fileSystem.renameImpl = { from, to in
            if !to.contains(".filetrail-") {
                throw codedError(.errno(EIO))
            }
            try fileSystem.renameDirectly(from, to)
        }
        let journal = ReplaceEntriesJournal()

        let (result, _) = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll, writeJournal: journal)

        #expect(
            itemFor(result, "/source/a.txt")?.error
                == "The old \u{201C}a.txt\u{201D} was moved to the Trash, but the new one couldn't be put in its place. It will be put there the next time File Trail starts. A disk error occurred."
        )
        // The journal keeps it, so the next start puts it in place.
        #expect(journal.live.map(\.staged) == [true])
    }

    // The new item's lock comes off for the swap. Left to the next start, it used to stay off, and the item was put
    // in place unlocked.
    @Test func leavesTheNewItemToTheNextStartLockedAsItsOriginalIs() async throws {
        let fileSystem = replaceSetup()
        let locked = UInt32(UF_IMMUTABLE)
        // copyfile(3) carries the lock to the copy.
        fileSystem.copyFileImpl = { source, destination, stop, _ in
            try fileSystem.copyDirectly(source, destination, stop: stop)
            try fileSystem.setFlags(destination, locked)
        }
        fileSystem.renameImpl = { from, to in
            if !to.contains(".filetrail-") {
                throw MockWriteServiceFileSystem.error(EIO, to)
            }
            try fileSystem.renameDirectly(from, to)
        }
        let journal = ReplaceEntriesJournal()

        let (result, _) = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll, writeJournal: journal)

        #expect(itemFor(result, "/source/a.txt")?.status == .failed)
        let entry = try #require(journal.live.first)
        #expect(fileSystem.readNode(entry.stagingPath)?.flags == locked)

        fileSystem.renameImpl = nil
        let outcomes = recoverInterruptedReplaces(journal.live, fileSystem)

        #expect(outcomes.map(\.outcome) == [.finished(path: "/target/a.txt")])
        #expect(fileSystem.readNode("/target/a.txt")?.flags == locked)
    }

    // A Replace by a move whose old item can't go to the Trash puts the moved folder back; when its old name was taken
    // meanwhile it can't, and it waits under its hidden name read-only again, as the next start carries over what it
    // finds.
    @Test func aMovedReadOnlyFolderThatCantBePutBackWaitsReadOnly() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Vault", .directory(mode: 0o555)), ("/source/Vault/a.txt", .file(size: 1)),
            ("/target/Vault/old.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()
        fileSystem.trashImpl = { _ in
            // Something takes the moved folder's old name, then the Trash fails.
            fileSystem.addFile("/source/Vault", .directory())
            throw MockWriteServiceFileSystem.error(EIO, "/target/Vault")
        }
        let journal = ReplaceEntriesJournal()

        let (result, _) = try await edgePaste(
            fileSystem, mode: .cut, sources: ["/source/Vault"], policy: NativePaste.replaceAll, writeJournal: journal)

        let entry = try #require(journal.live.first)
        #expect(entry.moved)
        #expect(fileSystem.readNode(entry.stagingPath)?.mode == 0o555)
        #expect(itemFor(result, "/source/Vault")?.error?.contains("under the hidden name") == true)
    }

    // A read-only folder moved on its disk is opened for the swap. Left to the next start, it used to stay open, and
    // was put in place no longer read-only.
    @Test func leavesAMovedReadOnlyFolderToTheNextStartReadOnly() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Vault", .directory(mode: 0o555)), ("/source/Vault/a.txt", .file(size: 1)),
            ("/target/Vault/old.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()
        fileSystem.renameImpl = { from, to in
            if !to.contains(".filetrail-") {
                throw MockWriteServiceFileSystem.error(EIO, to)
            }
            try fileSystem.renameDirectly(from, to)
        }
        let journal = ReplaceEntriesJournal()

        let (result, _) = try await edgePaste(
            fileSystem, mode: .cut, sources: ["/source/Vault"], policy: NativePaste.replaceAll, writeJournal: journal)

        #expect(itemFor(result, "/source/Vault")?.status == .failed)
        let entry = try #require(journal.live.first)
        #expect(entry.moved)
        #expect(fileSystem.readNode(entry.stagingPath)?.mode == 0o555)

        // As macOS 14 does, the disk refuses to rename a folder that can't be written to: recovery opens it for the
        // move, as the paste does.
        fileSystem.renameImpl = { from, to in
            if let mode = fileSystem.readNode(from)?.mode, fileSystem.readNode(from)?.kind == .directory,
                mode & 0o200 == 0
            {
                throw MockWriteServiceFileSystem.error(EACCES, from)
            }
            try fileSystem.renameDirectly(from, to)
        }
        let outcomes = recoverInterruptedReplaces(journal.live, fileSystem)

        #expect(outcomes.map(\.outcome) == [.finished(path: "/target/Vault")])
        #expect(fileSystem.readNode("/target/Vault")?.mode == 0o555)
        #expect(fileSystem.exists("/target/Vault/a.txt"))
    }

    @Test func refusesToReplaceWithAnItemLockedInAWayItsOwnerCantUndo() async throws {
        let fileSystem = replaceSetup()
        fileSystem.getFlagsImpl = { path in path.contains(".filetrail-") ? 0x20000 : 0 }
        fileSystem.setFlagsImpl = { _, _ in }

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll)

        #expect(itemFor(result, "/source/a.txt")?.error?.contains("is locked") == true)
        #expect(fileSystem.readNode("/target/a.txt")?.size == 1)
        #expect(fileSystem.trashed == [])
    }

    @Test func asksBeforeDeletingTheOldItemForGoodOnADiskWithoutATrash() async throws {
        let fileSystem = replaceSetup()
        fileSystem.trashImpl = { _ in throw NativeError(message: "no Trash", code: .noTrash) }

        let skipped = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll, resolve: { _ in .skip })
        #expect(itemFor(skipped.result, "/source/a.txt")?.status == .skipped)
        #expect(fileSystem.readNode("/target/a.txt")?.size == 1)

        let replaced = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll, resolve: { _ in .overwrite })
        #expect(itemFor(replaced.result, "/source/a.txt")?.status == .completed)
        #expect(fileSystem.readNode("/target/a.txt")?.size == 2)
    }

    // MARK: A replacing move to another disk

    @Test func reportsAnOriginalItCouldntRemoveOnceItsCopyWasInPlace() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/source/Docs/Inner/b.txt", .file(size: 1)),
            ("/target", .directory(dev: 2)), ("/target/Docs/old.txt", .file(size: 1, dev: 2)),
        ])
        fileSystem.enableTrash()
        fileSystem.rmImpl = { path, _, _ in
            if path == "/source/Docs/Inner/b.txt" {
                throw codedError(.errno(EBUSY))
            }
            try fileSystem.removeDirectly(path, recursive: true, force: true)
        }

        let (result, _) = try await edgePaste(
            fileSystem, mode: .cut, sources: ["/source/Docs"], policy: NativePaste.replaceAll)

        #expect(itemFor(result, "/source/Docs/Inner/b.txt")?.status == .failed)
        #expect(
            itemFor(result, "/source/Docs/Inner/b.txt")?.error
                == "It was copied, but the original couldn't be removed. The item is in use.")
        #expect(fileSystem.exists("/target/Docs/Inner/b.txt"))
        #expect(fileSystem.exists("/source/Docs/Inner/b.txt"))
        #expect(!fileSystem.exists("/source/Docs/a.txt"))
    }

    @Test func namesHowManyItemsWereAddedToAFolderWhileItWasBeingMoved() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/target", .directory(dev: 2)),
        ])

        let (result, _) = try await edgePaste(
            fileSystem, mode: .cut, sources: ["/source/Docs"],
            beforeExecute: {
                fileSystem.addFile("/source/Docs/late-1.txt")
                fileSystem.addFile("/source/Docs/late-2.txt")
            })

        #expect(
            itemFor(result, "/source/Docs")?.error
                == "2 items were added to \u{201C}Docs\u{201D} while it was being moved, so they were left in the original \u{201C}Docs\u{201D}."
        )
    }

    // MARK: A Replace that would destroy what it pastes

    // A hard link to the item being pasted took the place of the item to replace: sending it to the Trash would
    // send the item being pasted with it.
    @Test func refusesToReplaceAnItemWithItselfEvenWhenThatBecameSoAfterTheReview() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/a.txt", .file(size: 2, ino: 500)), ("/target/a.txt", .file(size: 1)),
        ])
        fileSystem.enableTrash()

        let (result, _) = try await edgePaste(
            fileSystem, sources: ["/source/a.txt"], policy: NativePaste.replaceAll,
            beforeExecute: {
                fileSystem.deleteNode("/target/a.txt")
                fileSystem.addFile("/target/a.txt", .file(size: 2, ino: 500))
            },
            resolve: { _ in .overwrite })

        #expect(itemFor(result, "/source/a.txt")?.status == .failed)
        #expect(
            itemFor(result, "/source/a.txt")?.error
                == "\u{201C}a.txt\u{201D} is the item being pasted, so it can't replace itself.")
        #expect(fileSystem.trashed == [])
    }

    // MARK: Putting right a Replace cut short

    @Test func locksTheHiddenItemAgainWhenItCantBeMovedIntoPlace() {
        let fileSystem = MockWriteServiceFileSystem([("/target/.a.txt.filetrail-00000001", .file(size: 2))])
        let calls = Locked<[[String]]>([])
        fileSystem.getFlagsImpl = { _ in 0x2 }
        fileSystem.setFlagsImpl = { path, flags in calls.mutate { $0.append([path, String(flags)]) } }
        fileSystem.renameImpl = { _, _ in throw codedError(.errno(EIO)) }

        let outcomes = recoverInterruptedReplaces(
            [
                ReplaceJournalEntry(
                    id: "1", stagingPath: "/target/.a.txt.filetrail-00000001", finalPath: "/target/a.txt",
                    sourcePath: "/source/a.txt", moved: false, staged: true)
            ], fileSystem)

        #expect(outcomes.map(\.outcome) == [.failed(error: "A disk error occurred.")])
        #expect(
            calls.value == [
                ["/target/.a.txt.filetrail-00000001", "0"], ["/target/.a.txt.filetrail-00000001", "2"],
            ])
    }

    // MARK: Pasting into the top of the disk

    @Test func mergesAFolderIntoOneAtTheTopOfTheDisk() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/Docs/a.txt", .file(size: 1)), ("/Docs/old.txt", .file(size: 1)),
        ])

        let (result, _) = try await edgePaste(fileSystem, sources: ["/source/Docs"], into: "/")

        #expect(result.status == .completed)
        #expect(fileSystem.exists("/Docs/a.txt"))
        #expect(fileSystem.exists("/Docs/old.txt"))
    }

    // MARK: Helpers

    @Test func seesASymlinkToAFileOrABrokenOneAsTheLinkItself() {
        let fileSystem = MockWriteServiceFileSystem([
            ("/a.txt", .file()), ("/link-to-file", .symlink("/a.txt")), ("/broken", .symlink("/missing")),
        ])

        #expect(captureFolderFingerprint(fileSystem, "/link-to-file").kind == .symlink)
        #expect(captureFolderFingerprint(fileSystem, "/broken").kind == .symlink)
    }

    @Test func treatsAnItemWhoseFlagsCantBeReadAsUnlocked() {
        #expect(!isLocked({ throw codedError(.errno(ENOENT), "ENOENT: \($0)") }, "/missing"))
        #expect(!isLocked(nil, "/a.txt"))
        #expect(lockedMessage("/") == "\u{201C}/\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
    }
}
