// The selection in a folder that holds one name twice, its accent composed in one and decomposed in the other
import Testing

@testable import FTFoundation

/// Some disks keep the two spellings of an accent as two names in one folder (FAT as some systems write it, shares
/// from Linux). The selection takes them for two items: a path is told from another by its bytes.
struct TwoSpellingsSelectionTests {
    /// "café.txt" with its "é" as one scalar, and as an "e" and its accent.
    private let composed = "/demo/caf\u{E9}.txt"
    private let decomposed = "/demo/cafe\u{301}.txt"
    private let plain = "/demo/plain.txt"
    private var entries: [String] { [composed, decomposed, plain] }

    private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }
    private func bytes(_ path: String?) -> DiskPath? { path.map(DiskPath.init) }

    @Test func aSelectionOfOneSpellingIsNotASelectionOfTheOther() {
        #expect(ContentSelection.single(composed) != ContentSelection.single(decomposed))
        #expect(ContentSelection.of([composed, plain]) != ContentSelection.of([decomposed, plain]))
        #expect(
            ContentSelection(paths: [plain], anchorPath: composed, leadPath: plain)
                != ContentSelection(paths: [plain], anchorPath: decomposed, leadPath: plain))
        #expect(
            ContentSelection(paths: [plain], anchorPath: plain, leadPath: composed)
                != ContentSelection(paths: [plain], anchorPath: plain, leadPath: decomposed))
        #expect(ContentSelection.single(decomposed) == ContentSelection.single(decomposed))
    }

    @Test func sanitizingKeepsBothSpellingsAndDropsOnlyWhatIsNotListed() {
        let all = ContentSelection(
            paths: [composed, decomposed, "/demo/gone.txt"], anchorPath: decomposed, leadPath: "/demo/gone.txt")
        let kept = all.sanitized(entryPaths: entries)
        #expect(bytes(kept.paths) == bytes([composed, decomposed]))
        #expect(bytes(kept.anchorPath) == DiskPath(decomposed))
        #expect(bytes(kept.leadPath) == DiskPath(decomposed))

        // One spelling leaves the list: the other stays selected, and is not taken for it.
        let one = ContentSelection.of([composed, decomposed]).sanitized(entryPaths: [decomposed, plain])
        #expect(bytes(one.paths) == bytes([decomposed]))
        #expect(bytes(one.anchorPath) == DiskPath(decomposed))
        #expect(bytes(one.leadPath) == DiskPath(decomposed))

        // The one selected leaves, the other stays listed: nothing is selected, and the place is the one it left.
        let gone = ContentSelection.single(decomposed).sanitized(entryPaths: [composed, plain], previousPaths: entries)
        #expect(gone == ContentSelection(gapIndex: 1))
    }

    @Test func aRangeRunsFromOneSpellingToTheOther() {
        #expect(
            bytes(ContentSelection.rangePaths(entryPaths: entries, anchor: composed, target: decomposed))
                == bytes([composed, decomposed]))
        #expect(
            bytes(ContentSelection.rangePaths(entryPaths: entries, anchor: plain, target: decomposed))
                == bytes([decomposed, plain]))
        let extended = ContentSelection.single(composed).extended(entryPaths: entries, to: decomposed)
        #expect(bytes(extended.paths) == bytes([composed, decomposed]))
        #expect(bytes(extended.anchorPath) == DiskPath(composed))
        #expect(bytes(extended.leadPath) == DiskPath(decomposed))
    }

    @Test func aToggleFlipsTheSpellingPressedAndLeavesTheOther() {
        // Added beside the other.
        let both = ContentSelection.single(composed).toggled(entryPaths: entries, path: decomposed)
        #expect(bytes(both.paths) == bytes([composed, decomposed]))
        #expect(bytes(both.anchorPath) == DiskPath(decomposed))
        #expect(bytes(both.leadPath) == DiskPath(decomposed))
        // Taken out, the other stays, and becomes the lead and the anchor.
        let one = both.toggled(entryPaths: entries, path: decomposed)
        #expect(bytes(one.paths) == bytes([composed]))
        #expect(bytes(one.anchorPath) == DiskPath(composed))
        #expect(bytes(one.leadPath) == DiskPath(composed))
        // The other spelling of the only one selected is not the one selected: it is added, not taken out.
        let added = ContentSelection.single(decomposed).toggled(entryPaths: entries, path: composed)
        #expect(bytes(added.paths) == bytes([composed, decomposed]))
    }

    @Test func allInvertedMergedAndTheMarqueeCountEachSpelling() {
        #expect(bytes(ContentSelection.all(entryPaths: entries).paths) == bytes(entries))
        #expect(
            bytes(ContentSelection.single(composed).inverted(entryPaths: entries).paths) == bytes([decomposed, plain]))
        #expect(
            bytes(ContentSelection.merged(entryPaths: entries, current: [plain], next: [decomposed]))
                == bytes([decomposed, plain]))
        let picked = ContentSelection.marquee(entryPaths: entries, picked: [decomposed], lead: decomposed)
        #expect(bytes(picked.paths) == bytes([decomposed]))
        // A drag-to-select that adds or flips goes by the spelling the box touches.
        #expect(
            bytes(DragSelection.combine(startPaths: [composed], hitPaths: [decomposed], mode: .add))
                == bytes([composed, decomposed]))
        #expect(
            bytes(DragSelection.combine(startPaths: [composed, decomposed], hitPaths: [decomposed], mode: .toggle))
                == bytes([composed]))
    }

    // A size measured for one spelling's item is not the other's.
    @Test func aMeasuredSizeBelongsToTheSpellingItWasMeasuredFor() {
        let layout = DesignTokens.flowList(density: .standard)
        let narrow = DragSelectionSize(width: 10, height: layout.rowHeight)
        let box = DragSelectionBox(left: 40, top: 0, right: 60, bottom: 2 * layout.rowHeight)
        let hits = DragSelection.flowListItems(
            box: box, entryPaths: entries, rowsPerColumn: 3, rowHeight: layout.rowHeight, itemWidth: layout.itemWidth,
            columnGap: layout.columnGap, sizes: [DiskPath(composed): narrow])
        #expect(bytes(hits.map(\.path)) == bytes([decomposed]))
    }

    // Back and Forward remember a folder by its own spelling.
    @Test func aFolderIsRememberedByItsOwnSpelling() {
        let (first, second) = ("/demo/caf\u{E9}", "/demo/cafe\u{301}")
        var memories: FolderViewMemories = [:]
        memories = memories.remembering(
            FolderViewMemory(selection: .single(first + "/a"), scrollTop: 1), at: first, historyPaths: [first])
        memories = memories.remembering(
            FolderViewMemory(selection: .single(second + "/b"), scrollTop: 2), at: second,
            historyPaths: [first, second])
        #expect(memories.count == 2)
        #expect(memories[DiskPath(first)]?.scrollTop == 1)
        #expect(memories[DiskPath(second)]?.scrollTop == 2)
        // A folder no longer in the history is forgotten, the other spelling of it kept.
        memories = memories.remembering(
            FolderViewMemory(selection: .empty, scrollTop: 3), at: "/demo", historyPaths: [second, "/demo"])
        #expect(memories[DiskPath(first)] == nil && memories[DiskPath(second)]?.scrollTop == 2)
    }
}
