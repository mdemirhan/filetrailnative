// Port of packages/core/src/fs/copyPastePartialFile.test.ts, but for what recovery does at the next start
// (recoverPartialFiles, P3-04's)
import FTFoundation
import FTTestSupport
import Foundation
import Testing
import os

@testable import FTOperations

// A large file is copied under a hidden name next to its place, written down in the journal first. Whatever stops
// it part way, nothing is left at its name, the part goes, and the journal lets go of it; a part that can't be
// removed stays written down for the next start.
struct PartialFileTests {
    private static let skip = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
    private static let source = "/source/movie.mov"
    private static let final = "/target/movie.mov"

    private struct Run {
        var result: CopyPasteOperationResult
        var journal: MemoryJournal
        var questions: [CopyPasteRuntimeConflict]

        /// What the journal holds still.
        var live: [WriteJournalEntry] { journal.entries }
        /// Every entry it was given.
        var recorded: [WriteJournalEntry] {
            journal.writes.compactMap {
                if case .add(let entry) = $0 { return entry }
                return nil
            }
        }
    }

    /// The file on another disk (dev 2): a move copies it, then removes the original.
    private func largeFileOnAnotherDisk() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), (Self.source, .file(size: journaledFileBytes, dev: 2)),
            ("/target", .directory()),
        ])
    }

    private func paste(
        _ fileSystem: MockWriteServiceFileSystem, _ mode: CopyPasteMode, signal: StopSignal = StopSignal(),
        answer: CopyPasteChoice? = nil
    ) async throws -> Run {
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-1",
            request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: [Self.source], destinationDirectoryPath: "/target"),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 100, largeBatchByteThreshold: 1_000_000_000_000))
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: Self.skip, fileSystem: fileSystem)
        let journal = MemoryJournal()
        let recorder = PasteRecorder()
        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-1", policy: Self.skip, signal: signal,
            writeJournal: journal, recorder: recorder, requestResolution: { _ in .immediate(answer) })
        let result = try #require(events.last?.result, "The paste didn't finish.")
        return Run(result: result, journal: journal, questions: recorder.conflicts)
    }

    /// Copies part of the file under its hidden name, then does `then` (throws, stops...).
    private func copyPartThen(
        _ fileSystem: MockWriteServiceFileSystem, _ then: @escaping (String, StopSignal?) throws -> Void
    ) {
        fileSystem.copyFileImpl = { _, destination, stop, _ in
            fileSystem.addFile(destination, .file(size: 1024))
            try then(destination, stop)
        }
    }

    /// Nothing at the file's name or under a hidden one, the journal let go of the entry it wrote (the part's
    /// hidden name), and the original is where it was.
    private func expectNothingLeft(_ fileSystem: MockWriteServiceFileSystem, _ run: Run) {
        #expect(run.recorded.count == 1)
        if case .partialFile(let entry)? = run.recorded.first {
            #expect(entry.partialPath.wholeMatch(of: /\/target\/\.movie\.mov\.filetrail-[0-9a-f]{8}/) != nil)
            #expect(entry.finalPath == Self.final)
        } else {
            Issue.record("no partial_file entry: \(run.recorded)")
        }
        #expect(run.live.isEmpty)
        #expect(fileSystem.temporaryLeftovers() == [])
        #expect(fileSystem.readNode(Self.source)?.size == journaledFileBytes)
    }

    // T-f00416eb F-257 F-275
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func leavesNothingBehindWhenStoppedPartWay(mode: CopyPasteMode) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        let signal = StopSignal()
        copyPartThen(fileSystem) { _, stop in
            signal.stop()
            try stop?.throwIfStopped()
        }

        let run = try await paste(fileSystem, mode, signal: signal)

        #expect(run.result.status == .cancelled)
        #expect(!fileSystem.exists(Self.final))
        expectNothingLeft(fileSystem, run)
    }

    // T-9e7a471a F-275 F-471
    @Test(arguments: [CopyPasteMode.copy, .cut], ["ENOSPC", "EIO"])
    func leavesNothingBehindAndSaysWhy(mode: CopyPasteMode, code: String) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        copyPartThen(fileSystem) { destination, _ in throw MockWriteServiceFileSystem.error(code, destination) }

        let run = try await paste(fileSystem, mode)

        #expect(run.result.status == .failed)
        #expect(run.result.items.map(\.sourcePath) == [Self.source])
        #expect(run.result.items.map(\.status) == [.failed])
        #expect(run.result.items.first?.error?.isEmpty == false)
        #expect(!fileSystem.exists(Self.final))
        expectNothingLeft(fileSystem, run)
    }

    // T-3980d27b F-258 F-275
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func asksAboutAnItemThatTookTheNameAsTheCopyWasDoneAndClearsItsOwnAway(mode: CopyPasteMode) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        // Another app saves a file at the name while the copy is being made.
        copyPartThen(fileSystem) { _, _ in fileSystem.addFile(Self.final, .file(size: 3)) }

        let run = try await paste(fileSystem, mode, answer: .skip)

        #expect(run.questions.map(\.sourcePath) == [Self.source])
        #expect(run.questions.map(\.destinationPath) == [Self.final])
        #expect(run.result.items.map(\.status) == [.skipped])
        // The other app's file is untouched.
        #expect(fileSystem.readNode(Self.final)?.size == 3)
        expectNothingLeft(fileSystem, run)
    }

    // T-eb0df2a7 F-274 F-275
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func failsTheItemWhenItCantTakeItsNameAndClearsItsOwnAway(mode: CopyPasteMode) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        fileSystem.renameImpl = { from, to in
            if to == Self.final && from.contains(".filetrail-") {
                throw MockWriteServiceFileSystem.error("EIO", to)
            }
            try fileSystem.renameDirectly(from, to)
        }

        let run = try await paste(fileSystem, mode)

        #expect(run.result.items.map(\.status) == [.failed])
        #expect(!fileSystem.exists(Self.final))
        expectNothingLeft(fileSystem, run)
    }

    // A large file's hidden part that a failed copy can't clear away stays written down, for the next start to
    // remove (that removal, recoverPartialFiles, is P3-04's).
    // T-93ae7a3b F-275
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func staysWrittenDownWhenAFailedCopyCantClearItAway(mode: CopyPasteMode) async throws {
        let fileSystem = largeFileOnAnotherDisk()
        // rm of the hidden part fails (a disk error).
        fileSystem.rmImpl = { path, recursive, force in
            if path.firstMatch(of: /\.filetrail-[0-9a-f]{8}$/) != nil {
                throw MockWriteServiceFileSystem.error("EIO", path)
            }
            try fileSystem.removeDirectly(path, recursive: recursive, force: force)
        }
        copyPartThen(fileSystem) { destination, _ in throw MockWriteServiceFileSystem.error("ENOSPC", destination) }

        let run = try await paste(fileSystem, mode)

        #expect(run.result.items.map(\.status) == [.failed])
        #expect(!fileSystem.exists(Self.final))
        #expect(fileSystem.readNode(Self.source)?.size == journaledFileBytes)
        #expect(run.live.count == 1)
        if case .partialFile(let entry)? = run.live.first {
            #expect(fileSystem.exists(entry.partialPath))
        }
        #expect(!fileSystem.temporaryLeftovers().isEmpty)
    }
}

