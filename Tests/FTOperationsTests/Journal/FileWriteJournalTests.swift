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

    // Only an entry added flushed is on the drive before the call returns; the other writes don't wait for that.
    @Test func flushesOnlyAnEntryAddedFlushed() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let flushes = Locked<[Bool]>([])
            let journal = FileWriteJournal.open(filePath) { path, contents, flush in
                flushes.mutate { $0.append(flush) }
                try FileWriteJournal.writeWhole(path, contents, flush: flush)
            }

            try journal.add(entry(directory, "a"))
            try journal.addFlushed(entry(directory, "b"))
            try journal.remove("a")

            #expect(flushes.value == [false, true, false])
            #expect(FileWriteJournal.open(filePath).entries() == [entry(directory, "b")])
            #expect(!Disk.exists(filePath + ".tmp"))
        }
    }

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

    // The journal's own failure is what it says.
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

    /// The file holds each entry's keys in a fixed order, and none an entry leaves out.
    @Test func writesEntriesInTheJournalsFormat() throws {
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

    /// A rename of several is kept in the same format: its kind, its id and each item's three paths.
    @Test func writesARenameOfSeveralInTheJournalsFormat() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let journal = FileWriteJournal.open(filePath)
            try journal.add(
                .batchRename(
                    BatchRenameJournalEntry(
                        id: "0123456789abcdef",
                        items: [
                            .init(
                                temporaryPath: "/d/.filetrail-rename-0a1b2c3d4e5f", originalPath: "/d/a",
                                newPath: "/d/b"),
                            .init(
                                temporaryPath: "/d/.filetrail-rename-a0b1c2d3e4f5", originalPath: "/d/b",
                                newPath: "/d/a"),
                        ])))

            #expect(
                Disk.read(filePath)
                    == #"[{"kind":"batch_rename","id":"0123456789abcdef","items":[{"temporaryPath":"/d/.filetrail-rename-0a1b2c3d4e5f","originalPath":"/d/a","newPath":"/d/b"},{"temporaryPath":"/d/.filetrail-rename-a0b1c2d3e4f5","originalPath":"/d/b","newPath":"/d/a"}]}]"#
            )
            #expect(FileWriteJournal.open(filePath).entries() == journal.entries())
        }
    }

    // Paths are written by hand: a quote, a backslash, a line break, a tab, a control character, a name stored
    // decomposed and one beyond the basic plane come back as they were, byte for byte. One that didn't would set the
    // whole journal aside, and the items it guards with it.
    @Test func readsBackEveryCharacterAPathCanHold() throws {
        try withTemporaryDirectory { directory in
            let filePath = directory.path + "/replace-journal.json"
            let name = "q\"b\\n\nr\rt\tc\u{01}u\u{1F}d\u{7F}e\u{301}\u{1F600}"
            let written = WriteJournalEntry.replace(
                ReplaceJournalEntry(
                    id: "1", stagingPath: "/d/.\(name).filetrail-0a1b2c3d", finalPath: "/d/\(name)",
                    sourcePath: "/s/\(name)", moved: true, staged: true))
            let journal = FileWriteJournal.open(filePath)
            try journal.add(written)

            let text = try #require(Disk.read(filePath))
            #expect(text.contains(#"q\"b\\n\nr\rt\tc\u0001u\u001fd"#))
            let read = FileWriteJournal.open(filePath).entries()
            #expect(read == [written])
            // Swift's == takes a name composed and decomposed as one: the scalars tell them apart.
            guard case .replace(let entry)? = read.first else {
                Issue.record("no entry read back")
                return
            }
            for (back, path) in [
                (entry.stagingPath, "/d/.\(name).filetrail-0a1b2c3d"), (entry.finalPath, "/d/\(name)"),
                (entry.sourcePath, "/s/\(name)"),
            ] {
                #expect(Array(back.unicodeScalars) == Array(path.unicodeScalars))
            }
        }
    }
}
