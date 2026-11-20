// A paste of items put on the clipboard some to copy and some to move: each picked item goes as it was put on, in one
// review, one run and one Undo; and two items of one name the person chose to keep both of take names of their own
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct MixedPasteTests {
    // MARK: The request

    @Test func aRequestKeepsTheItemsMovedOnlyAmongItsItems() {
        let request = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/a/x.txt", "/b/y.txt", "/a/x.txt"], destinationDirectoryPath: "/d",
                cutSourcePaths: ["/b/y.txt", "/elsewhere/z.txt"], renamedIfSharedSourcePaths: ["/gone.txt"]))
        #expect(request.mode == .copy)
        #expect(request.sourcePaths == ["/a/x.txt", "/b/y.txt"])
        #expect(request.cutSourcePaths == ["/b/y.txt"])
        #expect(request.renamedIfSharedSourcePaths == nil)
        #expect(request.isMixed)
        #expect(request.movedSourcePaths == ["/b/y.txt"])
    }

    @Test func aRequestWhoseEveryItemIsMovedIsAMoveAndOneWithNoneACopy() {
        let all = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/a/x.txt", "/b/y.txt"], destinationDirectoryPath: "/d",
                cutSourcePaths: ["/b/y.txt", "/a/x.txt"]))
        #expect(all.mode == .cut)
        #expect(all.cutSourcePaths == nil)
        #expect(!all.isMixed)
        #expect(all.movedSourcePaths == ["/a/x.txt", "/b/y.txt"])

        let none = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: ["/a/x.txt"], destinationDirectoryPath: "/d", cutSourcePaths: []))
        #expect(none.mode == .copy)
        #expect(none.cutSourcePaths == nil)
        #expect(none.movedSourcePaths.isEmpty)
    }

    @Test func aMoveIgnoresTheItemsNamedAsMoved() {
        let request = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: .cut, sourcePaths: ["/a/x.txt", "/b/y.txt"], destinationDirectoryPath: "/d",
                cutSourcePaths: ["/b/y.txt"]))
        #expect(request.mode == .cut)
        #expect(request.cutSourcePaths == nil)
        #expect(request.movedSourcePaths == ["/a/x.txt", "/b/y.txt"])
    }

    /// Two paths that differ only in how an accented letter is stored are two items, one moved and one copied.
    @Test func itemsAreToldApartByTheirExactBytes() {
        let nfc = "/a/caf\u{E9}.txt"
        let nfd = "/a/cafe\u{301}.txt"
        let request = normalizeCopyPasteAnalysisRequest(
            CopyPasteAnalysisRequest(
                mode: .copy, sourcePaths: [nfc, nfd], destinationDirectoryPath: "/d", cutSourcePaths: [nfd]))
        #expect(request.movedSourcePaths.map { Array($0.utf8) } == [Array(nfd.utf8)])
        let modes = CopyPasteItemModes(request)
        #expect(modes.mode(of: nfc) == .copy)
        #expect(modes.mode(of: nfd) == .cut)
    }

    // MARK: The review

    @Test func eachPickedItemOfAMixedReviewSaysWhatItDoes() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/copied.txt", "c")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/copied.txt", root.path + "/b/moved.txt"],
                into: root.path + "/d", cut: [root.path + "/b/moved.txt"])
            #expect(run.report.isMixed)
            #expect(run.report.cutSourcePaths == [root.path + "/b/moved.txt"])
            #expect(run.report.nodes.map(\.mode) == [.copy, .cut])
            #expect(run.report.nodes.map { run.report.mode(of: $0) } == [.copy, .cut])
            #expect(run.report.mode(ofSourcePath: root.path + "/b/moved.txt") == .cut)
            #expect(run.report.mode(ofSourcePath: root.path + "/a/copied.txt") == .copy)
        }
    }

    @Test func aReviewOfOneKindLeavesItsItemsWithoutAModeOfTheirOwn() throws {
        try withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/x.txt", "x")
            try Disk.makeDirectories(root.path + "/d")
            for mode in [CopyPasteMode.copy, .cut] {
                let report = try buildCopyPasteAnalysisReport(
                    analysisId: "one-kind",
                    request: CopyPasteAnalysisRequest(
                        mode: mode, sourcePaths: [root.path + "/a/x.txt"], destinationDirectoryPath: root.path + "/d"),
                    fileSystem: NativeWriteFileSystem())
                #expect(!report.isMixed)
                #expect(report.cutSourcePaths == nil)
                #expect(report.nodes.map(\.mode) == [nil])
                #expect(report.nodes.map { report.mode(of: $0) } == [mode])
            }
        }
    }

    /// Pasted into the folder they are in: the copied item is duplicated beside itself, the moved one is already in
    /// place and is told so, as each would be alone.
    @Test func intoTheirOwnFolderTheCopyIsDuplicatedAndTheMoveIsAlreadyInPlace() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/d/copied.txt", "c")
            try Disk.write(root.path + "/d/moved.txt", "m")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/d/copied.txt", root.path + "/d/moved.txt"],
                into: root.path + "/d", cut: [root.path + "/d/moved.txt"])
            #expect(run.report.issues.map(\.code) == [.samePath])
            #expect(run.report.issues.first?.sourcePath == root.path + "/d/moved.txt")
            #expect(run.report.nodes.map(\.destinationPath) == [root.path + "/d/copied copy.txt"])
        }
    }

    /// A folder moved on its own disk is renamed whole, as in a move; a folder copied beside it is read and copied.
    @Test func aMovedFolderIsRenamedWholeAndACopiedOneIsRead() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/Copied/inside.txt", "c")
            try Disk.write(root.path + "/b/Moved/inside.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/Copied", root.path + "/b/Moved"], into: root.path + "/d",
                cut: [root.path + "/b/Moved"])
            #expect(run.report.nodes.map(\.renameOnly) == [false, true])
            #expect(run.report.nodes.first?.children.count == 1)
            #expect(run.result?.status == .completed)
            #expect(Disk.lstat(root.path + "/a/Copied/inside.txt")?.type == .file)
            #expect(Disk.lstat(root.path + "/d/Copied/inside.txt")?.type == .file)
            #expect(Disk.lstat(root.path + "/b/Moved") == nil)
            #expect(Disk.lstat(root.path + "/d/Moved/inside.txt")?.type == .file)
        }
    }

    // MARK: The paste

    @Test func copiesTheCopiedItemsAndMovesTheCutOnesInOneRun() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/copied.txt", "c")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/copied.txt", root.path + "/b/moved.txt"],
                into: root.path + "/d", cut: [root.path + "/b/moved.txt"])
            let result = try #require(run.result)
            #expect(result.status == .completed)
            #expect(result.mode == .copy)
            #expect(result.items.map(\.mode) == [.copy, .cut])
            #expect(result.items.map(\.status) == [.completed, .completed])
            #expect(try String(contentsOfFile: root.path + "/a/copied.txt", encoding: .utf8) == "c")
            #expect(try String(contentsOfFile: root.path + "/d/copied.txt", encoding: .utf8) == "c")
            #expect(Disk.lstat(root.path + "/b/moved.txt") == nil)
            #expect(try String(contentsOfFile: root.path + "/d/moved.txt", encoding: .utf8) == "m")
        }
    }

    /// The items inside a picked folder go as it does, and the result says so of each.
    @Test func whatIsInsideAPickedFolderGoesAsTheFolderDoes() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/Copied/one.txt", "1")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.write(root.path + "/d/Copied/two.txt", "2")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/Copied", root.path + "/b/moved.txt"], into: root.path + "/d",
                policy: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip),
                cut: [root.path + "/b/moved.txt"])
            let result = try #require(run.result)
            let modes = Dictionary(uniqueKeysWithValues: result.items.map { ($0.sourcePath, $0.mode) })
            #expect(modes[root.path + "/a/Copied"] == .copy)
            #expect(modes[root.path + "/a/Copied/one.txt"] == .copy)
            #expect(modes[root.path + "/b/moved.txt"] == .cut)
            #expect(Disk.lstat(root.path + "/a/Copied/one.txt")?.type == .file)
            #expect(Disk.lstat(root.path + "/d/Copied/one.txt")?.type == .file)
        }
    }

    /// Each progress event says what the item it is on does, so a drag refused meanwhile names it rightly.
    @Test func progressSaysWhatTheItemBeingPastedDoes() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/copied.txt", "c")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/copied.txt", root.path + "/b/moved.txt"],
                into: root.path + "/d", cut: [root.path + "/b/moved.txt"])
            let byItem = run.events.filter { $0.result == nil && $0.currentSourcePath != nil }
            #expect(byItem.contains { $0.currentSourcePath == root.path + "/a/copied.txt" && $0.mode == .copy })
            #expect(byItem.contains { $0.currentSourcePath == root.path + "/b/moved.txt" && $0.mode == .cut })
            #expect(run.events.last?.mode == .copy)
        }
    }

    /// Moved to another disk, the original goes once its copy is in place; the copied item stays where it was.
    @Test func toAnotherDiskTheMovedOriginalGoesAndTheCopiedOneStays() async throws {
        try await withOtherDisk { source, destination, fileSystem in
            try Disk.write(source + "/copied.txt", "c")
            try Disk.write(source + "/Moved/inside.txt", "m")
            let run = try await runPaste(
                mode: .copy, sources: [source + "/copied.txt", source + "/Moved"], into: destination,
                fileSystem: fileSystem, cut: [source + "/Moved"])
            #expect(run.result?.status == .completed)
            #expect(Disk.lstat(source + "/copied.txt")?.type == .file)
            #expect(Disk.lstat(source + "/Moved") == nil)
            #expect(Disk.lstat(destination + "/copied.txt")?.type == .file)
            #expect(Disk.lstat(destination + "/Moved/inside.txt")?.type == .file)
        }
    }

    /// Stopped before any item: each not started still says what it was to do.
    @Test func itemsNotStartedKeepTheirMode() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/copied.txt", "c")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let signal = StopSignal()
            signal.stop()
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/copied.txt", root.path + "/b/moved.txt"],
                into: root.path + "/d", signal: signal, cut: [root.path + "/b/moved.txt"])
            let result = try #require(run.result)
            #expect(result.status == .cancelled)
            #expect(result.items.map(\.status) == [.cancelled, .cancelled])
            #expect(result.items.map(\.mode) == [.copy, .cut])
            #expect(Disk.lstat(root.path + "/b/moved.txt")?.type == .file)
        }
    }

    /// Stopped by a question about the first item: the moved item after it is not started, and says it was to move.
    @Test func itemsAfterAStopKeepTheirOwnModeNotTheStoppedItems() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/copied.txt", "c")
            try Disk.write(root.path + "/b/moved.txt", "m")
            try Disk.makeDirectories(root.path + "/d")
            let signal = StopSignal()
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/a/copied.txt", root.path + "/b/moved.txt"],
                into: root.path + "/d", signal: signal,
                beforeExecute: {
                    // Something takes the first item's name after the review: the question is answered by a Stop.
                    try Disk.write(root.path + "/d/copied.txt", "taken")
                },
                resolve: { _ in
                    signal.stop()
                    return nil
                }, cut: [root.path + "/b/moved.txt"])
            let result = try #require(run.result)
            #expect(result.status == .cancelled)
            #expect(result.items.map(\.mode) == [.copy, .cut])
            #expect(Disk.lstat(root.path + "/b/moved.txt")?.type == .file)
        }
    }

    // MARK: Undo

    @MainActor @Test func oneUndoMovesTheMovedItemsBackAndPutsTheCopiesInTheTrash() async throws {
        try await withUndoFolder { root, trashDir in
            for folder in ["a", "b", "b/Moved", "d"] { try UndoDisk.mkdir("\(root)/\(folder)") }
            try UndoDisk.write("\(root)/a/copied.txt", "c")
            try UndoDisk.write("\(root)/b/Moved/inside.txt", "m")
            let t = UndoTest(root: root, trashDir: trashDir)
            let before = t.snapshot()
            let result = try await t.paste(
                .copy, ["\(root)/a/copied.txt", "\(root)/b/Moved"], into: "\(root)/d", cut: ["\(root)/b/Moved"])
            #expect(result.status == .completed)
            guard case .undoable(let units) = try #require(result.undoLog) else {
                Issue.record("A mixed paste can't be undone.")
                return
            }
            #expect(units.count == 2)
            if case .created = units.first?.steps.first {} else { Issue.record("The copy isn't recorded as made.") }
            if case .moved = units.last?.steps.first {} else { Issue.record("The move isn't recorded as moved.") }

            #expect(try await t.undo().status == .completed)
            #expect(t.snapshot() == before)
            #expect(UndoDisk.names("\(root)/d").isEmpty)

            #expect(try await t.undo(.redo).status == .completed)
            #expect(UndoDisk.exists("\(root)/a/copied.txt"))
            #expect(UndoDisk.exists("\(root)/d/copied.txt"))
            #expect(!UndoDisk.exists("\(root)/b/Moved"))
            #expect(UndoDisk.exists("\(root)/d/Moved/inside.txt"))
            await t.shutDown()
        }
    }

    // MARK: Two items of one name

    @Test func theItemMarkedTakesANameOfItsOwnAndTheOtherKeepsItsName() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/api/README.md", "api")
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/api/README.md", root.path + "/web/README.md"],
                into: root.path + "/d", renamedIfShared: [root.path + "/web/README.md"])
            #expect(run.report.issues.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(try String(contentsOfFile: root.path + "/d/README.md", encoding: .utf8) == "api")
            #expect(try String(contentsOfFile: root.path + "/d/README copy.md", encoding: .utf8) == "web")
        }
    }

    /// Whatever order the two come in, the one marked is the one renamed.
    @Test func theMarkedItemIsRenamedEvenWhenItComesFirst() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/api/README.md", "api")
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/web/README.md", root.path + "/api/README.md"],
                into: root.path + "/d", renamedIfShared: [root.path + "/web/README.md"])
            #expect(run.report.issues.isEmpty)
            #expect(try String(contentsOfFile: root.path + "/d/README.md", encoding: .utf8) == "api")
            #expect(try String(contentsOfFile: root.path + "/d/README copy.md", encoding: .utf8) == "web")
        }
    }

    /// Without the mark, two items of one name still stop the review, as before.
    @Test func unmarkedItemsOfOneNameStillStopTheReview() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/api/README.md", "api")
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/api/README.md", root.path + "/web/README.md"],
                into: root.path + "/d")
            #expect(run.report.issues.map(\.code) == [.duplicateDestinationName])
        }
    }

    /// The name taken is free at the destination too, and of what this paste puts there: a third item marked takes
    /// the next one.
    @Test func theNameTakenIsFreeThereAndAmongTheOthers() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/a/notes.txt", "a")
            try Disk.write(root.path + "/b/notes.txt", "b")
            try Disk.write(root.path + "/c/notes.txt", "c")
            try Disk.write(root.path + "/d/notes copy.txt", "already")
            let run = try await runPaste(
                mode: .copy,
                sources: [root.path + "/a/notes.txt", root.path + "/b/notes.txt", root.path + "/c/notes.txt"],
                into: root.path + "/d", renamedIfShared: [root.path + "/b/notes.txt", root.path + "/c/notes.txt"])
            #expect(run.report.issues.isEmpty)
            #expect(
                run.report.nodes.map { NodePath.basename($0.destinationPath) } == [
                    "notes.txt", "notes copy 2.txt", "notes copy 3.txt",
                ])
            #expect(try String(contentsOfFile: root.path + "/d/notes copy.txt", encoding: .utf8) == "already")
        }
    }

    /// The other of the two was taken off the clipboard: the one marked keeps its own name.
    @Test func aMarkedItemAloneKeepsItsName() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/web/README.md"], into: root.path + "/d",
                renamedIfShared: [root.path + "/web/README.md"])
            #expect(run.report.nodes.map(\.destinationPath) == [root.path + "/d/README.md"])
        }
    }

    /// On a disk that doesn't tell case apart, "Readme.md" and "README.md" are one name: the one marked is renamed.
    @Test func namesTheDiskTakesForOneAreShared() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/api/README.md", "api")
            try Disk.write(root.path + "/web/Readme.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/api/README.md", root.path + "/web/Readme.md"],
                into: root.path + "/d", renamedIfShared: [root.path + "/web/Readme.md"])
            guard !run.report.destinationCaseSensitive else { return }
            #expect(run.report.issues.isEmpty)
            #expect(run.report.nodes.map { NodePath.basename($0.destinationPath) } == ["README.md", "Readme copy.md"])
        }
    }

    /// A clash with what is already at the destination is the review's, as ever: the mark is about the items of the
    /// paste, not about what is there.
    @Test func aClashWithWhatIsThereIsLeftToTheReview() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.write(root.path + "/d/README.md", "there")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/web/README.md"], into: root.path + "/d",
                renamedIfShared: [root.path + "/web/README.md"])
            #expect(run.report.nodes.first?.conflictClass == .fileConflict)
            #expect(run.report.nodes.first?.destinationPath == root.path + "/d/README.md")
        }
    }

    /// A moved item marked keeps both too: the copied one keeps the name, the moved one is renamed as it moves.
    @Test func aMovedItemMarkedIsRenamedAsItMoves() async throws {
        try await withTemporaryDirectory { root in
            try Disk.write(root.path + "/api/README.md", "api")
            try Disk.write(root.path + "/web/README.md", "web")
            try Disk.makeDirectories(root.path + "/d")
            let run = try await runPaste(
                mode: .copy, sources: [root.path + "/api/README.md", root.path + "/web/README.md"],
                into: root.path + "/d", cut: [root.path + "/web/README.md"],
                renamedIfShared: [root.path + "/web/README.md"])
            #expect(run.result?.status == .completed)
            #expect(Disk.lstat(root.path + "/web/README.md") == nil)
            #expect(try String(contentsOfFile: root.path + "/d/README copy.md", encoding: .utf8) == "web")
            #expect(try String(contentsOfFile: root.path + "/api/README.md", encoding: .utf8) == "api")
        }
    }
}
