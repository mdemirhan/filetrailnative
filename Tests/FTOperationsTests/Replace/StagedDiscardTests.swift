// Port of packages/core/src/fs/copyPasteStagedDiscard.test.ts: a complete hidden copy given up, whose removal stops
// part way
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct StagedDiscardTests {
    /// Removing a hidden copy takes one item in it away, then the disk errs: what is left is only part of the copy.
    private func failRemovingHiddenCopiesPartWay(_ fileSystem: MockWriteServiceFileSystem) {
        fileSystem.rmImpl = { path, _, _ in
            if !path.contains(".filetrail-") {
                throw codedError("EPERM")
            }
            if let inside = fileSystem.paths.first(where: { $0.hasPrefix(path + "/") }) {
                fileSystem.deleteNode(inside)
            }
            throw codedError("EIO")
        }
    }

    private func paste(
        _ fileSystem: MockWriteServiceFileSystem, policy: CopyPastePolicy, journal: ReplaceEntriesJournal
    ) async throws -> CopyPasteOperationResult {
        let operation = try createResolvedOperation(
            fileSystem, sources: ["/source/dir"], into: "/target", policy: policy)
        let events = await execute(fileSystem, operation, operationId: "op-1", policy: policy, writeJournal: journal)
        return try #require(events.last?.result, "The paste didn't finish.")
    }

    private func hiddenCopies(_ fileSystem: MockWriteServiceFileSystem) -> [String] {
        fileSystem.paths.filter { path in
            guard let range = path.range(of: "/.dir.filetrail-", options: .backwards) else { return false }
            let rest = path[range.upperBound...]
            return !rest.isEmpty && rest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
    }

    private func dirSource() -> MockWriteServiceFileSystem {
        MockWriteServiceFileSystem([("/source/dir/a.txt", .file(size: 1)), ("/source/dir/b.txt", .file(size: 2))])
    }

    // T-7797882e F-507
    @Test func isRemovedAtTheNextStartNotPutInPlaceAsIfWhole() async throws {
        let fileSystem = dirSource()
        fileSystem.addDirectory("/target")
        // Complete, but it can't take its name.
        fileSystem.renameImpl = { from, to in
            if to == "/target/dir" {
                throw codedError("EIO")
            }
            try fileSystem.renameDirectly(from, to)
        }
        let journal = ReplaceEntriesJournal()
        journal.onAdd = { [self] entry in
            if entry.staged {
                failRemovingHiddenCopiesPartWay(fileSystem)
            }
        }

        let result = try await paste(
            fileSystem, policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip), journal: journal)

        #expect(result.status == .failed)
        let entries = journal.live
        #expect(entries.map(\.staged) == [false])
        #expect(hiddenCopies(fileSystem).count == 1)

        // The next start.
        fileSystem.rmImpl = nil
        fileSystem.renameImpl = nil
        let outcomes = recoverInterruptedReplaces(entries, fileSystem)

        #expect(outcomes.map(\.outcome) == [.removedCopy])
        #expect(!fileSystem.exists("/target/dir"))
        #expect(hiddenCopies(fileSystem) == [])
    }

    // T-1de855e4 F-507 F-345
    @Test func isRemovedAtTheNextStartWhenAReplaceIsUndone() async throws {
        let fileSystem = dirSource()
        fileSystem.addFile("/target/dir/old.txt", .file(size: 3))
        fileSystem.enableTrash()
        let journal = ReplaceEntriesJournal()
        journal.onAdd = { [self] entry in
            if entry.staged {
                // Another app deletes the folder being replaced: the Replace is undone.
                for key in fileSystem.paths where key == "/target/dir" || key.hasPrefix("/target/dir/") {
                    fileSystem.deleteNode(key)
                }
                failRemovingHiddenCopiesPartWay(fileSystem)
            }
        }

        let result = try await paste(fileSystem, policy: NativePaste.replaceAll, journal: journal)

        #expect(result.status == .failed)
        let entries = journal.live
        #expect(entries.map(\.staged) == [false])

        fileSystem.rmImpl = nil
        let outcomes = recoverInterruptedReplaces(entries, fileSystem)

        #expect(outcomes.map(\.outcome) == [.removedCopy])
        #expect(!fileSystem.exists("/target/dir"))
        #expect(hiddenCopies(fileSystem) == [])
    }

    // T-ab0f33ba F-507
    @Test func isLeftWholeForTheNextStartToPutInPlaceWhenItsRecordCantBeChanged() async throws {
        let fileSystem = dirSource()
        fileSystem.addDirectory("/target")
        fileSystem.renameImpl = { from, to in
            if to == "/target/dir" {
                throw codedError("EIO")
            }
            try fileSystem.renameDirectly(from, to)
        }
        let journal = ReplaceEntriesJournal()
        let journalWorks = Locked(true)
        journal.refuseAdd = { journalWorks.value ? nil : codedError("EIO") }
        journal.onAdd = { entry in
            if entry.staged {
                journalWorks.mutate { $0 = false }
            }
        }

        _ = try await paste(
            fileSystem, policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip), journal: journal)

        #expect(journal.live.map(\.staged) == [true])
        let hidden = try #require(hiddenCopies(fileSystem).first)
        #expect(fileSystem.exists(hidden + "/a.txt"))
        #expect(fileSystem.exists(hidden + "/b.txt"))
    }
}
