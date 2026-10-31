// Port of the sheet's part of apps/desktop/src/renderer/App.tsx: `.modal-scrim.is-sheet` covers the tab strip
// (styles.css:1229-1243) and `copyPasteModalOpen` refuses newTab and closeTab (App.tsx:1089-1098) while it is up
import AppKit
import FTFileSystem
import FTFoundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ReviewProbe {
        @Test func newTabWaitsWhileTheSheetIsUp() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["a.txt", "b.txt"] {
                try "x".write(to: harness.folder.appending(name), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let paths = tab.content.entries.filter { $0.name.hasSuffix(".txt") }.map(\.path)
            tab.openBatchRenameSheet(
                paths.map { BatchRenameTarget(path: $0, name: NodePath.basename($0), isFolder: false) })
            #expect(tab.batchRenameSheet != nil)
            let before = group.tabs.count
            #expect(group.isBlocked)
            #expect(tab.dragDrop.isBlocked)
            // The tab bar's "+", and ⌘W: no tab opens or closes under the sheet.
            tab.newWindowForTab(nil)
            #expect(group.tabs.count == before)
            group.closeTab(tab)
            #expect(group.tabs.count == before)
            tab.batchRenameSheet?.onCancel()
            #expect(!group.isBlocked)
            #expect(!tab.dragDrop.isBlocked)
            await harness.close()
        }
    }
}
