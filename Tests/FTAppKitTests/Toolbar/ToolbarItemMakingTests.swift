import AppKit
import FTFoundation
import Testing

@testable import FTAppKit

@MainActor
struct ToolbarItemMakingTests {
    // The search item is made again whenever the toolbar is customized; the one field it holds keeps one pair of width
    // rules, not a pair more each time.
    @Test func theSearchFieldKeepsOnePairOfWidthsWhenItsItemIsMadeAgain() throws {
        _ = NSApplication.shared
        let explorer = ExplorerToolbar(identifier: "filetrail.test.\(UUID().uuidString)")
        let toolbar = NSToolbar(identifier: "filetrail.test.toolbar")
        for _ in 0..<3 {
            _ = explorer.toolbar(
                toolbar, itemForItemIdentifier: ExplorerToolbar.identifier(.search), willBeInsertedIntoToolbar: true)
        }
        let widths = explorer.searchField.constraints.filter { $0.firstAttribute == .width && $0.isActive }
        #expect(widths.count == 2)
    }
}
