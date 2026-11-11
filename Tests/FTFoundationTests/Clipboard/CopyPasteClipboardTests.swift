import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct CopyPasteClipboardTests {
    static let now = "2026-03-09T00:00:00.000Z"

    private func write(
        _ action: WriteOperationAction, mode: ClipboardMode? = nil, replaced: [String] = [],
        _ items: [(String?, String?, WriteItemEndStatus)]
    ) -> ClipboardWrite {
        ClipboardWrite(
            action: action, mode: mode,
            items: items.map { WriteEffectItem(sourcePath: $0.0, destinationPath: $0.1, status: $0.2) },
            replacedPaths: replaced)
    }

    private func file(_ kind: EntryKind = .file) -> ClipboardSourceEntry {
        ClipboardSourceEntry(kind: kind, isSymlink: false)
    }

    @Test func namesOneItemAndCountsSeveral() throws {
        #expect(ClipboardRules.describe(.empty) == nil)
        let one = try #require(
            ClipboardRules.describe(
                ClipboardRules.set(.copy, ["/tmp/a.txt"], capturedAt: Self.now, entries: ["/tmp/a.txt": file()])))
        #expect(one.mode == .copy)
        #expect(one.count == 1)
        #expect(one.countLabel == "1 item copied")
        #expect(one.label == "a.txt copied")
        #expect(one.breakdown == nil)
        let many = try #require(
            ClipboardRules.describe(
                ClipboardRules.set(
                    .cut, ["/tmp/docs", "/tmp/a.txt", "/tmp/b.txt"], capturedAt: Self.now,
                    entries: ["/tmp/docs": file(.directory), "/tmp/a.txt": file(), "/tmp/b.txt": file()])))
        #expect(many.mode == .cut)
        #expect(many.count == 3)
        #expect(many.countLabel == "3 items cut")
        #expect(many.label == "3 items cut")
        #expect(many.breakdown == "1 folder and 2 files")
        #expect(many.accessibilityLabel == "Clipboard: 3 items cut")
    }

    @Test func breaksSeveralItemsDownByKind() {
        func describe(_ kind: EntryKind) -> ClipboardSummary? {
            ClipboardRules.describe(
                ClipboardRules.set(
                    .copy, ["/tmp/a", "/tmp/b"], capturedAt: Self.now,
                    entries: ["/tmp/a": file(kind), "/tmp/b": file(kind)]))
        }
        #expect(describe(.directory)?.breakdown == "2 folders")
        #expect(describe(.file)?.breakdown == "2 files")
    }

    @Test func doesNotGuessWhatAnItemIsWhenItWasCopiedByPathAlone() {
        let summary = ClipboardRules.describe(ClipboardRules.set(.copy, ["/tmp/a", "/tmp/b.md"], capturedAt: Self.now))
        #expect(summary?.breakdown == nil)
        #expect(summary?.items.map(\.entry.kind) == [.other, .other])
        #expect(summary?.items.map(\.isFolder) == [nil, nil])
    }

    @Test func storesACopyClipboardPayloadWithDedupedPaths() {
        #expect(
            ClipboardRules.set(
                .copy, ["/tmp/a", "/tmp/a", "/tmp/b"], capturedAt: Self.now,
                entries: ["/tmp/a": file(.directory), "/tmp/elsewhere": file()])
                == .ready(
                    mode: .copy, sourcePaths: ["/tmp/a", "/tmp/b"], sourceEntries: ["/tmp/a": file(.directory)],
                    capturedAt: Self.now))
        #expect(ClipboardRules.set(.copy, ["", ""], capturedAt: Self.now) == .empty)
    }

    @Test func takesOneItemOffTheClipboardAndEmptiesItWithTheLast() {
        let clipboard = ClipboardRules.set(
            .cut, ["/tmp/a", "/tmp/b"], capturedAt: Self.now, entries: ["/tmp/a": file(.directory)])
        let withoutA = ClipboardRules.removeItem(clipboard, "/tmp/a")
        #expect(withoutA == .ready(mode: .cut, sourcePaths: ["/tmp/b"], sourceEntries: [:], capturedAt: Self.now))
        #expect(ClipboardRules.removeItem(withoutA, "/tmp/missing") == withoutA)
        #expect(ClipboardRules.removeItem(withoutA, "/tmp/b") == .empty)
    }

    @Test func groupsTheItemsUnderTheFoldersTheyCameFrom() {
        let items = ClipboardRules.items(
            ClipboardRules.set(.copy, ["/Users/demo/a.txt", "/top", "/Users/demo/b.txt"], capturedAt: Self.now))
        let groups = ClipboardRules.groupByFolder(items)
        #expect(groups.map(\.parentPath) == ["/Users/demo", "/"])
        #expect(groups.map(\.label) == ["demo", "/"])
        #expect(groups.map { $0.items.map(\.name) } == [["a.txt", "b.txt"], ["top"]])
    }

    @Test func clearsToAnEmptyClipboardState() {
        #expect(CopyPasteClipboard.empty.sourcePaths.isEmpty)
    }

    @Test func reportsWhetherClipboardItemsAreAvailable() {
        #expect(!CopyPasteClipboard.empty.hasItems)
        #expect(ClipboardRules.set(.copy, ["/tmp/a"], capturedAt: Self.now).hasItems)
    }

    // MARK: Following items the app renames, moves and deletes

    private var clipboard: CopyPasteClipboard {
        ClipboardRules.set(
            .copy, ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"],
            capturedAt: Self.now,
            entries: ["/Users/demo/report.pdf": file(), "/Users/demo/Folder/inner.txt": file()])
    }

    @Test func renamesAnItemAndTheItemsInsideARenamedFolder() {
        let next = ClipboardRules.remapPaths(
            clipboard,
            [("/Users/demo/report.pdf", "/Users/demo/final.pdf"), ("/Users/demo/Folder", "/Users/demo/Archive")])
        #expect(
            next
                == .ready(
                    mode: .copy,
                    sourcePaths: ["/Users/demo/final.pdf", "/Users/demo/Archive/inner.txt", "/Users/demo/other.txt"],
                    sourceEntries: ["/Users/demo/final.pdf": file(), "/Users/demo/Archive/inner.txt": file()],
                    capturedAt: Self.now))
        // A path that only starts with the same letters is another item.
        #expect(ClipboardRules.remapPaths(clipboard, [("/Users/demo/Fold", "/Users/demo/X")]) == clipboard)
    }

    @Test func dropsTrashedItemsAndAnythingInsideThem() {
        #expect(
            ClipboardRules.dropPaths(clipboard, ["/Users/demo/Folder", "/Users/demo/report.pdf"])
                == .ready(mode: .copy, sourcePaths: ["/Users/demo/other.txt"], sourceEntries: [:], capturedAt: Self.now)
        )
        #expect(ClipboardRules.dropPaths(clipboard, ["/Users/demo"]) == .empty)
        #expect(ClipboardRules.dropPaths(clipboard, ["/Users/demo/Fold"]) == clipboard)
    }

    @Test func followsAFinishedWriteCountingOnlyTheItemsItCompleted() {
        func follow(_ write: ClipboardWrite) -> [String] {
            ClipboardRules.followThroughWrite(clipboard, write).sourcePaths
        }
        #expect(
            follow(write(.rename, [("/Users/demo/report.pdf", "/Users/demo/final.pdf", .completed)]))
                == ["/Users/demo/final.pdf", "/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"])
        #expect(
            follow(
                write(
                    .moveTo,
                    [
                        ("/Users/demo/other.txt", "/Volumes/Backup/other.txt", .completed),
                        ("/Users/demo/report.pdf", "/Volumes/Backup/report.pdf", .failed),
                    ]))
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt", "/Volumes/Backup/other.txt"])
        #expect(
            follow(write(.trash, [("/Users/demo/Folder", nil, .completed)]))
                == ["/Users/demo/report.pdf", "/Users/demo/other.txt"])
        #expect(
            follow(write(.deleteImmediately, [("/Users/demo/other.txt", nil, .completed)]))
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt"])
        // Copies leave the originals where they were.
        let paste = write(.paste, [("/Users/demo/report.pdf", "/tmp/report.pdf", .completed)])
        #expect(ClipboardRules.followThroughWrite(clipboard, paste) == clipboard)
        let copyPaste = write(.paste, mode: .copy, [("/Users/demo/report.pdf", "/tmp/report.pdf", .completed)])
        #expect(ClipboardRules.followThroughWrite(clipboard, copyPaste) == clipboard)
    }

    @Test func dropsCopiedItemsAReplaceRemovedAndFollowsOneMovedOntoTheirPlace() {
        let moved = write(
            .moveTo, replaced: ["/Users/demo/Folder/inner.txt"],
            [("/Users/demo/other.txt", "/Users/demo/Folder/inner.txt", .completed)])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, moved).sourcePaths
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt"])
        let pasted = write(
            .paste, mode: .copy, replaced: ["/Users/demo/report.pdf"],
            [("/tmp/report.pdf", "/Users/demo/report.pdf", .completed)])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, pasted).sourcePaths
                == ["/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"])
    }

    @Test func keepsAnItemAlreadyInAFolderMergedInto() {
        let copied = ClipboardRules.set(.copy, ["/src/F/x", "/dst/F/y"], capturedAt: Self.now)
        let result = write(.moveTo, [("/src/F", "/dst/F", .completed)])
        #expect(ClipboardRules.followThroughWrite(copied, result).sourcePaths == ["/dst/F/x", "/dst/F/y"])
    }

    @Test func leavesItemsWhereAMergeLeftThemWithTheFoldersHoldingThem() {
        let copied = ClipboardRules.set(
            .copy, ["/src/F/a", "/src/F/b", "/src/F/sub", "/src/F/sub/c/d", "/src/F/other/e", "/src/G"],
            capturedAt: Self.now)
        let items: [(String?, String?, WriteItemEndStatus)] = [
            ("/src/F", "/dst/F", .completed), ("/src/F/a", "/dst/F/a", .skipped),
            ("/src/F/b", "/dst/F/b", .completed),
            ("/src/F/sub/c", "/dst/F/sub/c", .failed), ("/src/G", "/dst/G", .completed),
        ]
        let result = write(.paste, mode: .cut, items)
        #expect(
            ClipboardRules.followThroughWrite(copied, result).sourcePaths == [
                "/src/F/a", "/dst/F/b", "/src/F/sub", "/src/F/sub/c/d", "/dst/F/other/e", "/dst/G",
            ])
        // The merged folder itself is still at its old path while anything is left in it...
        let folder = ClipboardRules.set(.copy, ["/src/F"], capturedAt: Self.now)
        #expect(ClipboardRules.followThroughWrite(folder, result) == folder)
        // ...and is followed once everything in it went.
        let completedOnly = write(.paste, mode: .cut, items.filter { $0.2 == .completed })
        #expect(ClipboardRules.followThroughWrite(folder, completedOnly).sourcePaths == ["/dst/F"])
        // An item that failed outside the folder that moved doesn't keep what moved.
        let failedFolder = write(
            .paste, mode: .cut, items.filter { $0.0 != "/src/F" } + [("/src/F", "/dst/F", .failed)])
        #expect(
            ClipboardRules.followThroughWrite(
                ClipboardRules.set(.copy, ["/src/F/b"], capturedAt: Self.now), failedFolder
            )
            .sourcePaths == ["/dst/F/b"])
    }

    @Test func cancelsACutWhenAReplaceRemovesAnItemInIt() {
        let cut = ClipboardRules.set(.cut, ["/Users/demo/report.pdf"], capturedAt: Self.now)
        let pasted = write(
            .paste, mode: .copy, replaced: ["/Users/demo/report.pdf"],
            [("/tmp/report.pdf", "/Users/demo/report.pdf", .completed)])
        #expect(ClipboardRules.followThroughWrite(cut, pasted) == .empty)
    }

    @Test func followsItemsAPasteAfterCutMoved() {
        let pasted = write(.paste, mode: .cut, [("/Users/demo/Folder", "/Volumes/Backup/Folder", .completed)])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, pasted).sourcePaths
                == ["/Users/demo/report.pdf", "/Volumes/Backup/Folder/inner.txt", "/Users/demo/other.txt"])
    }

    @Test func cancelsAWholeCutOnceAnyItemInItIsRenamedMovedOrDeleted() {
        let cut = ClipboardRules.set(
            .cut, ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"],
            capturedAt: Self.now)
        for result in [
            write(.rename, [("/Users/demo/report.pdf", "/Users/demo/final.pdf", .completed)]),
            write(.moveTo, [("/Users/demo/Folder", "/Volumes/Backup/Folder", .completed)]),
            write(.batchRename, [("/Users/demo/other.txt", "/Users/demo/other 2.txt", .failed)]),
            write(.trash, [("/Users/demo/other.txt", nil, .completed)]),
            write(.deleteImmediately, [("/Users/demo/report.pdf", nil, .completed)]),
        ] {
            #expect(ClipboardRules.followThroughWrite(cut, result) == .empty)
        }
        for result in [
            write(
                .moveTo,
                [
                    ("/Users/demo/report.pdf", "/Volumes/Backup/report.pdf", .failed),
                    ("/Users/demo/Fold", "/Volumes/Backup/Fold", .completed),
                ]),
            write(.trash, [("/Users/demo/other.txt", nil, .failed)]),
            write(.paste, [("/Users/demo/report.pdf", "/tmp/report.pdf", .completed)]),
        ] {
            #expect(ClipboardRules.followThroughWrite(cut, result) == cut)
        }
    }

    @Test func followsAMoveOfThousandsOfItemsAtOnce() {
        let paths = (0..<20_000).map { "/Users/demo/a/item-\($0)" }
        let copied = ClipboardRules.set(.copy, paths, capturedAt: Self.now)
        let result = ClipboardWrite(
            action: .moveTo,
            items: paths.enumerated().map { index, path in
                WriteEffectItem(
                    sourcePath: path, destinationPath: path.replacingOccurrences(of: "/a/", with: "/b/"),
                    status: index == 0 ? .failed : .completed)
            })
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (followed, seconds) = CPUTime.measureThread { ClipboardRules.followThroughWrite(copied, result) }
        #expect(Array(followed.sourcePaths.prefix(2)) == ["/Users/demo/a/item-0", "/Users/demo/b/item-1"])
        #expect(seconds < 5)
    }

    @Test func dropsItemsAnotherAppTookAwayAndCancelsACutOfAny() {
        let removed = ClipboardRules.followThroughRemoval(clipboard, ["/Users/demo/other.txt"])
        #expect(removed.sourcePaths == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt"])
        let cut = ClipboardRules.set(.cut, ["/a/x", "/a/y"], capturedAt: Self.now)
        #expect(ClipboardRules.followThroughRemoval(cut, ["/a/y"]) == .empty)
        #expect(ClipboardRules.followThroughRemoval(cut, ["/a/z"]) == cut)
    }

    @Test func keepsNfcAndNfdSpellingsApart() {
        let nfc = "/a/Caf\u{E9}"
        let nfd = "/a/Cafe\u{301}"
        let both = ClipboardRules.set(.copy, [nfc, nfd], capturedAt: Self.now)
        #expect(both.sourcePaths.count == 2)
        #expect(ClipboardRules.dropPaths(both, [nfc]).sourcePaths.map { Array($0.utf8) } == [Array(nfd.utf8)])
    }

    @Test func groupsTheButtonCountAsEnUSDoes() {
        #expect(ClipboardSummary.grouped(7) == "7")
        #expect(ClipboardSummary.grouped(1234) == "1,234")
        #expect(ClipboardSummary.grouped(1_234_567) == "1,234,567")
    }
}
