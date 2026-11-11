import FTOperations
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTFoundation

// What a write moved or removed is worked out by the window after a write (`AfterWrite`), by the tabs of every window
// (`ExplorerTabs`) and by the clipboard (`ClipboardWrite`). On the same write they must give the same answer.
@Suite struct WriteMovedOrRemovedTests {
    private static let sources: [String?] = [nil, "", "/a/x", "/a/F"]
    private static let destinations: [String?] = [nil, "", "/a/x", "/b/x", "/a/y"]
    private static let statuses: [CopyPasteItemResult.Status] = [.completed, .skipped, .failed, .cancelled]
    private static let modes: [CopyPasteMode?] = [nil, .copy, .cut]

    /// Every kind of item: each status, with a source and a destination that are missing, empty, the same or another.
    private static let variants: [WriteOperationItem] = statuses.flatMap { status in
        sources.flatMap { source in
            destinations.map { WriteOperationItem(sourcePath: source, destinationPath: $0, status: status) }
        }
    }

    /// Each kind of item alone, all of them at once, and seeded runs of several.
    private static func itemLists() -> [[WriteOperationItem]] {
        var state: UInt64 = 7
        func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(limit))
        }
        let runs = (0..<200).map { _ in (0..<(1 + next(6))).map { _ in variants[next(variants.count)] } }
        return [[]] + variants.map { [$0] } + [variants] + runs
    }

    private func result(
        _ action: WriteOperationAction, _ mode: CopyPasteMode?, _ items: [WriteOperationItem], replaced: [String]?
    ) -> WriteOperationResult {
        WriteOperationResult(
            operationId: "op-1", action: action, mode: mode, status: .completed, targetPath: "/b",
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
            summary: CopyPasteOperationSummary(
                topLevelItemCount: items.count, totalItemCount: items.count, completedItemCount: 0,
                failedItemCount: 0, skippedItemCount: 0, cancelledItemCount: 0, completedByteCount: 0, totalBytes: nil),
            items: items, replacedPaths: replaced, error: nil)
    }

    @Test func theWindowTheTabsAndTheClipboardAgreeOnWhatAWriteMovedOrRemoved() {
        let lists = Self.itemLists()
        var compared = 0
        // Writes that moved something and writes that removed something, so the answers compared aren't all empty.
        var withMoves = 0
        var withRemovals = 0
        for action in WriteOperationAction.allCases {
            #expect(AfterWrite.isUndoOrRedo(action) == ClipboardWrite(action: action, items: []).isUndoOrRedo)
            #expect(ExplorerTabs.isRenameOrMove(action) == ClipboardWrite(action: action, items: []).isRenameOrMove)
            for mode in Self.modes {
                for replaced in [nil, ["/b/r"]] as [[String]?] {
                    for items in lists {
                        let full = result(action, mode, items, replaced: replaced)
                        // As each one is given the write.
                        let outcome = WriteOperationOutcome(
                            action: full.action, mode: full.mode, items: full.items.map(\.effect))
                        let clipboard = ClipboardWrite(
                            action: full.action, mode: full.mode.flatMap { ClipboardMode(rawValue: $0.rawValue) },
                            items: full.items.map(\.effect), replacedPaths: full.replacedPaths ?? [])
                        // Whether it moved items, where it took each one, and what it removed.
                        let moved = [
                            AfterWrite.movedItems(full), ExplorerTabs.movedItems(outcome), clipboard.movedItems,
                        ]
                        let tabMoves = ExplorerTabs.collectFollowedMoves(outcome)
                        let clipboardMoves = clipboard.followedMoves.map { PathMove(from: $0.from, to: $0.to) }
                        let windowRemoved = AfterWrite.removedByWrite(full)
                        let clipboardRemoved = clipboard.removedPaths
                        if Set(moved).count != 1 || tabMoves != clipboardMoves || windowRemoved != clipboardRemoved {
                            Issue.record(
                                """
                                \(action) \(String(describing: mode)) replaced \(String(describing: replaced)) \
                                items \(items): moved \(moved), moves \(tabMoves) and \(clipboardMoves), \
                                removed \(windowRemoved) and \(clipboardRemoved)
                                """)
                        }
                        compared += 1
                        withMoves += tabMoves.isEmpty ? 0 : 1
                        withRemovals += windowRemoved.isEmpty ? 0 : 1
                    }
                }
            }
        }
        #expect(compared > 10_000)
        #expect(withMoves > 1_000)
        #expect(withRemovals > 1_000)
    }
}
