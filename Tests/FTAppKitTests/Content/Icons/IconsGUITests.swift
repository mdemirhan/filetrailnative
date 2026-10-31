// Covers scrolling the Icon view of a large folder in a real explorer window on screen (PLAN.md section 4: the original's
// ballpark, reported rather than enforced)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct IconsGUITests {
        // F-757 F-758 B-VIEW-010 B-VIEW-019: scrolling 10,000 items draws only the rows on screen; the longest frame is
        // reported.
        @Test func scrollingTenThousandItemsReportsTheLongestFrame() async throws {
            let harness = try ExplorerHarness()
            let many = try harness.makeFolder(named: "Many", files: 10_000)
            let tab = try await harness.open(many.path)
            tab.perform(.viewAsIcons)
            let probe = GridProbe(tab: tab)
            #expect(await waitUntil { tab.content.entries.count == 10_000 && probe.icons != nil })
            let icons = try #require(probe.icons)
            let window = try #require(tab.window)
            window.displayIfNeeded()
            var longest = 0.0
            var total = 0.0
            let steps = 300
            for _ in 0..<steps {
                let start = ProcessInfo.processInfo.systemUptime
                icons.scroll.contentView.scroll(
                    to: NSPoint(x: 0, y: icons.scroll.contentView.bounds.origin.y + 120))
                icons.scroll.reflectScrolledClipView(icons.scroll.contentView)
                window.displayIfNeeded()
                let frame = (ProcessInfo.processInfo.systemUptime - start) * 1000
                longest = max(longest, frame)
                total += frame
            }
            print(
                "icons scroll 10k: longest frame \(String(format: "%.1f", longest)) ms, mean \(String(format: "%.2f", total / Double(steps))) ms"
            )
            #expect(icons.scroll.contentView.bounds.origin.y > 0)
            #expect(probe.grid.map { $0.indexPathsForVisibleItems().count < 10_000 } == true)
            await harness.close()
        }
    }
}
