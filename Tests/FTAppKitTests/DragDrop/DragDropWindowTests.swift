// Port by feature of App.dragOut.test.tsx and App.dragIn.test.tsx (and the drag cases of App.fileOperations.test.tsx):
// drags out of and onto an explorer window that is never shown, through the drop seams the capture uses, with the
// app's real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct DragDropWindowTests {
        private func entry(_ window: WritingWindow, _ name: String) throws -> DirectoryEntry {
            try #require(window.tab.content.entries.first { $0.name == name })
        }

        private func url(_ window: WritingWindow, _ name: String) -> URL {
            window.folder.appendingPathComponent(name)
        }

        // T-c5552cf7 T-d8c5f3b8 F-684 F-695 B-CLIP-148 B-CLIP-159 B-CLIP-163 B-CLIP-176: an item dragged onto a
        // folder of the same disk moves into it.
        // B-VIEW-074 T-0f30452a T-2b370a85 T-53a42a0a T-62d562b1 T-f4ffed39
        @Test func aDropOnAFolderOfTheSameDiskMoves() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let urls = drags.automationDragStarted([try entry(window, "note.txt")])
            #expect(urls == [url(window, "note.txt")])
            #expect(drags.automationDrop(urls, entry: try entry(window, "Alpha"), allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            #expect(TabDragDrop.ownDrag == nil)
            await window.close()
        }

        // F-031 F-683 B-CLIP-161: ⌥ copies, whatever the disks.
        // T-740a332a T-8fd59900
        @Test func optionCopies() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let urls = drags.automationDragStarted([try entry(window, "note.txt")])
            #expect(drags.automationDrop(urls, entry: try entry(window, "Beta"), allowed: .copy))
            #expect(await waitUntil { window.exists("Beta/note.txt") })
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // T-3d199f86 F-739 B-TREE-157 B-TREE-159 B-TREE-160: a drop on a folder of the tree goes into it, and the
        // tree stays on the folder it was on: the target is selected only when an item lands exactly there.
        // T-26eb6e20
        @Test func aDropOnAFolderOfTheTreeGoesIntoIt() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let beta = url(window, "Beta").path
            let target = TabDragDrop.Target(surface: .tree, path: beta, supportsMove: true, selectsInTree: true)
            let session = DragSession(
                sourceSurface: .external, sourceItems: [DragItem(path: url(window, "note.txt").path, kind: .file)],
                leadPath: url(window, "note.txt").path, leadKind: .file)
            #expect(drags.drop(session: session, target: target, offersMove: true, modifiers: [], sequence: 1))
            #expect(await waitUntil { window.exists("Beta/note.txt") })
            await window.close()
        }

        // T-84c8114c T-783e8e67 T-46e5bcfc B-CLIP-170 B-CLIP-173: the folder on screen takes a drag from another app
        // dropped on its empty space; the app's own drag doesn't (it hasn't sprung into it).
        @Test func theFolderOnScreenTakesDropsFromOtherApps() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let inner = url(window, "Alpha/outside.txt")
            try "o".write(to: inner, atomically: true, encoding: .utf8)
            #expect(drags.automationDrop([inner], entry: nil, allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("outside.txt") && !window.exists("Alpha/outside.txt") })
            _ = drags.automationDragStarted([try entry(window, "Gamma")])
            #expect(!drags.automationDrop([url(window, "Gamma")], entry: nil, allowed: [.copy, .move]))
            await window.close()
        }

        // T-a91faf09 T-c89e355a T-87626198 B-CLIP-156 B-CLIP-157: an alias of a folder takes nothing, nor the Trash; a
        // folder doesn't go into itself.
        // B-CLIP-168 B-TREE-190 B-VIEW-074 T-11ca1eea T-b7282f2f T-e711d033
        @Test func targetsThatRefuse() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let session = DragSession(
                sourceSurface: .external, sourceItems: [DragItem(path: url(window, "Gamma").path, kind: .directory)],
                leadPath: url(window, "Gamma").path, leadKind: .directory)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let trash = TabDragDrop.Target(surface: .favorite, path: home + "/.Trash", supportsMove: false)
            #expect(drags.decide(session, target: trash, offersMove: true, modifiers: []).refusal == .invalidTarget)
            let itself = TabDragDrop.Target(surface: .tree, path: url(window, "Gamma/Inner").path, supportsMove: true)
            #expect(drags.decide(session, target: itself, offersMove: true, modifiers: []).refusal == .parentIntoChild)
            let json = """
                {"path":"\(url(window, "Link").path)","name":"Link","fileExtension":"","kind":"symlink_directory",
                "isHidden":false,"isSymlink":true}
                """
            let link = try JSONDecoder().decode(DirectoryEntry.self, from: Data(json.utf8))
            let target = try #require(drags.contentTarget(session, entry: link))
            #expect(!target.supportsMove)
            await window.close()
        }

        // T-648c9eab T-f898989a T-e3b16fef B-CLIP-150 B-CLIP-151 B-CLIP-177: while a write runs a drag doesn't
        // start and a toast says why; a drop from another app is refused, told once.
        // B-TREE-162 B-VIEW-203
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
                    "Can't drag while \u{201C}Photos\u{201D} is being copied"
                ])
            #expect(TabDragDrop.ownDrag == nil)
            #expect(
                !tab.dragDrop.automationDrop(
                    [url(window, "note.txt")], entry: try entry(window, "Alpha"), allowed: .move))
            #expect(
                tab.notifications?.toasts.entries.last?.title
                    == "Can't drop while \u{201C}Photos\u{201D} is being copied")
            session.applyCard(nil)
            await window.close()
        }

        // T-cfac6ffc T-0914189a B-CLIP-050 B-CLIP-165: items dragged out that another app took away are dropped
        // from the clipboard, found by asking the disk after the drag.
        @Test func itemsAnotherAppTookAwayLeaveTheClipboard() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = url(window, "note.txt").path
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            tab.clipboardChanged()
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0])
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        // T-35a8bef5 B-CLIP-050 B-SRCH-142: a result dragged out and moved away by another app is looked for after the
        // drag, and the results on screen are found again, without it.
        @Test func searchResultsAreFoundAgainWhenAnotherAppMovedOneAway() async throws {
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
            #expect(tab.searchRootPath != nil)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "note.txt" } })
            let searches = engine.starts.count

            let note = url(window, "note.txt").path
            try FileManager.default.removeItem(atPath: note)
            engine.finds = { _ in ([], false, false) }
            tab.dragDrop.ownDragEnded(paths: [note], operation: .move, over: .elsewhere)
            #expect(await waitUntil { engine.starts.count == searches + 1 })
            #expect(await waitUntil { !tab.content.entries.contains { $0.name == "note.txt" } })
            tab.search.session.hideResults()
            await window.close()
        }

        // T-35a8bef5 B-CLIP-050 B-SRCH-142: each drag is followed on its own. A second drag ending while the first's
        // slow move is still going doesn't stop the first being looked for: when it leaves, a cut of it is cancelled and
        // the results are found again.
        @Test func aSecondDragDoesntStopTheFirstBeingLookedFor() async throws {
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

            let slow = url(window, "note.txt").path
            let quick = url(window, "quick.txt").path
            tab.services.clipboard.set(ClipboardRules.set(.cut, [slow], capturedAt: "t"), from: nil)
            tab.dragDrop.ownDragEnded(paths: [slow], operation: .move, over: .elsewhere)
            tab.dragDrop.ownDragEnded(paths: [quick], operation: .move, over: .elsewhere)
            // The second is gone at its own first check (it never existed); the first is still there then.
            #expect(await waitUntil { engine.starts.count == searches + 1 })
            #expect(tab.services.clipboard.contents.hasItems)

            engine.finds = { _ in ([], false, false) }
            try FileManager.default.removeItem(atPath: slow)
            #expect(await waitUntil { engine.starts.count == searches + 2 })
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            #expect(await waitUntil { !tab.content.entries.contains { $0.name == "note.txt" } })
            tab.search.session.hideResults()
            await window.close()
        }

        // T-35a8bef5: with no search on screen, nothing is searched.
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

        // B-SRCH-142: Empty Trash from the menu with a Trash item on the clipboard: it leaves the clipboard, and the results
        // on screen are found again.
        @Test func emptyTrashWithTrashedItemsOnTheClipboardFindsResultsAgain() async throws {
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
            _ = try await actions.emptyTrash()
            #expect(!tab.services.clipboard.contents.hasItems)
            #expect(await waitUntil { engine.starts.count == searches + 1 })
            tab.search.session.hideResults()
            await window.close()
        }

        // T-4c40ea4b T-20b0bfbe B-CLIP-162: a drop whose disks can't be read, with no key held, is refused.
        @Test func aDropWhoseDisksDontAnswerIsRefused() async throws {
            let window = try await WritingWindow.open()
            let read = TabDragDrop.readDiskIds
            TabDragDrop.readDiskIds = { paths in paths.map { _ in nil } }
            defer { TabDragDrop.readDiskIds = read }
            let drags = window.tab.dragDrop
            let urls = drags.automationDragStarted([try entry(window, "note.txt")])
            #expect(drags.automationDrop(urls, entry: try entry(window, "Alpha"), allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { !window.recorder.shown.isEmpty })
            #expect(window.recorder.shown.first?.title == "Couldn\u{2019}t Drop")
            #expect(window.exists("note.txt") && !window.exists("Alpha/note.txt"))
            await window.close()
        }

        // F-688 B-CLIP-149: a drag sets off from where its rows show: the icon and the name of each row in sight.
        @Test func theDragImagesComeFromTheRowsInSight() async throws {
            let window = try await WritingWindow.open()
            let note = url(window, "note.txt").path
            let placed = try #require(window.tab.content.dragPlacements(for: [note, "/nowhere"]))
            let placement = try #require(placed.placements[note])
            #expect(placement.inSight)
            #expect(placement.iconRect.width > 0 && placement.nameRect.minX > placement.iconRect.maxX)
            #expect(placed.placements["/nowhere"] == nil)
            #expect(placed.view is ListTableView)
            await window.close()
        }
    }
}
