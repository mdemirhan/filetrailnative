// Port of the rename-of-several cases of apps/desktop/src/main/bootstrap/writeJournal.test.ts
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// The disk as a process killed at one point leaves it: once `crash` is called, nothing more reaches it.
private final class CrashableDisk: BatchRenameFileSystem, @unchecked Sendable {
    private let disk = LocalBatchRenameFileSystem(NativeWriteFileSystem())
    private let lock = NSLock()
    private var crashed = false
    /// Called before each exclusive rename: true to crash right there.
    var crashesAt: (String, String) -> Bool = { _, _ in false }

    var hasCrashed: Bool { lock.withLock { crashed } }

    private func alive() throws {
        if hasCrashed { throw OperationError("The app is gone.", code: "ECANCELED") }
    }

    func lstat(_ path: String) throws -> WriteServiceStats {
        try alive()
        return try disk.lstat(path)
    }

    func renameExclusive(_ from: String, _ to: String) throws {
        try alive()
        if crashesAt(from, to) {
            lock.withLock { crashed = true }
            try alive()
        }
        try disk.renameExclusive(from, to)
    }

    func rename(_ from: String, _ to: String) throws {
        try alive()
        try disk.rename(from, to)
    }

    var readFolder: ((String) throws -> [String])? {
        { [self] in
            try alive()
            return try disk.readFolder?($0) ?? []
        }
    }

    var readFlags: ((String) throws -> UInt32)? { disk.readFlags }
    var caseSensitivity: ((String) throws -> Bool?)? { disk.caseSensitivity }
}

/// The journal file as a killed process leaves it: what it wrote before, nothing after.
private struct CrashableJournal: WriteJournal {
    let file: FileWriteJournal
    let disk: CrashableDisk

    func add(_ entry: WriteJournalEntry) throws {
        if !disk.hasCrashed { try file.add(entry) }
    }

    func remove(_ id: String) throws {
        if !disk.hasCrashed { try file.remove(id) }
    }
}

struct BatchRenameRecoveryTests {
    // A rename of several ("1" becomes "2", "2" becomes "3") stops dead as the first item takes its new name, as in a
    // crash: the items waiting under hidden names are put back at the next start, and the person is told.
    // T-b6cfb45b F-356 F-566
    @Test func putsBackTheItemsARenameOfSeveralLeftUnderHiddenNames() throws {
        try withTemporaryDirectory { directory in
            let folder = directory.path + "/trip"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            for name in ["1.jpg", "2.jpg", "3.jpg"] {
                try name.write(toFile: "\(folder)/\(name)", atomically: false, encoding: .utf8)
            }
            let journalPath = directory.path + "/replace-journal.json"
            let disk = CrashableDisk()
            disk.crashesAt = { _, to in NodePath.basename(to) == "2.jpg" }
            _ = BatchRenameExecution.run(
                BatchRenameRequest(
                    items: ["1.jpg", "2.jpg", "3.jpg"].enumerated().map { index, name in
                        .init(sourcePath: "\(folder)/\(name)", destinationName: "\(index + 2).jpg", isFolder: false)
                    }), fileSystem: disk, signal: StopSignal(),
                journal: CrashableJournal(file: FileWriteJournal.open(journalPath), disk: disk))
            #expect(disk.hasCrashed)
            // "2.jpg" and "3.jpg" were moved aside for the others; "1.jpg" was taking its new name.
            let visible = try FileManager.default.contentsOfDirectory(atPath: folder).filter { !$0.hasPrefix(".") }
            #expect(visible == ["1.jpg"])

            let reopened = FileWriteJournal.open(journalPath)
            let report = recoverWrites(reopened, NativeWriteFileSystem(), logger: RecordingLogger().logger)

            #expect(
                try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == ["1.jpg", "2.jpg", "3.jpg"])
            #expect(try String(contentsOfFile: "\(folder)/1.jpg", encoding: .utf8) == "1.jpg")
            #expect(
                report.notices == [
                    "A rename of several items was cut short when File Trail stopped. “2.jpg” is back under its old name; “3.jpg” is back under its old name."
                ])
            #expect(reopened.entries().isEmpty)
        }
    }

    // Items renamed from search results, one on a network share that hangs: the start goes on, and nothing of the
    // entry is put back until every folder answers.
    // T-51361091 F-356
    @Test func leavesARenameOfSeveralForLaterWhenAnyOfItsFoldersDoesntAnswer() throws {
        try withTemporaryDirectory { directory in
            let journal = FileWriteJournal.open(directory.path + "/replace-journal.json")
            let entry = WriteJournalEntry.batchRename(
                BatchRenameJournalEntry(
                    id: "rename",
                    items: [
                        .init(
                            temporaryPath: "/Users/me/Photos/.filetrail-rename-aaaaaaaaaaaa",
                            originalPath: "/Users/me/Photos/a.jpg", newPath: "/Users/me/Photos/b.jpg"),
                        .init(
                            temporaryPath: "/Volumes/Share/Photos/.filetrail-rename-bbbbbbbbbbbb",
                            originalPath: "/Volumes/Share/Photos/c.jpg", newPath: "/Volumes/Share/Photos/d.jpg"),
                    ]))
            try journal.add(entry)
            let fileSystem = MockWriteServiceFileSystem([
                ("/Users/me/Photos/.filetrail-rename-aaaaaaaaaaaa", .file(size: 1)),
                ("/Volumes/Share/Photos/.filetrail-rename-bbbbbbbbbbbb", .file(size: 1)),
            ])
            let renames = Locked(0)
            fileSystem.renameImpl = { _, _ in renames.mutate { $0 += 1 } }
            let hang = Hang()
            defer { hang.release() }
            hang.under(fileSystem, "/Volumes/Share")
            let started = Date()

            let report = recoverWrites(
                journal, fileSystem, logger: RecordingLogger().logger, answerWithinMs: 1_000)

            #expect(Date().timeIntervalSince(started) < 10)
            #expect(report.notices.isEmpty)
            #expect(renames.value == 0)
            #expect(fileSystem.exists("/Users/me/Photos/.filetrail-rename-aaaaaaaaaaaa"))
            #expect(journal.entries() == [entry])
        }
    }
}
