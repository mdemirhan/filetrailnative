// What a new tab costs as a window fills up to its limit: it leaves the tabs that didn't change alone. The rest of the
// time, and all of its growth but a little, is the system's tab bar.
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabOpeningTimeTests {
        @Test func aNewTabLeavesTheTitlesOfTheOthersAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            let tab = try #require(first.window?.tab)
            var titlesSet = 0
            let observation = tab.observe(\.title) { _, _ in
                MainActor.assumeIsolated { titlesSet += 1 }
            }
            group.openTab(path: harness.folder.appending("Alpha").path, from: first)
            group.openTab(path: harness.folder.appending("Beta").path, from: group.tabs[1])
            observation.invalidate()
            #expect(group.tabs.count == 3)
            #expect(titlesSet == 0)
            await harness.close()
        }

        @Test func aNewTabTellsTheMenuOnlyOfTheTabInFront() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let group = try #require(first.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: first)
            var told: [Int] = []
            harness.windows.onMenuState = { windowID, _ in told.append(windowID) }
            group.openTab(path: harness.folder.appending("Beta").path, from: group.tabs[1])
            harness.windows.onMenuState = { _, _ in }
            #expect(told == [group.tabs[2].windowID])
            await harness.close()
        }
    }
}
