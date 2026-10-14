// Port of the recovery cases of packages/core/src/fs/copyPasteRecovery.test.ts (its large-file copying cases are in
// Execution/)
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// Looking anything up under `folder` doesn't come back until `release` (a network disk that hangs); the test lets
/// go of it once it is done, so no thread is left waiting.
final class Hang: Sendable {
    private let gate = DispatchSemaphore(value: 0)

    func under(_ fileSystem: MockWriteServiceFileSystem, _ folder: String) {
        fileSystem.lstatImpl = { [gate] path in
            if path == folder || path.hasPrefix(folder + "/") {
                gate.wait()
                gate.signal()
            }
            return try fileSystem.lstatDirectly(path)
        }
    }

    func release() {
        gate.signal()
    }
}

/// How long a test lets a disk take to answer (the original's fake timers stand at 1000 ms).
private let answerWithinMs = 1_000

struct ReplaceRecoveryAtStartTests {
    // T-2438126e F-353 F-525
    @Test func leavesAnEntryForLaterUntouchedWhenItsOriginalsDiskDoesntAnswer() {
        let fileSystem = MockWriteServiceFileSystem([
            ("/away/a.txt", .file(size: 1)), ("/target/.a.txt.filetrail-0000abcd", .file(size: 1)),
            ("/target/a.txt", .file(size: 2)),
        ])
        let hang = Hang()
        defer { hang.release() }
        hang.under(fileSystem, "/away")
        let entry = ReplaceJournalEntry(
            id: "1", stagingPath: "/target/.a.txt.filetrail-0000abcd", finalPath: "/target/a.txt",
            sourcePath: "/away/a.txt", moved: true, staged: true)
        let started = Date()

        let outcomes = recoverInterruptedReplaces(
            [entry], fileSystem, RecoveryOptions(answerWithinMs: answerWithinMs))

        #expect(Date().timeIntervalSince(started) < 10)
        #expect(outcomes == [ReplaceRecovery(entry: entry, outcome: .unreachable(error: "The disk didn't answer."))])
        #expect(fileSystem.exists("/target/.a.txt.filetrail-0000abcd"))
        #expect(fileSystem.readNode("/target/a.txt")?.size == 2)
    }

    // A copy never goes back to its original's place: a share there that hangs doesn't hold up the copy, already
    // whole, from being put in place.
    // T-592ef0a4 F-353 F-525
    @Test func putsACopyInPlaceWhenOnlyItsOriginalsDiskDoesntAnswer() {
        let fileSystem = MockWriteServiceFileSystem([
            ("/away/a.txt", .file(size: 1)), ("/target/.a.txt.filetrail-0000abcd", .file(size: 1)),
        ])
        let hang = Hang()
        defer { hang.release() }
        hang.under(fileSystem, "/away")
        let entry = ReplaceJournalEntry(
            id: "1", stagingPath: "/target/.a.txt.filetrail-0000abcd", finalPath: "/target/a.txt",
            sourcePath: "/away/a.txt", moved: false, staged: true)

        let outcomes = recoverInterruptedReplaces(
            [entry], fileSystem, RecoveryOptions(answerWithinMs: answerWithinMs))

        #expect(outcomes == [ReplaceRecovery(entry: entry, outcome: .finished(path: "/target/a.txt"))])
        #expect(fileSystem.readNode("/target/a.txt")?.size == 1)
    }

    // Only an item under a hidden name this app makes is ever moved or removed: a record that names anything else
    // (a journal written wrong) leaves it alone.
    // T-0bb5550b F-347 F-525
    @Test func leavesAloneAnItemThatIsntUnderAHiddenNameOfThisApps() {
        let fileSystem = MockWriteServiceFileSystem([("/target/notes.txt", .file(size: 3))])
        let entry = ReplaceJournalEntry(
            id: "1", stagingPath: "/target/notes.txt", finalPath: "/target/a.txt", sourcePath: "/source/a.txt",
            moved: false, staged: false)

        #expect(
            recoverInterruptedReplaces([entry], fileSystem) == [ReplaceRecovery(entry: entry, outcome: .nothingLeft)])
        #expect(fileSystem.readNode("/target/notes.txt")?.size == 3)
    }
}

struct PartialFileRemovalTests {
    private static let folder = "/target/.movie.mov.filetrail-0000abcd"
    /// Written by builds after v0.4.3 that were never released: the part was copied as "part" in a hidden folder
    /// of its own (written down with the folder's id, no longer read).
    private static let legacyEntry = PartialFileJournalEntry(
        id: "p", partialPath: folder + "/part", finalPath: "/target/movie.mov")
    private static let part = "/target/.movie.mov.filetrail-0000abcd"
    private static let entry = PartialFileJournalEntry(id: "p", partialPath: part, finalPath: "/target/movie.mov")

    // T-22bd6a05 F-526
    @Test func removesTheHiddenFolderABuildAfterV043CopiedItIn() {
        let fileSystem = MockWriteServiceFileSystem([
            (Self.folder, .directory()), (Self.folder + "/part", .file(size: 9)),
        ])

        let outcomes = recoverPartialFiles([Self.legacyEntry], fileSystem)

        #expect(outcomes.map(\.outcome) == [.removedCopy])
        #expect(!fileSystem.exists(Self.folder))
    }

    // T-8399d35f F-526
    @Test func findsNothingLeftOnceThatFolderIsGone() {
        let fileSystem = MockWriteServiceFileSystem([("/target", .directory())])

        #expect(recoverPartialFiles([Self.legacyEntry], fileSystem).map(\.outcome) == [.nothingLeft])
    }

    // T-24b6ef42 F-526
    @Test func leavesAPartForLaterWhenItsDiskDoesntAnswerOrAnotherWriteRuns() {
        let fileSystem = MockWriteServiceFileSystem([(Self.part, .file(size: 9))])

        #expect(
            recoverPartialFiles([Self.entry], fileSystem, RecoveryOptions(runWriteAlone: { _ in false }))
                == [PartialFileRecovery(entry: Self.entry, outcome: .deferred)])
        let hang = Hang()
        defer { hang.release() }
        hang.under(fileSystem, "/target")
        #expect(
            recoverPartialFiles([Self.entry], fileSystem, RecoveryOptions(answerWithinMs: answerWithinMs))
                == [PartialFileRecovery(entry: Self.entry, outcome: .unreachable(error: "The disk didn't answer."))])
        hang.release()
        fileSystem.lstatImpl = nil
        #expect(fileSystem.exists(Self.part))
    }

    // T-e52d860b F-526
    @Test func saysWhyAPartCouldntBeRemoved() {
        let fileSystem = MockWriteServiceFileSystem([(Self.part, .file(size: 9))])
        fileSystem.rmImpl = { _, _, _ in throw codedError("EIO", "EIO: i/o error") }

        let outcomes = recoverPartialFiles(
            [Self.entry], fileSystem,
            RecoveryOptions(runWriteAlone: { write in
                write()
                return true
            }))

        #expect(outcomes.count == 1)
        if case .failed(let error)? = outcomes.first?.outcome {
            #expect(!error.isEmpty)
        } else {
            Issue.record("Not failed: \(String(describing: outcomes.first?.outcome))")
        }
        #expect(fileSystem.exists(Self.part))
    }

    // T-1ca9e8c1 F-526 F-354
    @Test func removesAPartByItsHiddenName() {
        let fileSystem = MockWriteServiceFileSystem([(Self.part, .file(size: 9))])

        #expect(recoverPartialFiles([Self.entry], fileSystem).map(\.outcome) == [.removedCopy])
        #expect(!fileSystem.exists(Self.part))
    }
}
