// Port of apps/desktop/src/renderer/lib/copyPasteClipboard.test.ts
import Foundation
import Testing

@testable import FTFoundation

struct CopyPasteClipboardTests {
    static let now = "2026-03-09T00:00:00.000Z"

    private func write(
        _ action: String, mode: ClipboardMode? = nil, replaced: [String] = [],
        _ items: [(String?, String?, String)]
    ) -> ClipboardWrite {
        ClipboardWrite(
            action: action, mode: mode,
            items: items.map { WriteEffectItem(sourcePath: $0.0, destinationPath: $0.1, status: $0.2) },
            replacedPaths: replaced)
    }

    private func file(_ kind: EntryKind = .file) -> ClipboardSourceEntry {
        ClipboardSourceEntry(kind: kind, isSymlink: false)
    }

    // T-7e5d9a4e
    // B-CLIP-023
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
        #expect(
            one.icon
                == .item(
                    ClipboardItemEntry(
                        path: "/tmp/a.txt", name: "a.txt", fileExtension: "txt", kind: .file, isHidden: false,
                        isSymlink: false)))
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
        #expect(many.icon == .items(.mixed))
        #expect(many.accessibilityLabel == "Clipboard: 3 items cut")
    }

    // T-6566d4d4
    // B-CLIP-023
    @Test func drawsSeveralFoldersOrSeveralFilesAsAPairOfTheirOwnIcon() {
        func describe(_ kind: EntryKind) -> ClipboardSummary? {
            ClipboardRules.describe(
                ClipboardRules.set(
                    .copy, ["/tmp/a", "/tmp/b"], capturedAt: Self.now,
                    entries: ["/tmp/a": file(kind), "/tmp/b": file(kind)]))
        }
        #expect(describe(.directory)?.breakdown == "2 folders")
        #expect(describe(.directory)?.icon == .items(.folders))
        #expect(describe(.file)?.breakdown == "2 files")
        #expect(describe(.file)?.icon == .items(.files))
        #expect(ClipboardIcon.pair(.folders).front == .genericFolder)
        #expect(ClipboardIcon.pair(.files).back == .genericFile)
        #expect(ClipboardIcon.pair(.mixed) == (.genericFolder, .genericFile))
    }

    // T-fdc40895
    // B-CLIP-006 B-CLIP-023
    @Test func doesNotGuessWhatAnItemIsWhenItWasCopiedByPathAlone() {
        let summary = ClipboardRules.describe(ClipboardRules.set(.copy, ["/tmp/a", "/tmp/b.md"], capturedAt: Self.now))
        #expect(summary?.breakdown == nil)
        #expect(summary?.icon == .items(.mixed))
        #expect(summary?.items.map(\.entry.kind) == [.other, .other])
        #expect(summary?.items.map(\.isFolder) == [nil, nil])
    }

    // T-8c69b7f2
    // B-CLIP-003
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

    // T-084d6478
    // B-CLIP-004
    @Test func takesOneItemOffTheClipboardAndEmptiesItWithTheLast() {
        let clipboard = ClipboardRules.set(
            .cut, ["/tmp/a", "/tmp/b"], capturedAt: Self.now, entries: ["/tmp/a": file(.directory)])
        let withoutA = ClipboardRules.removeItem(clipboard, "/tmp/a")
        #expect(withoutA == .ready(mode: .cut, sourcePaths: ["/tmp/b"], sourceEntries: [:], capturedAt: Self.now))
        #expect(ClipboardRules.removeItem(withoutA, "/tmp/missing") == withoutA)
        #expect(ClipboardRules.removeItem(withoutA, "/tmp/b") == .empty)
    }

    // T-5525dd65
    @Test func groupsTheItemsUnderTheFoldersTheyCameFrom() {
        let items = ClipboardRules.items(
            ClipboardRules.set(.copy, ["/Users/demo/a.txt", "/top", "/Users/demo/b.txt"], capturedAt: Self.now))
        let groups = ClipboardRules.groupByFolder(items)
        #expect(groups.map(\.parentPath) == ["/Users/demo", "/"])
        #expect(groups.map(\.label) == ["demo", "/"])
        #expect(groups.map { $0.items.map(\.name) } == [["a.txt", "b.txt"], ["top"]])
    }

    // T-4347c097
    @Test func clearsToAnEmptyClipboardState() {
        #expect(CopyPasteClipboard.empty.sourcePaths.isEmpty)
        #expect(ClipboardRules.clearedAfterSuccessfulPaste(.empty) == .empty)
    }

    // T-7e03550a
    @Test func buildsAPasteRequestOnlyWhenClipboardStateIsReady() {
        #expect(ClipboardRules.pasteRequest(.empty, destination: "/tmp/target") == nil)
        #expect(
            ClipboardRules.pasteRequest(
                ClipboardRules.set(.copy, ["/tmp/a"], capturedAt: Self.now), destination: "/tmp/target")
                == PasteRequest(
                    mode: .copy, sourcePaths: ["/tmp/a"], destinationDirectoryPath: "/tmp/target", action: "paste"))
    }

    // T-2e58b19b
    @Test func clearsClipboardStateAfterASuccessfulPaste() {
        #expect(
            ClipboardRules.clearedAfterSuccessfulPaste(ClipboardRules.set(.copy, ["/tmp/a"], capturedAt: Self.now))
                == .empty)
        #expect(
            ClipboardRules.clearedAfterSuccessfulPaste(ClipboardRules.set(.cut, ["/tmp/a"], capturedAt: Self.now))
                == .empty)
    }

    // T-b438a2bd
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

    // T-cfe071bf
    // B-CLIP-004 B-CLIP-040
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

    // T-af27fd51
    // B-CLIP-041 T-39f35623
    @Test func dropsTrashedItemsAndAnythingInsideThem() {
        #expect(
            ClipboardRules.dropPaths(clipboard, ["/Users/demo/Folder", "/Users/demo/report.pdf"])
                == .ready(mode: .copy, sourcePaths: ["/Users/demo/other.txt"], sourceEntries: [:], capturedAt: Self.now)
        )
        #expect(ClipboardRules.dropPaths(clipboard, ["/Users/demo"]) == .empty)
        #expect(ClipboardRules.dropPaths(clipboard, ["/Users/demo/Fold"]) == clipboard)
    }

    // T-d7dde650
    // B-CLIP-040 B-CLIP-042 T-01eb2f87 T-39f35623 T-d9f6ec5c
    @Test func followsAFinishedWriteCountingOnlyTheItemsItCompleted() {
        func follow(_ write: ClipboardWrite) -> [String] {
            ClipboardRules.followThroughWrite(clipboard, write).sourcePaths
        }
        #expect(
            follow(write("rename", [("/Users/demo/report.pdf", "/Users/demo/final.pdf", "completed")]))
                == ["/Users/demo/final.pdf", "/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"])
        #expect(
            follow(
                write(
                    "move_to",
                    [
                        ("/Users/demo/other.txt", "/Volumes/Backup/other.txt", "completed"),
                        ("/Users/demo/report.pdf", "/Volumes/Backup/report.pdf", "failed"),
                    ]))
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt", "/Volumes/Backup/other.txt"])
        #expect(
            follow(write("trash", [("/Users/demo/Folder", nil, "completed")]))
                == ["/Users/demo/report.pdf", "/Users/demo/other.txt"])
        #expect(
            follow(write("delete_immediately", [("/Users/demo/other.txt", nil, "completed")]))
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt"])
        // Copies leave the originals where they were.
        let paste = write("paste", [("/Users/demo/report.pdf", "/tmp/report.pdf", "completed")])
        #expect(ClipboardRules.followThroughWrite(clipboard, paste) == clipboard)
        let copyPaste = write("paste", mode: .copy, [("/Users/demo/report.pdf", "/tmp/report.pdf", "completed")])
        #expect(ClipboardRules.followThroughWrite(clipboard, copyPaste) == clipboard)
    }

    // T-a8972bed
    // B-CLIP-043
    @Test func dropsCopiedItemsAReplaceRemovedAndFollowsOneMovedOntoTheirPlace() {
        let moved = write(
            "move_to", replaced: ["/Users/demo/Folder/inner.txt"],
            [("/Users/demo/other.txt", "/Users/demo/Folder/inner.txt", "completed")])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, moved).sourcePaths
                == ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt"])
        let pasted = write(
            "paste", mode: .copy, replaced: ["/Users/demo/report.pdf"],
            [("/tmp/report.pdf", "/Users/demo/report.pdf", "completed")])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, pasted).sourcePaths
                == ["/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"])
    }

    // T-49bf0ba3
    // B-CLIP-044
    @Test func keepsAnItemAlreadyInAFolderMergedInto() {
        let copied = ClipboardRules.set(.copy, ["/src/F/x", "/dst/F/y"], capturedAt: Self.now)
        let result = write("move_to", [("/src/F", "/dst/F", "completed")])
        #expect(ClipboardRules.followThroughWrite(copied, result).sourcePaths == ["/dst/F/x", "/dst/F/y"])
    }

    // T-05a47f0d
    // B-CLIP-044
    @Test func leavesItemsWhereAMergeLeftThemWithTheFoldersHoldingThem() {
        let copied = ClipboardRules.set(
            .copy, ["/src/F/a", "/src/F/b", "/src/F/sub", "/src/F/sub/c/d", "/src/F/other/e", "/src/G"],
            capturedAt: Self.now)
        let items: [(String?, String?, String)] = [
            ("/src/F", "/dst/F", "completed"), ("/src/F/a", "/dst/F/a", "skipped"),
            ("/src/F/b", "/dst/F/b", "completed"),
            ("/src/F/sub/c", "/dst/F/sub/c", "failed"), ("/src/G", "/dst/G", "completed"),
        ]
        let result = write("paste", mode: .cut, items)
        #expect(
            ClipboardRules.followThroughWrite(copied, result).sourcePaths == [
                "/src/F/a", "/dst/F/b", "/src/F/sub", "/src/F/sub/c/d", "/dst/F/other/e", "/dst/G",
            ])
        // The merged folder itself is still at its old path while anything is left in it...
        let folder = ClipboardRules.set(.copy, ["/src/F"], capturedAt: Self.now)
        #expect(ClipboardRules.followThroughWrite(folder, result) == folder)
        // ...and is followed once everything in it went.
        let completedOnly = write("paste", mode: .cut, items.filter { $0.2 == "completed" })
        #expect(ClipboardRules.followThroughWrite(folder, completedOnly).sourcePaths == ["/dst/F"])
        // An item that failed outside the folder that moved doesn't keep what moved.
        let failedFolder = write(
            "paste", mode: .cut, items.filter { $0.0 != "/src/F" } + [("/src/F", "/dst/F", "failed")])
        #expect(
            ClipboardRules.followThroughWrite(
                ClipboardRules.set(.copy, ["/src/F/b"], capturedAt: Self.now), failedFolder
            )
            .sourcePaths == ["/dst/F/b"])
    }

    // T-3c3c0bea
    // B-CLIP-045
    @Test func cancelsACutWhenAReplaceRemovesAnItemInIt() {
        let cut = ClipboardRules.set(.cut, ["/Users/demo/report.pdf"], capturedAt: Self.now)
        let pasted = write(
            "paste", mode: .copy, replaced: ["/Users/demo/report.pdf"],
            [("/tmp/report.pdf", "/Users/demo/report.pdf", "completed")])
        #expect(ClipboardRules.followThroughWrite(cut, pasted) == .empty)
    }

    // T-3f0156e2
    @Test func followsItemsAPasteAfterCutMoved() {
        let pasted = write("paste", mode: .cut, [("/Users/demo/Folder", "/Volumes/Backup/Folder", "completed")])
        #expect(
            ClipboardRules.followThroughWrite(clipboard, pasted).sourcePaths
                == ["/Users/demo/report.pdf", "/Volumes/Backup/Folder/inner.txt", "/Users/demo/other.txt"])
    }

    // T-c80876f4
    // B-CLIP-045 T-e163f9b3
    @Test func cancelsAWholeCutOnceAnyItemInItIsRenamedMovedOrDeleted() {
        let cut = ClipboardRules.set(
            .cut, ["/Users/demo/report.pdf", "/Users/demo/Folder/inner.txt", "/Users/demo/other.txt"],
            capturedAt: Self.now)
        for result in [
            write("rename", [("/Users/demo/report.pdf", "/Users/demo/final.pdf", "completed")]),
            write("move_to", [("/Users/demo/Folder", "/Volumes/Backup/Folder", "completed")]),
            write("batch_rename", [("/Users/demo/other.txt", "/Users/demo/other 2.txt", "failed")]),
            write("trash", [("/Users/demo/other.txt", nil, "completed")]),
            write("delete_immediately", [("/Users/demo/report.pdf", nil, "completed")]),
        ] {
            #expect(ClipboardRules.followThroughWrite(cut, result) == .empty)
        }
        for result in [
            write(
                "move_to",
                [
                    ("/Users/demo/report.pdf", "/Volumes/Backup/report.pdf", "failed"),
                    ("/Users/demo/Fold", "/Volumes/Backup/Fold", "completed"),
                ]),
            write("trash", [("/Users/demo/other.txt", nil, "failed")]),
            write("paste", [("/Users/demo/report.pdf", "/tmp/report.pdf", "completed")]),
        ] {
            #expect(ClipboardRules.followThroughWrite(cut, result) == cut)
        }
    }

    // T-bf2db272
    // B-CLIP-040 B-CLIP-046
    @Test func followsAMoveOfThousandsOfItemsAtOnce() {
        let paths = (0..<20_000).map { "/Users/demo/a/item-\($0)" }
        let copied = ClipboardRules.set(.copy, paths, capturedAt: Self.now)
        let result = ClipboardWrite(
            action: "move_to",
            items: paths.enumerated().map { index, path in
                WriteEffectItem(
                    sourcePath: path, destinationPath: path.replacingOccurrences(of: "/a/", with: "/b/"),
                    status: index == 0 ? "failed" : "completed")
            })
        let started = ContinuousClock.now
        let followed = ClipboardRules.followThroughWrite(copied, result)
        let elapsed = ContinuousClock.now - started
        #expect(Array(followed.sourcePaths.prefix(2)) == ["/Users/demo/a/item-0", "/Users/demo/b/item-1"])
        #expect(elapsed < .seconds(5))
    }

    // T-a560f3a4
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
