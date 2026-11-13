import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
struct UndoHistoryRowsTests {
    static let home = "/Users/demo"
    static let id = ItemId(dev: 1, ino: 2)

    private func moved(_ from: String, _ to: String, fromTrash: Bool? = nil) -> UndoStep {
        .moved(
            UndoStep.Moved(from: from, to: to, id: Self.id, itemKind: .file, parentId: Self.id, fromTrash: fromTrash))
    }

    private func created(_ path: String) -> UndoStep { .created(path: path, id: Self.id, stamp: nil) }

    private func trashed(_ from: String) -> UndoStep {
        .trashed(from: from, trashPath: "/Users/demo/.Trash/x", id: Self.id, parentId: Self.id, stamp: nil)
    }

    private func entry(_ action: WriteOperationAction, _ units: [[UndoStep]], moves: Bool = false) -> UndoEntry {
        UndoEntry(
            id: 7, action: action, units: units.map { UndoUnit(steps: $0) }, moves: moves, size: 1,
            date: Date(timeIntervalSince1970: 1_000))
    }

    private func row(_ entry: UndoEntry, _ direction: UndoDirection = .undo) -> UndoHistoryRow {
        UndoHistoryRows.row(entry, direction, homePath: Self.home)
    }

    @Test func namesAMoveByItsFoldersAndListsItsItems() {
        let move = row(
            entry(
                .moveTo,
                [
                    [moved("/Users/demo/Downloads/a.pdf", "/Users/demo/Projects/a.pdf")],
                    [moved("/Users/demo/Downloads/b.md", "/Users/demo/Projects/b.md")],
                ], moves: true))
        #expect(move.title == "Move of 2 Items")
        #expect(move.icon == .move)
        #expect(move.place == "Downloads → Projects")
        #expect(move.placePaths == "~/Downloads → ~/Projects")
        #expect(move.items == ["a.pdf", "b.md"])
        #expect(move.date == Date(timeIntervalSince1970: 1_000))
    }

    @Test func namesARenameByItsFolderAndItsOldAndNewNames() {
        let rename = row(entry(.rename, [[moved("/Users/demo/Pictures/IMG.heic", "/Users/demo/Pictures/Trip.heic")]]))
        #expect(rename.title == "Rename")
        #expect(rename.place == "in Pictures")
        #expect(rename.items == ["IMG.heic → Trip.heic"])
        let batch = row(
            entry(
                .batchRename,
                [
                    [
                        .batchRenamed(items: [
                            BatchRenamedItem(from: "/p/a", to: "/p/1", id: nil, itemKind: .file),
                            BatchRenamedItem(from: "/p/b", to: "/p/2", id: nil, itemKind: .file),
                        ])
                    ]
                ]))
        #expect(batch.title == "Rename of 2 Items")
        #expect(batch.items == ["a → 1", "b → 2"])
        #expect(batch.place == "in p")
    }

    @Test func namesWhatWasMadeOrTrashedByItsFolder() {
        let copy = row(entry(.copyTo, [[created("/Users/demo/Projects/a.txt")]]))
        #expect(copy.place == "in Projects")
        #expect(copy.icon == .copy)
        let trash = row(entry(.trash, [[trashed("/Users/demo/Projects/old.key")]]))
        #expect(trash.title == "Move to Trash of \u{201C}old.key\u{201D}")
        #expect(trash.place == "from Projects")
        #expect(trash.placePaths == "from ~/Projects")
        #expect(trash.items == ["old.key"])
    }

    // An entry on the Redo list holds what its Undo did: it is told the way the person did it.
    @Test func tellsAnOperationToRedoTheWayItWasDone() {
        let move = row(entry(.moveTo, [[moved("/to/a.txt", "/from/a.txt")]], moves: true), .redo)
        #expect(move.place == "from → to")
        let rename = row(entry(.rename, [[moved("/p/new", "/p/old")]]), .redo)
        #expect(rename.items == ["old → new"])
        // Undoing a Move to Trash put the item back; redoing it trashes it again.
        let trash = row(entry(.trash, [[moved("/Users/demo/.Trash/a", "/p/a", fromTrash: true)]]), .redo)
        #expect(trash.place == "from p")
        // Undoing a copy trashed it; redoing it makes it again.
        let copy = row(entry(.copyTo, [[trashed("/p/a")]]), .redo)
        #expect(copy.place == "in p")
    }

