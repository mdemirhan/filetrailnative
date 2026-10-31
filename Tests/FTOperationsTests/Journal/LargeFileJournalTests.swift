// Port of "copying a large file" (packages/core/src/fs/copyPasteRecovery.test.ts); the recovery cases there are
// P3-04's
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct LargeFileJournalTests {
    /// Copies `sources` into /target, noting the journal's entries as each file's contents are written.
    private func copyLarge(_ fileSystem: MockWriteServiceFileSystem, _ sources: [String]) async throws
        -> (seen: [(destination: String, entries: [WriteJournalEntry])], journal: MemoryJournal)
    {
        let journal = MemoryJournal()
        let seen = Recorded<(destination: String, entries: [WriteJournalEntry])>()
        fileSystem.copyFileImpl = { _, destination, _, _ in
            seen.append((destination, journal.entries))
            fileSystem.addFile(destination, .file(size: journaledFileBytes))
        }
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(mode: .copy, sourcePaths: sources, destinationDirectoryPath: "/target"),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1_000_000_000_000))
        let policy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem)
        await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: policy, writeJournal: journal)
        return (seen.all, journal)
    }

    // T-afcfd54a F-275
    @Test func writesDownTheHiddenNameItIsCopiedUnderBeforeCopyingAnything() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/movie.mov", .file(size: journaledFileBytes)), ("/target", .directory()),
        ])

        let (seen, journal) = try await copyLarge(fileSystem, ["/source/movie.mov"])

        #expect(seen.count == 1)
        let destination = try #require(seen.first?.destination)
        #expect(destination.wholeMatch(of: /\/target\/\.movie\.mov\.filetrail-[0-9a-f]{8}/) != nil)
        #expect(seen.first?.entries.count == 1)
        if case .partialFile(let entry)? = seen.first?.entries.first {
            #expect(entry.id.wholeMatch(of: /[0-9a-f]{16}/) != nil)
            #expect(entry.partialPath == destination)
            #expect(entry.finalPath == "/target/movie.mov")
        } else {
            Issue.record("no partial_file entry")
        }
        // Done: the file has its name, and nothing is left under a hidden one.
        #expect(journal.entries.isEmpty)
        #expect(fileSystem.readNode("/target/movie.mov")?.size == journaledFileBytes)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // The folder's own record covers what is inside it: a crash leaves both to go with it.
    // T-94d72168 F-262 F-275
    @Test func isntWrittenDownOnItsOwnInsideAFolderBuiltUnderAHiddenName() async throws {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source/F", .directory()), ("/source/F/movie.mov", .file(size: journaledFileBytes)),
            ("/target", .directory()),
        ])

        let (seen, journal) = try await copyLarge(fileSystem, ["/source/F"])

        #expect(seen.count == 1)
        // Only the folder's own record.
        #expect(seen.first?.entries.count == 1)
        if case .replace(let entry)? = seen.first?.entries.first {
            #expect(entry.finalPath == "/target/F")
        } else {
            Issue.record("no folder entry")
        }
        #expect(journal.entries.isEmpty)
        #expect(fileSystem.readNode("/target/F/movie.mov")?.size == journaledFileBytes)
    }
}
