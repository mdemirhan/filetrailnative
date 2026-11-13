// Changes reach the tab as the folder watch sends them, through ExplorerWindows.folderChanged
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FolderChangesMatrixTests {
        private func opened() async throws -> (ExplorerHarness, MainWindowController, FolderReadProbe) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let probe = FolderReadProbe()
            harness.reading(through: probe, in: tab)
            return (harness, tab, probe)
        }

        /// What the folder watch does on a change: the listing kept of it goes, and the window hears.
        private func changed(_ harness: ExplorerHarness, _ tab: MainWindowController, _ paths: [String]?) {
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: paths))
        }

        private func write(_ name: String, in tab: MainWindowController) throws -> String {
            let path = tab.folder.appendingPathComponent(name).path
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }

        // A tab that let go of its folder (its disk ejected, say) no longer has it watched: nothing it shows can change.
        @Test func aTabThatLetGoOfItsFolderNoLongerWatchesIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let watches = FolderWatches(
                FolderWatches.Dependencies(
                    watchFolder: { _, _, _ in {} }, readModifiedTime: { _ in nil }, onFolderChanged: { _, _ in },
                    forgetCachedListings: { _, _ in }))
            harness.windows.folderWatches = watches
            let tab = try await harness.open()
            harness.windows.tabNavigated(tab)
            #expect(watches.watchedPaths[tab.windowID] != nil)
            tab.sidebarController.model.clearSelection()
            #expect(tab.shownFolderPath.isEmpty)
            #expect(watches.watchedPaths[tab.windowID] == nil)
            await harness.close()
        }

        // Changes held are gathered, then read once.
        @Test func gathersChangesWhileHeldAndReadsThemOnceWhenLetGo() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            tab.holdFolderChanges(.dialog, true)
            changed(harness, tab, ["\(folder)/a"])
            changed(harness, tab, ["\(folder)/b"])
            #expect(tab.pendingChange?.changedPaths == ["\(folder)/a", "\(folder)/b"])
            await settle()
            #expect(probe.reads(of: folder) == 0)

            tab.holdFolderChanges(.dialog, false)
            #expect(await waitUntil { probe.reads(of: folder) == 1 })
            #expect(tab.pendingChange == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(probe.reads(of: folder) == 1)
            await harness.close()
        }

        // What arrives during a read is read once more after it, however many came.
        @Test func changesArrivingDuringAReadAreReadOnceMore() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            probe.hold(folder)
            changed(harness, tab, ["\(folder)/a"])
            #expect(await waitUntil { probe.isHolding })
            changed(harness, tab, ["\(folder)/b"])
            changed(harness, tab, ["\(folder)/c"])
            probe.letGo()
            #expect(await waitUntil { probe.reads(of: folder) == 2 })
            #expect(await waitUntil { tab.pendingChange == nil })
            try await Task.sleep(for: .milliseconds(50))
            #expect(probe.reads(of: folder) == 2)
            await harness.close()
        }

        // A change while the folder on screen is being read again waits for that (250 ms at a time), then is
        // read: that read may have started before the change.
        @Test func aChangeWhileTheFolderIsBeingReadAgainIsAskedForAgain() async throws {
            let (harness, tab, probe) = try await opened()
            let timers = ManualTimers()
            tab.timers = timers
            let folder = tab.folder.path
            tab.services.directoryService.cache.clear()
            probe.hold(folder)
            tab.cameBack()
            #expect(await waitUntil { probe.isHolding })
            changed(harness, tab, nil)
            // A try comes and goes, and keeps it for the next.
            #expect(timers.pending == 1)
            timers.advance(MainWindowController.retryDelay)
            await settle()
            #expect(tab.isNavigating)
            #expect(tab.pendingChange != nil)
            #expect(timers.pending == 1)
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            // Nothing else asks for this read: only the 250 ms try comes back to it.
            #expect(tab.pendingChange != nil)
            timers.advance(MainWindowController.retryDelay)
            #expect(await waitUntil { tab.pendingChange == nil })
            await harness.close()
        }

        // A read that throws doesn't stop the next.
        @Test func aQuietReadThatFailsDoesNotStopTheNext() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            probe.refuse(folder)
            changed(harness, tab, nil)
            #expect(await waitUntil { tab.content.listed.isEmpty })
            probe.refuse(nil)
            let made = try write("After.txt", in: tab)
            changed(harness, tab, [made])
            #expect(await waitUntil { tab.content.listed.contains { $0.path == made } })
            await harness.close()
        }

        // A quiet read finishing after the user went elsewhere leaves the user's folder on screen.
        @Test func aQuietReadEndingAfterTheUserLeftStaysOutOfTheNewFolder() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            let beta = harness.folder.appending("Beta").path
            probe.hold(folder)
            changed(harness, tab, nil)
            #expect(await waitUntil { probe.isHolding })
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            probe.letGo()
            // The tree reads it too.
            #expect(await waitUntil { probe.reads(of: folder) >= 1 })
            try await Task.sleep(for: .milliseconds(50))
            #expect(tab.shownFolderPath == beta)
            #expect(tab.content.folderPath == beta)
            #expect(tab.content.listed.map(\.name) == ["Inner"])
            await harness.close()
        }

        // A name being typed holds the change, and its end shows it.
        @Test func waitsWhileARenameIsTypedAndShowsTheChangeWhenItEnds() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            tab.renameSelected()
            #expect(tab.content.inlineRename?.path == note.path)
            let made = try write("Made Outside.txt", in: tab)

            changed(harness, tab, [made])
            #expect(tab.pendingChange?.changedPaths == [made])
            await settle()
            #expect(probe.reads(of: folder) == 0)
            #expect(tab.content.inlineRename?.path == note.path)
            #expect(!tab.content.listed.contains { $0.path == made })

            tab.content.renameCancelled()
            #expect(await waitUntil { tab.content.listed.contains { $0.path == made } })
            #expect(tab.pendingChange == nil)
            await harness.close()
        }

        // A file that grows shows its new size, though the folder lists the same items.
        @Test func aFileThatGrowsShowsItsNewSize() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let note = try #require(tab.content.listed.first { $0.name == "note.txt" })
            tab.content.select(paths: [note.path])
            let status = tab.content.contentShell.pathBarRow.status
            let before = try #require(StatusSummary.sizeText(.ready(sizeBytes: 1)))
            #expect(await waitUntil { status.stringValue.hasSuffix(before) })

            try String(repeating: "x", count: 5000).write(toFile: note.path, atomically: true, encoding: .utf8)
            changed(harness, tab, [note.path])
            let after = try #require(StatusSummary.sizeText(.ready(sizeBytes: 5000)))
            #expect(await waitUntil { status.stringValue.hasSuffix(after) })
            #expect(tab.content.selection.paths == [note.path])
            await harness.close()
        }
    }
}
