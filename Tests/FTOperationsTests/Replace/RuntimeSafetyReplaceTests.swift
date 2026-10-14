// Port of the Replace cases of packages/core/src/fs/copyPasteRuntimeSafety.realfs.test.ts (its other cases are in
// Execution/RuntimeSafetyTests.swift and Execution/RuntimeSafetyWholeFolderTests.swift), on the real disk
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

struct RuntimeSafetyReplaceTests {
    private func withPlaces(
        _ body: (_ root: String, _ src: String, _ dst: String, _ trash: String) async throws -> Void
    ) async throws {
        try await withTemporaryDirectory { root in
            let (src, dst, trash) = (root.path + "/src", root.path + "/dst", root.path + "/trash")
            for folder in [src, dst, trash] {
                try Disk.makeDirectories(folder)
            }
            try await body(root.path, src, dst, trash)
        }
    }

    private func noTrash(_ base: any WriteServiceFileSystem = NativeWriteFileSystem()) -> TestFileSystem {
        let fileSystem = TestFileSystem(base)
        fileSystem.trash = { _ in throw noTrashHere() }
        return fileSystem
    }

    private func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: from, dest: to)
        }
    }

    // MARK: The swap at the end of a Replace

    // The old item is in the Trash by then; the new one must never be thrown away too.
    // T-e7b6aa80 F-344 F-492
    @Test func keepsTheNewItemUnderAVisibleNameWhenItCantTakeTheOldOnesName() async throws {
        try await withPlaces { _, src, dst, trash in
            try Disk.write(src + "/f.txt", "new")
            try Disk.write(dst + "/f.txt", "old")
            let fileSystem = TestFileSystem(NativePaste.withTrash(trash))
            fileSystem.renameExclusiveImpl = { from, to in
                if to == dst + "/f.txt" {
                    throw NativeError(message: "EIO: i/o error", code: "EIO")
                }
                try NativeFS.renameExclusive(from, to)
            }
            let journal = MemoryJournal()

            let run = try await runPaste(
                mode: .copy, sources: [src + "/f.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: fileSystem, writeJournal: journal)

            let item = run.result?.items.first
            #expect(item?.status == .failed)
            #expect(item?.destinationPath == dst + "/f copy.txt")
            #expect(
                item?.error?.contains(
                    "The old \u{201C}f.txt\u{201D} was moved to the Trash, but the new one couldn't take its name, so it was saved as \u{201C}f copy.txt\u{201D}."
                ) == true)
            #expect(Disk.list(dst) == ["f copy.txt"])
            #expect(Disk.read(dst + "/f copy.txt") == "new")
            #expect(journal.entries.isEmpty)
        }
    }

    // MARK: Going on after the item being pasted changed

    // T-4043a115 F-494
    @Test func replacesWithTheWholePackageNeverWithAnEmptyFolder() async throws {
        try await withPlaces { _, src, dst, trash in
            try Disk.write(src + "/Doc.key", "flat")
            try Disk.write(dst + "/Doc.key", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/Doc.key"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash),
                beforeExecute: {
                    try NativeWriteFileSystem().rm(src + "/Doc.key", recursive: true, force: true)
                    try Disk.write(src + "/Doc.key/Index.zip", "index")
                },
                resolve: { _ in .overwrite })

            #expect(run.result?.status == .completed)
            #expect(Disk.read(dst + "/Doc.key/Index.zip") == "index")
            #expect(Disk.list(trash) == ["1-Doc.key"])
        }
    }

    // MARK: The item a Replace removes is the one that was there

    // An app saves a new version of "a.txt" (a new file put in its place) while the copy replacing it is being
    // written.
    // T-30bf2d98 F-342 F-501
    @Test func keepsAnItemSavedInItsPlaceWhileTheNewOneWasBeingCopied() async throws {
        try await withPlaces { root, src, dst, trash in
            try Disk.write(src + "/a.txt", "pasted")
            try Disk.write(dst + "/a.txt", "old")
            let withTrash = NativePaste.withTrash(trash)
            let fileSystem = TestFileSystem(withTrash)
            fileSystem.copyFileImpl = { [self] from, to, stop, progress in
                try withTrash.copyFile(from, to, stop: stop, onProgress: progress)
                try Disk.write(root + "/saved.tmp", "saved meanwhile")
                try rename(root + "/saved.tmp", dst + "/a.txt")
            }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: fileSystem)

            #expect(run.result?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}a.txt\u{201D} changed while it was being replaced, so it was kept and nothing was replaced."
            )
            #expect(Disk.read(dst + "/a.txt") == "saved meanwhile")
            #expect(Disk.list(dst) == ["a.txt"])
            #expect(Disk.list(trash) == [])
        }
    }

    // With no Trash to get it back from, an item added to the folder since the review would be lost unseen: the
    // folder is kept.
    // T-15257524 F-343 F-501
    @Test func doesntDeleteForGoodAFolderThatGotANewItemWhileTheNewOneWasCopied() async throws {
        try await withPlaces { _, src, dst, _ in
            try Disk.write(src + "/F/x.txt", "pasted")
            try Disk.write(dst + "/F/old.txt", "old")
            let fileSystem = noTrash()
            fileSystem.copyFileImpl = { from, to, stop, progress in
                try NativeWriteFileSystem().copyFile(from, to, stop: stop, onProgress: progress)
                try Disk.write(dst + "/F/new work.txt", "unsaved elsewhere")
            }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll, fileSystem: fileSystem,
                resolve: { _ in .overwrite })

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(run.result?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "\u{201C}F\u{201D} changed while it was being replaced, so it was kept and nothing was replaced.")
            #expect(Disk.list(dst + "/F") == ["new work.txt", "old.txt"])
            #expect(Disk.list(dst) == ["F"])
        }
    }

    // Looking for a locked item inside a large folder takes a while: one swapped in for it meanwhile isn't
    // deleted.
    // T-0d702d5e F-501
    @Test func doesntDeleteAFolderSwappedInWhileItWasLookedThroughForLockedItems() async throws {
        try await withPlaces { root, src, dst, _ in
            try Disk.write(src + "/F/x.txt", "pasted")
            try Disk.write(dst + "/F/old.txt", "old")
            let swapped = Locked(false)
            let fileSystem = noTrash()
            fileSystem.getFlagsImpl = { [self] path in
                if !swapped.value && path == dst + "/F/old.txt" {
                    swapped.mutate { $0 = true }
                    try rename(dst + "/F", root + "/F asked about")
                    try Disk.write(dst + "/F/old.txt", "never asked about")
                }
                return try NativeFS.getFlags(path)
            }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll, fileSystem: fileSystem,
                resolve: { _ in .overwrite })

            #expect(swapped.value)
            #expect(run.result?.status == .failed)
            #expect(Disk.read(dst + "/F/old.txt") == "never asked about")
            #expect(Disk.list(dst) == ["F"])
        }
    }

    // On a disk with no Trash the person is asked first; another item put there while the question was open is
    // never deleted on that answer.
    // T-66f20243 F-343 F-501
    @Test func doesntDeleteForGoodAnItemPutInPlaceWhileTheNoTrashQuestionWasOpen() async throws {
        try await withPlaces { root, src, dst, _ in
            try Disk.write(src + "/a.txt", "pasted")
            try Disk.write(dst + "/a.txt", "old")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: noTrash(),
                resolve: { [self] _ in
                    try? Disk.write(root + "/other.tmp", "never asked about")
                    try? rename(root + "/other.tmp", dst + "/a.txt")
                    return .overwrite
                })

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(run.result?.status == .failed)
            #expect(Disk.read(dst + "/a.txt") == "never asked about")
            #expect(Disk.list(dst) == ["a.txt"])
        }
    }

    // MARK: Smaller cases a Replace and a copy get right

    // T-81c8fbf8 F-341 F-504
    @Test func keepsTheOldFolderWhenAnItemInTheNewOneChangedAndWasSkipped() async throws {
        try await withPlaces { _, src, dst, trash in
            try Disk.write(src + "/F/a.txt", "new a")
            try Disk.write(src + "/F/b.txt", "new b")
            try Disk.write(dst + "/F/b.txt", "old b")

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash), beforeExecute: { try Disk.write(src + "/F/b.txt", "newer b") },
                resolve: { _ in .skip })

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}F\u{201D} wasn't replaced because \u{201C}b.txt\u{201D} in it changed and was skipped.")
            #expect(Disk.read(dst + "/F/b.txt") == "old b")
            #expect(Disk.list(trash) == [])
            #expect(Disk.list(dst) == ["F"])
        }
    }

    // T-c0ecbaec F-504 F-345
    @Test func removesTheHiddenCopyWhenTheReplaceCantBeWrittenDown() async throws {
        try await withPlaces { _, src, dst, trash in
            try Disk.write(src + "/a.txt", "new")
            try Disk.write(dst + "/a.txt", "old")
            let journal = MemoryJournal(failOn: { write in
                if case .add(.replace(let entry)) = write, entry.staged {
                    return OperationError("The disk is full.")
                }
                return nil
            })

            let run = try await runPaste(
                mode: .copy, sources: [src + "/a.txt"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: NativePaste.withTrash(trash), writeJournal: journal)

            #expect(run.result?.status == .failed)
            #expect(Disk.list(dst) == ["a.txt"])
            #expect(Disk.read(dst + "/a.txt") == "old")
        }
    }

    // T-cfe02485 F-343 F-504
    @Test func deletesNothingOfAFolderThatHoldsALockedItemOnADiskWithoutATrash() async throws {
        try await withPlaces { _, src, dst, _ in
            try Disk.write(src + "/F", "a file now")
            try Disk.write(dst + "/F/keep.txt", "keep")
            try Disk.write(dst + "/F/other.txt", "other")
            Disk.lock(dst + "/F/keep.txt")
            defer { _ = lchflags(dst + "/F/keep.txt", 0) }

            let run = try await runPaste(
                mode: .copy, sources: [src + "/F"], into: dst, policy: NativePaste.replaceAll,
                fileSystem: noTrash(NativePaste.asOnAnotherDisk(src)), resolve: { _ in .overwrite })

            #expect(
                run.result?.items.first?.error
                    == "\u{201C}keep.txt\u{201D} is locked. Unlock it in Finder's Get Info and try again.")
            #expect(Disk.list(dst + "/F") == ["keep.txt", "other.txt"])
        }
    }
}
