// Port of the first half of packages/core/src/fs/copyPasteRuntimeSafety.realfs.test.ts, but for the cases that
// Replace (P3-04's): what a paste does when the items it is about relate to each other, or change between the review
// and the paste, on the real disk
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// The work folders of one test: what is pasted, where to, and a Trash.
struct SafetyFolders {
    let root: String
    let src: String
    let dst: String
    let trash: String

    init(_ directory: TemporaryDirectory) throws {
        root = directory.path
        src = root + "/src"
        dst = root + "/dst"
        trash = root + "/trash"
        for folder in [src, dst, trash] {
            try Disk.makeDirectories(folder)
        }
    }

    /// As on a move to another disk: items are copied and the originals removed.
    func withoutRenameAtAll() -> TestFileSystem {
        NativePaste.asOnAnotherDisk(src)
    }

    func withTrash() -> NativeWriteFileSystem {
        NativePaste.withTrash(trash)
    }
}

/// Runs `body` with fresh work folders.
func withSafetyFolders(_ body: (SafetyFolders) async throws -> Void) async throws {
    try await withTemporaryDirectory(prefix: "ft-runtime-safety") { directory in
        try await body(try SafetyFolders(directory))
    }
}

/// Makes `path` a package (a folder) holding `files`, in place of what is there.
private func becomePackage(_ path: String, _ files: [String: String]) throws {
    try? FileManager.default.removeItem(atPath: path)
    try Disk.makeDirectories(path)
    for (name, content) in files {
        try Disk.write(path + "/" + name, content)
    }
}

/// Replace never destroys another item of the same paste.
struct ReplaceNeverDestroysAnotherItemTests {
    // Cutting "src/a" and "dst/a/keep.txt" into "dst": replacing "dst/a" would send "keep.txt" to the Trash inside
    // it.
    // T-4b7e1bb5 F-449
    @Test func isBlockedInTheReviewForAFolderHoldingAnotherItemBeingPasted() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/a/new.txt", "new")
            try Disk.write(f.dst + "/a/keep.txt", "keep")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/a", f.dst + "/a/keep.txt"], into: f.dst, policy: NativePaste.replaceAll,
                fileSystem: f.withTrash())

            #expect(run.report.nodes.first?.replaceBlockedReason == "It contains another item being pasted.")
        }
    }

    // As the review shows it: Replace for all merges a folder it can't replace.
    // T-a1bb1edb F-449
    @Test func mergesTheFolderInsteadWhenReplaceIsChosenForAllAndKeepsEveryItem() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/a/new.txt", "new")
            try Disk.write(f.dst + "/a/keep.txt", "keep")

            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/a", f.dst + "/a/keep.txt"], into: f.dst, policy: NativePaste.replaceAll,
                fileSystem: f.withTrash())

            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.trash) == [])
            #expect(Disk.read(f.dst + "/keep.txt") == "keep")
            #expect(Disk.read(f.dst + "/a/new.txt") == "new")
            #expect(run.result?.replacedPaths == nil)
        }
    }

    // Planned as a merge (the review saw the other item in it), so nothing goes to the Trash even though the other
    // item has left it by then.
    // T-cc8bf910 F-449
    @Test func mergesTheFolderOnceTheOtherItemHasBeenMovedOutOfItFirst() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/a/new.txt", "new")
            try Disk.write(f.dst + "/a/keep.txt", "keep")

            // keep.txt goes first, so by the time "a" is replaced it is safe.
            let run = try await runPaste(
                mode: .cut, sources: [f.dst + "/a/keep.txt", f.src + "/a"], into: f.dst, policy: NativePaste.replaceAll,
                fileSystem: f.withTrash(), resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/keep.txt") == "keep")
            #expect(Disk.list(f.dst + "/a") == ["new.txt"])
            #expect(Disk.list(f.trash) == [])
        }
    }
}

