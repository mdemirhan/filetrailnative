// Port of the Replace and Replace journal cases of packages/core/src/fs/copyPasteFolderSafety.realfs.test.ts (its
// recovery cases are in Recovery/InterruptedReplaceRecoveryTests.swift, the others in Execution/FolderSafetyTests.swift)
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// The Replace entries a paste writes, each as written (`history`), and those still kept (`live`).
final class ReplaceHistoryJournal: WriteJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: ReplaceJournalEntry] = [:]
    private var written: [ReplaceJournalEntry] = []
    var beforeAdd: ((ReplaceJournalEntry) -> Void)?

    func add(_ entry: WriteJournalEntry) throws {
        guard case .replace(let replace) = entry else { return }
        beforeAdd?(replace)
        lock.lock()
        defer { lock.unlock() }
        kept[replace.id] = replace
        written.append(replace)
    }

    func remove(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        kept[id] = nil
    }

    var live: [ReplaceJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(kept.values)
    }

    var history: [ReplaceJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

/// A Trash that keeps nothing: only where things went matters, not what they were.
let trashThatKeepsNothing: @Sendable (String) throws -> String? = { path in
    try NativeWriteFileSystem().rm(path, recursive: true, force: true)
    return path
}

struct FolderSafetyReplaceTests {
    private func paste(
        _ mode: CopyPasteMode, _ sources: [String], into destination: String,
        policy: CopyPastePolicy = NativePaste.keepExisting, fileSystem: any WriteServiceFileSystem,
        writeJournal: (any WriteJournal)? = nil
    ) async throws -> CopyPasteOperationResult {
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-folder-safety",
            request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
        #expect(report.issues.isEmpty)
        let resolvedNodes = try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem)
        let events = await execute(
            fileSystem, (report, resolvedNodes), operationId: "op-folder-safety", policy: policy,
            writeJournal: writeJournal)
        return try #require(events.last?.result, "The paste reported no result.")
    }

    /// Read-only folders left by a test would stop the cleanup.
    private func withWritableCleanup(_ body: (String) async throws -> Void) async throws {
        try await withTemporaryDirectory { root in
            defer { makeWritable(root.path) }
            try await body(root.path)
        }
    }

    private func makeWritable(_ path: String) {
        Disk.chmod(path, 0o755)
        for name in Disk.list(path) where Disk.lstat(path + "/" + name)?.isDirectory == true {
            makeWritable(path + "/" + name)
        }
    }

    // T-465253ad F-508
    @Test func replacesAFolderWithAReadOnlyOne() async throws {
        try await withWritableCleanup { root in
            let source = root + "/src/module"
            try Disk.write(source + "/new.txt", "new")
            Disk.chmod(source, 0o555)
            try Disk.write(root + "/dst/module/old.txt", "old")

            let result = try await paste(
                .copy, [source], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: trashThatKeepsNothing))

            #expect(result.status == .completed, Comment(rawValue: "\(result)"))
            #expect(Disk.list(root + "/dst") == ["module"])
            #expect(Disk.list(root + "/dst/module") == ["new.txt"])
            #expect((Disk.lstat(root + "/dst/module")?.mode ?? 0) & 0o777 == 0o555)
        }
    }

    // MARK: Replace journal

    // T-2336e156 F-340 F-523
    @Test func writesAReplaceDownBeforeStagingItAndClearsItOnceSwappedIn() async throws {
        try await withWritableCleanup { root in
            try Disk.write(root + "/src/a.txt", "new")
            try Disk.write(root + "/dst/a.txt", "old")
            let journal = ReplaceHistoryJournal()

            let result = try await paste(
                .copy, [root + "/src/a.txt"], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: trashThatKeepsNothing), writeJournal: journal)

            #expect(result.status == .completed)
            #expect(journal.history.map { [$0.moved, $0.staged] } == [[false, false], [false, true]])
            #expect(journal.history.first?.finalPath == root + "/dst/a.txt")
            #expect(journal.live.isEmpty)
        }
    }

    // T-a3681238 F-340 F-523
    @Test func recordsASameVolumeMoveAsMovedBeforeTheSourceLeavesItsPlace() async throws {
        try await withWritableCleanup { root in
            try Disk.write(root + "/src/a.txt", "new")
            try Disk.write(root + "/dst/a.txt", "old")
            let journal = ReplaceHistoryJournal()
            let sourceSeen = Locked<[Bool]>([])
            journal.beforeAdd = { entry in
                let there = Disk.exists(entry.sourcePath)
                sourceSeen.mutate { $0.append(there) }
            }

            _ = try await paste(
                .cut, [root + "/src/a.txt"], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: trashThatKeepsNothing), writeJournal: journal)

            #expect(journal.history.map(\.moved) == [true])
            #expect(sourceSeen.value == [true])
            #expect(journal.live.isEmpty)
            #expect(Disk.read(root + "/dst/a.txt") == "new")
        }
    }
}