/// A file that failed inside a folder being copied.
struct FailedFileInsideAFolderTests {
    /// A folder on another disk with two files; copying "a.txt" writes part of it, then fails.
    private func copyFolderWithFailingFile(partRemovable: Bool) async throws
        -> (fileSystem: MockWriteServiceFileSystem, result: CopyPasteOperationResult, written: [String])
    {
        let fileSystem = MockWriteServiceFileSystem([
            ("/source", .directory(dev: 2)), ("/source/dir", .directory(dev: 2)),
            ("/source/dir/a.txt", .file(size: 10, dev: 2)), ("/source/dir/b.txt", .file(size: 10, dev: 2)),
            ("/target", .directory()),
        ])
        let written = Recorded<String>()
        fileSystem.copyFileImpl = { source, destination, _, _ in
            written.append(destination)
            let fails = source.hasSuffix("/a.txt")
            fileSystem.addFile(destination, .file(size: fails ? 4 : 10))
            if fails {
                throw MockWriteServiceFileSystem.error("EIO", destination)
            }
        }
        if !partRemovable {
            fileSystem.rmImpl = { path, recursive, force in
                if path.hasSuffix("/a.txt") {
                    throw MockWriteServiceFileSystem.error("EIO", path)
                }
                try fileSystem.removeDirectly(path, recursive: recursive, force: force)
            }
        }
        let policy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
        let operation = try createResolvedOperation(fileSystem, sources: ["/source/dir"], into: "/target", policy: policy)
        let events = await execute(fileSystem, operation, operationId: "op-1", policy: policy)
        let result = try #require(events.last?.result, "The paste didn't finish.")
        return (fileSystem, result, written.all)
    }

    // T-c0c25051 F-274
    @Test func isWrittenStraightIntoTheHiddenFolderWhichIsPutInPlaceWithoutIt() async throws {
        let (fileSystem, result, written) = try await copyFolderWithFailingFile(partRemovable: true)

        // No hidden name of its own inside the folder's.
        #expect(written.count == 2)
        #expect(written.first?.wholeMatch(of: /\/target\/\.dir\.filetrail-[0-9a-f]{8}\/a\.txt/) != nil)
        #expect(written.last?.wholeMatch(of: /\/target\/\.dir\.filetrail-[0-9a-f]{8}\/b\.txt/) != nil)
        #expect(result.items.contains { $0.sourcePath == "/source/dir/a.txt" && $0.status == .failed })
        #expect(!fileSystem.exists("/target/dir/a.txt"))
        #expect(fileSystem.readNode("/target/dir/b.txt")?.size == 10)
        #expect(fileSystem.temporaryLeftovers() == [])
    }

    // T-34d34071 F-274
    @Test func keepsTheWholeFolderFromBeingPutInPlaceWhenItsPartCantBeRemoved() async throws {
        let (fileSystem, result, _) = try await copyFolderWithFailingFile(partRemovable: false)

        #expect(result.status == .failed)
        #expect(result.items.map(\.sourcePath) == ["/source/dir"])
        #expect(result.items.map(\.status) == [.failed])
        // The cut-short "a.txt" never shows under its name.
        #expect(!fileSystem.exists("/target/dir"))
    }
}