/// An item that changed after the review.
struct ChangedAfterTheReviewTests {
    // Answering "use the changed file" is about the file being pasted; an item that appeared at the destination
    // meanwhile is asked about on its own.
    // T-39385cd0 F-324 F-325
    @Test func asksAboutTheDestinationTooWhenBothSidesChanged() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/notes.txt", "draft")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/notes.txt"], into: f.dst, fileSystem: f.withTrash(),
                beforeExecute: {
                    try Disk.write(f.src + "/notes.txt", "final draft")
                    try Disk.write(f.dst + "/notes.txt", "someone else's notes")
                },
                resolve: { $0.reason == .sourceChanged ? .overwrite : .keepBoth })

            #expect(run.conflicts.map(\.reason) == [.sourceChanged, .destinationCreated])
            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/notes.txt") == "someone else's notes")
            #expect(Disk.read(f.dst + "/notes copy.txt") == "final draft")
            #expect(Disk.list(f.trash) == [])
        }
    }

    // T-bab8f5be F-324
    @Test func asksOnceWhenOnlyTheItemBeingPastedChanged() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/notes.txt", "draft")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/notes.txt"], into: f.dst,
                beforeExecute: {
                    try Disk.write(f.src + "/notes.txt", "final draft")
                    try setDate(f.src + "/notes.txt", 1_580_515_200_000)
                },
                resolve: { _ in .overwrite })

            #expect(run.conflicts.map(\.reason) == [.sourceChanged])
            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/notes.txt") == "final draft")
        }
    }
}

/// Folders reached through a symlink, and duplicating several items.
struct LinkedFolderTests {
    // T-71bb66fd F-336
    @Test func pastesIntoASymlinkToAFolderAsIntoThatFolder() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/a.txt", "a")
            try Disk.symlink(f.dst, f.root + "/Shortcut to dst")

            let run = try await runPaste(mode: .copy, sources: [f.src + "/a.txt"], into: f.root + "/Shortcut to dst")

            #expect(run.report.issues.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/a.txt") == "a")
        }
    }

    // "L/a.txt" where L links to dst is "dst/a.txt": copying it into dst duplicates it.
    // T-942b8999 F-336
    @Test func duplicatesAnItemCopiedIntoItsOwnFolderThroughASymlink() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.dst + "/a.txt", "a")
            try Disk.symlink(f.dst, f.root + "/L")

            let run = try await runPaste(mode: .copy, sources: [f.root + "/L/a.txt"], into: f.dst)

            #expect(run.report.issues.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst) == ["a copy.txt", "a.txt"])
        }
    }

    // T-be52855a F-450
    @Test func namesEachCopyApartWhenOneItemsCopyNameIsAnotherItemsName() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.dst + "/a.txt", "a")
            try Disk.write(f.dst + "/a copy.txt", "a copy")

            let run = try await runPaste(mode: .copy, sources: [f.dst + "/a.txt", f.dst + "/a copy.txt"], into: f.dst)

            #expect(run.report.issues.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst) == ["a copy 2.txt", "a copy 3.txt", "a copy.txt", "a.txt"])
            #expect(Disk.read(f.dst + "/a copy 2.txt") == "a")
            #expect(Disk.read(f.dst + "/a copy 3.txt") == "a copy")
        }
    }
}

