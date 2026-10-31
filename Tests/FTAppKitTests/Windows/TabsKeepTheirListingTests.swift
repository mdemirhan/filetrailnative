// Ports the hidden files and Folders First cases of apps/desktop/src/renderer/App.tabs.test.tsx on real tabs of a window
// that is never shown
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabsKeepTheirListingTests {
        private func names(_ tab: MainWindowController) -> [String] { tab.content.entries.map(\.name) }

        private func newTab(from tab: MainWindowController) async throws -> MainWindowController {
            let group = try #require(tab.group)
            let count = group.tabs.count
            tab.perform(.newTab)
            #expect(await waitUntil { group.tabs.count == count + 1 })
            let new = try #require(group.selected)
            #expect(new !== tab)
            new.servicesOverride = tab.servicesOverride
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                new.whenFirstReadFinished { _ in done.resume() }
            }
            return new
        }

        private func openWithAHiddenFile() async throws -> (ExplorerHarness, MainWindowController) {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending(".secret"), atomically: true, encoding: .utf8)
            return (harness, try await harness.open())
        }

        // T-677d402c
        @Test func eachTabKeepsItsOwnHiddenFilesAndFoldersFirst() async throws {
            let (harness, first) = try await openWithAHiddenFile()
            let group = try #require(first.group)
            let second = try await newTab(from: first)

            second.perform(.toggleHiddenFiles)
            second.perform(.toggleFoldersFirst)
            #expect(await waitUntil { self.names(second).contains(".secret") })
            #expect(second.includeHidden)
            #expect(!second.foldersFirst)
            #expect(second.sidebarController.model.includeHidden)

            group.select(first)
            #expect(!first.includeHidden)
            #expect(first.foldersFirst)
            #expect(!first.sidebarController.model.includeHidden)
            // Its next read stays without them too, and the tree's.
            first.perform(.refreshOrApplySearchSort)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!names(first).contains(".secret"))
            #expect(names(first).first == "Alpha")
            #expect(!first.includeHidden)

            group.select(second)
            #expect(second.includeHidden)
            #expect(!second.foldersFirst)
            #expect(names(second).contains(".secret"))
            await harness.close()
        }

        // T-013d46d5
        @Test func aNewTabStartsWithTheHiddenFilesAndFoldersFirstOfItsSource() async throws {
            let (harness, first) = try await openWithAHiddenFile()
            first.perform(.toggleHiddenFiles)
            first.perform(.toggleFoldersFirst)
            #expect(await waitUntil { self.names(first).contains(".secret") })

            let new = try await newTab(from: first)
            #expect(new.includeHidden)
            #expect(!new.foldersFirst)
            #expect(await waitUntil { self.names(new).contains(".secret") })
            #expect(new.sidebarController.model.includeHidden)

            // And it keeps them in the folders it goes to.
            let alpha = harness.folder.appending("Alpha")
            try "x".write(to: alpha.appendingPathComponent(".inside"), atomically: true, encoding: .utf8)
            new.go(to: alpha)
            #expect(await waitUntil { self.names(new).contains(".inside") })
            #expect(new.includeHidden)
            #expect(!new.foldersFirst)
            await harness.close()
        }
    }
}
