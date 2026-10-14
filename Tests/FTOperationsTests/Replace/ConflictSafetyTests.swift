// Port of packages/core/src/fs/copyPasteConflictSafety.realfs.test.ts
import Darwin
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

/// What the app's Trash reports on a disk that may have no Trash (createTrashItem).
func noTrashHere() -> NativeError {
    NativeError(message: "no Trash on this volume", code: CopyPasteErrors.noTrashErrorCode)
}

/// A Trash that keeps what was moved into it, under its own name, for checking what a Replace removed.
func trashInto(_ trashDir: String) -> @Sendable (String) throws -> String? {
    { path in
        let inTrash = trashDir + "/" + NodePath.basename(path)
        if Darwin.rename(path, inTrash) != 0 {
            throw NativeError.errno(errno, syscall: "rename", path: path, dest: inTrash)
        }
        return inTrash
    }
}

/// A paste run as the conflict-safety tests run one: reviewed, planned (or, with `replaceEach`, every item picked
/// answered with Replace, as a Replace answered while the paste runs is: the review gives an item Replace can't
/// take another choice, so this is how the paste's own refusal is reached), then executed.
struct SafetyPaste {
    var mode: CopyPasteMode
    var sources: [String]
    var destination: String
    var policy: CopyPastePolicy = NativePaste.replaceAll
    var replaceEach = false
    var beforeExecute: (() throws -> Void)?
    var resolve: (@Sendable (CopyPasteRuntimeConflict) -> CopyPasteChoice?)?
    var onEvent: (@Sendable (CopyPasteProgressEvent, StopSignal) -> Void)?

    func run(_ fileSystem: any WriteServiceFileSystem) async throws -> PasteRun {
        let report = try buildCopyPasteAnalysisReport(
            analysisId: "analysis-safety",
            request: CopyPasteAnalysisRequest(mode: mode, sourcePaths: sources, destinationDirectoryPath: destination),
            fileSystem: fileSystem,
            thresholds: CopyPasteThresholds(largeBatchItemThreshold: 1000, largeBatchByteThreshold: 1_000_000_000))
        let resolvedNodes =
            replaceEach
            ? try report.nodes.map { node in
                try resolveSingleNodeWithAction(node: node, action: .overwrite, policy: policy, fileSystem: fileSystem)
            }
            : try resolveAnalysisWithPolicy(report: report, policy: policy, fileSystem: fileSystem)
        try beforeExecute?()
        let recorder = PasteRecorder()
        let signal = StopSignal()
        let onEvent = onEvent
        let resolve = resolve
        await executeCopyPasteFromAnalysis(
            CopyPasteRun(
                operationId: "op-safety", report: report, mode: mode, policy: policy, fileSystem: fileSystem,
                now: { Date(timeIntervalSince1970: 1_759_104_000) }, signal: signal, resolvedNodes: resolvedNodes,
                emit: { event in
                    recorder.record(event)
                    onEvent?(event, signal)
                },
                requestResolution: { conflict in
                    recorder.asked(conflict)
                    return .immediate(resolve?(conflict))
                }))
        return PasteRun(report: report, result: recorder.result, conflicts: recorder.conflicts, events: recorder.events)
    }
}

struct ConflictSafetyTests {
    private func withPlaces(_ body: (_ root: String, _ trashDir: String) async throws -> Void) async throws {
        try await withTemporaryDirectory { root in
            let trashDir = root.path + "/.trash"
            try Disk.makeDirectories(trashDir)
            try await body(root.path, trashDir)
        }
    }

    private func withTrash(_ trashDir: String) -> NativeWriteFileSystem {
        NativeWriteFileSystem(trash: trashInto(trashDir))
    }

    private func names(_ items: [CopyPasteItemResult]?) -> [[String]] {
        (items ?? []).map { [NodePath.basename($0.sourcePath), $0.status.rawValue] }
    }

