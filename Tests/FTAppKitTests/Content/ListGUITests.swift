// Covers the flow of folderWatch.spec.ts in a real explorer window on screen, by feature row (App.folderOrder.test.tsx
// and App.folderWatch.test.tsx): a change made outside the app keeps the selection
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ListGUITests: ListTesting {
        // F-756 F-828 B-VIEW-008 B-VIEW-009 B-SEL-175: a selection stays through a change made outside the app, which
        // appears without Loading….
        // B-NAV-124 B-SEL-027 B-SEL-031 T-742803ad T-8b8a3319
        @Test func aChangeOutsideKeepsTheSelection() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !bars(tab).isEmpty }
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }).path
            tab.content.select(paths: [note])
            #expect(tab.selectedPaths == [note])
            try "y".write(to: harness.folder.appending("new.txt"), atomically: true, encoding: .utf8)
            tab.refresh()
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "new.txt" } })
            #expect(tab.selectedPaths == [note])
            #expect(tab.content.container(for: .none))
            // A selected item removed outside drops out (B-VIEW-192).
            try FileManager.default.removeItem(atPath: note)
            tab.refresh()
            #expect(await waitUntil { tab.selectedPaths.isEmpty })
            await harness.close()
        }
    }
}