// The person is asked when the item being pasted changed after the review; going on must paste what is there now,
// not what the review saw.
struct GoingOnAfterTheSourceChangedTests {
    // T-e4a3d0a4 F-331
    @Test func copiesAFileThatBecameAPackageAsTheWholePackage() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/Doc.key", "flat")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/Doc.key"], into: f.dst,
                beforeExecute: { try becomePackage(f.src + "/Doc.key", ["Index.zip": "index"]) },
                resolve: { _ in .overwrite })

            #expect(run.conflicts.map(\.reason) == [.sourceChanged])
            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/Doc.key/Index.zip") == "index")
        }
    }

    // Keynote and Pages save a package as a new folder that takes the old one's name.
    // T-5ef4dac6 F-331
    @Test func copiesAPackageSavedAnewWithTheFilesItHasNow() async throws {
        try await withSafetyFolders { f in
            try becomePackage(f.src + "/Photos.key", ["a.jpg": "a"])

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/Photos.key"], into: f.dst,
                beforeExecute: {
                    try Disk.write(f.src + "/saving/a.jpg", "a")
                    try Disk.write(f.src + "/saving/b.jpg", "b")
                    try FileManager.default.removeItem(atPath: f.src + "/Photos.key")
                    #expect(rename(f.src + "/saving", f.src + "/Photos.key") == 0)
                },
                resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst + "/Photos.key") == ["a.jpg", "b.jpg"])
        }
    }

    // T-3de7ef98 F-331 F-469
    @Test func movesAFileThatBecameAFolderToAnotherPlaceAsTheWholeFolder() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/Doc.key", "flat")

            // As to another disk: copied, then the original removed.
            let run = try await runPaste(
                mode: .cut, sources: [f.src + "/Doc.key"], into: f.dst, fileSystem: f.withoutRenameAtAll(),
                beforeExecute: { try becomePackage(f.src + "/Doc.key", ["Index.zip": "index"]) },
                resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/Doc.key/Index.zip") == "index")
            #expect(Disk.list(f.src) == [])
        }
    }

    // T-aca6c73a F-331
    @Test func copiesAFolderThatBecameAFileAsTheFile() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/notes/a.txt", "a")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/notes"], into: f.dst,
                beforeExecute: {
                    try FileManager.default.removeItem(atPath: f.src + "/notes")
                    try Disk.write(f.src + "/notes", "now a file")
                },
                resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/notes") == "now a file")
        }
    }

    // T-7ecd40ee F-331
    @Test func copiesASymlinkThatBecameAFileAsTheFile() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/target.txt", "target")
            try Disk.symlink(f.src + "/target.txt", f.src + "/link")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/link"], into: f.dst,
                beforeExecute: {
                    #expect(unlink(f.src + "/link") == 0)
                    try Disk.write(f.src + "/link", "a file now")
                },
                resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.read(f.dst + "/link") == "a file now")
        }
    }

    // T-c29d4a53 F-332
    @Test func leavesAnItemThatIsNoLongerAFolderWhenTheAnswerWasMerge() async throws {
        try await withSafetyFolders { f in
            try Disk.makeDirectories(f.src + "/notes")
            try Disk.makeDirectories(f.dst + "/notes")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/notes"], into: f.dst,
                beforeExecute: {
                    try FileManager.default.removeItem(atPath: f.src + "/notes")
                    try Disk.write(f.src + "/notes", "a file now")
                },
                resolve: { _ in .merge })

            #expect(run.result?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}notes\u{201D} is no longer a folder, so it can't be merged and was left.")
            #expect(Disk.list(f.dst + "/notes") == [])
        }
    }

    // An item the review saw at the destination and that changed there since is still asked about, even inside a
    // folder that was read again.
    // T-75adad92 F-331 F-325
    @Test func stillAsksBeforeReplacingAnItemInsideItThatChangedAtTheDestination() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/Project/a.txt", "new a")
            try Disk.write(f.dst + "/Project/a.txt", "old a")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/Project"], into: f.dst,
                policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .skip),
                beforeExecute: {
                    try Disk.write(f.src + "/saving/a.txt", "newer a")
                    try FileManager.default.removeItem(atPath: f.src + "/Project")
                    #expect(rename(f.src + "/saving", f.src + "/Project") == 0)
                    try Disk.write(f.dst + "/Project/a.txt", "edited at the destination")
                },
                resolve: { $0.reason == .sourceChanged ? .merge : .skip })

            #expect(run.conflicts.map(\.reason) == [.sourceChanged, .destinationChanged])
            #expect(Disk.read(f.dst + "/Project/a.txt") == "edited at the destination")
        }
    }
}

