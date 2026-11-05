// The explorer window's frame on screen: a sidebar split under a unified system toolbar, as Finder's
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct WorkspaceGUITests {
        // On screen as off it: the content column at the sidebar's width with no divider, the items in the
        // band, a press in the title bar opening the Sort menu, and the search field taking the keyboard.
        @Test func placesTheBandAndTakesItsPressesOnScreen() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            window.setContentSize(MainWindowController.defaultContentSize)
            harness.layout(tab)
            let workspace = tab.workspace
            #expect(workspace.frame(of: workspace.mainCell).minX == 288, "\(workspace.frame(of: workspace.mainCell))")
            let sort = try #require(tab.explorerToolbar.button(.sort))
            let center = MouseEvents.center(of: sort)
            for (down, up) in MouseEvents.clicks(at: center, in: window, count: 1, modifiers: []) {
                window.sendEvent(down)
                window.sendEvent(up)
            }
            #expect(AppMenuPresenter.shared.menu != nil)
            AppMenuPresenter.shared.close()
            let field = try #require(tab.searchField)
            #expect(window.makeFirstResponder(field))
            #expect(field.isActive)
            await harness.close()
        }
    }
}
