// Port of the cases of apps/desktop/src/renderer/lib/explorerAppUtils.test.ts and App.undo.test.tsx on what an operation
// says when it ends and how an Undo follows the clipboard (shouldRenderCopyPasteResultDialog, followClipboardThroughWrite)
import Foundation
import Testing

@testable import FTFoundation

struct WriteEndMatrixTests {
    private func summary(
        _ action: String, _ status: String, completed: Int = 0, failed: Int = 0, skipped: Int = 0, cancelled: Int = 0,
        items: [WriteEndSummary.Item] = []
    ) -> WriteEndSummary {
        WriteEndSummary(
            action: action, status: status, targetPath: "/d", topLevelItemCount: 1, completedItemCount: completed,
            failedItemCount: failed, skippedItemCount: skipped, cancelledItemCount: cancelled, items: items)
    }

    // T-8339f67a B-CLIP-125: an Undo or Redo gets the sheet when an item has a note, when it failed or went part way, or
    // when it was stopped after doing something; nothing to read otherwise.
    @Test(arguments: ["undo", "redo"]) func anUndoGetsTheSheetOnlyWithSomethingToRead(_ action: String) {
        let noted = WriteEndSummary.Item(sourcePath: "/a", destinationPath: "/b", status: "completed", note: true)
        #expect(WriteEndNotices.needsResultSheet(summary(action, "completed", completed: 1, items: [noted])))
        #expect(WriteEndNotices.needsResultSheet(summary(action, "failed")))
        #expect(WriteEndNotices.needsResultSheet(summary(action, "partial", completed: 1, failed: 1)))
        #expect(WriteEndNotices.needsResultSheet(summary(action, "cancelled", completed: 1, cancelled: 1)))
        #expect(!WriteEndNotices.needsResultSheet(summary(action, "completed", completed: 1)))
        #expect(!WriteEndNotices.needsResultSheet(summary(action, "cancelled", cancelled: 1)))
    }

    // T-f9caa915: an item skipped at run time was not what the review planned: the sheet tells of it.
    @Test func aPartialResultOfARuntimeSkipKeepsTheSheet() {
        func skipped(_ reason: String) -> WriteEndSummary {
            summary(
                "paste", "partial", completed: 1, skipped: 1,
                items: [
                    WriteEndSummary.Item(
                        sourcePath: "/a", destinationPath: "/d/a", status: "skipped", skipReason: reason)
                ])
        }
        let atRunTime = skipped("runtime_conflict_resolution")
        #expect(!WriteEndNotices.isExpectedPlannedSkip(atRunTime))
        #expect(WriteEndNotices.needsResultSheet(atRunTime))
        let planned = skipped("planned_conflict_policy")
        #expect(WriteEndNotices.isExpectedPlannedSkip(planned))
        #expect(!WriteEndNotices.needsResultSheet(planned))
    }

    // T-b07dc4c5: a rename of several that skipped an item says so, even though the rest went.
    @Test func aRenameOfSeveralThatSkippedAnItemGetsTheSheet() {
        #expect(WriteEndNotices.needsResultSheet(summary("batch_rename", "completed", completed: 2, skipped: 1)))
        #expect(!WriteEndNotices.needsResultSheet(summary("batch_rename", "completed", completed: 2)))
    }

    // T-7e45ff37: a Trash stopped part way is never told as done, and needs the sheet.
    @Test func aStoppedTrashIsNeverToldAsDone() {
        let stopped = WriteResultNoticeInput(
            error: nil, totalItemCount: 3, completedItemCount: 1, failedItemCount: 0, skippedItemCount: 0,
            cancelledItemCount: 2, itemErrors: [])
        #expect(WriteResultNoticeText.message(stopped) == "Stopped before every item was done.")
        let done = WriteResultNoticeInput(
            error: nil, totalItemCount: 3, completedItemCount: 3, failedItemCount: 0, skippedItemCount: 0,
            cancelledItemCount: 0, itemErrors: [])
        #expect(WriteResultNoticeText.message(done) == "Done.")
        #expect(WriteEndNotices.needsResultSheet(summary("trash", "cancelled", completed: 1, cancelled: 2)))
    }

    private func undo(_ items: [(String, String?)], action: String = "undo") -> ClipboardWrite {
        ClipboardWrite(
            action: action,
            items: items.map { WriteEffectItem(sourcePath: $0.0, destinationPath: $0.1, status: "completed") })
    }

    // T-ec337946 B-CLIP-048: what an Undo sent to the Trash leaves the clipboard, what it moved is followed.
    @Test(arguments: ["undo", "redo"]) func anUndoIsFollowedByTheClipboard(_ action: String) {
        let copied = ClipboardRules.set(.copy, ["/d/gone.txt", "/d/moved.txt", "/d/other.txt"], capturedAt: "t")
        let followed = ClipboardRules.followThroughWrite(
            copied, undo([("/d/gone.txt", nil), ("/d/moved.txt", "/e/moved.txt")], action: action))
        #expect(Set(followed.sourcePaths) == ["/e/moved.txt", "/d/other.txt"])
        #expect(followed.capturedAt == "t")
    }

    // B-CLIP-048: a cut any of whose items an Undo touched is cancelled; one it left alone stays.
    @Test func anUndoThatTouchedACutCancelsIt() {
        let cut = ClipboardRules.set(.cut, ["/d/a.txt", "/d/b.txt"], capturedAt: "t")
        #expect(ClipboardRules.followThroughWrite(cut, undo([("/d/a.txt", nil)])) == .empty)
        #expect(ClipboardRules.followThroughWrite(cut, undo([("/d/b.txt", "/e/b.txt")])) == .empty)
        #expect(ClipboardRules.followThroughWrite(cut, undo([("/d/other.txt", "/e/other.txt")])) == cut)
    }
}
