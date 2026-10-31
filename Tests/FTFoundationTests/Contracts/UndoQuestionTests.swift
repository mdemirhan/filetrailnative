// Port of apps/desktop/src/renderer/lib/undoQuestion.test.ts
import Testing

@testable import FTFoundation

struct UndoQuestionTests {
    private enum Kind { case made, putBack, replaced }

    private func item(_ name: String, _ kind: Kind = .made) -> UndoQuestion.ChangedItem {
        UndoQuestion.ChangedItem(name: name, putBack: kind == .putBack, replaced: kind == .replaced)
    }

    // T-0304b141 F-551
    @Test func namesTheOperationAnItemThatChangedCameFrom() {
        let cases: [([UndoQuestion.ChangedItem], UndoDirection, WriteOperationAction)] = [
            ([item("1 copy.kt")], .undo, .duplicate),
            ([item("a"), item("b")], .undo, .duplicate),
            ([item("a.txt")], .undo, .copyTo),
            ([item("a"), item("b")], .undo, .paste),
            ([item("untitled folder")], .undo, .newFolder),
            ([item("a.txt", .replaced)], .undo, .paste),
            ([item("a", .replaced), item("b", .replaced)], .undo, .paste),
            ([item("a.txt", .putBack)], .redo, .trash),
            ([item("a", .putBack), item("b", .putBack)], .undo, .copyTo),
            ([item("a"), item("b", .replaced)], .undo, .paste),
            ([item("a.txt")], .redo, .rename),
        ]
        let texts = cases.map { items, direction, action in
            let text = UndoQuestionText.of(.changed(items: items), direction: direction, action: action)
            return "\(text.title) | \(text.message)"
        }
        #expect(
            texts == [
                "“1 copy.kt” was changed after it was duplicated. | Undoing the duplicate moves this copy to the Trash, along with your changes. The original isn’t affected.",
                "2 copies were changed after they were duplicated. | Undoing the duplicate moves these copies to the Trash, along with your changes. The originals aren’t affected.",
                "“a.txt” was changed after it was copied. | Undoing the copy moves it to the Trash, along with your changes. The original isn’t affected.",
                "2 copies were changed after they were copied. | Undoing the copy moves them to the Trash, along with your changes. The originals aren’t affected.",
                "“untitled folder” isn’t empty anymore. | Undoing New Folder moves it to the Trash, along with what you put in it.",
                "“a.txt” was changed after it replaced the old one. | Undoing moves it to the Trash, along with your changes, and puts the old “a.txt” back.",
                "2 items were changed after they replaced the old ones. | Undoing moves them to the Trash, along with your changes, and puts the old ones back.",
                "“a.txt” was changed after it was put back. | Redo moves it to the Trash again, along with your changes.",
                "2 items were changed after they were put back. | Undo moves them to the Trash again, along with your changes.",
                "2 items were changed after this was done. | Undo moves them to the Trash, along with your changes.",
                "“a.txt” was changed after this was done. | Redo moves it to the Trash, along with your changes.",
            ])
    }

    // T-86561a8d F-551
    @Test func neverGoesAheadWithChangedWorkByDefaultAndKeepsBothNamesByDefault() {
        let changed = UndoQuestionText.of(.changed(items: [item("a")]), direction: .undo, action: .duplicate)
        #expect(changed.confirmLabel == "Move to Trash")
        #expect(!changed.confirmIsDefault)
        #expect(
            UndoQuestionText.of(.nameTaken(names: ["a", "b"]), direction: .undo, action: .trash)
                == UndoQuestionText(
                    title: "2 items have names that other items have taken where they would go back.",
                    message: "Undo puts them back with a number added to their names.", confirmLabel: "Keep Both",
                    confirmIsDefault: true))
    }

    // T-1d67a013 B-CLIP-191
    @Test func listsTheFirstNamesOfSeveralAndCountsTheRest() {
        let names = ["a", "b", "c", "d", "e", "f", "g"]
        #expect(UndoQuestion.nameTaken(names: names).listedNames == ["a", "b", "c", "d", "e", "and 2 more"])
        #expect(UndoQuestion.changed(items: names.prefix(3).map { item($0) }).listedNames == ["a", "b", "c"])
        // One item is named in the title, and not listed.
        #expect(UndoQuestion.nameTaken(names: ["a"]).listedNames.isEmpty)
        #expect(UndoQuestion.changed(items: [item("a")]).listedNames.isEmpty)
        // The count is the locale's, with thousands separated.
        let many = (0..<1005).map { "\($0).txt" }
        #expect(UndoQuestion.nameTaken(names: many).listedNames.last == "and 1,000 more")
    }

    // T-643127df B-CLIP-191
    @Test func listsItemsWithTheSameNameFromDifferentFoldersEachOnce() {
        #expect(
            UndoQuestion.nameTaken(names: ["a.txt", "b.txt", "a.txt"]).listedNames == ["a.txt", "b.txt", "a.txt"])
        #expect(
            UndoQuestion.changed(items: [item("a.txt"), item("a.txt", .putBack)]).listedNames == ["a.txt", "a.txt"])
    }
}
