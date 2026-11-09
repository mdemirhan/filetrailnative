// Rows follow the pane's width, on an explorer window that is never shown, and an outside change
// keeps the details shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor @Suite struct ReviewRowWidthTests {
        @Test func rowsFollowAWiderPane() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !listViews("list.row", in: tab.window?.contentView).isEmpty }
            harness.layout(tab)
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.contentLayoutRect.width + 400, height: 600))
            harness.layout(tab)
            #expect(
                await waitUntil {
                    harness.layout(tab)
                    let pane = tab.content.contentShell.convert(tab.content.contentShell.bounds, to: nil)
                    return listViews("list.row", in: tab.window?.contentView).first.map {
                        pane.maxX - $0.convert($0.bounds, to: nil).maxX == 10
                    } == true
                })
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

    // An item that changed on disk keeps what is shown for it until it is read again.
    @MainActor @Test func changedItemsKeepTheirDetailsUntilReadAgain() async {
        let (controller, entries) = await loadedController()
        controller.show(
            folder: "/f", entries: entries, selecting: nil, keepingScroll: true, changedPaths: [entries[0].path])
        #expect(controller.metadata(for: entries[0].path) != nil)
        #expect(controller.staleMetadata == [entries[0].path])
    }

    // A folder read again with nothing said to have changed keeps its details as read (a17: hidden files shown).
    @MainActor @Test func aReadThatNamesNothingLeavesEveryRowsDetailsCurrent() async {
        let (controller, entries) = await loadedController()
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false, changedPaths: [])
        #expect(entries.allSatisfy { controller.metadata(for: $0.path) != nil })
        #expect(controller.staleMetadata.isEmpty)
    }

    @MainActor @Test func aFullReadKeepsEveryRowsDetails() async {
        let (controller, entries) = await loadedController()
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: true)
        #expect(entries.allSatisfy { controller.metadata(for: $0.path) != nil })
        #expect(controller.staleMetadata == Set(entries.map(\.path)))
    }

    /// Reads of details that wait until the test lets each one answer, with the size the item had as each began.
    @MainActor final class HeldReads {
        var size = 1
        private(set) var count = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        var loaders: ContentLoaders {
            ContentLoaders(
                metadata: { [self] _, paths in
                    count += 1
                    let sizeAtStart = size
                    await withCheckedContinuation { waiting.append($0) }
                    return paths.compactMap { ReviewStaleDetailsTests.details($0, size: sizeAtStart) }
                }, hiddenCount: { _ in 0 }, iconStore: { nil }, homePath: "/", openPrivacySettings: {})
        }

        func answerOldest() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
        func answerAll() { while !waiting.isEmpty { answerOldest() } }
    }

    static func details(_ path: String, size: Int) -> EntryMetadata? {
        let json: [String: Any] = [
            "path": path, "kindLabel": "Plain Text", "createdAt": "2026-10-13T14:30:00.000Z",
            "modifiedAt": "2026-10-13T14:37:00.000Z", "sizeBytes": size, "sizeStatus": "ready",
            "permissionMode": 0o100644,
        ]
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap {
            try? JSONDecoder().decode(EntryMetadata.self, from: $0)
        }
    }

    @MainActor private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // An item that changes while its details are being read is read again: the answer may be from before.
    @MainActor @Test func anItemThatChangesWhileItsDetailsAreReadIsReadAgain() async {
        let reads = HeldReads()
        let entries = [ContentModelTests.entry("a.txt")]
        let path = entries[0].path
        let controller = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_002), loaders: reads.loaders)
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false)
        controller.requestMetadata(for: [path])
        await settle { reads.count == 1 }
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: true, changedPaths: [path])
        reads.size = 2
        reads.answerOldest()
        await settle { reads.count == 2 }
        #expect(reads.count == 2)
        reads.answerAll()
        await settle { controller.metadata(for: path)?.sizeBytes == 2 }
        #expect(controller.metadata(for: path)?.sizeBytes == 2)
        #expect(controller.staleMetadata.isEmpty)
        #expect(!controller.isReadingDetails)
    }

    // Left and opened again, the folder's details are read afresh: an answer to a read from before it was left is
    // dropped and leaves the new read under way.
    @MainActor @Test func aReadFromBeforeTheFolderWasLeftIsDropped() async {
        let reads = HeldReads()
        let entries = [ContentModelTests.entry("a.txt")]
        let path = entries[0].path
        let controller = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_003), loaders: reads.loaders)
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false)
        controller.requestMetadata(for: [path])
        await settle { reads.count == 1 }
        controller.show(folder: "/g", entries: [], selecting: nil, keepingScroll: false)
        controller.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false)
        reads.size = 2
        controller.requestMetadata(for: [path])
        await settle { reads.count == 2 }
        reads.answerOldest()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(controller.isReadingDetails)
        #expect(controller.metadata(for: path) == nil)
        reads.answerAll()
        await settle { controller.metadata(for: path) != nil }
        #expect(controller.metadata(for: path)?.sizeBytes == 2)
        #expect(!controller.isReadingDetails)
    }
}
