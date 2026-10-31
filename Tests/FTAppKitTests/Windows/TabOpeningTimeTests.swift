// What a new tab costs as a window fills up to its limit: it leaves the tabs that didn't change alone. Timed by hand with
// FILETRAIL_TAB_TIMING=1, once: the rest of the time, and all of its growth but a little, is the system's tab bar.
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

/// Opens tabs up to the limit, once, and says how long each `openNewTab` took until its folder was read and its window
/// laid out, by the average of every ten tabs.
@MainActor
private func timeNewTabs(_ harness: ExplorerHarness) async throws -> String {
    let first = try await harness.open()
    let group = try #require(first.group)
    let clock = ContinuousClock()
    var times: [Duration] = []
    while group.tabs.count < AppPreferenceLimits.openTabsLimit {
        let from = try #require(group.selected)
        let before = Set(group.tabs.map(ObjectIdentifier.init))
        let start = clock.now
        group.openNewTab(from: from)
        let opened = try #require(group.tabs.first { !before.contains(ObjectIdentifier($0)) })
        while !opened.loaded {
            try await Task.sleep(for: .milliseconds(1))
        }
        harness.layout(opened)
        times.append(clock.now - start)
    }
    return stride(from: 0, to: times.count, by: 10).map { index in
        let part = times[index..<min(index + 10, times.count)]
        let average = part.reduce(Duration.zero, +) / part.count
        return average.formatted(.units(allowed: [.milliseconds], width: .narrow))
    }.joined(separator: " ")
}

private let timesTabs = ProcessInfo.processInfo.environment["FILETRAIL_TAB_TIMING"] == "1"

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

        @Test(.enabled(if: timesTabs)) func newTabsWithoutTheTabBar() async throws {
            let harness = try ExplorerHarness.windowless()
            print("new tab, every ten tabs, no tab bar:", try await timeNewTabs(harness))
            await harness.close()
        }
    }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct TabOpeningTimeGUITests {
        @Test(.enabled(if: timesTabs)) func newTabsWithTheTabBar() async throws {
            let harness = try ExplorerHarness()
            print("new tab, every ten tabs, on screen:", try await timeNewTabs(harness))
            await harness.close()
        }
    }
}
