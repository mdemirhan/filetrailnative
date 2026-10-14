// Review round 1 of P5-03: rows follow the pane's width, a size bar is cut at its cell, an outside change keeps the
// details shown, and the folder watch's changed items reach the reload
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
private func reviewViews(_ id: String, in root: NSView?) -> [NSView] {
    guard let root else { return [] }
    var found: [NSView] = root.accessibilityIdentifier() == id && !root.isHidden ? [root] : []
    for child in root.subviews where !child.isHidden { found += reviewViews(id, in: child) }
    return found
}

extension ExplorerWindowGUITests {
    @MainActor @Suite struct ReviewRowWidthTests {
        @Test func rowsFollowAWiderPane() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !reviewViews("list.row", in: tab.window?.contentView).isEmpty }
            harness.layout(tab)
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.contentLayoutRect.width + 400, height: 600))
            harness.layout(tab)
            try? await Task.sleep(for: .milliseconds(300))
            harness.layout(tab)
            let pane = tab.content.contentShell.convert(tab.content.contentShell.bounds, to: nil)
            let all = reviewViews("list.row", in: tab.window?.contentView)
            let bar = try #require(all.first)
            let frame = bar.convert(bar.bounds, to: nil)
            #expect(pane.maxX - frame.maxX == 10)
            await harness.close()
        }

        // The Size cell cuts its bar at the cell's edge (`.details-row > span { overflow: hidden }`).
        @Test func theSizeCellClipsItsBar() {
            #expect(SizeCellView().clipsToBounds)
        }

        // The folder watch's changed items reach the reload, not "anything may have changed".
        @Test func aFolderWatchChangeKeepsItsChangedPaths() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.folderChangesHeld = true
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: ["/x/a"]))
            #expect(tab.pendingChange?.changedPaths == ["/x/a"])
            tab.folderChangesHeld = false
            await harness.close()
        }
    }
}

struct ReviewStaleDetailsTests {
    @MainActor
    private func loadedController() async -> (ContentPaneController, [DirectoryEntry]) {
        let entries = [ContentModelTests.entry("a.txt"), ContentModelTests.entry("b.txt")]
        let loaders = ContentLoaders(
            metadata: { _, paths in
                paths.compactMap { path in
                    let json: [String: Any] = [
                        "path": path, "kindLabel": "Plain Text", "createdAt": "2026-10-13T14:30:00.000Z",
                        "modifiedAt": "2026-10-13T14:37:00.000Z", "sizeBytes": 9, "sizeStatus": "ready",
                        "permissionMode": 0o100644,
                    ]
                    return (try? JSONSerialization.data(withJSONObject: json)).flatMap {
                        try? JSONDecoder().decode(EntryMetadata.self, from: $0)
                    }
                }
            }, hiddenCount: { _ in 0 }, iconStore: { nil }, homePath: "/", openPrivacySettings: {})
        let controller = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_001), loaders: loaders)
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false)
        controller.requestMetadata(for: entries.map(\.path))
        for _ in 0..<200 where controller.metadata(for: entries[1].path) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (controller, entries)
    }

    // An item that changed on disk keeps what is shown for it until it is read again (B-NAV-134).
    @MainActor @Test func changedItemsKeepTheirDetailsUntilReadAgain() async {
        let (controller, entries) = await loadedController()
        controller.show(
            folder: "/f", entries: entries, selecting: nil, keepingScroll: true, changedPaths: [entries[0].path])
        #expect(controller.metadata(for: entries[0].path) != nil)
        #expect(controller.staleMetadata == [entries[0].path])
    }

    @MainActor @Test func aFullReadKeepsEveryRowsDetails() async {
        let (controller, entries) = await loadedController()
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: true)
        #expect(entries.allSatisfy { controller.metadata(for: $0.path) != nil })
        #expect(controller.staleMetadata == Set(entries.map(\.path)))
    }
}
