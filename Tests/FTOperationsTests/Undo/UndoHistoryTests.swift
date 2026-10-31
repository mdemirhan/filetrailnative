// Port of apps/desktop/src/main/bootstrap/undoHistory.test.ts
import FTFoundation
import Testing

@testable import FTOperations

@MainActor
struct UndoHistoryTests {
    static let id = ItemId(dev: 1, ino: 2)

    static func moved(_ from: String, _ to: String) -> UndoStep {
        .moved(UndoStep.Moved(from: from, to: to, id: id, itemKind: .file, parentId: id))
    }

    static func created(_ path: String) -> UndoStep {
        .created(path: path, id: id, stamp: nil)
    }

    static func trashed(_ from: String) -> UndoStep {
        .trashed(from: from, trashPath: "/Users/demo/.Trash/x", id: id, parentId: id, stamp: nil)
    }

    static func units(_ steps: [UndoStep]...) -> [UndoUnit] {
        steps.map { UndoUnit(steps: $0) }
    }

    static func undoable(_ action: WriteOperationAction, _ steps: [UndoStep]...) -> FinishedWrite {
        FinishedWrite(action: .write(action), log: .undoable(units: steps.map { UndoUnit(steps: $0) }), items: [])
    }

    static func renamed(_ from: String, _ to: String) -> UndoStep {
        .batchRenamed(items: [BatchRenamedItem(from: from, to: to, id: id, itemKind: .file)])
    }

    static func renamedMany(_ count: Int) -> UndoStep {
        .batchRenamed(
            items: (0..<count).map { BatchRenamedItem(from: "/a\($0)", to: "/b\($0)", id: id, itemKind: .file) })
    }

    private func moved(_ from: String, _ to: String) -> UndoStep { Self.moved(from, to) }
    private func created(_ path: String) -> UndoStep { Self.created(path) }
    private func trashed(_ from: String) -> UndoStep { Self.trashed(from) }
    private func units(_ steps: [UndoStep]...) -> [UndoUnit] { steps.map { UndoUnit(steps: $0) } }
    private func undoable(_ action: WriteOperationAction, _ steps: [UndoStep]...) -> FinishedWrite {
        FinishedWrite(action: .write(action), log: .undoable(units: steps.map { UndoUnit(steps: $0) }), items: [])
    }

    private func finish(
        _ history: UndoHistory, _ direction: UndoDirection = .undo, id: Int? = nil, done: [UndoUnit] = [],
        leftover: [UndoUnit] = []
    ) throws {
        try history.finish(direction, entryId: id ?? history.top(direction)?.id ?? -1, done: done, leftover: leftover)
    }

    // T-bf47e254 F-559
    @Test func hasNothingToUndoOrRedoAtFirst() {
        let history = UndoHistory()
        #expect(history.top(.undo) == nil)
        #expect(history.top(.redo) == nil)
        #expect(history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
    }

    // T-85dcc0d3 F-559
    @Test func undoesTheNewestOperationFirst() {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        history.record(undoable(.newFolder, [created("/F")]))
        #expect(history.top(.undo)?.action == .newFolder)
        #expect(history.menu().undo == "New Folder")
    }

    // T-4f8080d3 F-376 F-559
    @Test func movesWhatAnUndoDidToRedoAndBack() throws {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        let done = units([moved("/b", "/a")])
        try finish(history, done: done)
        #expect(history.top(.undo) == nil)
        #expect(history.top(.redo)?.action == .rename)
        #expect(history.top(.redo)?.units == done)
        try finish(history, .redo, done: units([moved("/a", "/b")]))
        #expect(history.menu() == UndoMenuLabels(undo: "Rename", redo: nil, cantUndo: false))
    }

    // T-6b8571f8 F-376 F-559
    @Test func keepsWhatAStopLeftOnTopAndDropsWhatCouldntBeDone() throws {
        let history = UndoHistory()
        history.record(undoable(.trash, [trashed("/a")], [trashed("/b")], [trashed("/c")]))
        try finish(history, done: units([moved("/x/c", "/c")]), leftover: units([trashed("/a")]))
        #expect(history.top(.undo)?.units == units([trashed("/a")]))
        #expect(history.top(.redo)?.units == units([moved("/x/c", "/c")]))
    }

    // T-2fc49dca F-559
    @Test func forgetsAnOperationNoneOfWhichCouldBeUndone() throws {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        try finish(history)
        #expect(history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: false))
    }

