// Drags out of and onto an explorer window that is never shown, through the drop seams the capture uses, with the app's
// real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct DragDropWindowTests {
        private func entry(_ window: WritingWindow, _ name: String) throws -> DirectoryEntry {
            try #require(window.tab.content.entries.first { $0.name == name })
        }

        private func url(_ window: WritingWindow, _ name: String) -> URL {
            window.folder.appendingPathComponent(name)
        }

        // An item dragged onto a
        // folder of the same disk moves into it.
        @Test func aDropOnAFolderOfTheSameDiskMoves() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let dragged = drags.automationDragStarted([try entry(window, "note.txt")])
            #expect(dragged == [url(window, "note.txt").path])
            #expect(
                drags.automationDrop(dragged, entry: try entry(window, "Alpha"), allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            #expect(TabDragDrop.ownDrag == nil)
            await window.close()
        }

        // ⌥ copies, whatever the disks.
        @Test func optionCopies() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let urls = drags.automationDragStarted([try entry(window, "note.txt")])
            #expect(drags.automationDrop(urls, entry: try entry(window, "Beta"), allowed: .copy))
            #expect(await waitUntil { window.exists("Beta/note.txt") })
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // A drop on a folder of the tree goes into it, and the
        // tree stays on the folder it was on: the target is selected only when an item lands exactly there.
        @Test func aDropOnAFolderOfTheTreeGoesIntoIt() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            let beta = url(window, "Beta").path
            let shownInTree = tab.sidebarController.selectedTreeTargetPath
            let target = TabDragDrop.Target(surface: .tree, path: beta, supportsMove: true, selectsInTree: true)
            let session = DragSession(
                sourceSurface: .external, sourceItems: [DragItem(path: url(window, "note.txt").path, kind: .file)],
                leadPath: url(window, "note.txt").path, leadKind: .file)
            #expect(drags.drop(session: session, target: target, offersMove: true, modifiers: [], sequence: 1))
            #expect(await waitUntil { window.exists("Beta/note.txt") && !tab.isWriteLocked })
            await settle()
            #expect(tab.sidebarController.selectedTreeTargetPath == shownInTree)
            await window.close()
        }

        // The folder on screen takes a drag from another app
        // dropped on its empty space; the app's own drag doesn't (it hasn't sprung into it).
        @Test func theFolderOnScreenTakesDropsFromOtherApps() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let inner = url(window, "Alpha/outside.txt")
            try "o".write(to: inner, atomically: true, encoding: .utf8)
            #expect(drags.automationDrop([inner.path], entry: nil, allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("outside.txt") && !window.exists("Alpha/outside.txt") })
            _ = drags.automationDragStarted([try entry(window, "Gamma")])
            #expect(!drags.automationDrop([url(window, "Gamma").path], entry: nil, allowed: [.copy, .move]))
            await window.close()
        }

        // While a write runs a drag doesn't
        // start and a toast says why; a drop from another app is refused, told once.
        @Test func dragsAreRefusedWhileAWriteRuns() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let session = window.operations.session(for: try #require(tab.group))
            session.applyCard(
                WriteOperationCardState(
                    action: .paste, stage: .running, targetPath: "/x", currentSourcePath: "/Users/demo/Photos"))
            let event = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            #expect(tab.dragDrop.beginDrag([try entry(window, "note.txt")], event: event, from: tab.content.view))
            #expect(
                tab.notifications?.toasts.entries.map(\.title) == [
                    "Can\u{2019}t drag while \u{201C}Photos\u{201D} is being copied"
                ])
            #expect(TabDragDrop.ownDrag == nil)
            #expect(
                !tab.dragDrop.automationDrop(
                    [url(window, "note.txt").path], entry: try entry(window, "Alpha"), allowed: .move))
            #expect(
                tab.notifications?.toasts.entries.last?.title
                    == "Can\u{2019}t drop while \u{201C}Photos\u{201D} is being copied")
            session.applyCard(nil)
            await window.close()
        }

        // Each drag is followed on its own. A second drag ending while the first's
        // slow move is still going doesn't stop the first being looked for: when it leaves, a cut of it is cancelled and
        // it leaves the results, which are not searched again.
        @Test func aSecondDragDoesntStopTheFirstBeingLookedFor() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            let dragTimers = window.manualDragTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(tab.searchRootPath != nil)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "note.txt" } })
            let searches = engine.starts.count

            let slow = url(window, "note.txt").path
            let quick = url(window, "quick.txt").path
            tab.services.clipboard.set(ClipboardRules.set(.cut, [slow], capturedAt: "t"), from: nil)
            tab.dragDrop.ownDragEnded(paths: [slow], operation: .move, over: .elsewhere)
            tab.dragDrop.ownDragEnded(paths: [quick], operation: .move, over: .elsewhere)
            // The second is gone at its own first check (it never existed); the first is still there then.
            dragTimers.advance(DragTimings.draggedAwayChecksMs[0] / 1000)
            for _ in 0..<5 { await Task.yield() }
            #expect(tab.services.clipboard.contents.hasItems)
            #expect(tab.content.entries.contains { $0.name == "note.txt" })

            try FileManager.default.removeItem(atPath: slow)
            dragTimers.advance(DragTimings.draggedAwayChecksMs[1] / 1000)
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            #expect(await waitUntil { !tab.content.entries.contains { $0.name == "note.txt" } })
            #expect(engine.starts.count == searches)
            #expect(!tab.search.session.mayBeMissingItems)
            tab.search.session.hideResults()
            await window.close()
        }

        // With no search on screen, nothing is searched.
        @Test func noSearchStartsWhenAnotherAppMovedAnItemAwayFromAFolder() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let engine = FakeSearchEngine()
            tab.search.session.engine = engine
            let note = url(window, "note.txt").path
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0])
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            #expect(engine.starts.isEmpty)
            await window.close()
        }

        // A cut item dragged away to another app leaves the clipboard, and one notification names it, as nothing else
        // says it went. A copied one leaves without a word.
        @Test func aCutItemDraggedAwayIsNamedAsItLeavesTheClipboard() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let clipboard = tab.services.clipboard
            let note = url(window, "note.txt").path
            let alpha = url(window, "Alpha").path
            let beta = url(window, "Beta").path
            clipboard.set(
                ClipboardRules.setMode(
                    ClipboardRules.set(.cut, [note, alpha, beta], capturedAt: "t"), [beta], to: .copy, at: "t"),
                from: nil)
            func leftNotices() -> [String] {
                tab.notifications?.toasts.entries.map(\.title).filter { $0.hasSuffix("no longer on the clipboard") }
                    ?? []
            }

            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0])
            #expect(await waitUntil { clipboard.contents.sourcePaths == [alpha, beta] })
            #expect(leftNotices() == ["\u{201C}note.txt\u{201D} is no longer on the clipboard"])

            try FileManager.default.removeItem(atPath: beta)
            tab.dragDrop.checkDraggedAway([beta], intoTrash: false, after: [0])
            #expect(await waitUntil { clipboard.contents.sourcePaths == [alpha] })
            #expect(clipboard.contents.mode == .cut)
            #expect(leftNotices().count == 1)
            await window.close()
        }

        // Empty Trash from the menu with a Trash item on the clipboard: it leaves the clipboard, and the results
        // on screen, which it didn't act on, stay as they are.
        @Test func emptyTrashWithTrashedItemsOnTheClipboardLeavesTheResults() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "note.txt" } })
            let searches = engine.starts.count

            var dialogs = window.recorder.dialogs
            dialogs.confirm = { _, _ in true }
            window.operations.dialogs = dialogs
            let actions = try #require(tab.writeActions)
            actions.emptyTrashRunner = { (true, nil) }
            let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/gone.txt").path
            tab.services.clipboard.set(ClipboardRules.set(.copy, [trashed], capturedAt: "t"), from: nil)
            _ = await actions.emptyTrash()
            #expect(!tab.services.clipboard.contents.hasItems)
            for _ in 0..<5 { await Task.yield() }
            #expect(engine.starts.count == searches)
            #expect(tab.content.entries.contains { $0.name == "note.txt" })
            tab.search.session.hideResults()
            await window.close()
        }

        // A drag sets off from where its rows show: the icon and the name of each row in sight.
        @Test func theDragImagesComeFromTheRowsInSight() async throws {
            let window = try await WritingWindow.open()
            let note = url(window, "note.txt").path
            let placed = try #require(window.tab.content.dragPlacements(for: [note, "/nowhere"]))
            let placement = try #require(placed.placements[DiskPath(note)])
            #expect(placement.inSight)
            #expect(placement.iconRect.width > 0 && placement.nameRect.minX > placement.iconRect.maxX)
            #expect(placed.placements["/nowhere"] == nil)
            #expect(placed.view is ListTableView)
            await window.close()
        }
    }
}
