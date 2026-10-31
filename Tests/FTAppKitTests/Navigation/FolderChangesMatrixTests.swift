// Port of the held and repeated reads of apps/desktop/src/renderer/hooks/useFolderWatch.test.ts and
// App.folderWatch.test.tsx, App.folderOrder.test.tsx: changes reach the tab as the folder watch sends them, through
// ExplorerWindows.folderChanged
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

        // T-bfbc3d06: changes held are gathered, then read once.
        @Test func gathersChangesWhileHeldAndReadsThemOnceWhenLetGo() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            tab.folderChangesHeld = true
            changed(harness, tab, ["\(folder)/a"])
            changed(harness, tab, ["\(folder)/b"])
            #expect(tab.pendingChange?.changedPaths == ["\(folder)/a", "\(folder)/b"])
            try await Task.sleep(for: .milliseconds(100))
            #expect(probe.reads(of: folder) == 0)

            tab.folderChangesHeld = false
            #expect(await waitUntil { probe.reads(of: folder) == 1 })
            #expect(tab.pendingChange == nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(probe.reads(of: folder) == 1)
            await harness.close()
        }

        // T-277f84be: one change that doesn't say what changed makes the read a full one, whatever came before or after.
        @Test func aChangeToAnythingAmongThoseHeldBackReadsEverything() async throws {
            let (harness, tab, _) = try await opened()
            tab.folderChangesHeld = true
            changed(harness, tab, ["/x/a"])
            changed(harness, tab, nil)
            #expect(tab.pendingChange != nil && tab.pendingChange?.changedPaths == nil)
            changed(harness, tab, ["/x/b"])
            #expect(tab.pendingChange != nil && tab.pendingChange?.changedPaths == nil)
            await harness.close()
        }

        // T-73c88821: past the most it lists, the read is a full one.
        @Test func tooManyChangedItemsReadEverything() async throws {
            let (harness, tab, _) = try await opened()
            tab.folderChangesHeld = true
            changed(harness, tab, (0..<600).map { "/x/a\($0)" })
            #expect(tab.pendingChange?.changedPaths?.count == 600)
            changed(harness, tab, (0..<600).map { "/x/b\($0)" })
            #expect(tab.pendingChange != nil && tab.pendingChange?.changedPaths == nil)
            await harness.close()
        }

        // T-efb24fb9: what arrives during a read is read once more after it, however many came.
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
            try await Task.sleep(for: .milliseconds(150))
            #expect(probe.reads(of: folder) == 2)
            await harness.close()
        }

        // B-VIEW-189: a change while the folder on screen is being read again waits for that (250 ms at a time), then is
        // read: that read may have started before the change.
        @Test func aChangeWhileTheFolderIsBeingReadAgainIsAskedForAgain() async throws {
            let (harness, tab, probe) = try await opened()
            let folder = tab.folder.path
            tab.services.directoryService.cache.clear()
            probe.hold(folder)
            tab.cameBack()
            #expect(await waitUntil { probe.isHolding })
            changed(harness, tab, nil)
            // A try has come and gone by now, and kept it.
            try await Task.sleep(for: .milliseconds(350))
            #expect(tab.isNavigating)
            #expect(tab.pendingChange != nil)
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            // Nothing else asks for this read: only the 250 ms try comes back to it.
            #expect(await waitUntil { tab.pendingChange == nil })
            await harness.close()
        }

        /// Opens Beta, with something done while it is being opened, and says what that came to once a retry would have
        /// been and gone: how many times each folder was read (the tree reads them too), and whether Beta was read again
        /// after it arrived, seen by an item the watch isn't told of and a listing no longer kept.
        private func openingBeta(
            during: (ExplorerHarness, MainWindowController) -> Void,
            afterArrival: (URL, MainWindowController) throws -> Void
        ) async throws -> (left: Int, opened: Int, late: Bool) {
            let (harness, tab, probe) = try await opened()
            let home = tab.folder.path
            let beta = harness.folder.appending("Beta")
            probe.hold(beta.path)
            tab.go(to: beta)
            #expect(await waitUntil { probe.isHolding })
            during(harness, tab)
            #expect(tab.pendingChange == nil)
            probe.letGo()
            #expect(await waitUntil { tab.shownFolderPath == beta.path && !tab.isNavigating })
            try afterArrival(beta, tab)
            try await Task.sleep(for: .milliseconds(400))
            let result = (
                left: probe.reads(of: home), opened: probe.reads(of: beta.path),
                late: tab.content.listed.contains { $0.name == "Late.txt" }
            )
            await harness.close()
            return result
        }

        private func noMoreReads(during: (ExplorerHarness, MainWindowController) -> Void) async throws {
            let clearing: (ExplorerHarness, MainWindowController) -> Void = { _, tab in
                tab.services.directoryService.cache.clear()
            }
            let baseline = try await openingBeta(during: clearing) { _, _ in }
            let counted = try await openingBeta(during: during) { _, _ in }
            #expect(counted.left == baseline.left)
            #expect(counted.opened == baseline.opened)
            let shown = try await openingBeta(during: during) { beta, tab in
                try "x".write(to: beta.appending(path: "Late.txt"), atomically: true, encoding: .utf8)
                tab.services.directoryService.cache.clear()
            }
            #expect(!shown.late)
        }

        // B-VIEW-195: a change to the folder being left isn't kept, and isn't read into the one that opens.
        @Test func aChangeToTheFolderBeingLeftIsDropped() async throws {
            try await noMoreReads { harness, tab in changed(harness, tab, nil) }
        }

        // B-VIEW-195: a change held back while the folder was left is forgotten when it is let go of.
        @Test func aChangeHeldBackWhileTheFolderWasLeftIsForgotten() async throws {
            let (harness, tab, _) = try await opened()
            let beta = harness.folder.appending("Beta")
            tab.folderChangesHeld = true
            changed(harness, tab, nil)
            tab.go(to: beta)
            #expect(await waitUntil { tab.shownFolderPath == beta.path && !tab.isNavigating })
            try "x".write(to: beta.appending(path: "Late.txt"), atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.clear()
            tab.folderChangesHeld = false
            #expect(tab.pendingChange == nil)
            try await Task.sleep(for: .milliseconds(150))
            #expect(tab.content.listed.map(\.name) == ["Inner"])
            await harness.close()
        }

        // B-VIEW-195: what was held back of the folder left doesn't add to a change of the folder come to.
        @Test func aChangeOfTheNewFolderTakesThePlaceOfOneHeldBackOfTheOld() async throws {
            let (harness, tab, _) = try await opened()
            let beta = harness.folder.appending("Beta").path
            tab.folderChangesHeld = true
            changed(harness, tab, ["\(tab.folder.path)/a"])
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            changed(harness, tab, ["\(beta)/b"])
            #expect(tab.pendingChange?.changedPaths == ["\(beta)/b"])
            tab.folderChangesHeld = false
            await harness.close()
        }

        // B-VIEW-195: a change told of a folder that is no longer the one on screen is not taken in.
        @Test func aChangeToAFolderNoLongerOnScreenIsLeftOut() async throws {
            let (harness, tab, _) = try await opened()
            tab.folderChangesHeld = true
            harness.windows.folderChanged(
                windowID: tab.windowID,
                FolderChange(path: harness.folder.appending("Beta").path, changedPaths: nil))
            #expect(tab.pendingChange == nil)
            await harness.close()
        }

        // B-VIEW-189: a read that throws doesn't stop the next.
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

        // B-VIEW-195: a quiet read finishing after the user went elsewhere leaves the user's folder on screen.
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
            try await Task.sleep(for: .milliseconds(150))
            #expect(tab.shownFolderPath == beta)
            #expect(tab.content.folderPath == beta)
            #expect(tab.content.listed.map(\.name) == ["Inner"])
            await harness.close()
        }

        // T-3de1e419: Refresh while a folder is being opened doesn't take its place.
        @Test func refreshDoesNotTakeThePlaceOfAFolderBeingOpened() async throws {
            let (harness, tab, probe) = try await opened()
            let home = tab.folder.path
            let beta = harness.folder.appending("Beta").path
            probe.hold(beta)
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { probe.isHolding })
            tab.refresh()
            #expect(tab.pendingChange == nil)
            try await Task.sleep(for: .milliseconds(50))
            #expect(tab.shownFolderPath == home)
            probe.letGo()
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            try await Task.sleep(for: .milliseconds(350))
            #expect(tab.shownFolderPath == beta)
            #expect(tab.content.listed.map(\.name) == ["Inner"])
            await harness.close()
        }

        // T-3de1e419: it ends there, after letting go of the caches: neither the folder left nor the one opening is read
        // for it.
        @Test func refreshWhileAnotherFolderIsOpeningReadsNothingMore() async throws {
            try await noMoreReads { _, tab in tab.refresh() }
        }

        // T-e2e495bf B-SEL-139: a name being typed holds the change, and its end shows it.
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
            try await Task.sleep(for: .milliseconds(100))
            #expect(probe.reads(of: folder) == 0)
            #expect(tab.content.inlineRename?.path == note.path)
            #expect(!tab.content.listed.contains { $0.path == made })

            tab.content.renameCancelled()
            #expect(await waitUntil { tab.content.listed.contains { $0.path == made } })
            #expect(tab.pendingChange == nil)
            await harness.close()
        }

        // T-da1ee7fd: a file that grows shows its new size, though the folder lists the same items.
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