    @Test func saysWhatAReplaceReplaced() {
        let paste = row(entry(.paste, [[trashed("/p/a.txt"), created("/p/a.txt")]]))
        #expect(paste.items == ["a.txt, replacing the one there"])
        #expect(paste.place == "in p")
    }

    @Test func givesEachItemItsFoldersWhenTheyAreInSeveral() {
        let trash = row(entry(.trash, [[trashed("/a/x")], [trashed("/Users/demo/b/y")]]))
        #expect(trash.place == "from 2 folders")
        #expect(trash.placePaths == nil)
        #expect(trash.items == ["x (from /a)", "y (from ~/b)"])
    }

    @Test func listsAtMostTenItemsTheLastSayingHowManyMore() {
        let many = row(entry(.trash, (0..<25).map { [trashed("/p/f\($0)")] }))
        #expect(many.items.count == UndoHistoryRows.maxItemLines)
        #expect(many.items.first == "f0")
        #expect(many.items.last == "and 16 more")
        let ten = row(entry(.trash, (0..<10).map { [trashed("/p/f\($0)")] }))
        #expect(ten.items.count == 10)
        #expect(ten.items.last == "f9")
    }

    @Test func writesTheHomeFolderAsATilde() {
        #expect(UndoHistoryRows.tilde("/Users/demo", homePath: Self.home) == "~")
        #expect(UndoHistoryRows.tilde("/Users/demo/a", homePath: Self.home) == "~/a")
        #expect(UndoHistoryRows.tilde("/Users/demonstration", homePath: Self.home) == "/Users/demonstration")
        #expect(UndoHistoryRows.folderName("/") == "/")
    }

    @Test func listsWhatRedoWouldDoAboveWhatUndoWould() throws {
        var now = Date(timeIntervalSince1970: 0)
        let history = UndoHistory(clock: { now })
        let rename = { (from: String, to: String) in
            FinishedWrite(
                action: .write(.rename), log: .undoable(units: [UndoUnit(steps: [moved(from, to)])]), items: [])
        }
        for index in 0..<4 {
            now = Date(timeIntervalSince1970: Double(index))
            history.record(rename("/p/\(index)", "/p/\(index)b"))
        }
        // Two undone: the newest first, so the Redo list's next one is the one undone last.
        for _ in 0..<2 {
            let top = try #require(history.top(.undo))
            let step = try #require(top.units.first?.steps.first)
            guard case .moved(let move) = step else { return }
            try history.finish(
                .undo, entryId: top.id, done: [UndoUnit(steps: [moved(move.to, move.from)])], leftover: [])
        }
        let content = UndoHistoryRows.content(history, homePath: Self.home)
        #expect(content.redo.flatMap(\.items) == ["3 → 3b", "2 → 2b"])
        #expect(content.undo.flatMap(\.items) == ["1 → 1b", "0 → 0b"])
        #expect(content.undo.map(\.date) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 0)])
        let limited = UndoHistoryRows.content(history, homePath: Self.home, limit: 1)
        #expect(limited.redo.flatMap(\.items) == ["2 → 2b"])
        #expect(limited.redoMore == 1)
        #expect(limited.undo.flatMap(\.items) == ["1 → 1b"])
        #expect(limited.undoMore == 1)
        #expect(!content.isEmpty)
        #expect(UndoHistoryRows.content(UndoHistory(), homePath: Self.home).isEmpty)
    }

