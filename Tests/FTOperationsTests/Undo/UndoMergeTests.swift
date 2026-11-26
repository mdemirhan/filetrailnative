// Undo and Redo of a folder merged into one of its name already there, on a real disk, through the write coordinator:
// each item put in goes back on its own, a folder a move removed is made again with what it had, and what changed
// since is left and said.
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoMergeTests {
    private func items(_ end: WriteOperationEvent) -> [WriteOperationItem] { end.result?.items ?? [] }

    /// Folders merge, and a file replaces the one of its name.
    private static let mergeAndReplace = CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip)
    private static let tagsName = "com.apple.metadata:_kMDItemUserTags"

    /// `src/F` and `dst/F`, each with the files given (a path in it ending in "/" is a folder).
    private func folders(_ root: String, source: [String], destination: [String]) throws -> (src: String, dst: String) {
        let (src, dst) = ("\(root)/src", "\(root)/dst")
        try UndoDisk.mkdir("\(src)/F")
        try UndoDisk.mkdir("\(dst)/F")
        for (folder, names) in [(src, source), (dst, destination)] {
            for name in names {
                if name.hasSuffix("/") {
                    try UndoDisk.mkdir("\(folder)/F/\(name)")
                } else {
                    try UndoDisk.mkdir(NodePath.dirname("\(folder)/F/\(name)"))
                    try UndoDisk.write("\(folder)/F/\(name)", "\(folder == src ? "new" : "old") \(name)")
                }
            }
        }
        return (src, dst)
    }

    private func withPasteTrash(_ root: String) throws -> NativeWriteFileSystem {
        try UndoDisk.mkdir("\(root)/.PasteTrash")
        return NativePaste.withTrash("\(root)/.PasteTrash")
    }

    // MARK: Copies

    @Test func movesWhatACopyPutIntoTheFolderToTheTrashAndPutsItBackOnRedo() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["new.txt", "Sub/deep.txt"], destination: ["old.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.copy, ["\(src)/F"], into: dst)
            #expect(UndoDisk.names("\(dst)/F") == ["Sub", "new.txt", "old.txt"])
            #expect(t.history.menu().undo == "Copy of \u{201C}F\u{201D}")

            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(dst)/F") == ["old.txt"])
            #expect(t.inTrash() == ["1-new.txt", "2-Sub"])
            #expect(UndoDisk.names("\(src)/F") == ["Sub", "new.txt"])
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Copy of \u{201C}F\u{201D}", cantUndo: false))

            #expect(try await t.undo(.redo).status == .completed)
            #expect(UndoDisk.names("\(dst)/F") == ["Sub", "new.txt", "old.txt"])
            #expect(try UndoDisk.read("\(dst)/F/Sub/deep.txt") == "new Sub/deep.txt")
            #expect(t.inTrash() == [])
            await t.shutDown()
        }
    }

    // A copy that replaced files in the folder: Undo moves the copies to the Trash and puts back what they replaced.
    @Test func putsBackWhatACopyReplacedInsideTheFolder() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "Sub/b.txt"], destination: ["a.txt", "Sub/b.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(
                .copy, ["\(src)/F"], into: dst, policy: Self.mergeAndReplace, fileSystem: try withPasteTrash(root))
            #expect(try UndoDisk.read("\(dst)/F/Sub/b.txt") == "new Sub/b.txt")

            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(dst)/F/a.txt") == "old a.txt")
            #expect(try UndoDisk.read("\(dst)/F/Sub/b.txt") == "old Sub/b.txt")
            #expect(UndoDisk.names("\(root)/.PasteTrash") == [])
            // Newest first: "Sub" comes before "a.txt", so "a.txt" was copied last.
            #expect(t.inTrash() == ["1-a.txt", "2-b.txt"])

            #expect(try await t.undo(.redo).status == .completed)
            #expect(try UndoDisk.read("\(dst)/F/a.txt") == "new a.txt")
            #expect(try UndoDisk.read("\(dst)/F/Sub/b.txt") == "new Sub/b.txt")
            await t.shutDown()
        }
    }

    // MARK: Moves

    // The folder a move took every item out of is made again where it was, its items moved back into it: the same
    // items (their file ids), the folder with its tags, Hidden flag, mode and date.
    @Test func makesTheFolderAMoveRemovedAgainAndMovesItsItemsBack() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "Sub/b.txt"], destination: ["old.txt", "Sub/"])
            let tags = Data("tags".utf8)
            try NativeFS.setExtendedAttribute("\(src)/F", Self.tagsName, tags)
            #expect(Darwin.chmod("\(src)/F", 0o750) == 0)
            try NativeFS.utimes("\(src)/F", atimeMs: 1_600_000_000_000, mtimeMs: 1_600_000_000_000)
            #expect(chflags("\(src)/F", UInt32(UF_HIDDEN)) == 0)
            try addAccessRule("\(src)/F", "everyone allow list")
            let acl = try #require(try NativeFS.getAcl("\(src)/F"))
            let (a, b) = (UndoDisk.ino("\(src)/F/a.txt"), UndoDisk.ino("\(src)/F/Sub/b.txt"))
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(t.history.menu().undo == "Move of \u{201C}F\u{201D}")

            let undone = try await t.undo()
            #expect(undone.status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["Sub", "a.txt"])
            #expect(UndoDisk.ino("\(src)/F/a.txt") == a)
            #expect(UndoDisk.ino("\(src)/F/Sub/b.txt") == b)
            #expect(UndoDisk.names("\(dst)/F") == ["Sub", "old.txt"])
            #expect(UndoDisk.names("\(dst)/F/Sub") == [])
            #expect(try NativeFS.extendedAttributes("\(src)/F")[Self.tagsName] == tags)
            let made = try #require(Disk.lstat("\(src)/F"))
            #expect(made.mode & 0o7777 == 0o750)
            #expect(made.mtimeMs == 1_600_000_000_000)
            #expect(Disk.flags("\(src)/F") & UInt32(UF_HIDDEN) != 0)
            #expect(try NativeFS.getAcl("\(src)/F") == acl)
            // Said as a folder made, never as a move from the folder its items were in.
            #expect(
                items(undone).first
                    == WriteOperationItem(
                        sourcePath: nil, destinationPath: "\(src)/F", status: .completed))
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Move of \u{201C}F\u{201D}", cantUndo: false))

            let redone = try await t.undo(.redo)
            #expect(redone.status == .completed)
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(UndoDisk.names("\(dst)/F") == ["Sub", "a.txt", "old.txt"])
            #expect(UndoDisk.ino("\(dst)/F/Sub/b.txt") == b)
            #expect(
                items(redone).last
                    == WriteOperationItem(sourcePath: "\(src)/F", destinationPath: nil, status: .completed))

            // And again: made again with what it had, its date too, though its items left it on the way.
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["Sub", "a.txt"])
            #expect(try NativeFS.extendedAttributes("\(src)/F")[Self.tagsName] == tags)
            #expect(Disk.lstat("\(src)/F")?.mtimeMs == 1_600_000_000_000)
            await t.shutDown()
        }
    }

    // An empty folder merged into one of its name by a move is only removed: Undo makes it again, Redo removes it.
    @Test func makesAnEmptyFolderAMergingMoveRemovedAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: [], destination: ["old.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            #expect(!UndoDisk.exists("\(src)/F"))

            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.isDirectory("\(src)/F"))
            #expect(UndoDisk.names("\(src)/F") == [])
            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.exists("\(src)/F"))
            await t.shutDown()
        }
    }

    @Test func putsBackWhatAMoveReplacedInsideTheFolder() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: ["a.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(
                .cut, ["\(src)/F"], into: dst, policy: Self.mergeAndReplace, fileSystem: try withPasteTrash(root))
            #expect(!UndoDisk.exists("\(src)/F"))

            #expect(try await t.undo().status == .completed)
            #expect(try UndoDisk.read("\(src)/F/a.txt") == "new a.txt")
            #expect(try UndoDisk.read("\(dst)/F/a.txt") == "old a.txt")
            #expect(UndoDisk.names("\(root)/.PasteTrash") == [])

            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(try UndoDisk.read("\(dst)/F/a.txt") == "new a.txt")
            #expect(t.inTrash() == ["1-a.txt"])
            await t.shutDown()
        }
    }

    // A folder an item was left in stays: Undo moves the others back into it, and asks first when one's name was
    // taken there since.
    @Test func putsAnItemBackUnderANumberWhenItsNameInTheFolderLeftWasTaken() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["same.txt", "b.txt"], destination: ["same.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            #expect(UndoDisk.names("\(src)/F") == ["same.txt"])
            try UndoDisk.write("\(src)/F/b.txt", "another")

            let prepared = try await t.prepare()
            #expect(prepared.nameTaken == ["b.txt"])
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["b 2.txt", "b.txt", "same.txt"])
            #expect(try UndoDisk.read("\(src)/F/b 2.txt") == "new b.txt")
            #expect(try UndoDisk.read("\(src)/F/b.txt") == "another")
            await t.shutDown()
        }
    }

    // MARK: What changed since

    @Test func leavesAnItemGoneSinceAndPutsTheOthersBack() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try UndoDisk.remove("\(dst)/F/a.txt")

            let undone = try await t.undo()
            #expect(undone.status == .partial)
            #expect(UndoDisk.names("\(src)/F") == ["b.txt"])
            #expect(
                items(undone).filter { $0.status == .skipped }.map(\.error)
                    == ["\u{201C}a.txt\u{201D} is no longer in \u{201C}F\u{201D}."])
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: "Move of \u{201C}F\u{201D}", cantUndo: false))
            await t.shutDown()
        }
    }

    // Every item went away since: no folder is made for none of them to go back to, and there is nothing to redo.
    @Test func makesNoFolderWhenNoneOfItsItemsCanGoBack() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try UndoDisk.remove("\(dst)/F/a.txt")
            try UndoDisk.remove("\(dst)/F/b.txt")

            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(items(undone).count == 2 && items(undone).allSatisfy { $0.status == .skipped })
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    // Another item took the folder's name where it was: nothing is moved into it, and the items stay where the merge
    // put them.
    @Test func leavesTheItemsWhereTheMergePutThemWhenAnotherItemTookTheFoldersName() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try UndoDisk.mkdir("\(src)/F")
            try UndoDisk.write("\(src)/F/theirs.txt", "theirs")

            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(
                items(undone).map(\.error) == [
                    "\u{201C}F\u{201D} wasn\u{2019}t made again for its items to go back to, because another item named \u{201C}F\u{201D} is in \u{201C}src\u{201D} now."
                ])
            #expect(UndoDisk.names("\(src)/F") == ["theirs.txt"])
            #expect(UndoDisk.names("\(dst)/F") == ["a.txt"])
            #expect(t.history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
            await t.shutDown()
        }
    }

    @Test func leavesTheItemsWhereTheyAreWhenTheFolderTheFolderWasInIsGone() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try UndoDisk.remove(src)

            let undone = try await t.undo()
            #expect(undone.status == .failed)
            #expect(items(undone).map(\.error) == ["Its folder \u{201C}src\u{201D} no longer exists."])
            #expect(UndoDisk.names("\(dst)/F") == ["a.txt"])
            await t.shutDown()
        }
    }

    // Redo leaves the folder Undo made again when something else was put in it since: only its own items leave.
    @Test func leavesTheFolderMadeAgainOnRedoWhenSomethingElseWasPutInIt() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try await t.undo()
            try UndoDisk.write("\(src)/F/extra.txt", "extra")

            #expect(try await t.undo(.redo).status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["extra.txt"])
            #expect(UndoDisk.names("\(dst)/F") == ["a.txt"])
            // Undo again moves it back into the folder that stayed.
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["a.txt", "extra.txt"])
            await t.shutDown()
        }
    }

    // Finder's view settings alone don't keep it: they go with it, as when the merge removed it.
    @Test func removesTheFolderMadeAgainOnRedoWithFindersViewSettingsInIt() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            try await t.undo()
            try UndoDisk.write("\(src)/F/.DS_Store", "view")

            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.exists("\(src)/F"))
            await t.shutDown()
        }
    }

    // MARK: The rest of the history

    // An operation before the merge knew the folder by the id it had then: it is undone in the folder made again.
    @Test func undoesWhatWasDoneInTheFolderBeforeAMergeRemovedIt() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt"], destination: [])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.rename("\(src)/F/a.txt", "b.txt")
            try await t.newFolder("\(src)/F", "New")
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            #expect(!UndoDisk.exists("\(src)/F"))

            for _ in 0..<3 {
                #expect(try await t.undo().status == .completed)
            }
            #expect(UndoDisk.names("\(src)/F") == ["a.txt"])
            #expect(t.inTrash() == ["1-New"])
            #expect(UndoDisk.names("\(dst)/F") == [])
            // And Redo of all three.
            for _ in 0..<3 {
                #expect(try await t.undo(.redo).status == .completed)
            }
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(UndoDisk.names("\(dst)/F") == ["New", "b.txt"])
            await t.shutDown()
        }
    }

    // Stopped after the folder was made again and an item moved back: the next Undo moves the rest into that folder.
    @Test func goesOnWithTheFolderMadeAgainAfterAStop() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt", "c.txt"], destination: [])
            let stopping = UndoFlag()
            let stop = StopButton()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    try base.renameExclusive(from, to)
                    if stopping.take() { stop.press() }
                }
            }
            stop.test = t
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            stopping.set(true)

            let stopped = try await t.undo()
            #expect(stopped.status == .partial)
            #expect(UndoDisk.names("\(src)/F").count == 1)
            #expect(t.history.menu().undo == "Move of \u{201C}F\u{201D}")

            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)") == ["F"])
            #expect(UndoDisk.names("\(src)/F") == ["a.txt", "b.txt", "c.txt"])
            #expect(UndoDisk.names("\(dst)/F") == [])
            await t.shutDown()
        }
    }

    // A stopped Undo, then Redo of what it did, which removes the folder again, then Undo of both: the folder is made
    // again once more, and the items left by the stop go back into it, as it is known by its newest id.
    @Test func getsEveryItemBackThroughAStoppedUndoARedoAndTwoUndos() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt", "c.txt"], destination: ["old.txt"])
            let stopping = UndoFlag()
            let stop = StopButton()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    try base.renameExclusive(from, to)
                    if stopping.take() { stop.press() }
                }
            }
            stop.test = t
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            stopping.set(true)
            #expect(try await t.undo().status == .partial)
            #expect(UndoDisk.names("\(src)/F").count == 1)

            #expect(try await t.undo(.redo).status == .completed)
            #expect(!UndoDisk.exists("\(src)/F"))
            #expect(UndoDisk.names("\(dst)/F") == ["a.txt", "b.txt", "c.txt", "old.txt"])

            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)/F").count == 1)
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)") == ["F"])
            #expect(UndoDisk.names("\(src)/F") == ["a.txt", "b.txt", "c.txt"])
            #expect(UndoDisk.names("\(dst)/F") == ["old.txt"])
            #expect(t.history.top(.undo) == nil)
            await t.shutDown()
        }
    }

    // A write that failed (no permission) leaves the rest of the merge to the next Undo, which finishes it.
    @Test func triesAnItemWhoseMoveBackFailedAgainOnTheNextUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt"], destination: [])
            let failing = UndoFlag()
            let t = UndoTest(root: root, trashDir: trashDir) { fileSystem in
                let base = fileSystem.base
                fileSystem.renameExclusiveImpl = { from, to in
                    if NodePath.basename(from) == "a.txt", failing.take() {
                        throw codedError(.errno(EACCES), "EACCES: permission denied")
                    }
                    try base.renameExclusive(from, to)
                }
            }
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            failing.set(true)

            #expect(try await t.undo().status == .partial)
            #expect(UndoDisk.names("\(src)/F") == ["b.txt"])
            #expect(t.history.menu().undo == "Move of \u{201C}F\u{201D}")
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.names("\(src)/F") == ["a.txt", "b.txt"])
            await t.shutDown()
        }
    }

    @Test func namesTheMergeByTheFolderPickedInTheUndoHistory() async throws {
        try await withUndoFolder { root, trashDir in
            let (src, dst) = try folders(root, source: ["a.txt", "b.txt"], destination: ["old.txt"])
            let t = UndoTest(root: root, trashDir: trashDir)
            try await t.paste(.cut, ["\(src)/F"], into: dst)
            let entry = try #require(t.history.top(.undo))
            let row = UndoHistoryRows.row(entry, .undo, homePath: root)
            #expect(row.title == "Move of \u{201C}F\u{201D}")
            #expect(row.items == ["F"])
            #expect(row.place == "src \u{2192} dst")
            // Counted as the Undo counts: its two items and the folder made again.
            #expect(UndoHistory.itemStepCount(entry.units) == 3)
            await t.shutDown()
        }
    }
}
