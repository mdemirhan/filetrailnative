// Checks against useExplorerShortcuts.ts:1109-1117 and useExplorerNavigationController.ts:1447
// (`navigateTreeFileSystemPath`): with the tree focused, Open opens the folder; only Return and ⌘↓ fold it
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct OpenFromTheTreeTests {
        /// A tab on its folder with the tree focused and the row of `Alpha` selected, not opened.
        private func openedOnARow(_ harness: ExplorerHarness) async throws -> (MainWindowController, String) {
            let tab = try await harness.open()
            let alpha = harness.folder.appending("Alpha").path
            let model = tab.sidebarController.model
            // Rooted here, so the test doesn't wait for the tree to read its way down from the disk's root.
            model.rootTree(at: harness.folder.path)
            #expect(await waitUntil { model.nodes[alpha] != nil })
            tab.perform(.focusTreePane)
            model.restoreSelected(.filesystem(alpha))
            #expect(tab.focusedPane == .tree)
            return (tab, alpha)
        }

        // File > Open and ⌘O
        // B-NAV-092 B-TREE-152
        @Test func openOpensTheSelectedFolderAndLeavesItsBranchAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, alpha) = try await openedOnARow(harness)
            let model = tab.sidebarController.model
            let expanded = model.nodes[alpha]?.expanded

            tab.perform(.openSelection)
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            #expect(model.selected == .filesystem(alpha))
            #expect(tab.canGoBack)
            #expect(model.nodes[alpha]?.expanded == expanded)
            await harness.close()
        }

        // The toolbar's Open is the same command.
        // B-NAV-092
        @Test func theToolbarsOpenOpensTheSelectedFolderToo() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, alpha) = try await openedOnARow(harness)
            tab.updatePreferences(["topToolbarItems": .array([.string(ToolbarItemID.openSelection.rawValue)])])
            harness.layout(tab)
            let open = try #require(tab.explorerToolbar.button(.openSelection))
            open.onClick?()
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            await harness.close()
        }

        // Return and ⌘↓ stay `openTreeNode`: they read and unfold the folder, and what is on screen stays.
        // B-NAV-091
        @Test func openingTheNodeStillFoldsTheBranch() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, alpha) = try await openedOnARow(harness)
            let model = tab.sidebarController.model
            let shown = tab.shownFolderPath
            #expect(tab.sidebarController.openSelection())
            #expect(await waitUntil { model.nodes[alpha]?.loaded == true })
            #expect(tab.shownFolderPath == shown)
            await harness.close()
        }
    }
}
