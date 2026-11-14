// A pinned filter while the folder changes under it: a file pasted or renamed out of what it shows, the folder read
// again, and search results brought back where they were scrolled
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor @Suite struct PinnedFilterWritesTests {
        private static let unpinnedToast = "The filter “no” is no longer pinned, to show an item it hid"

        /// A tab on the harness's folder with the app's file operations, "no" pinned: note.txt and the folders show.
        private func pinned() async throws -> (ExplorerHarness, MainWindowController, AppWriteOperations) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) },
                log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            for letter in "no" { tab.content.applyFilterKey(.type(String(letter))) }
            tab.perform(.togglePinFilter)
            #expect(tab.content.pinnedFilter == PinnedListFilter(query: "no", mode: .fuzzy))
            #expect(shownFiles(tab) == ["note.txt"])
            return (harness, tab, operations)
        }

        private func shownFiles(_ tab: MainWindowController) -> [String] {
            tab.content.entries.filter { !$0.isDirectoryLike }.map(\.name)
        }

        private func toasts(_ tab: MainWindowController) -> [String] {
            tab.notifications?.toasts.entries.map(\.title) ?? []
        }

        // The file Paste as File makes is named in its row; one the pin would hide lets the pin go, and says so.
        @Test func pasteAsFileOfANameThePinHidesUnpinsAndOpensTheNameInItsRow() async throws {
            let (harness, tab, operations) = try await pinned()
            harness.pasteboard.clearContents()
            harness.pasteboard.setString("milk\neggs", forType: .string)

            tab.perform(.pasteAsFile)
            #expect(await waitUntil { tab.content.inlineRename != nil })

            let made = tab.folder.path + "/Pasted Text.txt"
            #expect(tab.content.inlineRename?.path == made)
            #expect(try String(contentsOfFile: made, encoding: .utf8) == "milk\neggs")
            #expect(tab.content.pinnedFilter == nil)
            #expect(tab.content.filter.isEmpty)
            #expect(!tab.menuState.filterPinned)
            #expect(!tab.content.container.filterPill.isShowingFilter)
            #expect(toasts(tab).contains(Self.unpinnedToast))
            #expect(shownFiles(tab).contains("Pasted Text.txt"))
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // An item renamed to a name the pin doesn't match is selected where it is now: the pin goes, with its toast.
        @Test func renamingAnItemToANameThePinHidesUnpins() async throws {
            let (harness, tab, operations) = try await pinned()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            tab.renameSelected()
            #expect(tab.content.inlineRename?.path == note)
            #expect(tab.content.pinnedFilter != nil)
            #expect(toasts(tab).isEmpty)

            tab.content.renameSubmitted("zebra.txt")
            #expect(await waitUntil { tab.content.selection.leadPath?.hasSuffix("/zebra.txt") == true })
            #expect(tab.content.pinnedFilter == nil)
            #expect(shownFiles(tab).contains("zebra.txt"))
            #expect(toasts(tab).contains(Self.unpinnedToast))
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // A name the pin still matches leaves it pinned.
        @Test func renamingAnItemToANameThePinMatchesKeepsThePin() async throws {
            let (harness, tab, operations) = try await pinned()
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }?.path)
            tab.content.select(paths: [note])
            tab.renameSelected()
            tab.content.renameSubmitted("another note.txt")
            #expect(await waitUntil { tab.content.selection.leadPath?.hasSuffix("/another note.txt") == true })
            #expect(tab.content.pinnedFilter?.query == "no")
            #expect(shownFiles(tab) == ["another note.txt"])
            #expect(toasts(tab).isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // Renaming an item the pin hides (from the tree, a search, Info) shows it first: the name opens in its row.
        @Test func startingARenameOfAnItemThePinHidesUnpinsAndOpensTheName() async throws {
            let (harness, tab, operations) = try await pinned()
            let hidden = tab.folder.path + "/zebra.txt"
            try "x".write(toFile: hidden, atomically: true, encoding: .utf8)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID, FolderChange(path: tab.folder.path, changedPaths: [hidden]))
            #expect(await waitUntil { tab.content.listedEntry(at: hidden) != nil })
            #expect(tab.content.position(of: hidden) == nil)
            #expect(tab.content.beginRename(path: hidden))
            #expect(tab.content.inlineRename?.path == hidden)
            #expect(tab.content.position(of: hidden) != nil)
            #expect(tab.content.pinnedFilter == nil)
            #expect(toasts(tab) == [Self.unpinnedToast])
            tab.content.renameCancelled()
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // The folder watch reads the folder again: the pin holds, and what arrived is shown or not as the pin says.
        @Test func aFolderReadAgainWhilePinnedKeepsThePinAndShowsOnlyWhatItMatches() async throws {
            let (harness, tab, operations) = try await pinned()
            let folder = tab.folder.path
            let listedBefore = tab.content.listed.count
            try "x".write(toFile: folder + "/nomad.txt", atomically: true, encoding: .utf8)
            try "x".write(toFile: folder + "/zebra.txt", atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(atPath: folder + "/Zoo", withIntermediateDirectories: false)
            tab.services.directoryService.cache.clear()
            harness.windows.folderChanged(
                windowID: tab.windowID,
                FolderChange(
                    path: folder, changedPaths: [folder + "/nomad.txt", folder + "/zebra.txt", folder + "/Zoo"]))

            #expect(await waitUntil { tab.content.listed.count == listedBefore + 3 })
            #expect(tab.content.pinnedFilter == PinnedListFilter(query: "no", mode: .fuzzy))
            #expect(shownFiles(tab) == ["nomad.txt", "note.txt"])
            // Folders show whatever their names.
            #expect(tab.content.entries.contains { $0.name == "Zoo" })
            #expect(tab.content.container.filterPill.isPinned)
            tab.content.applySelection(.empty)
            let status = tab.content.contentShell.pathBarRow.status.stringValue
            #expect(status.hasPrefix("\(tab.content.entries.count) of \(listedBefore + 3) items"))
            #expect(toasts(tab).isEmpty)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // Search results put away and brought back are scrolled where they were, also when the selected result was
        // out of view: selecting it again doesn't pull the list to it.
        @Test func resultsComeBackScrolledWhereTheyWereWithTheSelectedResultOutOfView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in ((0..<200).map { String(format: "file-%03d.txt", $0) }, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "file"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            let content = tab.content
            #expect(await waitUntil { content.entries.count == 200 })
            harness.layout(tab)

            // The first result selected, the list scrolled to its foot: the selected one is far out of view.
            let first = try #require(content.entries.first)
            content.applySelection(.single(first.path))
            content.pane?.scrollPosition = (top: 100_000, left: 0)
            harness.layout(tab)
            let scrolled = try #require(content.pane?.scrollPosition.top)
            #expect(scrolled > 1_000)

            tab.search.session.hideResults()
            #expect(tab.searchRootPath == nil)
            tab.perform(.showLastSearchResults)
            harness.layout(tab)
            #expect(content.entries.count == 200)
            #expect(content.selection.paths == [first.path])
            #expect(content.pane?.scrollPosition.top == scrolled)
            // A layout afterwards leaves it there too.
            harness.layout(tab)
            #expect(content.pane?.scrollPosition.top == scrolled)
            await harness.close()
        }
    }
}
