// A closed explorer window is freed: its tab, window and views go, and with them their observers of the app's state
import AppKit
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct ClosedWindowTests {
        /// What a window closed by the user leaves behind: nothing. A tab kept alive keeps its sidebar's watch of the
        /// disks, its folder's and its window's observers, and every later window pays for them.
        @Test func aClosedWindowIsFreedWithItsTabAndViews() async throws {
            let harness = try ExplorerHarness.windowless()
            weak var tab: MainWindowController?
            weak var window: NSWindow?
            weak var group: ExplorerTabGroup?
            weak var sidebar: SidebarViewController?
            weak var content: ContentPaneController?
            weak var workspace: WorkspaceView?
            do {
                let opened = try await harness.open()
                tab = opened
                window = opened.window
                group = opened.group
                sidebar = opened.sidebarController
                content = opened.content
                workspace = opened.workspace
            }
            #expect(tab != nil && window != nil && group != nil)
            await harness.close()
            let freed = await waitUntil {
                tab == nil && window == nil && group == nil && sidebar == nil && content == nil && workspace == nil
            }
            #expect(freed)
            let tabFreed = tab == nil
            let windowFreed = window == nil
            let groupFreed = group == nil
            let sidebarFreed = sidebar == nil
            let contentFreed = content == nil
            let workspaceFreed = workspace == nil
            #expect(tabFreed)
            #expect(windowFreed)
            #expect(groupFreed)
            #expect(sidebarFreed)
            #expect(contentFreed)
            #expect(workspaceFreed)
        }
    }
}
