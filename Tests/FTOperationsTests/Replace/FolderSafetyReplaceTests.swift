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

/// Each write of a paste's journal, and whether it was flushed to the drive.
private final class FlushRecordingJournal: WriteJournal {
    private let writes = Locked<[Bool]>([])
    private let flushedEntries = Locked<[WriteJournalEntry]>([])

    func add(_ entry: WriteJournalEntry) throws {
        writes.mutate { $0.append(false) }
    }

    func addFlushed(_ entry: WriteJournalEntry) throws {
        writes.mutate { $0.append(true) }
        flushedEntries.mutate { $0.append(entry) }
    }

    func remove(_ id: String) throws {
        writes.mutate { $0.append(false) }
    }

    /// Whether each write, in order, was flushed.
    var flushes: [Bool] { writes.value }
    var flushed: [WriteJournalEntry] { flushedEntries.value }
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

    // A Replace by a move on one disk leaves the moved item's only copy under a hidden name: the record that says so
    // is flushed to the drive before the item moves, so not even a power cut loses it. A Replace by a copy leaves
    // its original in place, and none of its writes is flushed.
    @Test func flushesOnlyTheRecordOfAnItemMovedUnderAHiddenName() async throws {
        try await withWritableCleanup { root in
            try Disk.write(root + "/src/a.txt", "new a")
            try Disk.write(root + "/src/b.txt", "new b")
            try Disk.write(root + "/dst/a.txt", "old a")
            try Disk.write(root + "/dst/b.txt", "old b")
            let moving = FlushRecordingJournal()
            let copying = FlushRecordingJournal()

            _ = try await paste(
                .cut, [root + "/src/a.txt"], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: trashThatKeepsNothing), writeJournal: moving)
            _ = try await paste(
                .copy, [root + "/src/b.txt"], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: NativeWriteFileSystem(trash: trashThatKeepsNothing), writeJournal: copying)

            #expect(Disk.read(root + "/dst/a.txt") == "new a")
            #expect(moving.flushes == [true, false])
            guard case .replace(let entry)? = moving.flushed.first else {
                Issue.record("no flushed Replace entry: \(moving.flushed)")
                return
            }
            #expect(entry.moved && entry.staged)
            #expect(entry.sourcePath == root + "/src/a.txt")
            #expect(copying.flushes == [false, false, false])
        }
    }

    // A Replace by a move whose old item can't go to the Trash puts the moved item back. When its old name was taken
    // meanwhile it can't: it waits under its hidden name, written down for the next start, and the item's error
    // says where it is.
    @Test func saysWhereAMovedItemWaitsWhenAFailedReplaceCantPutItBack() async throws {
        try await withWritableCleanup { root in
            try Disk.write(root + "/src/a.txt", "new")
            try Disk.write(root + "/dst/a.txt", "old")
            let journal = ReplaceHistoryJournal()
            // Something takes the moved item's old name, then the Trash fails.
            let fileSystem = NativeWriteFileSystem(trash: { _ in
                try Disk.write(root + "/src/a.txt", "newcomer")
                throw codedError("EIO", "EIO: i/o error")
            })

            let result = try await paste(
                .cut, [root + "/src/a.txt"], into: root + "/dst", policy: NativePaste.replaceAll,
                fileSystem: fileSystem, writeJournal: journal)

            let hidden = try #require(Disk.list(root + "/dst").first(where: { $0.hasPrefix(".a.txt.filetrail-") }))
            #expect(Disk.read(root + "/dst/" + hidden) == "new")
            #expect(Disk.read(root + "/dst/a.txt") == "old")
            #expect(Disk.read(root + "/src/a.txt") == "newcomer")
            #expect(journal.live.map(\.moved) == [true])
            #expect(result.items.first?.status == .failed)
            #expect(
                result.items.first?.error
                    == "\u{201C}a.txt\u{201D} wasn't replaced, and couldn't be put back where it was, so it is under the hidden name \u{201C}\(hidden)\u{201D} in \u{201C}\(root)/dst\u{201D} until File Trail starts again. An item with this name already exists."
            )
        }
    }
}
