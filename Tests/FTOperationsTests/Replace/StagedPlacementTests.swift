// What a folder built under a hidden name and a Replace share (stageThenPlace), and where they differ
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct StagedPlacementTests {
    private func replaceEntries(_ journal: MemoryJournal) -> [ReplaceJournalEntry] {
        journal.writes.compactMap { write in
            if case .add(.replace(let entry)) = write { return entry }
            return nil
        }
    }

    /// A large file to put in place of one that is there, the hidden names it is copied to, and the journal.
    private func largeFileReplace() -> (MockWriteServiceFileSystem, Locked<[String]>, MemoryJournal) {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/a.bin", .file(size: journaledFileBytes)), ("/target", .directory()),
            ("/target/a.bin", .file(size: 3)),
        ])
        fileSystem.enableTrash()
        let written = Locked<[String]>([])
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            written.mutate { $0.append(destination) }
            try copy(source, destination, stop, onProgress)
        }
        return (fileSystem, written, MemoryJournal())
    }

    private func replace(_ fileSystem: MockWriteServiceFileSystem, _ journal: MemoryJournal) async throws
        -> CopyPasteOperationResult
    {
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/a.bin"], into: "/target", policy: NativePaste.replaceAll)
        let events = await execute(
            fileSystem, operation, operationId: "op-1", policy: NativePaste.replaceAll, writeJournal: journal)
        return try #require(events.last?.result, "The paste didn't finish.")
    }

    // The new file of a Replace is written once, under the hidden name its record names: no second hidden name
    // beside it, and no record of its own for a large one.
    @Test func aFileReplaceWritesItsNewFileUnderTheOneHiddenNameWrittenDown() async throws {
        let (fileSystem, written, journal) = largeFileReplace()

        let result = try await replace(fileSystem, journal)

        #expect(result.status == .completed)
        #expect(written.value.count == 1)
        let entries = replaceEntries(journal)
        #expect(entries.map(\.staged) == [false, true])
        #expect(entries.map(\.stagingPath) == [written.value.first, written.value.first])
        #expect(journal.writes.count == 3, "\(journal.writes)")
        #expect(journal.entries.isEmpty)
        #expect(fileSystem.readNode("/target/a.bin")?.size == journaledFileBytes)
        #expect(fileSystem.trashed == ["/target/a.bin"])
        #expect(fileSystem.temporaryLeftovers().isEmpty)
    }

    // A new file cut short that can't be cleared away stays written down, the old file in place, and the next
    // start clears it away.
    @Test func aNewFileCutShortThatCantBeClearedAwayIsClearedAtTheNextStart() async throws {
        let (fileSystem, written, journal) = largeFileReplace()
        fileSystem.copyFileImpl = { _, destination, _, _ in
            written.mutate { $0.append(destination) }
            fileSystem.addFile(destination, .file(size: 1))
            throw MockWriteServiceFileSystem.error(EIO, destination)
        }
        fileSystem.rmImpl = { path, _, _ in throw MockWriteServiceFileSystem.error(EIO, path) }

        let result = try await replace(fileSystem, journal)

        #expect(result.items.map(\.status) == [.failed])
        #expect(fileSystem.readNode("/target/a.bin")?.size == 3)
        #expect(fileSystem.trashed == [])
        let hidden = try #require(written.value.first)
        #expect(fileSystem.exists(hidden))
        let left = journal.entries.compactMap { entry -> ReplaceJournalEntry? in
            if case .replace(let replace) = entry { return replace }
            return nil
        }
        #expect(left.map(\.stagingPath) == [hidden])
        #expect(left.map(\.staged) == [false])

        fileSystem.rmImpl = nil
        let recovered = recoverInterruptedReplaces(left, fileSystem)
        #expect(recovered.map(\.outcome) == [.removedCopy])
        #expect(!fileSystem.exists(hidden))
        #expect(fileSystem.readNode("/target/a.bin")?.size == 3)
    }

    /// A folder of two files, and a paste of it stopped once the last of them is copied.
    private func stoppedAsTheLastFileIsWritten(replacing: Bool) async throws
        -> (MockWriteServiceFileSystem, CopyPasteOperationResult)
    {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory()), ("/source/dir", .directory()), ("/source/dir/a.txt", .file(size: 1)),
            ("/source/dir/b.txt", .file(size: 2)), ("/target", .directory()),
        ])
        if replacing {
            fileSystem.addDirectory("/target/dir")
            fileSystem.addFile("/target/dir/old.txt", .file(size: 9))
            fileSystem.enableTrash()
        }
        let signal = StopSignal()
        let copy = copyingSize(fileSystem)
        fileSystem.copyFileImpl = { source, destination, stop, onProgress in
            try copy(source, destination, stop, onProgress)
            if source == "/source/dir/b.txt" { signal.stop() }
        }
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/dir"], into: "/target", policy: NativePaste.replaceAll)
        let events = await execute(
            fileSystem, operation, operationId: "op-1", policy: NativePaste.replaceAll, signal: signal)
        return (fileSystem, try #require(events.last?.result, "The paste didn't finish."))
    }

    // The one place the two differ, each kept as it was: a folder copied to a free name and stopped as its last
    // file is written is cleared away, as one stopped part way is.
    @Test func aFolderCopiedAndStoppedAsItsLastFileIsWrittenIsClearedAway() async throws {
        let (fileSystem, result) = try await stoppedAsTheLastFileIsWritten(replacing: false)

        #expect(!fileSystem.exists("/target/dir"))
        #expect(fileSystem.temporaryLeftovers().isEmpty)
        #expect(result.status == .cancelled)
        #expect(result.items.first?.status == .cancelled)
        #expect(result.summary.completedByteCount == 0)
    }

    // A Replace stopped as its last file is written has its new folder whole: it goes on and replaces.
    @Test func aFolderReplaceStoppedAsItsLastFileIsWrittenStillReplaces() async throws {
        let (fileSystem, result) = try await stoppedAsTheLastFileIsWritten(replacing: true)

        #expect(fileSystem.exists("/target/dir/a.txt") && fileSystem.exists("/target/dir/b.txt"))
        #expect(!fileSystem.exists("/target/dir/old.txt"))
        #expect(fileSystem.trashed == ["/target/dir"])
        #expect(fileSystem.temporaryLeftovers().isEmpty)
        #expect(result.items.first?.status == .completed)
    }
}
