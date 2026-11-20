// The review of a paste that copies some items and moves others: each row says which, and what a row says of an
// item left alone follows what that item was to do
import Foundation
import Testing

@testable import FTFoundation

struct ReviewOfBothTests {
    private let absent = ReviewFingerprint(exists: false, kind: .missing)
    private let file = ReviewFingerprint(exists: true, kind: .file, size: 1, mtimeMs: 0)
    private let folder = ReviewFingerprint(exists: true, kind: .directory)

    private func clash(
        _ id: String, _ source: String, mode: ReviewMode?, folder isFolder: Bool = false, children: [ReviewNode] = []
    ) -> ReviewNode {
        ReviewNode(
            id: id, sourcePath: source, destinationPath: "/d/" + (source as NSString).lastPathComponent,
            sourceKind: isFolder ? .directory : .file, destinationKind: isFolder ? .directory : .file,
            conflictClass: isFolder ? .directoryConflict : .fileConflict, sourceFingerprint: isFolder ? folder : file,
            destinationFingerprint: isFolder ? folder : file, children: children,
            totalNodeCount: 1 + children.count, conflictNodeCount: 1 + children.count, mode: mode)
    }

    private func report(_ nodes: [ReviewNode]) -> ReviewReport {
        ReviewReport(
            analysisId: "a", mode: .copy, destinationDirectoryPath: "/d", nodes: nodes,
            summary: .init(
                totalNodeCount: nodes.count,
                directoryConflictCount: nodes.filter { $0.conflictClass == .directoryConflict }.count))
    }

    @Test func aReviewOfBothKnowsIt() {
        #expect(report([clash("1", "/a/x", mode: .copy), clash("2", "/b/y", mode: .cut)]).isMixed)
        #expect(!report([clash("1", "/a/x", mode: nil), clash("2", "/b/y", mode: nil)]).isMixed)
        #expect(!report([clash("1", "/a/x", mode: .cut), clash("2", "/b/y", mode: .cut)]).isMixed)
    }

    /// Skipped, a moved item stays where it was and says so; a copied one is left as it is.
    @Test func eachRowSaysWhatItsItemDoesAndWhatSkippingItLeaves() {
        let review = report([clash("1", "/a/x", mode: .copy), clash("2", "/b/y", mode: .cut)])
        let rows = CopyPasteReview.rows(
            review, policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip), overrides: [:],
            showNewItems: false, now: 0)
        #expect(rows.map(\.mode) == [.copy, .cut])
        #expect(rows.map(\.detail) == ["Left as is", "Stays in \u{201C}b\u{201D}"])
    }

    /// What is inside a merged folder goes as the folder does.
    @Test func whatIsInsideAMergedFolderGoesAsTheFolderDoes() {
        let inner = clash("1.1", "/b/F/inner", mode: nil)
        let review = report([
            clash("1", "/b/F", mode: .cut, folder: true, children: [inner]), clash("2", "/a/x", mode: .copy),
        ])
        let rows = CopyPasteReview.rows(
            review, policy: CopyPastePolicy(file: .skip, directory: .merge, mismatch: .skip), overrides: [:],
            showNewItems: false, now: 0)
        #expect(rows.map(\.id) == ["1", "1.1", "2"])
        #expect(rows.map(\.mode) == [.cut, .cut, .copy])
        #expect(rows[1].detail == "Stays in \u{201C}F\u{201D}")
    }

    @Test func aReviewOfOneIntentHasNoRowIntents() {
        let review = report([clash("1", "/a/x", mode: nil)])
        let rows = CopyPasteReview.rows(
            review, policy: CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip), overrides: [:],
            showNewItems: false, now: 0)
        #expect(rows.map(\.mode) == [nil])
    }

    /// Add Missing would split a moved folder between both places, as it would in a move.
    @Test func addMissingIsLeftOutWhenAFolderMovedClashes() {
        let moved = report([clash("1", "/b/F", mode: .cut, folder: true), clash("2", "/a/x", mode: .copy)])
        #expect(!CopyPasteReview.allConflictsChoices(moved).contains(.addMissing))
        let copied = report([clash("1", "/b/F", mode: .copy, folder: true), clash("2", "/a/x", mode: .cut)])
        #expect(CopyPasteReview.allConflictsChoices(copied).contains(.addMissing))
    }

    /// A paste of both is a paste: its title says Paste, and a new item is added either way, the row saying whether it
    /// moves.
    @Test func theSheetOfBothSaysPaste() {
        let new = ReviewNode(
            id: "2", sourcePath: "/b/y", destinationPath: "/d/y", sourceKind: .file, destinationKind: .missing,
            conflictClass: nil, sourceFingerprint: file, destinationFingerprint: absent, totalNodeCount: 1,
            conflictNodeCount: 0, mode: .cut)
        let review = report([clash("1", "/a/x", mode: .copy), new])
        let policy = CopyPastePolicy(file: .skip, directory: .skip, mismatch: .skip)
        let text = ReviewSheetText(
            review, action: .paste, summary: CopyPasteReview.summarize(review, policy: policy, overrides: [:]))
        #expect(text.addsLabel == "Adds")
        #expect(text.title == "1 of 2 items already exists in \u{201C}d\u{201D}")
    }
}
