// Search results on screen through the app's real file operations: they change only where a write acted on them, are
// never searched again by it, and say when something was put inside the folder searched that they may not list
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SearchResultsWritesTests {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        private func make(_ window: WritingWindow, _ name: String) throws {
            try "x".write(toFile: path(window, name), atomically: true, encoding: .utf8)
        }

        /// The rows on screen, by their paths under the window's folder.
        private func rows(_ pane: BrowserPane) -> [String] {
            pane.content.entries.map { String($0.path.dropFirst(pane.search.session.rootPath.count + 1)) }.sorted()
        }

        private func row(_ pane: BrowserPane, _ relative: String) throws -> DirectoryEntry {
            let full = pane.search.session.rootPath + "/" + relative
            return try #require(pane.content.entries.first { samePath($0.path, full) })
        }

        /// The banner of `pane`'s results: whether it shows, and Search Again.
        private func banner(_ pane: BrowserPane) -> SearchBannerView { pane.search.header.banner }

        private func tellsMayBeMissing(_ pane: BrowserPane) -> Bool {
            pane.search.session.mayBeMissingItems && !banner(pane).isHidden && !banner(pane).searchAgain.isHidden
                && banner(pane).shownText == SearchBarText.mayBeMissingBanner
        }

        private func tellsNothing(_ pane: BrowserPane) -> Bool {
            !pane.search.session.mayBeMissingItems && banner(pane).isHidden
        }

        /// The results of `pane`, of a stand-in engine that finds `names` (a folder ending with "/") under `root`, the
        /// window's folder by default.
        @discardableResult
        private func searching(
            _ window: WritingWindow, _ pane: BrowserPane? = nil, in root: String? = nil, finding names: [String]
        ) async throws -> FakeSearchEngine {
            let tab = window.tab
            let pane = pane ?? tab.activePane
            if pane !== tab.activePane { tab.activate(pane) }
            let engine = FakeSearchEngine()
            pane.search.session.engine = engine
            engine.finds = { _ in (names, false, false) }
            pane.search.session.submit("no")
            if let root { pane.search.session.changeRoot(root) }
            #expect(
                await waitUntil {
                    pane.search.session.isSearchMode && pane.content.entries.count == names.count
                })
            return engine
        }

        private func twoPanes(_ window: WritingWindow, right name: String) async throws -> BrowserPane {
            let right = window.tab.openSecondPane(at: path(window, name))
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            window.harness.layout(window.tab)
            window.tab.activate(window.tab.panes[0])
            return right
        }

        private func idle(_ window: WritingWindow) async {
            #expect(await waitUntil { !window.tab.isWriteLocked })
            // What a write's end does comes on the main actor after it.
            for _ in 0..<5 { await Task.yield() }
        }

        private func noKeys() -> () -> Void {
            let saved = TabDragDrop.modifiers
            TabDragDrop.modifiers = { [] }
            return { TabDragDrop.modifiers = saved }
        }

        // MARK: Taken away

        // A result moved to the Trash leaves the list; a found folder takes the results inside it along. Nothing is
        // searched again and nothing is told.
        @Test func trashedResultsLeave() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let pane = tab.activePane
            try make(window, "Alpha/inner.txt")
            let engine = try await searching(
                window, finding: ["note.txt", "Alpha/", "Alpha/inner.txt", "Alpha/Inner/", "Beta/"])
            let searches = engine.starts.count
            let actions = try #require(tab.writeActions)

            _ = await actions.trash([path(window, "note.txt"), path(window, "Alpha")])
            #expect(await waitUntil { !window.exists("note.txt") && !window.exists("Alpha") })
            await idle(window)
            #expect(rows(pane) == ["Beta"])
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(pane))
            #expect(tab.searchRootPath != nil)
            pane.search.session.hideResults()
            await window.close()
        }

        // A result moved by Move To into a folder the search doesn't cover leaves the list, and nothing is told.
        @Test func aResultMovedOutLeaves() async throws {
            let window = try await WritingWindow.open()
            let pane = window.tab.activePane
            try make(window, "Alpha/a.txt")
            let engine = try await searching(
                window, in: path(window, "Alpha"), finding: ["a.txt", "Inner/"])
            let searches = engine.starts.count
            let actions = try #require(window.tab.writeActions)

            _ = await actions.moveTo([path(window, "Alpha/a.txt")], destination: path(window, "Gamma"))
            #expect(await waitUntil { window.exists("Gamma/a.txt") })
            await idle(window)
            #expect(rows(pane) == ["Inner"])
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // A result moved to another app (a drag out with a move) leaves the list once it is gone.
        @Test func aResultDraggedAwayToAnotherAppLeaves() async throws {
            let window = try await WritingWindow.open()
            let pane = window.tab.activePane
            let engine = try await searching(window, finding: ["note.txt", "Beta/"])
            let searches = engine.starts.count
            let note = path(window, "note.txt")
            try FileManager.default.removeItem(atPath: note)

            window.tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0])
            #expect(await waitUntil { rows(pane) == ["Beta"] })
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // MARK: Renamed

        // A result renamed keeps its row and its selection under the new name, though the search would no longer find
        // it; a found folder renamed takes the results inside it along. Undo renames it back in place.
        @Test func renamedResultsAreRenamedInPlace() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let pane = tab.activePane
            let engine = try await searching(window, finding: ["note.txt", "Alpha/", "Alpha/Inner/"])
            let searches = engine.starts.count
            let actions = try #require(tab.writeActions)
            tab.content.select(paths: [path(window, "note.txt")])

            _ = await actions.rename(path(window, "note.txt"), to: "zzz.md")
            #expect(await waitUntil { window.exists("zzz.md") })
            await idle(window)
            #expect(rows(pane) == ["Alpha", "Alpha/Inner", "zzz.md"])
            #expect(tab.content.selection.paths == [path(window, "zzz.md")])
            #expect(try row(pane, "zzz.md").fileExtension == "md")

            _ = await actions.rename(path(window, "Alpha"), to: "Omega")
            #expect(await waitUntil { window.exists("Omega/Inner") })
            await idle(window)
            #expect(rows(pane) == ["Omega", "Omega/Inner", "zzz.md"])

            _ = await actions.undo()
            #expect(await waitUntil { window.exists("Alpha/Inner") })
            await idle(window)
            #expect(rows(pane) == ["Alpha", "Alpha/Inner", "zzz.md"])
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // A found folder and results inside it renamed by one Rename of several: the folder's row is renamed, and the
        // result renamed with it and the one only selected with it keep their rows under it; nothing says the list
        // may be missing anything. Undo puts every row back.
        @Test func aFolderAndResultsInsideItRenamedTogetherKeepTheirRows() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let pane = tab.activePane
            try make(window, "Alpha/inner.txt")
            try make(window, "Alpha/other.txt")
            let engine = try await searching(
                window, finding: ["note.txt", "Alpha/", "Alpha/inner.txt", "Alpha/other.txt", "Alpha/Inner/"])
            let searches = engine.starts.count
            let actions = try #require(tab.writeActions)

            _ = await actions.batchRename(
                BatchRenameRequest(items: [
                    .init(sourcePath: path(window, "Alpha"), destinationName: "Omega", isFolder: true),
                    .init(sourcePath: path(window, "Alpha/inner.txt"), destinationName: "renamed.txt", isFolder: false),
                    .init(sourcePath: path(window, "Alpha/other.txt"), destinationName: "other.txt", isFolder: false),
                ]))
            #expect(await waitUntil { window.exists("Omega/renamed.txt") })
            await idle(window)
            #expect(rows(pane) == ["Omega", "Omega/Inner", "Omega/other.txt", "Omega/renamed.txt", "note.txt"])
            #expect(tellsNothing(pane))

            _ = await actions.undo()
            #expect(await waitUntil { window.exists("Alpha/inner.txt") })
            await idle(window)
            #expect(rows(pane) == ["Alpha", "Alpha/Inner", "Alpha/inner.txt", "Alpha/other.txt", "note.txt"])
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // MARK: Put inside

        // A result dragged onto a folder found leaves its row; the list says it may be missing it, and Search Again
        // finds it where it went.
        @Test func aResultDroppedOnAFolderFoundLeavesAndIsTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let pane = tab.activePane
            let restore = noKeys()
            defer { restore() }
            let engine = try await searching(window, finding: ["note.txt", "Alpha/"])
            let searches = engine.starts.count
            let dragged = tab.dragDrop.automationDragStarted([try row(pane, "note.txt")])

            #expect(tab.dragDrop.automationDrop(dragged, entry: try row(pane, "Alpha"), allowed: [.copy, .move]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            await idle(window)
            #expect(rows(pane) == ["Alpha"])
            #expect(engine.starts.count == searches)
            #expect(tellsMayBeMissing(pane))

            engine.finds = { _ in (["Alpha/", "Alpha/note.txt"], false, false) }
            banner(pane).searchAgain.performClick(nil)
            #expect(engine.starts.count == searches + 1)
            #expect(await waitUntil { rows(pane) == ["Alpha", "Alpha/note.txt"] })
            #expect(tellsNothing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // A file from another app dropped on a folder found changes no row, and the list says it may be missing it.
        @Test func aDropFromAnotherAppOnAFolderFoundIsTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let pane = tab.activePane
            let restore = noKeys()
            defer { restore() }
            try make(window, "Gamma/out.txt")
            let engine = try await searching(window, in: path(window, "Alpha"), finding: ["Inner/"])
            let searches = engine.starts.count
            let drag = StubDraggingInfo(paths: [path(window, "Gamma/out.txt")], sequence: 501, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }

            #expect(tab.dragDrop.contentPerformDrop(drag, entry: try row(pane, "Inner")))
            #expect(await waitUntil { window.exists("Alpha/Inner/out.txt") })
            await idle(window)
            #expect(rows(pane) == ["Inner"])
            #expect(engine.starts.count == searches)
            #expect(tellsMayBeMissing(pane))
            pane.search.session.hideResults()
            await window.close()
        }

        // A file dragged from the other pane onto a folder found in this one's results changes no row, and this list
        // says it may be missing it; the other pane, showing a folder, just lets it go.
        @Test func aDropFromTheOtherPaneOnAFolderFoundIsTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.panes[0]
            let right = try await twoPanes(window, right: "Beta")
            let restore = noKeys()
            defer { restore() }
            let engine = try await searching(window, right, in: window.folder.path, finding: ["Alpha/", "Gamma/"])
            let searches = engine.starts.count
            tab.activate(left)
            let dragged = tab.dragDrop.automationDragStarted([
                try #require(left.content.entries.first { $0.name == "note.txt" })
            ])

            tab.dragDrop.paneUnderDrag = right
            #expect(tab.dragDrop.automationDrop(dragged, entry: try row(right, "Alpha"), allowed: [.copy, .move]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            await idle(window)
            #expect(rows(right) == ["Alpha", "Gamma"])
            #expect(engine.starts.count == searches)
            #expect(tellsMayBeMissing(right))
            right.search.session.hideResults()
            await window.close()
        }

        // A result copied to the other pane's folder, inside the folder searched, keeps its row; the list says it may
        // be missing the copy.
        @Test func aResultCopiedInsideTheSearchIsTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.panes[0]
            _ = try await twoPanes(window, right: "Gamma")
            let engine = try await searching(window, left, finding: ["note.txt", "Alpha/"])
            let searches = engine.starts.count

            tab.sendToOtherPane([path(window, "note.txt")], copying: true)
            #expect(await waitUntil { window.exists("Gamma/note.txt") })
            await idle(window)
            #expect(rows(left) == ["Alpha", "note.txt"])
            #expect(engine.starts.count == searches)
            #expect(tellsMayBeMissing(left))
            left.search.session.hideResults()
            await window.close()
        }

        // MARK: Not acting on the results

        // Writes that touch no result and put nothing into a folder found leave the list as it is, though they change
        // the folder searched: a copy into a folder that isn't a result, a file trashed that isn't one.
        @Test func writesThatDontActOnTheResultsLeaveThem() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.panes[0]
            let right = try await twoPanes(window, right: "Gamma")
            try make(window, "Gamma/other.txt")
            let engine = try await searching(window, right, in: window.folder.path, finding: ["Alpha/", "Beta/"])
            let searches = engine.starts.count
            tab.activate(left)
            let actions = try #require(tab.writeActions)

            _ = await actions.copyTo([path(window, "note.txt")], destination: path(window, "Gamma"))
            #expect(await waitUntil { window.exists("Gamma/note.txt") })
            await idle(window)
            _ = await actions.trash([path(window, "Gamma/other.txt")])
            #expect(await waitUntil { !window.exists("Gamma/other.txt") })
            await idle(window)
            _ = await actions.copyTo([path(window, "note.txt")], destination: path(window, "Alpha/Inner"))
            #expect(await waitUntil { window.exists("Alpha/Inner/note.txt") })
            await idle(window)

            #expect(rows(right) == ["Alpha", "Beta"])
            #expect(engine.starts.count == searches)
            #expect(tellsNothing(right))
            right.search.session.hideResults()
            await window.close()
        }

        // MARK: The banner

        // The banner says the results were cut short, that they may be missing something, or both, and offers Search
        // Again only for what may be missing.
        @Test func theBannerSaysWhatItMust() {
            let header = SearchHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
            let scopes = [SearchScopeOption(path: "/demo", label: "demo")]
            func show(truncated: Bool, missing: Bool) {
                header.show(
                    scopes: scopes, rootPath: "/demo", isRunning: false, truncated: truncated,
                    mayBeMissingItems: missing, filterText: "")
                header.layoutSubtreeIfNeeded()
            }
            show(truncated: false, missing: false)
            #expect(header.banner.isHidden)
            let bare = header.height

            show(truncated: true, missing: false)
            #expect(!header.banner.isHidden)
            #expect(header.banner.shownText == SearchBarText.truncatedBanner)
            #expect(header.banner.searchAgain.isHidden)
            #expect(header.height > bare)

            show(truncated: false, missing: true)
            #expect(header.banner.shownText == SearchBarText.mayBeMissingBanner)
            #expect(!header.banner.searchAgain.isHidden)
            #expect(header.banner.searchAgain.frame.maxX <= header.banner.bounds.maxX)
            #expect(header.banner.searchAgain.frame.minY >= 0)
            #expect(header.banner.searchAgain.frame.maxY <= header.banner.bounds.maxY)

            show(truncated: true, missing: true)
            #expect(
                header.banner.shownText == SearchBarText.truncatedBanner + " " + SearchBarText.mayBeMissingBanner)
            #expect(!header.banner.searchAgain.isHidden)

            var pressed = 0
            header.onSearchAgain = { pressed += 1 }
            header.banner.searchAgain.performClick(nil)
            #expect(pressed == 1)

            show(truncated: false, missing: false)
            #expect(header.banner.isHidden)
            #expect(header.height == bare)
        }
    }
}
