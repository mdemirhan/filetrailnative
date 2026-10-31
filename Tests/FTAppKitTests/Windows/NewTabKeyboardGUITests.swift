// A new tab on a real window: AppKit hands a window coming to the front its first key view, which is the sidebar's
import AppKit
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct NewTabKeyboardGUITests: SidebarTesting {
        @Test(arguments: [false, true])
        func aNewTabHasTheKeyboardInItsPaneFromTheMomentItShows(fromTree: Bool) async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open(listed(harness, ""))
            tab.perform(fromTree ? .focusTreePane : .focusContentPane)
            let group = try #require(tab.group)

            tab.perform(.newTab)
            let index = try #require(group.tabs.firstIndex { $0 === tab })
            let new = group.tabs[index + 1]
            new.servicesOverride = tab.servicesOverride

            // Its first folder is yet to be read.
            let pane: ExplorerPane = fromTree ? .tree : .content
            #expect(new.focusedPane == pane)
            #expect(new.sidebarController.isFocused == fromTree)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                new.whenFirstReadFinished { _ in done.resume() }
            }
            #expect(new.focusedPane == pane)
            await harness.close()
        }
    }
}
