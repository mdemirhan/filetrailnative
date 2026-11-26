// Changes of tags on a real disk, through the write coordinator: a color chosen is one Undo, a visit of the Tags popover
// is one, their Undo and Redo, what is left alone, and the write refused while another operation runs
import Darwin
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTOperations

@MainActor
@Suite(.serialized, .localOperationHang)
struct UndoTagsTests {
    private let work = FinderTag(name: "Work", color: .blue)
    private let red = FinderTag(name: "Red", color: .red)

    private func tags(_ path: String) -> [FinderTag]? { try? FinderTags.read(path) }

    @Test func aColorChosenIsOneUndoAndRedoChoosesItAgain() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            try FinderTags.write([work], to: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            let run = try await t.coordinator.changeTags(.color(.red, name: "Red"), paths: [a], visit: TagsVisit())
            #expect(run.failures.isEmpty)
            #expect(run.items.map(\.path) == [a])
            #expect(tags(a) == [work, red])
            #expect(t.history.menu().undo == "Tags of \u{201C}a.txt\u{201D}")

            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [work])
            #expect(
                t.history.menu() == UndoMenuLabels(undo: nil, redo: "Tags of \u{201C}a.txt\u{201D}", cantUndo: false))
            #expect(try await t.undo(.redo).status == .completed)
            #expect(tags(a) == [work, red])
            await t.shutDown()
        }
    }

    // Each color chosen is an Undo of its own: two Undos take them off one after the other.
    @Test func eachColorChosenIsAnUndoOfItsOwn() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.color(.red, name: "Red"), paths: [a], visit: TagsVisit())
            _ = try await t.coordinator.changeTags(.color(.blue, name: "Blue"), paths: [a], visit: TagsVisit())
            #expect(t.history.entries(.undo).count == 2)
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [red])
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [])
            await t.shutDown()
        }
    }

    // Everything chosen while the popover is open is one Undo: it puts back each item's tags as they were when it
    // opened, Remove All Tags included, and Redo gives them the last of it again.
    @Test func oneVisitOfThePopoverIsOneUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/b.txt")
            try UndoDisk.write(a, "a")
            try UndoDisk.write(b, "b")
            try FinderTags.write([red], to: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = TagsVisit()
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a, b], visit: visit)
            #expect(tags(a) == [red, work])
            #expect(tags(b) == [work])
            _ = try await t.coordinator.changeTags(.removeAll, paths: [a], visit: visit)
            _ = try await t.coordinator.changeTags(.tag(red), paths: [b], visit: visit)
            #expect(tags(a) == [])
            #expect(tags(b) == [work, red])
            #expect(t.history.entries(.undo).count == 1)
            #expect(t.history.menu().undo == "Tags of 2 Items")

            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [red])
            #expect(tags(b) == [])
            #expect(try await t.undo(.redo).status == .completed)
            #expect(tags(a) == [])
            #expect(tags(b) == [work, red])
            await t.shutDown()
        }
    }

    // A tag put on and taken off again in the same visit leaves nothing to undo.
    @Test func aTagTakenBackInTheSameVisitLeavesNoEntry() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = TagsVisit()
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a], visit: visit)
            #expect(t.history.entries(.undo).count == 1)
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a], visit: visit)
            #expect(tags(a) == [])
            #expect(t.history.entries(.undo).isEmpty)
            await t.shutDown()
        }
    }

    // Once an Undo took the visit's entry, its next choice is an entry of its own, from the tags the item has now.
    @Test func aChoiceAfterAnUndoOfTheVisitIsAnotherEntry() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = TagsVisit()
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a], visit: visit)
            #expect(try await t.undo().status == .completed)
            _ = try await t.coordinator.changeTags(.tag(red), paths: [a], visit: visit)
            #expect(tags(a) == [red])
            #expect(t.history.entries(.undo).count == 1)
            #expect(t.history.top(.redo) == nil)
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [])
            await t.shutDown()
        }
    }

    // Another operation between two choices of the popover: the second starts an Undo of its own, above it, so each
    // Undo takes back what came after the one before.
    @Test func aChoiceAfterAnotherOperationIsAnotherEntry() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/b.txt")
            try UndoDisk.write(a, "a")
            try UndoDisk.write(b, "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            let visit = TagsVisit()
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a], visit: visit)
            try await t.rename(b, "c.txt")
            _ = try await t.coordinator.changeTags(.tag(red), paths: [a], visit: visit)
            #expect(t.history.entries(.undo).count == 3)
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [work])
            #expect(try await t.undo().status == .completed)
            #expect(UndoDisk.exists(b))
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [])
            await t.shutDown()
        }
    }

    // Through a link the original's tags change, and Undo and Redo change them there again.
    @Test func undoAndRedoGoThroughALinkToItsOriginal() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, link) = ("\(root)/a.txt", "\(root)/link")
            try UndoDisk.write(a, "a")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.tag(work), paths: [link], visit: TagsVisit())
            #expect(tags(a) == [work])
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [])
            #expect(try await t.undo(.redo).status == .completed)
            #expect(tags(a) == [work])
            await t.shutDown()
        }
    }

    // A link and its original, both chosen, are one item: kept for Undo once, which puts its tags back without saying
    // the other was changed since.
    @Test func aLinkAndItsOriginalChosenTogetherAreUndoneAsOneItem() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, link) = ("\(root)/a.txt", "\(root)/link")
            try UndoDisk.write(a, "a")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            let run = try await t.coordinator.changeTags(.tag(work), paths: [a, link], visit: TagsVisit())
            #expect(run.items.map(\.path) == [a])
            #expect(t.history.menu().undo == "Tags of \u{201C}a.txt\u{201D}")
            let undone = try await t.undo()
            #expect(undone.status == .completed)
            #expect(tags(a) == [])
            await t.shutDown()
        }
    }

    // An item whose tags were changed since, in Finder say, is left as it is and said; the others are undone.
    @Test func anItemWhoseTagsChangedSinceIsLeftAsItIs() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/b.txt")
            try UndoDisk.write(a, "a")
            try UndoDisk.write(b, "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.color(.red, name: "Red"), paths: [a, b], visit: TagsVisit())
            try FinderTags.write([red, work], to: b)

            let undone = try await t.undo()
            #expect(undone.status == .partial)
            #expect(tags(a) == [])
            #expect(tags(b) == [red, work])
            #expect(
                undone.result?.items.filter { $0.status == .skipped }.map(\.error)
                    == ["\u{201C}b.txt\u{201D} was left as it is, because its tags were changed since."])
            await t.shutDown()
        }
    }

    @Test func anItemGoneSinceIsSaid() async throws {
        try await withUndoFolder { root, trashDir in
            let (a, b) = ("\(root)/a.txt", "\(root)/b.txt")
            try UndoDisk.write(a, "a")
            try UndoDisk.write(b, "b")
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a, b], visit: TagsVisit())
            try UndoDisk.remove(a)

            let undone = try await t.undo()
            #expect(undone.status == .partial)
            #expect(tags(b) == [])
            #expect(
                undone.result?.items.filter { $0.status == .skipped }.map(\.error)
                    == [UndoPlan.missingReason(NativeWriteFileSystem(), a)])
            await t.shutDown()
        }
    }

    // A custom tag keeps its color and its place among the others when Undo puts it back.
    @Test func undoPutsBackEachTagAsItWasInItsOrder() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let before = [FinderTag(name: "Project", color: .purple), red, FinderTag(name: "Plain", color: nil)]
            try FinderTags.write(before, to: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.removeAll, paths: [a], visit: TagsVisit())
            #expect(tags(a) == [])
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == before)
            await t.shutDown()
        }
    }

    // One file operation at a time: a change of tags is refused while another holds the write slot, and nothing is
    // written.
    @Test func isRefusedWhileAnotherOperationRuns() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            let held = HeldCall()
            let coordinator = t.coordinator
            DispatchQueue.global().async { _ = coordinator.runWriteAlone { held.hold() } }
            _ = try await Coordinators.waitFor { held.hasBegun ? true : nil }
            await #expect(throws: (any Error).self) {
                try await coordinator.changeTags(.color(.red, name: "Red"), paths: [a], visit: TagsVisit())
            }
            #expect(tags(a) == [])
            #expect(t.history.entries(.undo).isEmpty)
            held.release()
            _ = try await Coordinators.waitFor { coordinator.slotHolder == nil ? true : nil }
            _ = try await coordinator.changeTags(.color(.red, name: "Red"), paths: [a], visit: TagsVisit())
            #expect(tags(a) == [red])
            await t.shutDown()
        }
    }

    @Test func theHistoryListSaysWhatChanged() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            try FinderTags.write([work], to: a)
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.color(.red, name: "Red"), paths: [a], visit: TagsVisit())
            _ = try await t.coordinator.changeTags(.removeAll, paths: [a], visit: TagsVisit())
            let rows = UndoHistoryRows.content(t.history, homePath: root)
            #expect(rows.undo.map(\.items) == [["a.txt: \u{2212}Work, \u{2212}Red"], ["a.txt: +Red"]])
            #expect(rows.undo.map(\.title) == ["Tags of \u{201C}a.txt\u{201D}", "Tags of \u{201C}a.txt\u{201D}"])
            #expect(try await t.undo().status == .completed)
            // On the Redo list, as it was done.
            let after = UndoHistoryRows.content(t.history, homePath: root)
            #expect(after.redo.map(\.items) == [["a.txt: \u{2212}Work, \u{2212}Red"]])
            await t.shutDown()
        }
    }

    // An item locked since (no permission to write its tags) stays to be undone, and the next Undo, once it is
    // unlocked, puts its tags back.
    @Test func anItemThatCouldntBeWrittenIsTriedAgainByTheNextUndo() async throws {
        try await withUndoFolder { root, trashDir in
            let a = "\(root)/a.txt"
            try UndoDisk.write(a, "a")
            let t = UndoTest(root: root, trashDir: trashDir)
            _ = try await t.coordinator.changeTags(.tag(work), paths: [a], visit: TagsVisit())
            #expect(Darwin.chflags(a, UInt32(UF_IMMUTABLE)) == 0)
            defer { Darwin.chflags(a, 0) }
            let failed = try await t.undo()
            #expect(failed.status == .failed)
            #expect(tags(a) == [work])
            #expect(t.history.menu().undo == "Tags of \u{201C}a.txt\u{201D}")
            #expect(Darwin.chflags(a, 0) == 0)
            #expect(try await t.undo().status == .completed)
            #expect(tags(a) == [])
            await t.shutDown()
        }
    }

    // Red chosen on an item with an uncolored tag "red": the line says what came and went by color too.
    @Test func theHistoryLineTellsATagThatOnlyChangedItsColor() {
        let item = TagsUndoItem(
            path: "/demo/a.txt", id: nil, before: [UndoTag(name: "red", color: 0)],
            after: [UndoTag(name: "Red", color: 6)])
        #expect(UndoHistoryRows.tagsChange(item) == .tags("/demo/a.txt", what: "+Red, \u{2212}red"))
    }

    @Test func theStepIsReadBackAsWritten() throws {
        let step = UndoStep.tags(items: [
            TagsUndoItem(
                path: "/demo/a.txt", id: ItemId(dev: 1, ino: 2), before: [UndoTag(name: "Work", color: 4)],
                after: [UndoTag(name: "Work", color: 4), UndoTag(name: "Plain", color: 0)])
        ])
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(UndoStep.self, from: data) == step)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(
            String(decoding: try encoder.encode(step), as: UTF8.self)
                == #"{"items":[{"after":[{"color":4,"name":"Work"},{"color":0,"name":"Plain"}],"#
                + #""before":[{"color":4,"name":"Work"}],"id":{"dev":1,"ino":2},"path":"/demo/a.txt"}],"kind":"tags"}"#)
    }
}
