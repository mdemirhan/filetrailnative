// The review as it opens on a window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

private func node(_ name: String, conflict: Bool, blocked: String? = nil) -> CopyPasteAnalysisNode {
    let exists = NodeFingerprint(exists: true, kind: .file, size: 1)
    return CopyPasteAnalysisNode(
        id: name, sourcePath: "/src/\(name)", destinationPath: "/dest/\(name)", sourceKind: .file,
        destinationKind: conflict ? .file : .missing, conflictClass: conflict ? .fileConflict : nil,
        sourceFingerprint: exists,
        destinationFingerprint: conflict ? exists : NodeFingerprint(exists: false, kind: .missing),
        children: [], totalNodeCount: 1, conflictNodeCount: conflict ? 1 : 0,
        keepBothDestinationPath: conflict ? "/dest/\(name) copy" : nil, replaceBlockedReason: blocked)
}

private func report(_ nodes: [CopyPasteAnalysisNode]) -> CopyPasteAnalysisReport {
    CopyPasteAnalysisReport(
        analysisId: "analysis-1", mode: .copy, sourcePaths: nodes.map(\.sourcePath),
        destinationDirectoryPath: "/dest", nodes: nodes, issues: [],
        summary: CopyPasteAnalysisSummary(
            topLevelItemCount: nodes.count, totalNodeCount: nodes.count, totalBytes: Int64(nodes.count),
            fileConflictCount: nodes.filter { $0.conflictClass != nil }.count, directoryConflictCount: 0,
            mismatchConflictCount: 0))
}

/// The review's limit on the rows it draws, on its model: drawing hundreds of real rows takes a second.
@MainActor
@Suite struct ReviewSheetRowLimitTests {
    private func model(_ count: Int, conflict: Bool) -> ReviewSheetModel {
        let nodes = (0..<count).map { node("f\($0).txt", conflict: conflict) }
        return ReviewSheetModel(
            report: report(nodes), action: .paste, policy: WindowWriteActions.safePolicy, now: 0)
    }

    // 300 rows, then all of them once asked for.
    @Test(arguments: [(301, 1), (1_400, 1_100)])
    func aLongListOfConflictsDrawsItsFirstRows(_ count: Int, _ hidden: Int) {
        let model = model(count, conflict: true)
        #expect(model.visibleRows.count == 300)
        #expect(model.hiddenRowCount == hidden)
        model.showAllRows = true
        #expect(model.visibleRows.count == count)
        #expect(model.hiddenRowCount == 0)
    }

    @Test func theLinkCountsInThousands() {
        #expect(ReviewSheetText.showAll(1_400) == "Show all 1,400")
    }

    // A list of exactly the limit has nothing to show.
    @Test func aListOfThreeHundredHidesNothing() {
        let model = model(300, conflict: true)
        #expect(model.visibleRows.count == 300)
        #expect(model.hiddenRowCount == 0)
    }

    // The list of a large operation without conflicts has the same limit.
    @Test func aLargeOperationWithoutConflictsHasTheSameLimit() {
        let model = model(500, conflict: false)
        #expect(!model.hasConflicts)
        #expect(model.visibleRows.count == 300)
        #expect(model.hiddenRowCount == 200)
    }
}

/// What of a report the review reads.
@Suite struct ReviewReportTests {
    private func item(
        _ path: String, _ conflictClass: ConflictClass? = nil, folder: Bool = false,
        _ children: [CopyPasteAnalysisNode] = []
    ) -> CopyPasteAnalysisNode {
        let kind: CopyPasteNodeKind = folder ? .directory : .file
        let there = conflictClass != nil
        return CopyPasteAnalysisNode(
            id: path, sourcePath: "/src/\(path)", destinationPath: "/dest/\(path)", sourceKind: kind,
            destinationKind: there ? kind : .missing, conflictClass: conflictClass,
            sourceFingerprint: NodeFingerprint(exists: true, kind: kind),
            destinationFingerprint: there
                ? NodeFingerprint(exists: true, kind: kind) : NodeFingerprint(exists: false, kind: .missing),
            children: children, totalNodeCount: 1 + children.reduce(0) { $0 + $1.totalNodeCount },
            conflictNodeCount: there ? 1 : 0)
    }

