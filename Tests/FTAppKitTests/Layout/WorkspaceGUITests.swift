// The explorer window's frame on screen as the user reported it: no lines the original doesn't have
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct WorkspaceGUITests {
        // F-707: the window's frame is the original's: no system toolbar or title, no lines in the title bar, the band
        // 52 tall, the traffic lights 14 in and 16 down; the sidebar is translucent and runs the window's height.
        @Test func drawsNoLinesTheOriginalDoesNotHave() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            let window = try #require(tab.window)
            #expect(window.toolbar == nil)
            #expect(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
            #expect(window.titlebarSeparatorStyle == .none)
            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(!(window.contentViewController is NSSplitViewController))
            let close = try #require(window.standardWindowButton(.closeButton))
            let frame = close.convert(close.bounds, to: nil)
            #expect(frame.minX == WindowChrome.trafficLights.x)
            #expect(window.frame.height - frame.maxY == WindowChrome.trafficLights.y)
            let container = try #require(close.superview?.superview)
            #expect(container.frame.height == 52)
            #expect(tab.workspace.sidebarCell.frame.minY == 0)
            await harness.close()
        }
    }
}
