// Drags from one pane of a tab to the other, through the drop seams the capture uses, with the app's real file
// operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing
import os

@testable import FTAppKit

/// The disks of a test's drop, held from answering until it lets them.
private final class HeldDisks: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (released: false, asked: 0))
    /// The id each path's disk gives once let go.
    private let id: @Sendable (String) -> Int64?

    init(id: @escaping @Sendable (String) -> Int64? = { _ in 1 }) { self.id = id }

    var asked: Int { state.withLock { $0.asked } }

    func release() { state.withLock { $0.released = true } }

    /// What the drop asks the disks: it waits, off the main thread, until the test lets them answer.
    func read(_ paths: [String]) -> [Int64?] {
        state.withLock { $0.asked += 1 }
        while !state.withLock({ $0.released }) { usleep(5_000) }
        return paths.map(id)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct DragBetweenPanesTests {
        private func url(_ window: WritingWindow, _ name: String) -> URL {
            window.folder.appendingPathComponent(name)
        }

        /// The window's tab with a second pane on `name`, read, and the first pane active.
        private func twoPanes(_ window: WritingWindow, right name: String) async throws -> BrowserPane {
            let right = window.tab.openSecondPane(at: url(window, name).path)
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            window.harness.layout(window.tab)
            return right
        }

        private func entry(_ pane: BrowserPane, _ name: String) throws -> DirectoryEntry {
            try #require(pane.content.entries.first { $0.name == name })
        }

        // The other pane's list takes the drag on its background: the item moves into the folder it shows.
        @Test func theOtherPanesBackgroundTakesTheDragIntoItsFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let right = try await twoPanes(window, right: "Beta")
            let drags = tab.dragDrop
            let dragged = drags.automationDragStarted([try entry(left, "note.txt")])

            drags.paneUnderDrag = right
            #expect(drags.automationDrop(dragged, entry: nil, allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("Beta/note.txt") && !window.exists("note.txt") })
            // Both panes show the move at once, without waiting for a folder watch; what arrived is selected.
            let moved = url(window, "Beta/note.txt").path
            #expect(await waitUntil { right.content.selection.paths.contains { samePath($0, moved) } })
            #expect(await waitUntil { !left.content.listed.contains { $0.name == "note.txt" } })
            await window.close()
        }

        // A folder row in the other pane takes the drag into that folder.
        @Test func aFolderInTheOtherPaneTakesTheDrag() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let right = try await twoPanes(window, right: "Beta")
            let drags = tab.dragDrop
            let dragged = drags.automationDragStarted([try entry(left, "note.txt")])

            drags.paneUnderDrag = right
            #expect(drags.automationDrop(dragged, entry: try entry(right, "Inner"), allowed: [.copy, .move]))
            #expect(await waitUntil { window.exists("Beta/Inner/note.txt") })
            await window.close()
        }

        // The list the drag came from still takes it only on its folders, and a pane on the same folder refuses a move.
        @Test func theSourceListAndAPaneOnTheSameFolderRefuseTheBackgroundDrop() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let drags = tab.dragDrop
            let right = tab.openSecondPane()
            #expect(await waitUntil { right.loaded && right.hasShownFolder && !right.isNavigating })
            let dragged = drags.automationDragStarted([try entry(left, "note.txt")])

            drags.paneUnderDrag = left
            #expect(!drags.automationDrop(dragged, entry: nil, allowed: [.copy, .move]))
            _ = drags.automationDragStarted([try entry(left, "note.txt")])
            drags.paneUnderDrag = right
            #expect(!drags.automationDrop(dragged, entry: nil, allowed: [.move]))
            #expect(window.exists("note.txt"))
            await window.close()
        }

        /// The disks answer only when the test lets them, until `restore`.
        private func holdDisks(id: @escaping @Sendable (String) -> Int64? = { _ in 1 }) -> (
            disks: HeldDisks, restore: () -> Void
        ) {
            let disks = HeldDisks(id: id)
            let saved = TabDragDrop.readDiskIds
            let savedWait = TabDragDrop.diskAnswerWaitMs
            TabDragDrop.readDiskIds = { disks.read($0) }
            // The drop waits for them as long as the test holds them, however busy the Mac is.
            TabDragDrop.diskAnswerWaitMs = 60_000
            return (
                disks,
                {
                    disks.release()
                    TabDragDrop.readDiskIds = saved
                    TabDragDrop.diskAnswerWaitMs = savedWait
                }
            )
        }

        /// A drag of search results from the tab's active pane.
        private func searchDrag(_ tab: MainWindowController, _ path: String) -> DragSession {
            let session = DragSession(
                sourceSurface: .search, sourceItems: [DragItem(path: path, kind: .file)], leadPath: path,
                leadKind: .file)
            TabDragDrop.ownDrag = TabDragDrop.OwnDrag(
                session: session, windowNumber: tab.window?.windowNumber ?? 0, tab: tab, pane: tab.activePane)
            return session
        }

        // A search result dropped on the other pane's background with no key held, before the disks have answered,
        // waits for them and then moves into the folder that pane shows.
        @Test func aSearchResultDroppedBeforeTheDisksAnswerMovesIntoTheOtherPanesFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let right = try await twoPanes(window, right: "Gamma")
            let (disks, restore) = holdDisks()
            defer {
                restore()
                TabDragDrop.ownDrag = nil
            }
            let session = searchDrag(tab, url(window, "note.txt").path)
            let drags = tab.dragDrop
            drags.paneUnderDrag = right
            let target = try #require(drags.contentTarget(session, entry: nil))
            #expect(target.isAnotherList)

            #expect(drags.drop(session: session, target: target, offersMove: true, modifiers: [], sequence: 41))
            #expect(await waitUntil { disks.asked > 0 })
            #expect(window.exists("note.txt") && !window.exists("Gamma/note.txt"))
            disks.release()
            #expect(await waitUntil { window.exists("Gamma/note.txt") && !window.exists("note.txt") })
            #expect(window.recorder.shown.isEmpty)
            await window.close()
        }

        // Dropped on a folder of the other pane while the disks haven't answered, items of another disk are copied.
        @Test func aDropOnTheOtherPaneBeforeTheDisksAnswerCopiesFromAnotherDisk() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let right = try await twoPanes(window, right: "Beta")
            let inner = url(window, "Beta/Inner").path
            let (disks, restore) = holdDisks { samePath($0, inner) ? 2 : 1 }
            defer { restore() }
            let drags = tab.dragDrop
            let dragged = drags.automationDragStarted([try entry(left, "note.txt")])

            drags.paneUnderDrag = right
            #expect(drags.automationDrop(dragged, entry: try entry(right, "Inner"), allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { disks.asked > 0 })
            #expect(!window.exists("Beta/Inner/note.txt"))
            disks.release()
            #expect(await waitUntil { window.exists("Beta/Inner/note.txt") })
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // Both panes searched and found the same file, and the right one's results were put away since. A move of
        // that file out of the left pane's results finds those again; the right pane's search stays put away.
        @Test func aMoveOutOfOnePanesResultsLeavesTheOtherPanesSearchPutAway() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let right = try await twoPanes(window, right: "Gamma")
            let folder = window.folder.path
            var engines: [FakeSearchEngine] = []
            for pane in [right, left] {
                tab.activate(pane)
                let engine = FakeSearchEngine()
                engine.finds = { _ in (["note.txt"], false, false) }
                pane.search.session.engine = engine
                pane.search.session.submit("note")
                pane.search.session.changeRoot(folder)
                #expect(
                    await waitUntil {
                        pane.search.session.results.contains { samePath($0.path, folder + "/note.txt") }
                    })
                engines.append(engine)
                if pane === right { pane.search.session.hideResults() }
            }
            #expect(!right.search.session.isSearchMode)
            #expect(left.search.session.isSearchMode)
            let searches = engines.map(\.starts.count)

            tab.sendToOtherPane([folder + "/note.txt"], copying: false)
            #expect(await waitUntil { window.exists("Gamma/note.txt") && !window.exists("note.txt") })
            #expect(await waitUntil { engines[1].starts.count == searches[1] + 1 })
            for _ in 0..<5 { await Task.yield() }
            #expect(engines[0].starts.count == searches[0])
            #expect(!right.search.session.isSearchMode)
            left.search.session.hideResults()
            await window.close()
        }

        // A search result dragged to the other pane's folder goes there.
        @Test func aSearchResultDraggedToTheOtherPaneGoesIntoItsFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let right = try await twoPanes(window, right: "Gamma")
            let session = DragSession(
                sourceSurface: .search, sourceItems: [DragItem(path: url(window, "note.txt").path, kind: .file)],
                leadPath: url(window, "note.txt").path, leadKind: .file)
            TabDragDrop.ownDrag = TabDragDrop.OwnDrag(
                session: session, windowNumber: tab.window?.windowNumber ?? 0, tab: tab, pane: tab.activePane)
            defer { TabDragDrop.ownDrag = nil }

            tab.dragDrop.paneUnderDrag = right
            let target = try #require(tab.dragDrop.contentTarget(session, entry: nil))
            #expect(target.isAnotherList)
            let decision = tab.dragDrop.decide(session, target: target, offersMove: true, modifiers: [])
            #expect(decision.refusal == nil)
            await window.close()
        }

        // A folder found in the other pane's search results takes a drag from this pane, and those results are found
        // again; their background takes nothing.
        @Test func aFolderFoundInTheOtherPanesResultsTakesTheDrag() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let left = tab.activePane
            let right = try await twoPanes(window, right: "Beta")
            tab.activate(right)
            let engine = FakeSearchEngine()
            engine.finds = { _ in (["Inner/"], false, false) }
            right.search.session.engine = engine
            right.search.session.submit("inner")
            right.search.session.changeRoot(url(window, "Beta").path)
            #expect(await waitUntil { right.content.entries.contains { $0.name == "Inner" } })
            tab.activate(left)
            let searches = engine.starts.count
            let drags = tab.dragDrop

            drags.paneUnderDrag = right
            let dragged = drags.automationDragStarted([try entry(left, "note.txt")])
            #expect(!drags.automationDrop(dragged, entry: nil, allowed: [.copy, .move, .generic]))
            _ = drags.automationDragStarted([try entry(left, "note.txt")])
            #expect(drags.automationDrop(dragged, entry: try entry(right, "Inner"), allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("Beta/Inner/note.txt") && !window.exists("note.txt") })
            #expect(await waitUntil { engine.starts.count > searches })
            #expect(right.search.session.isSearchMode)
            right.search.session.hideResults()
            await window.close()
        }
    }
}