    // It looks inside a folder only when the folder exists on both sides: nothing inside a new folder, the items of
    // a clashing folder, and nothing inside a new folder within it. The counts stay those of the whole report.
    @Test func readsInsideOnlyTheFoldersOnBothSides() {
        let album = item(
            "album", folder: true,
            [item("album/one.jpg"), item("album/raw", folder: true, [item("album/raw/one.dng")])])
        let shared = item(
            "shared", .directoryConflict, folder: true,
            [
                item("shared/clash.txt", .fileConflict), item("shared/deep", folder: true, [item("shared/deep/a.txt")]),
                item("shared/new.txt"),
            ])
        var whole = report([album, shared])
        whole.summary.totalNodeCount = album.totalNodeCount + shared.totalNodeCount

        let review = ReviewReport(whole)

        #expect(review.nodes.map(\.id) == ["album", "shared"])
        #expect(review.nodes[0].children.isEmpty)
        #expect(review.nodes[0].totalNodeCount == 4)
        #expect(review.nodes[1].children.map(\.id) == ["shared/clash.txt", "shared/deep", "shared/new.txt"])
        #expect(review.nodes[1].children[1].children.isEmpty)
        #expect(review.nodes[1].children[1].totalNodeCount == 2)
        #expect(review.summary.totalNodeCount == 9)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ReviewSheetRowsMatrixTests {
        private var reviews: CopyPasteReviewPresenter { CopyPasteReviewPresenter.shared }

        private func open(_ nodes: [CopyPasteAnalysisNode], on window: WritingWindow) throws {
            reviews.review(
                report(nodes), action: .paste, policy: WindowWriteActions.safePolicy, clearsCutClipboard: nil,
                actions: try #require(window.tab.writeActions))
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
        }

        private func showAll(in sheet: CopyPasteReviewSheet) -> SheetLink? {
            findViews("reviewSheet.showAll", in: sheet).first as? SheetLink
        }

        // The link after the first rows draws the rest, once.
        @Test func theLinkDrawsTheRestOfALongList() async throws {
            let window = try await WritingWindow.open()
            try open((0..<301).map { node("f\($0).txt", conflict: true) }, on: window)
            let sheet = try #require(reviews.sheet)
            #expect(sheet.rowViewsShown.count == 300)
            let link = try #require(showAll(in: sheet))
            #expect(link.title == "Show all 301")
            link.sendAction(link.action, to: link.target)
            #expect(sheet.rowViewsShown.count == 301)
            #expect(showAll(in: sheet) == nil)
            sheet.onClose()
            await window.close()
        }

        // An operation without conflicts has no "For all", and its rows say "Adds".
        @Test func anOperationWithoutConflictsListsWhatItAdds() async throws {
            let window = try await WritingWindow.open()
            try open((0..<2).map { node("f\($0).txt", conflict: false) }, on: window)
            let sheet = try #require(reviews.sheet)
            #expect(sheet.bar == nil)
            #expect(sheet.rowViewsShown.first?.addsLabel.stringValue == "Adds")
            #expect(showAll(in: sheet) == nil)
            sheet.onClose()
            await window.close()
        }

        // Replace is offered on a row only where it can be done: elsewhere it is there, disabled,
        // saying why.
        @Test func aRowReplaceCantTakeHasItDisabledWithTheReason() async throws {
            let window = try await WritingWindow.open()
            try open(
                [node("inside", conflict: true, blocked: "contains the pasted item"), node("plain", conflict: true)],
                on: window)
            let sheet = try #require(reviews.sheet)
            let rows = sheet.rowViewsShown
            let blocked = try #require(rows.first { $0.row?.name == "inside" }?.popUp)
            let replace = try #require(blocked.itemArray.first { $0.title.hasPrefix("Replace") })
            #expect(replace.title == "Replace (contains the pasted item)")
            #expect(!replace.isEnabled)
            let plain = try #require(rows.first { $0.row?.name == "plain" }?.popUp)
            let offered = try #require(plain.itemArray.first { $0.title.hasPrefix("Replace") })
            #expect(offered.title == "Replace")
            #expect(offered.isEnabled)
            sheet.onClose()
            await window.close()
        }

        // The one item of a paste being one Replace can't take, the alert offers Keep Both and no Replace, and
        // says nothing of the Trash (with Replace possible: CopyPasteDialogsTests).
        @Test func aSingleConflictReplaceCantTakeOffersNoReplace() async throws {
            let window = try await WritingWindow.open()
            try open([node("inside", conflict: true, blocked: "contains the pasted item")], on: window)
            let alert = try #require(reviews.alert)
            let titles = alert.buttons.map(\.title)
            #expect(titles.contains("Keep Both"))
            #expect(!titles.contains { $0.hasPrefix("Replace") })
            await window.close()
        }

    }
}
