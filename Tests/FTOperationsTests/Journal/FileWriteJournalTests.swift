// Port of the openWriteJournal cases of apps/desktop/src/main/bootstrap/writeJournal.test.ts
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct FileWriteJournalTests {
    private func entry(_ directory: TemporaryDirectory, _ id: String, staged: Bool = true) -> WriteJournalEntry {
        .replace(
            ReplaceJournalEntry(
                id: id, stagingPath: directory.path + "/.\(id).txt.filetrail-00000000",
                finalPath: directory.path + "/\(id).txt", sourcePath: directory.path + "/source/\(id).txt",
                moved: false, staged: staged))
    }

    // T-ca751261
    @Test func keepsItsEntriesAcrossAReopen() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath)
            try journal.add(entry(directory, "a"))
            try journal.add(entry(directory, "b"))

            let reopened = FileWriteJournal.open(filePath)

            #expect(reopened.entries() == [entry(directory, "a"), entry(directory, "b")])
            // Written in one piece: no temporary file is left next to it.
            #expect(!Disk.exists(filePath + ".tmp"))
        }
    }

    // T-e034bee2
    @Test func replacesAnEntryAddedAgainWithTheSameId() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath)
            try journal.add(entry(directory, "a", staged: false))
            try journal.add(entry(directory, "a", staged: true))

            #expect(journal.entries() == [entry(directory, "a", staged: true)])
            #expect(FileWriteJournal.open(filePath).entries() == [entry(directory, "a", staged: true)])
        }
    }

    // T-09fd9df2
    @Test func takesOutARemovedEntryOnDiskToo() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath)
            try journal.add(entry(directory, "a"))
            try journal.add(entry(directory, "b"))
            try journal.remove("a")
            // Removing one that isn't there changes nothing.
            try journal.remove("missing")

            #expect(journal.entries() == [entry(directory, "b")])
            #expect(FileWriteJournal.open(filePath).entries() == [entry(directory, "b")])
        }
    }

    // The journal is on the startup disk: when that is full, the copy to another disk with room isn't blamed on the
    // destination.
    // T-baf8d9d1
    @Test func saysTheStartupDiskIsFullWhenItCantBeWrittenForLackOfSpace() async throws {
        try await withTemporaryDirectory { directory in
            let journal = FileWriteJournal.open(directory.path + "/replace-journal.json") { path, _ in
                throw NativeError.errno(ENOSPC, syscall: "open", path: path + ".tmp")
            }
            let source = directory.path + "/source"
            let destination = directory.path + "/destination"
            try Disk.write(source + "/Photos/a.jpg", "a")
            try Disk.makeDirectories(destination)

            let run = try await runPaste(
                mode: .copy, sources: [source + "/Photos"], into: destination,
                fileSystem: NativePaste.asOnAnotherDisk(source), writeJournal: journal)

            #expect(
                run.result?.items.map { [$0.status.rawValue, $0.error ?? ""] } == [
                    [
                        "failed",
                        "File Trail couldn't save its recovery information because the startup disk is full. Free some space there and try again.",
                    ]
                ])
            #expect(Disk.list(destination) == [])
        }
    }

    // The original shows this through a rename of several (P3-08's); the journal's own failure is what it says.
    // T-e596cc6d
    @Test func saysItCouldntSaveItsRecoveryInformationWhenItCantBeWrittenOtherwise() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath) { path, _ in
                throw NativeError.errno(EIO, syscall: "open", path: path + ".tmp")
            }
            #expect(
                throws: OperationError.self,
                performing: { try journal.add(entry(directory, "a")) })
            do {
                try journal.add(entry(directory, "a"))
            } catch {
                #expect(errorMessage(error) == "File Trail couldn't save its recovery information.")
            }
            // A temporary file that can't be made is the disk's own failure, said the same way.
            try Disk.makeDirectories(filePath + ".tmp")
            do {
                try FileWriteJournal.open(filePath).add(entry(directory, "b"))
                Issue.record("the write should have failed")
            } catch {
                #expect(errorMessage(error) == "File Trail couldn't save its recovery information.")
            }
        }
    }

    // T-39c8a445
    @Test func opensEmptyWhenTheFileIsMissingUnreadableAsJSONOrNotAListOfEntries() throws {
        try withTemporaryDirectory { directory in
            #expect(FileWriteJournal.open(directory.path + "/missing.json").entries() == [])

            let corrupt = directory.path + "/corrupt.json"
            try Disk.write(corrupt, #"[{"id": "a", "stagingPa"#)
            #expect(FileWriteJournal.open(corrupt).entries() == [])
            // What it may still say is kept aside, not written over by the next Replace.
            let keptAside = Disk.list(directory.path).filter { $0.hasPrefix("corrupt.json.unreadable-") }
            #expect(keptAside.count == 1)
            #expect(Disk.read(directory.path + "/" + (keptAside.first ?? "")) == #"[{"id": "a", "stagingPa"#)

            let notAList = directory.path + "/object.json"
            try Disk.write(notAList, #"{"id":"a"}"#)
            #expect(FileWriteJournal.open(notAList).entries() == [])

            // Entries of the wrong shape are dropped; good ones next to them are kept.
            let mixed = directory.path + "/mixed.json"
            let good = entry(directory, "good")
            try Disk.write(mixed, "[{\"id\":\"broken\"}," + JournalJSON.object(good.jsonObject) + "]")
            #expect(FileWriteJournal.open(mixed).entries() == [good])
        }
    }

    /// The file holds what JSON.stringify writes: the original's keys, and none it leaves out.
    @Test func writesEntriesAsTheOriginalDoes() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath)
            try journal.add(
                .replace(
                    ReplaceJournalEntry(
                        id: "0011223344556677", stagingPath: "/d/.f.filetrail-0a1b2c3d", finalPath: "/d/f",
                        sourcePath: "/s/f", moved: false, staged: false, movingCopy: true)))
            try journal.add(
                .partialFile(PartialFileJournalEntry(id: "8899aabbccddeeff", partialPath: "/d/.b", finalPath: "/d/b")))

            #expect(
                Disk.read(filePath)
                    == #"[{"id":"0011223344556677","stagingPath":"/d/.f.filetrail-0a1b2c3d","finalPath":"/d/f","sourcePath":"/s/f","moved":false,"staged":false,"movingCopy":true},{"kind":"partial_file","id":"8899aabbccddeeff","partialPath":"/d/.b","finalPath":"/d/b"}]"#
            )
            #expect(FileWriteJournal.open(filePath).entries() == journal.entries())
        }
    }
}
