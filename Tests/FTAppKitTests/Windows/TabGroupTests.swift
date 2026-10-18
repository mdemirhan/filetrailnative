// Ports the tab order of apps/desktop/e2e/windows.spec.ts on a tab group that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabGroupTests {
        // F-615 B-VIEW-149
        @Test func savesTheTabsInTheOrderOfTheTabBar() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            let folder = harness.folder
            group.openTab(path: folder.appending("Alpha").path, from: first)
            #expect(await waitUntil { group.tabs.count == 2 })

            // The system tab bar has the tabs in another order (a tab dragged along it).
            group.replaceTabs(group.tabs.reversed())
            #expect(
                harness.store.windowPreferences(group.recordID).openTabs.map(\.path) == [
                    folder.appending("Alpha").path, folder.path,
                ])
            await harness.close()
        }
    }
}
