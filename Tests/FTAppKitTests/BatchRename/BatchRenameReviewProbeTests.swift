// While the Rename sheet is up its window's tabs are held: no tab opens or closes, and `copyPasteModalOpen` refuses
// New Tab and Close Tab
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