    @Test func saysWhatTheHistoryStartsAfterUntilItLetsGoOfTheOldest() {
        let history = UndoHistory(maxItemSteps: 2, clock: { Date(timeIntervalSince1970: 5) })
        history.record(
            FinishedWrite(
                action: .write(.deleteImmediately), log: .notUndoable(reason: .deletedForGood), items: []))
        let barrier = UndoBarrier(
            action: .write(.deleteImmediately), reason: .deletedForGood, date: Date(timeIntervalSince1970: 5))
        #expect(history.barrier == barrier)
        #expect(UndoHistoryRows.barrierTitle(barrier) == "Can\u{2019}t undo before Delete Immediately")
        #expect(UndoHistoryRows.barrierReason(barrier) == "Items were deleted for good")
        // An operation after it keeps it, below the operation.
        let rename = FinishedWrite(
            action: .write(.rename), log: .undoable(units: [UndoUnit(steps: [moved("/p/a", "/p/b")])]), items: [])
        history.record(rename)
        history.record(rename)
        #expect(UndoHistoryRows.content(history, homePath: Self.home).barrier == barrier)
        // Past the history's size the oldest goes, and the history no longer starts right after it.
        history.record(rename)
        #expect(history.barrier == nil)
        #expect(history.entries(.undo).count == 2)
    }

    // An operation on many thousands of items in as many folders is told in the time of going over them once: its
    // folders are counted, and only the lines the tooltip shows are written.
    @Test func tellsAnOperationOnManyItemsInManyFoldersQuickly() {
        let count = 40_000
        let big = entry(.trash, (0..<count).map { [trashed("/Users/demo/d\($0)/f\($0)")] })
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (told, seconds) = CPUTime.measureThread { row(big) }
        #expect(told.place == "from \(count) folders")
        #expect(told.placePaths == nil)
        #expect(told.items.count == UndoHistoryRows.maxItemLines)
        #expect(told.items.first == "f0 (from ~/d0)")
        #expect(told.items.last == "and \(count - 9) more")
        #expect(seconds < 1)
    }

    // The rows of a list that is open are kept from one change of the history to the next, and say the same as
    // rows built anew: an operation a stopped Undo left smaller is told again.
    @Test func keepsTheRowsOfAnOpenListAndTellsAChangedOperationAgain() throws {
        let history = UndoHistory(clock: { Date(timeIntervalSince1970: 5) })
        let cache = UndoHistoryRowCache()
        func same() -> UndoHistoryContent {
            let kept = UndoHistoryRows.content(history, homePath: Self.home, cache: cache)
            #expect(kept == UndoHistoryRows.content(history, homePath: Self.home))
            return kept
        }
        let units = [UndoUnit(steps: [moved("/p/a", "/p/b")]), UndoUnit(steps: [moved("/p/c", "/p/d")])]
        history.record(FinishedWrite(action: .write(.batchRename), log: .undoable(units: units), items: []))
        #expect(same().undo.map(\.items) == [["a → b", "c → d"]])
        history.record(
            FinishedWrite(
                action: .write(.rename), log: .undoable(units: [UndoUnit(steps: [moved("/p/e", "/p/f")])]), items: []))
        #expect(same().undo.map(\.items) == [["e → f"], ["a → b", "c → d"]])
        // An Undo stopped after its first item: the operation stays, under its id, with what is left of it.
        let top = try #require(history.top(.undo))
        try history.finish(.undo, entryId: top.id, done: [], leftover: [])
        let first = try #require(history.top(.undo))
        try history.finish(
            .undo, entryId: first.id, done: [UndoUnit(steps: [moved("/p/d", "/p/c")])], leftover: [units[0]])
        let after = same()
        #expect(after.undo.map(\.items) == [["a → b"]])
        #expect(after.redo.map(\.items) == [["c → d"]])
    }

    @Test func namesEachThingThatCantBeUndone() {
        func title(_ action: FinishedWrite.Action, _ reason: CantUndoReason?) -> String {
            UndoHistoryRows.barrierTitle(UndoBarrier(action: action, reason: reason, date: .distantPast))
        }
        #expect(title(.emptyTrash, nil) == "Can\u{2019}t undo before Empty Trash")
        #expect(title(.write(.paste), .otherDiskMove) == "Can\u{2019}t undo before Move")
        #expect(title(.write(.paste), .merge) == "Can\u{2019}t undo before Paste")
        let reason = { (why: CantUndoReason) in
            UndoHistoryRows.barrierReason(UndoBarrier(action: .emptyTrash, reason: why, date: .distantPast))
        }
        #expect(reason(.otherDiskMove) == "Items were moved to another disk")
        #expect(reason(.noTrash) == "Its disk has no Trash")
    }
}