    // T-cb5e6182 F-376 F-559
    @Test func refusesTheEndOfAnUndoOfAnEntryThatIsNoLongerOnTop() throws {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        let first = history.top(.undo)
        history.record(undoable(.rename, [moved("/c", "/d")]))
        #expect(
            throws: UndoHistoryError(message: "The Undo list changed while one of its operations was being undone.")
        ) {
            try finish(history, id: first?.id ?? -1, done: units([moved("/b", "/a")]))
        }
        #expect(history.top(.undo)?.units == units([moved("/c", "/d")]))
        #expect(history.top(.redo) == nil)
    }

    // T-0433a01c F-374 F-559
    @Test func leavesNothingToRedoAfterANewOperation() throws {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        try finish(history, done: units([moved("/b", "/a")]))
        history.record(undoable(.newFolder, [created("/F")]))
        #expect(history.top(.redo) == nil)
    }

    // T-48637f84 F-373 F-559
    @Test func leavesTheHistoryAsItWasAfterAnOperationThatChangedNothing() throws {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        try finish(history, done: units([moved("/b", "/a")]))
        let generation = history.generation
        history.record(undoable(.paste))
        #expect(history.menu() == UndoMenuLabels(undo: nil, redo: "Rename", cantUndo: false))
        #expect(history.generation == generation)
    }

    // T-6b739125 F-374 F-395 F-559
    @Test func leavesNothingToUndoAfterAnOperationThatCantBeUndoneUntilTheNextOne() {
        let history = UndoHistory()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        history.record(FinishedWrite(action: .emptyTrash, log: .notUndoable(reason: .deletedForGood), items: []))
        #expect(history.menu() == UndoMenuLabels(undo: nil, redo: nil, cantUndo: true))
        history.record(undoable(.newFolder, [created("/F")]))
        #expect(history.menu() == UndoMenuLabels(undo: "New Folder", redo: nil, cantUndo: false))
    }

    // T-8aeaced7 F-376 F-559
    @Test func countsChangesAndTellsAboutThem() throws {
        let history = UndoHistory()
        var calls = 0
        let stop = history.onChange { calls += 1 }
        let before = history.generation
        history.record(undoable(.rename, [moved("/a", "/b")]))
        try finish(history)
        #expect(history.generation == before + 2)
        #expect(calls == 2)
        stop()
        history.record(undoable(.rename, [moved("/a", "/b")]))
        #expect(calls == 2)
    }

    // T-5341ab7d F-559
    @Test func keepsEachTryOfABatchRenameItsOwnEntryToRedoTheLastOneFirst() throws {
        let history = UndoHistory()
        history.record(undoable(.batchRename, [Self.renamed("/a", "/b"), Self.renamed("/b", "/a")]))
        let entry = history.top(.undo)
        try finish(
            history, id: entry?.id, done: units([Self.renamed("/b", "/a")]), leftover: units([Self.renamed("/a", "/b")])
        )
        try finish(history, id: entry?.id, done: units([Self.renamed("/a", "/b")]))
        #expect(history.top(.redo)?.units == units([Self.renamed("/a", "/b")]))
        #expect(history.menu().redo == "Rename")
    }

    // T-4ab45822 F-559
    @Test func keepsOtherPartsApartEachToRedoOnItsOwn() throws {
        let history = UndoHistory()
        history.record(undoable(.trash, [trashed("/a")], [trashed("/b")]))
        let entry = history.top(.undo)
        try finish(history, id: entry?.id, done: units([moved("/T/b", "/b")]), leftover: units([trashed("/a")]))
        try finish(history, id: entry?.id, done: units([moved("/T/a", "/a")]))
        #expect(history.top(.redo)?.units == units([moved("/T/a", "/a")]))
    }

    // T-e20ea8b9 F-248 F-375
    @Test func isAMillionItemSteps() {
        #expect(UndoHistory.maxItemStepsDefault == 1_000_000)
    }

    // T-8bc5192c F-375
    @Test func countsEachStepAndEachItemOfABatch() {
        #expect(UndoHistory.itemStepCount(units([moved("/a", "/b"), created("/c")], [Self.renamedMany(3)])) == 5)
    }

    // T-e14206d9 F-375 F-559
    @Test func letsGoOfTheOldestOperationsOnceThereAreTooManyItemsNeverTheNewest() throws {
        let history = UndoHistory(maxItemSteps: 5)
        history.record(undoable(.rename, [moved("/a", "/b")]))
        history.record(undoable(.batchRename, [Self.renamedMany(3)]))
        history.record(undoable(.newFolder, [created("/F")]))
        try finish(history, done: units([trashed("/F")]))
        #expect(history.menu().undo == "Rename of 3 Items")
        #expect(history.menu().redo == "New Folder")
        // Two more: the rename at the bottom goes, then the batch.
        history.record(undoable(.rename, [moved("/c", "/d")]))
        #expect(history.top(.redo) == nil)
        history.record(undoable(.batchRename, [Self.renamedMany(2)]))
        var left: [String] = []
        while let entry = history.top(.undo) {
            left.append(UndoHistory.labelOf(entry.action, entry.units))
            try finish(history, id: entry.id)
        }
        #expect(left == ["Rename of 2 Items", "Rename"])
    }

    // T-3bd24a62 F-375 F-559
    @Test func keepsAnOperationLargerThanTheLimitOnItsOwn() throws {
        let history = UndoHistory(maxItemSteps: 2)
        history.record(undoable(.rename, [moved("/a", "/b")]))
        history.record(undoable(.batchRename, [Self.renamedMany(4)]))
        #expect(history.menu().undo == "Rename of 4 Items")
        try finish(history)
        #expect(history.top(.undo) == nil)
    }

    // T-90ef517b F-375 F-559
    @Test func keepsWhatAnUndoDidAndLeftThoughTogetherTheyAreOverTheLimit() throws {
        let history = UndoHistory(maxItemSteps: 3)
        history.record(undoable(.rename, [moved("/x", "/y")]))
        history.record(undoable(.batchRename, [Self.renamedMany(3)]))
        try finish(history, done: units([Self.renamedMany(2)]), leftover: units([Self.renamedMany(1)]))
        #expect(history.menu() == UndoMenuLabels(undo: "Rename", redo: "Rename of 2 Items", cantUndo: false))
        try finish(history)
        // The older rename was let go.
        #expect(history.top(.undo) == nil)
    }

    // T-fbb82ef3 F-377 F-559
    @Test func staysAMoveWhenWhatIsLeftOfAMovingReplaceIsItsTripToTheTrash() throws {
        let history = UndoHistory()
        history.record(undoable(.paste, [trashed("/F/a.txt"), moved("/a.txt", "/F/a.txt")]))
        try finish(history, done: units([moved("/F/a.txt", "/a.txt")]), leftover: units([trashed("/F/a.txt")]))
        #expect(
            history.menu()
                == UndoMenuLabels(
                    undo: "Move of \u{201C}a.txt\u{201D}", redo: "Move of \u{201C}a.txt\u{201D}", cantUndo: false))
    }

    static let labelCases: [(FinishedWrite, String)] = [
        (undoable(.rename, [moved("/a.txt", "/b.txt")]), "Rename"),
        (
            undoable(
                .batchRename,
                [
                    .batchRenamed(items: [
                        BatchRenamedItem(from: "/a", to: "/b", id: id, itemKind: .file),
                        BatchRenamedItem(from: "/c", to: "/d", id: id, itemKind: .file),
                    ])
                ]), "Rename of 2 Items"
        ),
        (
            undoable(
                .batchRename, [.batchRenamed(items: [BatchRenamedItem(from: "/a", to: "/b", id: id, itemKind: .file)])]),
            "Rename"
        ),
        (undoable(.newFolder, [created("/untitled folder")]), "New Folder"),
        (undoable(.trash, [trashed("/Docs/a.txt")]), "Move to Trash of “a.txt”"),
        (undoable(.duplicate, [created("/a copy.txt")]), "Duplicate of “a copy.txt”"),
        (undoable(.moveTo, [moved("/a.txt", "/F/a.txt")], [moved("/b", "/F/b")]), "Move of 2 Items"),
        (undoable(.copyTo, [created("/F/a.txt")]), "Copy of “a.txt”"),
        (undoable(.paste, [moved("/a.txt", "/F/a.txt")]), "Move of “a.txt”"),
        (undoable(.paste, [created("/F/a.txt")], [created("/F/b.txt")]), "Copy of 2 Items"),
        // A Replace: named after the new item, not the one that went to the Trash.
        (undoable(.paste, [trashed("/F/a.txt"), created("/F/a.txt")]), "Copy of “a.txt”"),
    ]

    // T-d6b03f3d F-377
    @Test func namesEachOperation() {
        for (entry, label) in Self.labelCases {
            guard case .write(let action) = entry.action, case .undoable(let units) = entry.log else {
                Issue.record("not an undoable write")
                continue
            }
            #expect(UndoHistory.labelOf(action, units) == label)
        }
    }

    // T-10c5e24e F-377
    @Test func namesAUnitWithNothingToGoByPlainly() {
        #expect(UndoHistory.labelOf(.trash, units([.batchRenamed(items: [])])) == "Move to Trash of 1 Item")
    }
}
