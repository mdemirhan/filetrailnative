// Port of "asks to confirm a large operation without conflicts" and "keeps a choice made for a row Replace can't take" of
// apps/desktop/src/renderer/components/CopyPasteReviewDialog.test.tsx, on the sheet's words and setChoice
import Foundation
import Testing

@testable import FTFoundation

struct ReviewChoicesMatrixTests {
    private let absent = ReviewFingerprint(exists: false, kind: .missing, size: nil, mtimeMs: nil)
    private let file = ReviewFingerprint(exists: true, kind: .file, size: 1, mtimeMs: 0)

    private func node(_ name: String, conflict: Bool, blocked: String? = nil, total: Int = 1) -> ReviewNode {
        ReviewNode(
            id: name, sourcePath: "/src/\(name)", destinationPath: "/dest/\(name)", sourceKind: .file,
            destinationKind: conflict ? .file : .missing, conflictClass: conflict ? .fileConflict : nil,
            sourceFingerprint: file, destinationFingerprint: conflict ? file : absent, children: [],
            totalNodeCount: total, conflictNodeCount: conflict ? 1 : 0, destinationTotalNodeCount: nil,
            keepBothDestinationPath: conflict ? "/dest/\(name) copy" : nil, destinationOnly: nil,
            replaceBlockedReason: blocked, renameOnly: false)
    }

    // T-e2456922: nothing clashes, but the operation is large: it asks, with no "For all conflicts".
    @Test func aLargeOperationWithoutConflictsIsAsked() {
        let report = ReviewReport(
            analysisId: "analysis-1", mode: .copy, destinationDirectoryPath: "/dest",
            nodes: [node("big", conflict: false, total: 1200)],
            summary: ReviewReport.Summary(totalNodeCount: 1200, directoryConflictCount: 0))
        let policy = CopyPasteReview.policy(for: .skip)
        let text = ReviewSheetText(
            report, action: .paste, summary: CopyPasteReview.summarize(report, policy: policy, overrides: [:]))
        #expect(text.title == "Paste 1 item into \u{201C}dest\u{201D}?")
        #expect(text.message == "This is a large operation (1,200 items in total).")
        #expect(!text.hasConflicts)
    }

    // T-aae8fec2 B-CLIP-093: a row Replace can't take keeps the choice made for it though the policy would give it the
    // same; on any other row a choice equal to the policy is no choice.
    @Test func aChoiceOnARowReplaceCantTakeIsKept() {
        let replaceAll = CopyPasteReview.policy(for: .overwrite)
        let blocked = node("inside", conflict: true, blocked: "holds what is pasted")
        let kept = CopyPasteReview.overrides(setting: .keepBoth, for: blocked, policy: replaceAll, overrides: [:])
        #expect(kept["inside"] == .keepBoth)
        let plain = node("plain", conflict: true)
        let chosen = CopyPasteReview.overrides(setting: .keepBoth, for: plain, policy: replaceAll, overrides: [:])
        #expect(chosen["plain"] == .keepBoth)
        #expect(
            CopyPasteReview.overrides(setting: .overwrite, for: plain, policy: replaceAll, overrides: chosen).isEmpty)
    }
}