/// Items added to a folder after the review; merging folders that both have Finder's .DS_Store.
struct AddedAfterTheReviewTests {
    // T-2df7cd78 F-272
    @Test func areNamedInTheResultOfACopyInsteadOfCallingItComplete() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/F"], into: f.dst,
                beforeExecute: { try Disk.write(f.src + "/F/late.txt", "late") })

            #expect(run.result?.status == .partial)
            #expect(
                run.result?.items.first { $0.sourcePath == f.src + "/F" }?.error
                    == "\u{201C}late.txt\u{201D} was added to \u{201C}F\u{201D} after the copy began, so it wasn't copied.")
            #expect(Disk.list(f.dst + "/F") == ["a.txt"])
        }
    }

    // T-25681a6f F-272
    @Test func dontCountFindersOwnDSStore() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/a.txt", "a")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/F"], into: f.dst,
                beforeExecute: { try Disk.write(f.src + "/F/.DS_Store", "view") })

            #expect(run.result?.status == .completed)
        }
    }

    // Finder writes .DS_Store into a folder just by showing it: merging two folders that both have one isn't a
    // clash to ask about, and the folder merged into keeps its own.
    // T-e69a3b0c F-448
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func keepsTheDestinationsAskingNothing(mode: CopyPasteMode) async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/.DS_Store", "pasted view")
            try Disk.write(f.src + "/F/a.txt", "a")
            try Disk.write(f.dst + "/F/.DS_Store", "own view")
            try Disk.write(f.dst + "/F/b.txt", "b")

            let run = try await runPaste(
                mode: mode, sources: [f.src + "/F"], into: f.dst,
                policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .overwrite))

            #expect(run.report.summary.fileConflictCount == 0)
            #expect(run.report.summary.directoryConflictCount == 1)
            #expect(run.report.nodes.first?.children.map { NodePath.basename($0.sourcePath) } == ["a.txt"])
            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst + "/F") == [".DS_Store", "a.txt", "b.txt"])
            #expect(Disk.read(f.dst + "/F/.DS_Store") == "own view")
        }
    }

    // T-17da6372 F-448
    @Test func copiesThePastedOneIntoAFolderThatHasNone() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/F/.DS_Store", "pasted view")
            try Disk.makeDirectories(f.dst + "/F")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/F"], into: f.dst,
                policy: CopyPastePolicy(file: .overwrite, directory: .merge, mismatch: .overwrite))

            #expect(run.report.summary.fileConflictCount == 0)
            #expect(Disk.read(f.dst + "/F/.DS_Store") == "pasted view")
        }
    }
}

/// What is picked to paste, and the folder pasted into going away.
struct WhatIsPickedTests {
    // "/" holds everything, so wherever it is pasted is inside it.
    // T-17fe1e11 F-447
    @Test func refusesToPasteTheStartupDiskIntoOneOfItsOwnFolders() async throws {
        try await withSafetyFolders { f in
            let run = try await runPaste(mode: .copy, sources: ["/"], into: f.dst)

            #expect(run.report.issues.map(\.code) == [.parentIntoChild])
            #expect(run.result == nil)
        }
    }

    // Select All in search results picks a folder and items inside it.
    // T-6bdd38a0 F-447
    @Test func copiesAnItemPickedWithItsFolderOnceInsideTheFolder() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/A/b.txt", "b")

            let run = try await runPaste(mode: .copy, sources: [f.src + "/A/b.txt", f.src + "/A"], into: f.dst)

            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst) == ["A"])
            #expect(Disk.list(f.dst + "/A") == ["b.txt"])
        }
    }

    // T-3b3f54f5 F-461
    @Test func movesAnItemPickedWithItsFolderAlongWithTheFolderWithoutAsking() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/A/b.txt", "b")

            let run = try await runPaste(mode: .cut, sources: [f.src + "/A", f.src + "/A/b.txt"], into: f.dst)

            #expect(run.conflicts.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(f.dst + "/A") == ["b.txt"])
            #expect(Disk.list(f.src) == [])
        }
    }

    // T-070e93f1 F-280
    @Test func countsAFolderAsOneItemPickedNotTheItemsInsideIt() async throws {
        try await withSafetyFolders { f in
            for name in ["1.jpg", "2.jpg", "3.jpg"] {
                try Disk.write(f.src + "/Photos/" + name, name)
            }

            let run = try await runPaste(mode: .copy, sources: [f.src + "/Photos"], into: f.dst)

            #expect(run.result?.summary.topLevelItemCount == 1)
        }
    }

    // T-c73d9a4c F-269
    @Test func doesntMakeTheFolderPastedIntoAgainAndSaysItIsGone() async throws {
        try await withSafetyFolders { f in
            try Disk.write(f.src + "/a.txt", "a")
            try Disk.write(f.src + "/F/b.txt", "b")

            let run = try await runPaste(
                mode: .copy, sources: [f.src + "/a.txt", f.src + "/F"], into: f.dst,
                beforeExecute: { try FileManager.default.removeItem(atPath: f.dst) })

            #expect(run.result?.status == .failed)
            #expect(
                run.result?.items.map(\.error) == [
                    "The folder \u{201C}dst\u{201D} no longer exists.", "The folder \u{201C}dst\u{201D} no longer exists.",
                ])
            #expect(!Disk.list(f.root).contains("dst"))
        }
    }
}
