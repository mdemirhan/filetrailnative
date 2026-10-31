// Port by feature of "renders the first rows of a long list", "caps the list of a large operation without conflicts" and
// "won't offer Replace for an item that contains what is being pasted" of
// apps/desktop/src/renderer/components/CopyPasteReviewDialog.test.tsx: the review as it opens on a window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct ReviewSheetRowsMatrixTests {
        private var reviews: CopyPasteReviewPresenter { CopyPasteReviewPresenter.shared }

        private func node(_ name: String, conflict: Bool, blocked: String? = nil) -> CopyPasteAnalysisNode {
            let exists = NodeFingerprint(exists: true, kind: .file, size: 1)
            return CopyPasteAnalysisNode(
                id: name, sourcePath: "/src/\(name)", destinationPath: "/dest/\(name)", sourceKind: .file,
                destinationKind: conflict ? .file : .missing, disposition: conflict ? .conflict : .new,
                conflictClass: conflict ? .fileConflict : nil, sourceFingerprint: exists,
                destinationFingerprint: conflict ? exists : NodeFingerprint(exists: false, kind: .missing),
                children: [], totalNodeCount: 1, conflictNodeCount: conflict ? 1 : 0,
                keepBothDestinationPath: conflict ? "/dest/\(name) copy" : nil, replaceBlockedReason: blocked)
        }

        private func report(_ nodes: [CopyPasteAnalysisNode]) -> CopyPasteAnalysisReport {
            CopyPasteAnalysisReport(
                analysisId: "analysis-1", mode: .copy, sourcePaths: nodes.map(\.sourcePath),
                destinationDirectoryPath: "/dest", nodes: nodes, issues: [], warnings: [],
                summary: CopyPasteAnalysisSummary(
                    topLevelItemCount: nodes.count, totalNodeCount: nodes.count, totalBytes: Int64(nodes.count),
                    fileConflictCount: nodes.filter { $0.conflictClass != nil }.count, directoryConflictCount: 0,
                    mismatchConflictCount: 0, blockedCount: 0))
        }

        private func open(_ nodes: [CopyPasteAnalysisNode], on window: WritingWindow) throws {
            reviews.review(
                report(nodes), action: .paste, policy: WindowWriteActions.safePolicy, clearsCutClipboard: nil,
                actions: try #require(window.tab.writeActions))
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
        }

        private func showAll(in sheet: CopyPasteReviewSheet) -> SheetLink? {
            findViews("reviewSheet.showAll", in: sheet).first as? SheetLink
        }

        // T-f10b2d4f B-CLIP-086: 300 rows are drawn, and "Show all N" draws the rest, once.
        @Test(arguments: [(301, "Show all 301"), (1_400, "Show all 1,400")])
        func aLongListOfConflictsDrawsItsFirstRows(_ count: Int, _ label: String) async throws {
            let window = try await WritingWindow.open()
            try open((0..<count).map { node("f\($0).txt", conflict: true) }, on: window)
            let sheet = try #require(reviews.sheet)
            #expect(sheet.rowViewsShown.count == 300)
            let link = try #require(showAll(in: sheet))
            #expect(link.title == label)
            link.sendAction(link.action, to: link.target)
            #expect(sheet.rowViewsShown.count == count)
            #expect(showAll(in: sheet) == nil)
            sheet.onClose()
            await window.close()
        }

        // A list of exactly the limit has nothing to show.
        @Test func aListOfThreeHundredHasNoLink() async throws {
            let window = try await WritingWindow.open()
            try open((0..<300).map { node("f\($0).txt", conflict: true) }, on: window)
            let sheet = try #require(reviews.sheet)
            #expect(sheet.rowViewsShown.count == 300)
            #expect(showAll(in: sheet) == nil)
            sheet.onClose()
            await window.close()
        }

        // T-15f564ad B-CLIP-086: the list of a large operation without conflicts has the same limit, its rows "Adds".
        @Test func aLargeOperationWithoutConflictsDrawsItsFirstRows() async throws {
            let window = try await WritingWindow.open()
            try open((0..<500).map { node("f\($0).txt", conflict: false) }, on: window)
            let sheet = try #require(reviews.sheet)
            #expect(sheet.bar == nil)
            #expect(sheet.rowViewsShown.count == 300)
            #expect(sheet.rowViewsShown.first?.addsLabel.stringValue == "Adds")
            #expect(showAll(in: sheet)?.title == "Show all 500")
            sheet.onClose()
            await window.close()
        }

        // T-d7a7c28b B-CLIP-093: Replace is offered on a row only where it can be done: elsewhere it is there, disabled,
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

        // T-d7a7c28b: the one item of a paste being one Replace can't take, the alert offers Keep Both and no Replace, and
        // says nothing of the Trash.
        @Test func aSingleConflictReplaceCantTakeOffersNoReplace() async throws {
            let window = try await WritingWindow.open()
            try open([node("inside", conflict: true, blocked: "contains the pasted item")], on: window)
            let alert = try #require(reviews.alert)
            let titles = alert.buttons.map(\.title)
            #expect(titles.contains("Keep Both"))
            #expect(!titles.contains { $0.hasPrefix("Replace") })
            await window.close()
        }

        // T-d7a7c28b: with Replace possible, the alert has it.
        @Test func aSingleConflictOffersReplace() async throws {
            let window = try await WritingWindow.open()
            try open([node("plain", conflict: true)], on: window)
            let alert = try #require(reviews.alert)
            #expect(alert.buttons.map(\.title).contains("Replace"))
            await window.close()
        }
    }
}
