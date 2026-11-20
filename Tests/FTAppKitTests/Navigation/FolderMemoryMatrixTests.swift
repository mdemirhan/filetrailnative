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
            _ view: AppCommand = .viewAsDetails
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
            return (harness, tab, tab.folderPath, NodePath.join(tab.folderPath, "Sub"))
        }

        private func arrive(_ tab: MainWindowController, _ path: String, _ harness: ExplorerHarness) async -> Bool {
            let arrived = await waitUntil { tab.shownFolderPath == path && !tab.isNavigating }
            harness.layout(tab)
            return arrived
        }

        private func scroll(_ tab: MainWindowController, _ view: AppCommand = .viewAsDetails) throws
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

        // The enclosing folder and any fresh opening start with nothing selected, at the
        // top; Back from there restores the folder left.
        @Test func aFreshOpeningStartsEmptyAtTheTopWhileBackRestores() async throws {
            let (harness, tab, outer, sub) = try await openLong()
            _ = try twoSelected(tab)
            _ = try scroll(tab)
            tab.go(to: sub)
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
            tab.go(to: outer)
            #expect(await arrive(tab, outer, harness))
            tab.go(to: sub)
            #expect(await arrive(tab, sub, harness))
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.pane?.scrollPosition.top == 0)
            await harness.close()
        }

        // Back restores no gap: the folder left had one where its selected item stood, and the first arrow after
        // Back starts from the top, not from there.
        @Test func backCarriesNoGap() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let gamma = try #require(tab.content.entries.first { $0.name == "Gamma" })
            tab.content.select(paths: [gamma.path])
            try FileManager.default.removeItem(atPath: gamma.path)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folderPath, changedPaths: [gamma.path]))
            #expect(await waitUntil { tab.content.entries.count == 3 })
            #expect(tab.content.selection.gapIndex == 2)

            let beta = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Beta").path
            tab.go(to: beta)
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

        // An item that went drops out of what Back restores; the anchor and lead fall to one still there.
        @Test func backDropsAnItemThatWentFromTheSelection() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" })
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            tab.content.applySelection(
                ContentSelection(paths: [alpha.path, note.path], anchorPath: alpha.path, leadPath: note.path))
            let beta = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Beta").path
            tab.go(to: beta)
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            try FileManager.default.removeItem(atPath: note.path)
            tab.services.directoryService.cache.clear()
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath != beta && !tab.isNavigating })
            #expect(tab.content.selection.paths == [alpha.path])
            #expect(tab.content.selection.leadPath == alpha.path)
            await harness.close()
        }

        // Each view goes back to where it was scrolled, with what was selected,
        // the anchor and the lead.
        @Test(arguments: [AppCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func backPutsEachViewWhereItWasScrolled(view: AppCommand) async throws {
            let (harness, tab, outer, _) = try await openLong(view)
            let chosen = try twoSelected(tab)
            let position = try scroll(tab, view)
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { tab.folderPath != outer && !tab.isNavigating })
            harness.layout(tab)
            tab.perform(.goBack)
            #expect(await arrive(tab, outer, harness))
            #expect(tab.content.selection.paths == chosen.paths)
            #expect(tab.content.selection.anchorPath == chosen.anchorPath)
            #expect(tab.content.selection.leadPath == chosen.leadPath)
            let back = try #require(tab.content.pane?.scrollPosition)
            #expect(back.top == position.top && back.left == position.left)
            await harness.close()
        }

        // (each view's is in LeadStaysInViewTests): an item more on disk, told by the folder watch, leaves a list
        // with nothing selected where it is.
        @Test func staysWhereItWasScrolledWhenReadAgainWithAnItemMore() async throws {
            let (harness, tab, outer, _) = try await openLong()
            let position = try scroll(tab)
            try "y".write(toFile: outer + "/item-999.txt", atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: outer, changedPaths: [outer + "/item-999.txt"]))
            #expect(await waitUntil { tab.content.entries.count == 302 })
            #expect(tab.content.pane?.scrollPosition.top == position.top)
            await harness.close()
        }

        // The listing in front stays and the message goes while the next folder is read; on arrival they change.
        @Test func theFolderInFrontStaysUntilTheNextArrives() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let home = tab.folderPath
            let listed = tab.content.listed.map(\.name)
            let gone = harness.folder.appending("Gone")
            tab.perform(.viewAsDetails)
            let message = "ENOENT: no such file or directory, stat '\(gone.path)'"
            tab.go(to: gone.path)
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })

            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let beta = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Beta").path
            probe.hold(beta)
            tab.go(to: beta)
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

        // From a list with nothing in it "Loading…" shows, and not before 400 ms.
        @Test func loadingShowsAfterItsDelayFromAnEmptyList() async throws {
            let harness = try ExplorerHarness.windowless()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
            let tab = try await harness.open(empty.path)
            #expect(tab.content.listed.isEmpty)
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let beta = NodePath.join(NodePath.dirname(tab.folderPath), "Beta")
            probe.hold(beta)
            let started = ContinuousClock.now
            tab.go(to: beta)
            #expect(!tab.content.container(for: .loading))
            #expect(await waitUntil { tab.content.container(for: .loading) })
            #expect(ContinuousClock.now - started >= .milliseconds(400))
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            #expect(!tab.content.container(for: .loading))
            await harness.close()
        }

        // From a list with items in it, never.
        @Test func loadingNeverShowsOverAListWithItems() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            let timers = ManualTimers()
            tab.content.timers = timers
            let beta = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Beta").path
            probe.hold(beta)
            tab.go(to: beta)
            #expect(await waitUntil { probe.isHolding })
            // Past the 400 ms a Loading… would wait for.
            timers.advance(ContentStateText.loadingDelayMilliseconds / 1000 + 0.05)
            #expect(!tab.content.container(for: .loading))
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            await harness.close()
        }

        // Another order (Folders First goes the same way, `viewChanged`) and Go To the same folder clear the
        // selection; Refresh and Hidden Files keep it.
        @Test(arguments: [false, true])
        func readingAgainWithoutKeepingClearsTheSelection(goToTheSameFolder: Bool) async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            try "x".write(toFile: tab.folderPath + "/.hidden", atomically: true, encoding: .utf8)
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { !tab.isNavigating })
            await settle()
            #expect(tab.content.selection.paths == [note.path])
            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == ".hidden" } && !tab.isNavigating })
            await settle()
            #expect(tab.content.selection.paths == [note.path])

            if goToTheSameFolder { tab.go(to: tab.folderPath) } else { tab.setSort(.name, .desc) }
            #expect(await waitUntil { tab.content.selection.isEmpty })
            await settle()
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }
    }

    /// The store the visits go to is the app's global: no other test at the same time.
    @MainActor
    @Suite struct FolderVisitMatrixTests {
        // Only going to a folder counts: Back to it and using it there records nothing.
        @Test func backDoesNotCountAsAVisit() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let alpha = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Alpha").path
            let beta = URL(fileURLWithPath: tab.folderPath).appendingPathComponent("Beta").path
            tab.go(to: alpha)
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.go(to: beta)
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.onFolderUsed?()
            #expect(!store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            // The same use after going there counts, so the line above can tell.
            tab.go(to: beta)
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            tab.go(to: alpha)
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            tab.onFolderUsed?()
            #expect(store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            await harness.close()
        }
    }
}
