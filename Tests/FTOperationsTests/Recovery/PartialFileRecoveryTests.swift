// Port of what recovery does at the next start in packages/core/src/fs/copyPastePartialFile.test.ts (the copying half
// of its cases is in Execution/PartialFileTests.swift)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct PartialFileRecoveryTests {
    private static let skip = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
    private static let source = "/source/movie.mov"
    private static let final = "/target/movie.mov"

    /// The file on another disk (dev 2): a move copies it, then removes the original.
    private func largeFileOnAnotherDisk() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), (Self.source, .file(size: journaledFileBytes, dev: 2)),
            ("/target", .directory()),
        ])
    }

    private func operation(_ fileSystem: MockWriteServiceFileSystem, _ mode: CopyPasteMode) throws
        -> (report: CopyPasteAnalysisReport, resolvedNodes: [ResolvedCopyPasteNode])
    {
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(
                mode: mode, sourcePaths: [Self.source], destinationDirectoryPath: "/target"),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1_000_000_000_000))
        return (report, try resolveAnalysisWithPolicy(report: report, policy: Self.skip, fileSystem: fileSystem))
    }

    private func partialEntries(_ journal: MemoryJournal) -> [PartialFileJournalEntry] {
        journal.entries.compactMap {
            if case .partialFile(let entry) = $0 { return entry }
            return nil
        }
    }

    // The part a failed copy couldn't clear away is removed at the next start (its copying half is in
    // Execution/PartialFileTests.swift).
    // T-93ae7a3b F-275 F-513 F-354
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func staysWrittenDownWhenAFailedCopyCantClearItAwayAndGoesAtTheNextStart(mode: CopyPasteMode) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        let removalWorks = Locked(false)
        fileSystem.rmImpl = { path, recursive, force in
            if !removalWorks.value && path.firstMatch(of: /\.filetrail-[0-9a-f]{8}$/) != nil {
                throw MockWriteServiceFileSystem.error("EIO", path)
            }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
        fileSystem.copyFileImpl = { _, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 1024))
            throw MockWriteServiceFileSystem.error("ENOSPC", destination)
        }
        let journal = MemoryJournal()

        let events = await execute(
            fileSystem, try operation(fileSystem, mode), operationId: "op-1", policy: Self.skip, writeJournal: journal)

        #expect(events.last?.result?.items.map(\.status) == [.failed])
        #expect(!fileSystem.exists(Self.final))
        #expect(fileSystem.readNode(Self.source)?.size == journaledFileBytes)
        let entries = partialEntries(journal)
        #expect(entries.count == 1)
        #expect(!fileSystem.temporaryLeftovers().isEmpty)

        removalWorks.mutate { $0 = true }
        let outcomes = recoverPartialFiles(entries, fileSystem)

        #expect(outcomes.map(\.outcome) == [.removedCopy])
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // The copy never comes back, as when the app is killed part way: the journal entry it wrote and the part are
    // all that is left.
    // T-df25867e F-513 F-354
    @Test func hasItsPartRemovedAtTheNextStart() async throws {
        let fileSystem = largeFileOnAnotherDisk()
        let written = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        fileSystem.copyFileImpl = { _, destination, _, _ in
            fileSystem.addFile(destination, .file(size: 1024))
            written.signal()
            // Never comes back while the test looks (let go once it is done).
            released.wait()
            throw StopError()
        }
        let journal = MemoryJournal()
        let paste = Task { [operation = try operation(fileSystem, .copy)] in
            await execute(fileSystem, operation, operationId: "op-1", policy: Self.skip, writeJournal: journal)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                written.wait()
                continuation.resume()
            }
        }
        let entry = try #require(partialEntries(journal).first)
        #expect(fileSystem.exists(entry.partialPath))

        let outcomes = recoverPartialFiles([entry], fileSystem)

        #expect(outcomes.map(\.outcome) == [.removedCopy])
        #expect(fileSystem.temporaryLeftovers() == [])
        #expect(!fileSystem.exists(Self.final))
        #expect(fileSystem.readNode(Self.source)?.size == journaledFileBytes)
        released.signal()
        _ = await paste.value
    }
}
