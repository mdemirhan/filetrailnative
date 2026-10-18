// Ports the keyboard cases of components/TreePane.test.tsx and App.treeKeys.test.tsx on a real explorer window on
// screen: arrow keys sent through the window to the focused sidebar
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct SidebarGUITests: SidebarTesting {
        // T-9f474d2b T-fc0da8c2 T-6625a938 F-740 B-TREE-108 B-TREE-111 B-TREE-113
        // T-945f8c88 F-736 B-TREE-070 B-TREE-012: a folder opens to show what is inside it
        @Test func theArrowKeysMoveOpenAndCloseBranchesInTheFocusedSidebar() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open(listed(harness, ""))
            await rooted(tab, harness)
            let controller = sidebar(tab)
            #expect(await waitUntil { self.labels(controller).contains("Alpha") })
            tab.perform(.focusTreePane)
            #expect(controller.isFocused)
            controller.model.selectItem(.filesystem(listed(harness, "Alpha")))
            // The click's own navigation finishes reading the folder before a key comes after it.
            await settle()
            key(124, "\u{F703}", in: tab.window)  // →
            #expect(await waitUntil { self.labels(controller).contains("Inner") })
            key(125, "\u{F701}", in: tab.window)  // ↓
            #expect(controller.model.selected == .filesystem(listed(harness, "Alpha/Inner")))
            key(123, "\u{F702}", in: tab.window)  // ←
            #expect(controller.model.selected == .filesystem(listed(harness, "Alpha")))
            await harness.close()
        }
    }
}
