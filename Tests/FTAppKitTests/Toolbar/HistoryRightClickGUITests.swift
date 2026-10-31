// Covers the right-click of Back and Forward (HistoryButton.tsx:158-163) through the window, as the press arrives
import AppKit
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct HistoryRightClickGUITests: ToolbarTesting {
        // F-715: AppKit routes a right press on the toolbar itself: sent to the window, it reaches Forward, whose menu
        // lists the folders ahead, and not the toolbar's own menu, whose tracking would hold the window.
        @Test func aRightPressOnForwardOpensItsHistory() async throws {
            let harness = try ExplorerHarness()
            let root = harness.folder.url
            let tab = try await harness.open(root.path)
            for name in ["Alpha", "Alpha/Inner"] {
                await tab.navigate(to: root.appendingPathComponent(name))
            }
            tab.goBack(nil)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == "Alpha" })
            tab.goBack(nil)
            #expect(await waitUntil { tab.currentFolder.lastPathComponent == root.lastPathComponent })
            harness.layout(tab)
            let window = try #require(tab.window)
            let forward = try #require(button(tab, .forward))
            #expect(await waitUntil { forward.isEnabled })
            let press = try #require(
                MouseEvents.event(.rightMouseDown, at: MouseEvents.center(of: forward), in: window))
            #expect(ToolbarButton.takingRightPress(at: press.locationInWindow, in: window) === forward)
            window.sendEvent(press)
            #expect(menu?.identifier == "historyMenu")
            #expect(titles(menu) == ["Alpha", "Inner"])
            AppMenuPresenter.shared.close()
            // A sheet keeps the window's presses from it: no folder is picked behind a question about a write.
            let sheet = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.beginSheet(sheet, completionHandler: nil)
            #expect(await waitUntil { window.attachedSheet != nil })
            window.sendEvent(press)
            #expect(menu == nil)
            AppMenuPresenter.shared.close()
            window.endSheet(sheet)
            await harness.close()
        }
    }
}
