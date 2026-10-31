// Port of the Back and fresh-navigation cases of apps/desktop/src/renderer/App.history.test.tsx and
// App.scrollRestore.test.tsx, the loading rules of hooks/useExplorerNavigationController.ts (:1099-1141) and the
// scroll kept across a read of components/ContentPane.test.tsx
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FolderMemoryMatrixTests {
        /// A list of 300 files with a 300-file folder inside, so both scroll.
        private func openLong(
            _ view: RendererCommand = .viewAsDetails
        ) async throws -> (harness: ExplorerHarness, tab: MainWindowController, outer: String, sub: String) {
            let harness = try ExplorerHarness.windowless()
            let outer = try harness.makeFolder(named: "Long", files: 300)
            let sub = outer.appendingPathComponent("Sub")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
            for index in 0..<300 {
                try "x".write(
                    to: sub.appendingPathComponent(String(format: "item-%03d.txt", index)), atomically: true,
                    encoding: .utf8)
            }
            let tab = try await harness.open(outer.path)
            tab.perform(view)
            #expect(await waitUntil { tab.content.entries.count == 301 })
            harness.layout(tab)
            return (harness, tab, tab.folder.path, tab.folder.appendingPathComponent("Sub").path)
        }

        private func arrive(_ tab: MainWindowController, _ path: String, _ harness: ExplorerHarness) async -> Bool {
            let arrived = await waitUntil { tab.shownFolderPath == path && !tab.isNavigating }
            harness.layout(tab)
            return arrived
        }

        private func scroll(_ tab: MainWindowController, _ view: RendererCommand = .viewAsDetails) throws
            -> (top: Double, left: Double)
        {
            tab.content.pane?.scrollPosition = view == .viewAsList ? (top: 0, left: 700) : (top: 700, left: 0)
            let position = try #require(tab.content.pane?.scrollPosition)
            #expect(view == .viewAsList ? position.left > 0 : position.top > 0)
            return position
        }

        private func twoSelected(_ tab: MainWindowController) throws -> ContentSelection {
            let first = try #require(tab.content.entries.first { $0.name == "item-010.txt" }).path
            let second = try #require(tab.content.entries.first { $0.name == "item-020.txt" }).path
            let selection = ContentSelection(paths: [first, second], anchorPath: second, leadPath: first)
            tab.content.applySelection(selection)
            return selection
        }

        // T-6250e1a8 B-NAV-043 B-NAV-047: what was selected, the anchor, the lead and the scroll come back with Back.
        @Test func backBringsAFolderBackWithItsSelectionAnchorLeadAndScroll() async throws {
            let (harness, tab, outer, sub) = try await openLong()
            let selection = try twoSelected(tab)
            let position = try scroll(tab)
            tab.go(to: URL(fileURLWithPath: sub))
            #expect(await arrive(tab, sub, harness))
            #expect(tab.content.selection.isEmpty)

            tab.perform(.goBack)
            #expect(await arrive(tab, outer, harness))
            #expect(tab.content.selection.paths == selection.paths)
            #expect(tab.content.selection.anchorPath == selection.anchorPath)
            #expect(tab.content.selection.leadPath == selection.leadPath)
            #expect(tab.content.pane?.scrollPosition.top == position.top)
            await harness.close()
        }

        // T-6250e1a8 B-NAV-059 B-SEL-120: the enclosing folder and any fresh opening start with nothing selected, at the
        // top; Back from there restores the folder left.
        @Test func aFreshOpeningStartsEmptyAtTheTopWhileBackRestores() async throws {
            let (harness, tab, outer, sub) = try await openLong()
            _ = try twoSelected(tab)
            _ = try scroll(tab)
            tab.go(to: URL(fileURLWithPath: sub))
            #expect(await arrive(tab, sub, harness))
            let selection = try twoSelected(tab)
            let position = try scroll(tab)

            tab.perform(.goEnclosingFolder)
            #expect(await arrive(tab, outer, harness))
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.pane?.scrollPosition.top == 0)

            tab.perform(.goBack)
            #expect(await arrive(tab, sub, harness))
            #expect(tab.content.selection.paths == selection.paths)
            #expect(tab.content.pane?.scrollPosition.top == position.top)

            // Back on to the first folder, then the same folder opened afresh: its memory isn't used.
            tab.go(to: URL(fileURLWithPath: outer))
            #expect(await arrive(tab, outer, harness))
            tab.go(to: URL(fileURLWithPath: sub))
            #expect(await arrive(tab, sub, harness))
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.pane?.scrollPosition.top == 0)
            await harness.close()
        }

        // B-NAV-049: Back restores no gap: the folder left had one where its selected item stood, and the first arrow after
        // Back starts from the top, not from there.
        @Test func backCarriesNoGap() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let gamma = try #require(tab.content.entries.first { $0.name == "Gamma" })
            tab.content.select(paths: [gamma.path])
            try FileManager.default.removeItem(atPath: gamma.path)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: [gamma.path]))
            #expect(await waitUntil { tab.content.entries.count == 3 })
            #expect(tab.content.selection.gapIndex == 2)

            let beta = tab.folder.appendingPathComponent("Beta").path
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath != beta && !tab.isNavigating })
            harness.layout(tab)
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.selection.gapIndex == nil)
            tab.content.focusList()
            list.key("ArrowDown")
            #expect(list.selectedNames == ["Alpha"])
            await harness.close()
        }

        // B-NAV-047: an item that went drops out of what Back restores; the anchor and lead fall to one still there.
        @Test func backDropsAnItemThatWentFromTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            tab.content.applySelection(
                ContentSelection(paths: [alpha.path, note.path], anchorPath: alpha.path, leadPath: note.path))
            let beta = tab.folder.appendingPathComponent("Beta").path
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            try FileManager.default.removeItem(atPath: note.path)
            tab.services.directoryService.cache.clear()
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath != beta && !tab.isNavigating })
            #expect(tab.content.selection.paths == [alpha.path])
            #expect(tab.content.selection.leadPath == alpha.path)
            await harness.close()
        }

        // T-bcd1990e: each view goes back to where it was scrolled.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func backPutsEachViewWhereItWasScrolled(view: RendererCommand) async throws {
            let (harness, tab, outer, _) = try await openLong(view)
            let chosen = try twoSelected(tab)
            let position = try scroll(tab, view)
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { tab.folder.path != outer && !tab.isNavigating })
            harness.layout(tab)
            tab.perform(.goBack)
            #expect(await arrive(tab, outer, harness))
            #expect(tab.content.selection.paths == chosen.paths)
            let back = try #require(tab.content.pane?.scrollPosition)
            #expect(back.top == position.top && back.left == position.left)
            await harness.close()
        }

        // T-6c281f26 (the Compact List's is in CompactListTests): an item more on disk leaves the view where it is.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsIcons])
        func staysWhereItWasScrolledWhenReadAgainWithAnItemMore(view: RendererCommand) async throws {
            let (harness, tab, outer, _) = try await openLong(view)
            let position = try scroll(tab, view)
            try "y".write(toFile: outer + "/item-999.txt", atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: outer, changedPaths: [outer + "/item-999.txt"]))
            #expect(await waitUntil { tab.content.entries.count == 302 })
            #expect(tab.content.pane?.scrollPosition.top == position.top)
            await harness.close()
        }

        // B-NAV-113: the listing in front stays and the message goes while the next folder is read; on arrival they change.
        @Test func theFolderInFrontStaysUntilTheNextArrives() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let home = tab.folder.path
            let listed = tab.content.listed.map(\.name)
            let gone = harness.folder.appending("Gone")
            tab.perform(.viewAsDetails)
            let message = "ENOENT: no such file or directory, stat '\(gone.path)'"
            tab.go(to: gone)
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })

            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let beta = tab.folder.appendingPathComponent("Beta").path
            probe.hold(beta)
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { probe.isHolding })
            #expect(tab.isNavigating)
            #expect(!tab.content.container(for: .error(message: message)))
            #expect(tab.shownFolderPath == home)
            #expect(tab.content.folderPath == home)
            #expect(tab.content.listed.map(\.name) == listed)

            probe.letGo()
            #expect(await waitUntil { tab.shownFolderPath == beta })
            #expect(tab.content.listed.map(\.name) == ["Inner"])
            await harness.close()
        }

        // B-NAV-114: from a list with nothing in it "Loading…" shows, and not before 400 ms.
        @Test func loadingShowsAfterItsDelayFromAnEmptyList() async throws {
            let harness = try ExplorerHarness.windowless()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
            let tab = try await harness.open(empty.path)
            #expect(tab.content.listed.isEmpty)
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let beta = tab.folder.deletingLastPathComponent().appendingPathComponent("Beta").path
            probe.hold(beta)
            let started = ContinuousClock.now
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(!tab.content.container(for: .loading))
            #expect(await waitUntil { tab.content.container(for: .loading) })
            #expect(ContinuousClock.now - started >= .milliseconds(400))
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            #expect(!tab.content.container(for: .loading))
            await harness.close()
        }

        // B-NAV-114: from a list with items in it, never.
        @Test func loadingNeverShowsOverAListWithItems() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let beta = tab.folder.appendingPathComponent("Beta").path
            probe.hold(beta)
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { probe.isHolding })
            try await Task.sleep(for: .milliseconds(550))
            #expect(!tab.content.container(for: .loading))
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            await harness.close()
        }

        // B-NAV-132: an order, Folders First, hidden files and Go To the same folder clear the selection; Refresh keeps it.
        @Test(arguments: 0..<4)
        func readingAgainWithoutKeepingClearsTheSelection(change: Int) async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { !tab.isNavigating })
            await settle()
            #expect(tab.content.selection.paths == [note.path])

            switch change {
            case 0: tab.perform(.sortBySize)
            case 1: tab.perform(.toggleFoldersFirst)
            case 2: tab.perform(.toggleHiddenFiles)
            default: tab.go(to: tab.folder)
            }
            #expect(await waitUntil { tab.content.selection.isEmpty })
            await harness.close()
        }
    }

    /// The store the visits go to is the app's global: no other test at the same time.
    @MainActor
    @Suite(.windowlessAlone) struct FolderVisitMatrixTests {
        // B-DLG-068: only going to a folder counts: Back to it and using it there records nothing.
        @Test func backDoesNotCountAsAVisit() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let alpha = tab.folder.appendingPathComponent("Alpha").path
            let beta = tab.folder.appendingPathComponent("Beta").path
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.onFolderUsed?()
            #expect(!store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            // The same use after going there counts, so the line above can tell.
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.onFolderUsed?()
            #expect(store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            await harness.close()
        }
    }
}
