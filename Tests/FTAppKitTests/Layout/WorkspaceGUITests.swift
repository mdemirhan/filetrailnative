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
        // F-707: no title; a unified system toolbar whose band is 52 tall, the toolbar's row over the content column;
        // the traffic lights over the sidebar, which is the system's material and runs the window's height.
        @Test func drawsNoLinesTheOriginalDoesNotHave() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            #expect(window.toolbar === tab.explorerToolbar.toolbar && window.toolbarStyle == .unified)
            #expect(window.titleVisibility == .hidden)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(WindowChrome.panesTop(window) == 52)
            let close = try #require(window.standardWindowButton(.closeButton))
            let workspace = tab.workspace
            #expect(workspace.frame(of: close).maxX < workspace.frame(of: workspace.sidebarCell).maxX)
            #expect(workspace.frame(of: workspace.sidebarCell).minY == 0)
            let first = try #require(tab.explorerToolbar.button(.folderTree))
            #expect(workspace.frame(of: first).minX >= workspace.frame(of: workspace.mainCell).minX)
            #expect(workspace.frame(of: first).maxY <= 52)
            await harness.close()
        }

        // On screen as off it: the content column at the sidebar's width with no divider, the items in the
        // band, a press in the title bar opening the Sort menu, and the search field taking the keyboard.
        // covered-by-feature F-707 F-708 F-712 F-713
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