    // T-ef1c6877 F-338 F-476
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func refusesToReplaceAFolderThatContainsTheItemBeingPasted(mode: CopyPasteMode) async throws {
        try await withPlaces { root, trashDir in
            // Flattening "foo/foo" into its parent must never delete either copy.
            let outer = root + "/foo"
            try Disk.write(outer + "/outer.txt", "outer")
            try Disk.write(outer + "/foo/a.txt", "important")

            let run = try await SafetyPaste(mode: mode, sources: [outer + "/foo"], destination: root, replaceEach: true)
                .run(withTrash(trashDir))

            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "Can't replace \u{201C}foo\u{201D} because it contains the item being pasted.")
            #expect(Disk.read(outer + "/outer.txt") == "outer")
            #expect(Disk.read(outer + "/foo/a.txt") == "important")
            #expect(Disk.list(trashDir) == [])
        }
    }

    // T-90781e38 F-338 F-476
    @Test(arguments: [CopyPasteMode.copy, .cut])
    func refusesToReplaceAFolderThatHoldsTheItemPastedThroughASymlinkedFolder(mode: CopyPasteMode) async throws {
        try await withPlaces { root, trashDir in
            // "L" links to "X", so "L/X" is really "X/X": replacing "X" would destroy it.
            let outer = root + "/X"
            try Disk.write(outer + "/X/a.txt", "inner")
            try Disk.write(outer + "/other.txt", "other")
            try Disk.symlink(outer, root + "/L")

            let run = try await SafetyPaste(mode: mode, sources: [root + "/L/X"], destination: root, replaceEach: true)
                .run(withTrash(trashDir))

            #expect(run.report.nodes.first?.replaceBlockedReason == "It contains the item being pasted.")
            #expect(run.result?.items.first?.status == .failed)
            #expect(
                run.result?.items.first?.error
                    == "Can't replace \u{201C}X\u{201D} because it contains the item being pasted.")
            #expect(Disk.read(outer + "/X/a.txt") == "inner")
            #expect(Disk.read(outer + "/other.txt") == "other")
            #expect(Disk.list(trashDir) == [])
        }
    }

    // T-0636af7c F-338 F-476
    @Test func refusesToReplaceAFolderWithAFileItContains() async throws {
        try await withPlaces { root, trashDir in
            let outer = root + "/foo"
            try Disk.write(outer + "/foo", "inner file")
            try Disk.write(outer + "/keep.txt", "keep")

            let run = try await SafetyPaste(
                mode: .copy, sources: [outer + "/foo"], destination: root, replaceEach: true
            )
            .run(withTrash(trashDir))

            #expect(run.result?.items.first?.status == .failed)
            #expect(Disk.read(outer + "/foo") == "inner file")
            #expect(Disk.read(outer + "/keep.txt") == "keep")
        }
    }

    // T-e715e742 F-476 F-493
    @Test func treatsADestinationReachedThroughASymlinkedFolderAsTheSourceFolder() async throws {
        try await withPlaces { root, trashDir in
            // "alias/docs" is "real/docs" reached through a symlinked parent folder.
            let real = root + "/real/docs"
            try Disk.write(real + "/a.txt", "original")
            try Disk.symlink(root + "/real", root + "/alias")

            let copied = try await SafetyPaste(
                mode: .copy, sources: [real + "/a.txt"], destination: root + "/alias/docs"
            )
            .run(withTrash(trashDir))
            // Same folder: the copy gets a new name instead of replacing the original.
            #expect(copied.report.issues.isEmpty)
            #expect(copied.result?.status == .completed)
            #expect(Disk.read(real + "/a.txt") == "original")
            #expect(Disk.read(real + "/a copy.txt") == "original")

            let moved = try await SafetyPaste(mode: .cut, sources: [real + "/a.txt"], destination: root + "/alias/docs")
                .run(withTrash(trashDir))
            #expect(moved.report.issues.map(\.code) == [.samePath])
            #expect(Disk.read(real + "/a.txt") == "original")
        }
    }

    // T-fcb4b870 F-342 F-477
    @Test func movesReplacedItemsToTheTrashInsteadOfDeletingThem() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")
            try Disk.write(source + "/photos/a.jpg", "new a")
            try Disk.write(target + "/photos/d.jpg", "only here")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/notes.txt", source + "/photos"], destination: target
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .completed)
            #expect(Disk.read(target + "/notes.txt") == "new notes")
            #expect(!Disk.exists(target + "/photos/d.jpg"))
            #expect(Disk.read(trashDir + "/notes.txt") == "old notes")
            #expect(Disk.read(trashDir + "/photos/d.jpg") == "only here")
        }
    }

    // T-a68d8dc9 F-342 F-477
    @Test func movesAnItemReplacedByASameDiskMoveToTheTrashToo() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")

            let run = try await SafetyPaste(mode: .cut, sources: [source + "/notes.txt"], destination: target)
                .run(withTrash(trashDir))

            #expect(run.result?.status == .completed)
            #expect(Disk.read(target + "/notes.txt") == "new notes")
            #expect(Disk.read(trashDir + "/notes.txt") == "old notes")
            #expect(!Disk.exists(source + "/notes.txt"))
        }
    }

    // T-b8ddfea8 F-343 F-477
    @Test(arguments: [(CopyPasteChoice.skip, "old notes"), (.overwrite, "new notes")])
    func asksBeforeDeletingPermanentlyWhenTheTrashIsUnavailable(answer: CopyPasteChoice, expected: String)
        async throws
    {
        try await withPlaces { root, _ in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/notes.txt"], destination: target, resolve: { _ in answer }
            ).run(NativeWriteFileSystem(trash: { _ in throw noTrashHere() }))

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(run.result?.items.first?.status == (answer == .skip ? .skipped : .completed))
            #expect(Disk.read(target + "/notes.txt") == expected)
            #expect(Disk.read(source + "/notes.txt") == "new notes")
            // The hidden copy the replacement was built under never stays behind.
            #expect(Disk.list(target) == ["notes.txt"])
        }
    }

    // T-5aa57002 F-262 F-478
    @Test func neverShowsTheHiddenNameAReplacementIsBuiltUnder() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source/photos"
            let target = root + "/target"
            try Disk.write(source + "/a.jpg", "a")
            try Disk.write(target + "/photos/old.jpg", "old")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source], destination: target,
                // Changing a file inside after review asks about it while the hidden copy is built.
                beforeExecute: { try Disk.write(source + "/a.jpg", "changed after review") },
                resolve: { _ in .overwrite }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.map(\.reason) == [.sourceChanged])
            let shown = run.events.flatMap { [$0.currentDestinationPath, $0.runtimeConflict?.destinationPath] }
            #expect(shown.compactMap { $0 }.filter { $0.contains(".filetrail-") } == [])
            #expect(
                run.events.first { $0.runtimeConflict != nil }?.runtimeConflict?.destinationPath
                    == target + "/photos/a.jpg")
            #expect(run.result?.status == .completed)
            #expect(Disk.list(target + "/photos") == ["a.jpg"])
        }
    }

    // T-565e3d5a F-339 F-479
    @Test func asksAgainWhenAnItemToBeReplacedChangedAfterReview() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/x", "pasted")
            try Disk.write(target + "/x", "reviewed file")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/x"], destination: target,
                // Between review and paste, "x" became a folder with new work in it.
                beforeExecute: {
                    try NativeWriteFileSystem().rm(target + "/x", recursive: false, force: false)
                    try Disk.write(target + "/x/important.doc", "new work")
                },
                resolve: { _ in .skip }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.map(\.reason) == [.destinationChanged])
            #expect(run.result?.items.first?.status == .skipped)
            #expect(Disk.read(target + "/x/important.doc") == "new work")
        }
    }

    // T-5b1bda8b F-479
    @Test func copiesWithoutAskingWhenAnItemToBeReplacedIsAlreadyGone() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/x.txt", "pasted")
            try Disk.write(target + "/x.txt", "old")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/x.txt"], destination: target,
                beforeExecute: { try NativeWriteFileSystem().rm(target + "/x.txt", recursive: false, force: false) }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.read(target + "/x.txt") == "pasted")
        }
    }

    // T-0a6d7635 F-480
    @Test(.enabled(if: getuid() != 0, "files that can't be read are readable anyway as root"))
    func keepsGoingAfterAnItemFailsAndReportsEveryItem() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            for name in ["a.txt", "b.txt", "c.txt"] {
                try Disk.write(source + "/" + name, String(name.prefix(1)))
            }
            try Disk.makeDirectories(target)
            Disk.chmod(source + "/b.txt", 0o000)
            defer { Disk.chmod(source + "/b.txt", 0o644) }

            let run = try await SafetyPaste(
                mode: .copy, sources: ["a.txt", "b.txt", "c.txt"].map { source + "/" + $0 }, destination: target
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .partial)
            #expect(
                names(run.result?.items) == [["a.txt", "completed"], ["b.txt", "failed"], ["c.txt", "completed"]])
            #expect(run.result?.items[1].error == "You don't have permission to access this item.")
            // The failed copy leaves nothing half-written behind.
            #expect(!Disk.exists(target + "/b.txt"))
            #expect(Disk.read(target + "/c.txt") == "c")
        }
    }

    // T-4b52b1fd F-480
    @Test(.enabled(if: getuid() != 0, "files that can't be read are readable anyway as root"))
    func keepsGoingInsideAFolderAfterOneOfItsItemsFails() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "a")
            try Disk.write(source + "/docs/b.txt", "b")
            try Disk.makeDirectories(target)
            Disk.chmod(source + "/docs/a.txt", 0o000)
            defer { Disk.chmod(source + "/docs/a.txt", 0o644) }

            let run = try await SafetyPaste(mode: .copy, sources: [source + "/docs"], destination: target)
                .run(withTrash(trashDir))

            #expect(run.result?.items.first?.status == .failed)
            let failed = (run.result?.items ?? []).filter { $0.status == .failed }.map(\.sourcePath)
            #expect(failed.contains(source + "/docs/a.txt"))
            #expect(Disk.read(target + "/docs/b.txt") == "b")
        }
    }

    // T-b6e1f69d F-480 F-362
    @Test func reportsItemsThatWereNeverStartedWhenThePasteIsStopped() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            for name in ["a.txt", "b.txt", "c.txt"] {
                try Disk.write(source + "/" + name, name)
            }
            try Disk.makeDirectories(target)

            let run = try await SafetyPaste(
                mode: .copy, sources: ["a.txt", "b.txt", "c.txt"].map { source + "/" + $0 }, destination: target,
                onEvent: { event, signal in
                    if event.status == .running && event.currentSourcePath?.hasSuffix("a.txt") == true {
                        signal.stop()
                    }
                }
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .partial)
            #expect(
                names(run.result?.items) == [["a.txt", "completed"], ["b.txt", "cancelled"], ["c.txt", "cancelled"]])
            #expect(run.result?.items[2].error == "Not started because the operation was stopped.")
        }
    }

    // T-0d7a2a22 F-481
    @Test func mergesIntoAFolderThatAppearedDuringThePasteUsingTheChosenPolicy() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/D/c.txt", "new c")
            try Disk.write(target + "/D/c.txt", "old c")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/D"], destination: target,
                policy: CopyPastePolicy(file: .keepBoth, directory: .keepBoth, mismatch: .skip),
                // "D copy" appears before the paste creates it; merging into it must still honor the file policy
                // for the nested conflict.
                beforeExecute: { try Disk.write(target + "/D copy/c.txt", "someone else's c") },
                resolve: { $0.reason == .destinationCreated ? .merge : .keepBoth }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.first?.reason == .destinationCreated)
            #expect(run.result?.status != .failed)
            #expect(Disk.read(target + "/D copy/c.txt") == "someone else's c")
            #expect(Disk.read(target + "/D copy/c copy.txt") == "new c")
        }
    }

    // T-dd08d729 F-343 F-477
    @Test func asksRatherThanDeletingPermanentlyWhenThereIsNoTrashAtAll() async throws {
        try await withPlaces { root, _ in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/notes.txt"], destination: target, resolve: { _ in nil }
            ).run(NativeWriteFileSystem())

            #expect(run.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(run.result?.items.first?.status == .failed)
            #expect(Disk.read(target + "/notes.txt") == "old notes")
            #expect(Disk.list(target) == ["notes.txt"])
        }
    }

    // T-394acb48 F-481 F-345
    @Test func keepsTheExistingFileInPlaceWhenTheReplacementCantBeWritten() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")
            let trashed = Locked<[String]>([])
            let fileSystem = TestFileSystem(withTrash(trashDir))
            fileSystem.copyFileImpl = { _, destination, _, _ in
                // The disk fills up half way through.
                try Disk.write(destination, "new no")
                throw NativeError(message: "ENOSPC: no space left on device", code: "ENOSPC")
            }
            let trash = trashInto(trashDir)
            fileSystem.trash = { path in
                trashed.mutate { $0.append(path) }
                return try trash(path)
            }

            let run = try await SafetyPaste(mode: .copy, sources: [source + "/notes.txt"], destination: target)
                .run(fileSystem)

            #expect(run.result?.items.first?.status == .failed)
            #expect(run.result?.items.first?.error == "There isn't enough free space on the destination disk.")
            #expect(trashed.value == [])
            #expect(Disk.read(target + "/notes.txt") == "old notes")
            #expect(Disk.list(target) == ["notes.txt"])
        }
    }

    // T-ee58de08 F-341 F-481
    @Test(.enabled(if: getuid() != 0, "files that can't be read are readable anyway as root"))
    func keepsTheExistingFolderWhenItemsInsideTheReplacementCantBeCopied() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "new a")
            try Disk.write(source + "/docs/b.txt", "new b")
            try Disk.write(target + "/docs/keep.txt", "existing work")
            Disk.chmod(source + "/docs/a.txt", 0o000)
            defer { Disk.chmod(source + "/docs/a.txt", 0o644) }

            let run = try await SafetyPaste(mode: .copy, sources: [source + "/docs"], destination: target)
                .run(withTrash(trashDir))

            #expect(run.result?.status == .failed)
            let item = run.result?.items.first
            #expect(item?.status == .failed)
            #expect(item?.error == "\u{201C}docs\u{201D} wasn't replaced because some items inside couldn't be copied.")
            #expect(item?.childFailureCount == 1)
            #expect(names(run.result?.items) == [["docs", "failed"], ["a.txt", "failed"]])
            #expect(Disk.list(trashDir) == [])
            #expect(Disk.list(target + "/docs") == ["keep.txt"])
            #expect(Disk.list(target) == ["docs"])
        }
    }

    // On the startup disk the Trash always exists: a failure there (a busy item, a permission) is reported, and
    // deleting for good is never offered instead.
    // T-fd669458 F-477
    @Test func failsTheItemWithoutOfferingToDeleteForGoodWhenTheTrashRefusesIt() async throws {
        try await withPlaces { root, _ in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/notes.txt", "new notes")
            try Disk.write(target + "/notes.txt", "old notes")
            let message = "\u{201C}notes.txt\u{201D} couldn\u{2019}t be moved to the trash because it\u{2019}s in use."

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/notes.txt"], destination: target, resolve: { _ in .overwrite }
            ).run(NativeWriteFileSystem(trash: { _ in throw OperationError(message) }))

            #expect(run.conflicts.isEmpty)
            #expect(run.result?.items.first?.status == .failed)
            #expect(run.result?.items.first?.error == message)
            #expect(Disk.read(target + "/notes.txt") == "old notes")
            #expect(Disk.list(target) == ["notes.txt"])
        }
    }

    // T-a95de86e F-343 F-345 F-477
    @Test func movesAReplacingFolderBackWhenTheTrashIsUnavailableAndThePersonSkips() async throws {
        try await withPlaces { root, _ in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "new a")
            try Disk.write(target + "/docs/keep.txt", "existing work")
            let sourceIno = Disk.lstat(source + "/docs")?.ino
            let noTrash = NativeWriteFileSystem(trash: { _ in throw noTrashHere() })

            let skipped = try await SafetyPaste(
                mode: .cut, sources: [source + "/docs"], destination: target, resolve: { _ in .skip }
            ).run(noTrash)

            #expect(skipped.conflicts.map(\.reason) == [.trashUnavailable])
            #expect(skipped.result?.items.first?.status == .skipped)
            // Moved to a hidden name by rename, then moved back: still the same folder.
            #expect(Disk.lstat(source + "/docs")?.ino == sourceIno)
            #expect(Disk.read(source + "/docs/a.txt") == "new a")
            #expect(Disk.list(target + "/docs") == ["keep.txt"])
            #expect(Disk.list(target) == ["docs"])

            let replaced = try await SafetyPaste(
                mode: .cut, sources: [source + "/docs"], destination: target, resolve: { _ in .overwrite }
            ).run(noTrash)

            #expect(replaced.result?.status == .completed)
            #expect(!Disk.exists(source + "/docs"))
            #expect(Disk.list(target + "/docs") == ["a.txt"])
        }
    }

    // T-c44da6d3 F-482
    @Test func replacesAFolderWithOneMovedFromAnotherDiskRemovingTheOriginalsLast() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "new a")
            try Disk.write(source + "/docs/sub/b.txt", "new b")
            try Disk.write(target + "/docs/keep.txt", "existing work")
            let seenAtSwap = Locked<[String]>([])
            let fileSystem = TestFileSystem(withTrash(trashDir))
            // Behaves like another disk: nothing under "source" can be renamed away.
            fileSystem.renameExclusiveImpl = { from, to in
                if from.hasPrefix(source + "/") {
                    throw NativeError(message: "EXDEV", code: "EXDEV")
                }
                // The swap itself; each copied file is also renamed into place on the way.
                if to == target + "/docs" {
                    seenAtSwap.mutate { $0 += Disk.list(source + "/docs") }
                }
                if Darwin.rename(from, to) != 0 {
                    throw NativeError.errno(errno, syscall: "rename", path: from, dest: to)
                }
            }

            let run = try await SafetyPaste(mode: .cut, sources: [source + "/docs"], destination: target)
                .run(fileSystem)

            #expect(run.result?.status == .completed)
            // The originals were all still there when the copy took the existing folder's place.
            #expect(seenAtSwap.value.sorted() == ["a.txt", "sub"])
            #expect(!Disk.exists(source + "/docs"))
            #expect(Disk.read(target + "/docs/a.txt") == "new a")
            #expect(Disk.read(target + "/docs/sub/b.txt") == "new b")
            #expect(Disk.read(trashDir + "/docs/keep.txt") == "existing work")
            #expect(Disk.list(target) == ["docs"])
        }
    }

    // T-78e72cea F-482
    @Test func keepsAMovedFolderWhoseItemsWereSkippedWhileMerging() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/D/a.txt", "new a")
            try Disk.write(source + "/D/b.txt", "new b")
            try Disk.write(target + "/D/a.txt", "old a")

            let run = try await SafetyPaste(
                mode: .cut, sources: [source + "/D"], destination: target, policy: NativePaste.keepExisting
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .partial)
            #expect(Disk.list(source + "/D") == ["a.txt"])
            #expect(Disk.read(target + "/D/a.txt") == "old a")
            #expect(Disk.read(target + "/D/b.txt") == "new b")
        }
    }

    // T-2b3173c1 F-483
    @Test func asksInsteadOfMovingOverAnItemThatAppearsAtTheLastMoment() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/x.txt", "moved")
            try Disk.makeDirectories(target)
            let fileSystem = TestFileSystem(withTrash(trashDir))
            // Someone saves "x.txt" right before the move.
            fileSystem.renameExclusiveImpl = { from, to in
                if to == target + "/x.txt" && !Disk.exists(to) {
                    try Disk.write(to, "someone else's")
                }
                try NativeFS.renameExclusive(from, to)
            }

            let run = try await SafetyPaste(
                mode: .cut, sources: [source + "/x.txt"], destination: target, resolve: { _ in .skip }
            ).run(fileSystem)

            #expect(run.conflicts.map(\.reason) == [.destinationCreated])
            #expect(run.result?.items.first?.status == .skipped)
            #expect(Disk.read(target + "/x.txt") == "someone else's")
            #expect(Disk.read(source + "/x.txt") == "moved")
        }
    }

    // T-b79eeb1a F-483
    @Test func doesntAskAgainWhenOnlyAFoldersTimestampChanged() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "new a")
            try Disk.makeDirectories(target + "/docs")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/docs"], destination: target,
                beforeExecute: {
                    try Disk.write(target + "/docs/.DS_Store", "finder")
                    let later = (Date().timeIntervalSince1970 + 60) * 1000
                    try NativeFS.utimes(target + "/docs", atimeMs: later, mtimeMs: later)
                }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.list(target + "/docs") == ["a.txt"])
        }
    }

    // T-7f58cc34 F-483
    @Test(arguments: [(CopyPasteChoice.overwrite, ["a.txt"] as [String]?), (.skip, nil)])
    func asksWhenTheFolderToMergeIntoWasDeleted(answer: CopyPasteChoice, expected: [String]?) async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/D/a.txt", "new a")
            try Disk.makeDirectories(target + "/D")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/D"], destination: target, policy: NativePaste.keepExisting,
                beforeExecute: { try NativeWriteFileSystem().rm(target + "/D", recursive: true, force: false) },
                resolve: { _ in answer }
            ).run(withTrash(trashDir))

            #expect(run.conflicts.map(\.reason) == [.destinationDeleted])
            #expect(run.conflicts.first?.currentDestinationFingerprint.exists == false)
            #expect(run.result?.items.first?.status == (answer == .skip ? .skipped : .completed))
            if let expected {
                #expect(Disk.list(target + "/D") == expected)
            } else {
                #expect(!Disk.exists(target + "/D"))
            }
        }
    }

    // T-e18bad5b F-484 F-268
    @Test(.enabled(if: getuid() != 0, "files that can't be read are readable anyway as root"))
    func reportsAFolderWhoseEveryItemFailedAsFailedWithTheCount() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/docs/a.txt", "a")
            try Disk.write(source + "/docs/b.txt", "b")
            try Disk.makeDirectories(target)
            Disk.chmod(source + "/docs/a.txt", 0o000)
            Disk.chmod(source + "/docs/b.txt", 0o000)
            defer {
                Disk.chmod(source + "/docs/a.txt", 0o644)
                Disk.chmod(source + "/docs/b.txt", 0o644)
            }

            let run = try await SafetyPaste(mode: .copy, sources: [source + "/docs"], destination: target)
                .run(withTrash(trashDir))

            #expect(run.result?.status == .failed)
            #expect(run.result?.items.first?.status == .failed)
            #expect(run.result?.items.first?.error == nil)
            #expect(run.result?.items.first?.childFailureCount == 2)
        }
    }

    // The folder is built under a hidden name: stopped, it goes, and no half folder is left under its real name to
    // pass for the whole one.
    // T-c1242d6a F-265 F-362
    @Test func leavesNoPartOfAFolderBehindWhenThePasteIsStopped() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            for name in ["a.txt", "b.txt", "c.txt"] {
                try Disk.write(source + "/docs/" + name, name)
            }
            try Disk.makeDirectories(target)

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/docs"], destination: target,
                onEvent: { event, signal in
                    if event.status == .running && event.currentSourcePath?.hasSuffix("a.txt") == true {
                        signal.stop()
                    }
                }
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .cancelled)
            #expect(names(run.result?.items) == [["docs", "cancelled"]])
            #expect(Disk.list(target) == [])
        }
    }

    // T-06516805
    @Test func givesAKeepBothCopyANameNoOtherPastedItemUses() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            try Disk.write(source + "/a.txt", "pasted a")
            try Disk.write(source + "/a copy.txt", "pasted a copy")
            try Disk.write(target + "/a.txt", "existing a")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/a.txt", source + "/a copy.txt"], destination: target,
                policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip)
            ).run(withTrash(trashDir))

            #expect(run.conflicts.isEmpty)
            #expect(run.result?.status == .completed)
            #expect(Disk.read(target + "/a copy 2.txt") == "pasted a")
            #expect(Disk.read(target + "/a copy.txt") == "pasted a copy")
        }
    }

    // T-e19c988d
    @Test func shortensAKeepBothNameThatWouldBeLongerThanTheFileSystemAllows() async throws {
        try await withPlaces { root, trashDir in
            let source = root + "/source"
            let target = root + "/target"
            let longName = String(repeating: "n", count: 246) + ".txt"
            try Disk.write(source + "/" + longName, "pasted")
            try Disk.write(target + "/" + longName, "existing")

            let run = try await SafetyPaste(
                mode: .copy, sources: [source + "/" + longName], destination: target,
                policy: CopyPastePolicy(file: .keepBoth, directory: .merge, mismatch: .skip)
            ).run(withTrash(trashDir))

            #expect(run.result?.status == .completed)
            let copyName = Disk.list(target).first { $0 != longName } ?? ""
            #expect(copyName.utf8.count <= 255)
            #expect(copyName.hasSuffix(" copy.txt"))
        }
    }
}

/// A value several threads change, behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
