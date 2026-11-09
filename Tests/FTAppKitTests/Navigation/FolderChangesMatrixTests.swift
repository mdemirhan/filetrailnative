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
            let folder = tab.folder.path
            tab.services.directoryService.cache.clear()
            probe.hold(folder)
            tab.cameBack()
            #expect(await waitUntil { probe.isHolding })
            changed(harness, tab, nil)
            // A try has come and gone by now, and kept it.
            try await Task.sleep(for: .milliseconds(300))
            #expect(tab.isNavigating)
            #expect(tab.pendingChange != nil)
            probe.letGo()
            #expect(await waitUntil { !tab.isNavigating })
            // Nothing else asks for this read: only the 250 ms try comes back to it.
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

/// How the changes waiting to be read are merged.
@MainActor
struct PendingChangeTests {
    private typealias Pending = MainWindowController.PendingChange

    // One change that doesn't say what changed makes the read a full one, whatever came before or after.
    @Test func aChangeToAnythingAmongThoseHeldBackReadsEverything() {
        let some = Pending.merging(nil, path: "/x", ["/x/a"])
        #expect(some.changedPaths == ["/x/a"])
        let all = Pending.merging(some, path: "/x", nil)
        #expect(all.changedPaths == nil)
        #expect(Pending.merging(all, path: "/x", ["/x/b"]).changedPaths == nil)
    }

    // Past the most it lists, the read is a full one.
    @Test func tooManyChangedItemsReadEverything() {
        let many = Pending.merging(nil, path: "/x", (0..<600).map { "/x/a\($0)" })
        #expect(many.changedPaths?.count == 600)
        #expect(Pending.merging(many, path: "/x", (0..<600).map { "/x/b\($0)" }).changedPaths == nil)
    }

    // What was held back of the folder left doesn't add to a change of the folder come to.
    @Test func aChangeOfTheNewFolderTakesThePlaceOfOneHeldBackOfTheOld() {
        let old = Pending.merging(nil, path: "/old", ["/old/a"])
        let new = Pending.merging(old, path: "/new", ["/new/b"])
        #expect(new.path == "/new")
        #expect(new.changedPaths == ["/new/b"])
    }
}
