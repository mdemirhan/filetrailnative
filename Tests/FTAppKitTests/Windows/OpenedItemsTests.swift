// Ports the "items opened with File Trail from another app" cases of apps/desktop/src/renderer/App.openItems.test.tsx, in an
// explorer window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct OpenedItemsTests {
        private func path(_ name: String, in tab: MainWindowController) -> String {
            tab.content.entries.first { $0.name == name }?.path ?? ""
        }

        // T-0adbc934 F-136 B-NAV-227
        @Test func opensAFolderInANewTabWithTheListGivenTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            tab.perform(.focusTreePane)
            let alpha = path("Alpha", in: tab)

            #expect(harness.windows.openFromOtherApp(OpenRequest(path: alpha, kind: .folder)))

            #expect(group.tabs.count == 2)
            let opened = try #require(group.selected)
            #expect(opened !== tab)
            #expect(await waitUntil { opened.content.entries.map(\.name) == ["Inner"] })
            #expect(opened.shownFolderPath == alpha)
            #expect(await waitUntil { opened.focusedPane == .content })
            await harness.close()
        }

        // T-424b62a7 F-136 B-NAV-228
        @Test func selectsAnyOtherItemInItsFolderInANewTabWithTheListGivenTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            tab.perform(.focusTreePane)
            let note = path("note.txt", in: tab)

            #expect(harness.windows.openFromOtherApp(OpenRequest(path: note, kind: .reveal)))

            #expect(group.tabs.count == 2)
            let opened = try #require(group.selected)
            #expect(opened !== tab)
            #expect(await waitUntil { opened.content.selection.paths == [note] })
            #expect(opened.shownFolderPath == tab.shownFolderPath)
            #expect(await waitUntil { opened.focusedPane == .content })
            await harness.close()
        }

        // F-136 B-NAV-228: an item the list doesn't show (hidden items off) is selected all the same, and the Info panel
        // describes it: `setSingleContentSelection` asks nothing of the listing.
        @Test func selectsAnItemTheListDoesNotShow() async throws {
            let harness = try ExplorerHarness.windowless()
            let hidden = harness.folder.appending(".secret")
            try Data("x".utf8).write(to: hidden)
            let tab = try await harness.open()
            let group = try #require(tab.group)

            #expect(harness.windows.openFromOtherApp(OpenRequest(path: hidden.path, kind: .reveal)))

            let opened = try #require(group.selected)
            var read: Bool?
            opened.whenFirstReadFinished { read = $0 }
            #expect(await waitUntil { read != nil })
            #expect(read == true)
            #expect(opened.content.selection.paths == [hidden.path])
            #expect(opened.infoController?.targetPath == hidden.path)
            await harness.close()
        }

        // F-136 B-NAV-229: the item isn't selected once another tab has been shown.
        @Test func selectsNothingOnceAnotherTabHasBeenShown() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let note = path("note.txt", in: tab)

            #expect(harness.windows.openFromOtherApp(OpenRequest(path: note, kind: .reveal)))
            let opened = try #require(group.selected)
            group.select(tab)

            var read = false
            opened.whenFirstReadFinished { _ in read = true }
            #expect(await waitUntil { read })
            #expect(opened.content.selection.paths.isEmpty)
            await harness.close()
        }

        // F-136 B-NAV-229: nor when the folder is gone.
        @Test func selectsNothingWhenTheFolderIsGone() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let gone = harness.folder.appending("Gone").path

            #expect(harness.windows.openFromOtherApp(OpenRequest(path: gone + "/item.txt", kind: .reveal)))
            let opened = try #require(group.selected)

            var read: Bool?
            opened.whenFirstReadFinished { read = $0 }
            #expect(await waitUntil { read != nil })
            #expect(read == false)
            #expect(opened.content.selection.paths.isEmpty)
            await harness.close()
        }

        // T-a4715c8c T-bb5cec67 F-136 B-NAV-230
        @Test func selectsTheItemAWindowWasOpenedOnItsFolderForInTheTabItOpenedWith() async throws {
            let harness = try ExplorerHarness.windowless()
            let note = harness.folder.appending("note.txt").path

            harness.windows.openWindowOnFolder(harness.folder.path, selecting: note)

            let tab = try #require(harness.windows.front as? MainWindowController)
            #expect(await waitUntil { tab.content.selection.paths.count == 1 })
            #expect(NodePath.basename(tab.content.selection.paths[0]) == "note.txt")
            #expect(tab.group?.tabs.count == 1)
            #expect(tab.focusedPane == .content)
            await harness.close()
        }
    }
}
