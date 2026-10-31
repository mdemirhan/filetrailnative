// Port by feature of springWhenHeld and of the drag-overs of the rows (useExplorerDragAndDrop.ts:60-68, :1271-1300,
// entryItemEvents.ts:100) in the List view, and of tellDropRefused and noteExternalDragLetGo (:896-918), on real tabs in
// windows that are never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct ListDragOverTests {
        private func table(_ tab: MainWindowController) throws -> ListTableView {
            try #require(Views.all(ListTableView.self, in: tab.workspace).first)
        }

        /// The middle of a row, in the window.
        private func point(_ window: WritingWindow, _ name: String) throws -> NSPoint {
            let list = try table(window.tab)
            let row = try #require(window.tab.content.entries.firstIndex { $0.name == name })
            let rect = list.rect(ofRow: row)
            return list.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
        }

        private func info(_ window: WritingWindow, at point: NSPoint = .zero, sequence: Int) -> StubDraggingInfo {
            StubDraggingInfo(
                paths: [window.folder.appendingPathComponent("note.txt").path], at: point, sequence: sequence,
                window: window.tab.window)
        }

        private func blockByACopy(_ window: WritingWindow) throws {
            window.operations.session(for: try #require(window.tab.group)).applyCard(
                WriteOperationCardState(
                    action: .paste, stage: .running, targetPath: "/x", currentSourcePath: "/Users/demo/Photos"))
        }

        private func unblock(_ window: WritingWindow) throws {
            window.operations.session(for: try #require(window.tab.group)).applyCard(nil)
        }

        private func toasts(_ tab: MainWindowController) -> [String] {
            tab.notifications?.toasts.entries.map(\.title) ?? []
        }

        private let refusal = "Can't drop while \u{201C}Photos\u{201D} is being copied"

        // The table asks its data source only when the row changes; every drag-over of a resting drag still reaches
        // the tab, as the Icons view's and the tree's do.
        // T-d16e383b
        @Test func everyDragOverOfTheListIsHeard() async throws {
            let window = try await WritingWindow.open()
            let list = try table(window.tab)
            var heard = 0
            window.tab.content.dragHooks.dragUpdated = { _, _ in
                heard += 1
                return .copy
            }
            let drag = info(window, at: try point(window, "Alpha"), sequence: 41)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(list.draggingEntered(drag) == .copy)
            for _ in 0..<10 { #expect(list.draggingUpdated(drag) == .copy) }
            #expect(heard == 11)
            #expect(list.wantsPeriodicDraggingUpdates())
            await window.close()
        }

        // The answer is the tab's each time, so a refusal that lifts on the same row is told to AppKit, and the table
        // doesn't refuse the drop for an answer it gave earlier.
        // T-62d562b1
        @Test func theAnswerFollowsTheTabOnTheSameRow() async throws {
            let window = try await WritingWindow.open()
            let list = try table(window.tab)
            var answer: NSDragOperation = []
            var dropped = 0
            window.tab.content.dragHooks.dragUpdated = { _, _ in answer }
            window.tab.content.dragHooks.performDrop = { _, entry in
                if entry?.name == "Alpha" { dropped += 1 }
                return true
            }
            let drag = info(window, at: try point(window, "Alpha"), sequence: 42)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(list.draggingEntered(drag) == [])
            answer = .copy
            #expect(list.draggingUpdated(drag) == .copy)
            #expect(list.prepareForDragOperation(drag))
            #expect(list.performDragOperation(drag))
            #expect(dropped == 1)
            await window.close()
        }

        // `springWhenHeld`: a drag resting on a folder row keeps it lit past the 300 ms of silence, and opens it.
        // T-e9b3fa09
        @Test func aDragHeldOverAFolderRowSpringsItOpen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let list = try table(tab)
            let alpha = window.folder.appendingPathComponent("Alpha").path
            let saved = TabDragDrop.dragIsHeldOver
            defer { TabDragDrop.dragIsHeldOver = saved }
            TabDragDrop.dragIsHeldOver = { _ in true }
            let drag = info(window, at: try point(window, "Alpha"), sequence: 43)
            defer { drag.draggingPasteboard.releaseGlobally() }
            _ = list.draggingEntered(drag)
            var opened = false
            for _ in 0..<60 where !opened {
                _ = list.draggingUpdated(drag)
                try await Task.sleep(for: .milliseconds(50))
                opened = samePath(tab.folder.path, alpha)
            }
            #expect(opened)
            await window.close()
        }

        // T-e3b16fef B-CLIP-177: AppKit never asks for a drop whose last answer was none, and tells the view the drag
        // left: let go there, it is told once for the drag.
        @Test func aDropRefusedWhileAWriteRunsIsToldFromTheLetGo() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let list = try table(tab)
            try blockByACopy(window)
            let saved = TabDragDrop.dragWasLetGoOver
            defer { TabDragDrop.dragWasLetGoOver = saved }
            TabDragDrop.dragWasLetGoOver = { $0 === tab.window }
            let drag = info(window, at: try point(window, "Alpha"), sequence: 44)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(list.draggingEntered(drag) == [])
            #expect(list.draggingUpdated(drag) == [])
            list.draggingExited(drag)
            #expect(toasts(tab) == [refusal])
            list.draggingExited(drag)
            try await Task.sleep(for: .milliseconds(500))
            #expect(toasts(tab) == [refusal])
            try unblock(window)
            await window.close()
        }

        // "Not for a drag that only passes over the window."
        @Test func aDragThatOnlyPassesOverIsNotTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let list = try table(tab)
            try blockByACopy(window)
            let saved = TabDragDrop.dragWasLetGoOver
            defer { TabDragDrop.dragWasLetGoOver = saved }
            TabDragDrop.dragWasLetGoOver = { _ in false }
            let drag = info(window, at: try point(window, "Alpha"), sequence: 45)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(list.draggingUpdated(drag) == [])
            list.draggingExited(drag)
            try await Task.sleep(for: .milliseconds(500))
            #expect(toasts(tab).isEmpty)
            try unblock(window)
            await window.close()
        }

        // No write runs: nothing to tell.
        @Test func aDragLetGoWithNoWriteRunningIsNotTold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let saved = TabDragDrop.dragWasLetGoOver
            defer { TabDragDrop.dragWasLetGoOver = saved }
            TabDragDrop.dragWasLetGoOver = { _ in true }
            let drag = info(window, sequence: 46)
            defer { drag.draggingPasteboard.releaseGlobally() }
            _ = tab.dragDrop.contentDragUpdated(drag, entry: nil)
            tab.dragDrop.dragExited()
            #expect(toasts(tab).isEmpty)
            await window.close()
        }

        // Where AppKit tells no leaving (the sidebar, a part of the window that hears no drags), the drag-overs stopping
        // with the button up is the let-go; held there, it isn't yet.
        // T-532dcad7
        @Test func aDropLetGoWhereNoLeavingIsToldIsToldWhenTheDragOversStop() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            try blockByACopy(window)
            let savedLetGo = TabDragDrop.dragWasLetGoOver
            let savedHeld = TabDragDrop.dragIsHeldOver
            defer {
                TabDragDrop.dragWasLetGoOver = savedLetGo
                TabDragDrop.dragIsHeldOver = savedHeld
            }
            var held = true
            TabDragDrop.dragIsHeldOver = { _ in held }
            TabDragDrop.dragWasLetGoOver = { _ in !held }
            let drag = info(window, sequence: 47)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(tab.dragDrop.sidebarDragUpdated(drag, row: nil) == [])
            try await Task.sleep(for: .milliseconds(700))
            #expect(toasts(tab).isEmpty)
            held = false
            #expect(await waitUntil { toasts(tab) == [refusal] })
            try unblock(window)
            await window.close()
        }

        /// The tab's tree, with the row of `Alpha` in it, not opened, and a drag over that row; the drag's pasteboard is
        /// the caller's to release.
        private func dragOverTheTree(
            _ window: WritingWindow, sequence: Int
        ) async throws -> (tree: SidebarOutlineView, drag: StubDraggingInfo, alpha: String) {
            let tab = window.tab
            let alpha = window.folder.appendingPathComponent("Alpha").path
            let model = tab.sidebarController.model
            // Rooted here, so the test doesn't wait for the tree to read its way down from the disk's root.
            model.rootTree(at: window.folder.path)
            #expect(await waitUntil { model.nodes[alpha] != nil })
            window.harness.layout(tab)
            let tree = try #require(Views.all(SidebarOutlineView.self, in: tab.workspace).first)
            let list = try #require(tree.list)
            let index = try #require(
                (0..<tree.numberOfRows).first { row in
                    if case .item(let state)? = list.row(at: row) { return state.item.path == alpha }
                    return false
                })
            let rect = tree.rect(ofRow: index)
            let drag = StubDraggingInfo(
                paths: [window.folder.appendingPathComponent("note.txt").path],
                at: tree.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), sequence: sequence,
                window: tab.window)
            #expect(tree.draggingEntered(drag) != [])
            #expect(tab.sidebarController.dropStates[alpha] == .valid)
            return (tree, drag, alpha)
        }

        // T-d9fde40a: a drag moved from a folder of the tree to the list: the folder shows nothing and doesn't open, with
        // the list's drag-overs going on past the time a held folder opens.
        @Test func aFolderOfTheTreeTheDragMovedOnFromShowsNothingAndDoesntOpen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let over = try await dragOverTheTree(window, sequence: 49)
            defer { over.drag.draggingPasteboard.releaseGlobally() }
            over.drag.draggingLocation = try point(window, "Gamma")
            let list = try table(tab)
            #expect(list.draggingEntered(over.drag) != [])
            #expect(tab.sidebarController.dropStates.isEmpty)
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                _ = list.draggingUpdated(over.drag)
            }
            #expect(tab.sidebarController.dropStates.isEmpty)
            #expect(tab.sidebarController.model.nodes[over.alpha]?.expanded == false)
            #expect(tab.sidebarController.model.nodes[over.alpha]?.loading == false)
            tab.dragDrop.dragExited()
            await window.close()
        }

        // T-492d90a0: the drag-overs stop, with no word from the tree: the folder shows nothing and doesn't open.
        @Test func aFolderOfTheTreeTheDragLeftShowsNothingAndDoesntOpen() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let over = try await dragOverTheTree(window, sequence: 50)
            defer { over.drag.draggingPasteboard.releaseGlobally() }
            try await Task.sleep(for: .milliseconds(1000))
            #expect(tab.sidebarController.dropStates.isEmpty)
            #expect(tab.sidebarController.model.nodes[over.alpha]?.expanded == false)
            #expect(tab.sidebarController.model.nodes[over.alpha]?.loading == false)
            await window.close()
        }

        // T-4390276a B-CLIP-171: held on a folder of the tree, the folder opens.
        @Test func aFolderOfTheTreeOpensUnderADragHeldThere() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let over = try await dragOverTheTree(window, sequence: 51)
            defer { over.drag.draggingPasteboard.releaseGlobally() }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                _ = over.tree.draggingUpdated(over.drag)
            }
            #expect(await waitUntil { tab.sidebarController.model.nodes[over.alpha]?.expanded == true })
            tab.dragDrop.clearTargets()
            await window.close()
        }

        // endExternalDrag at the drop (:1168-1171): a drag that was taken is over, so its own write's card, still up when
        // the drag-overs have been quiet for a while, tells nothing of it.
        // T-62d562b1
        @Test func aTakenDropWithItsWriteStillRunningIsNotToldAsRefused() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let savedLetGo = TabDragDrop.dragWasLetGoOver
            let savedHeld = TabDragDrop.dragIsHeldOver
            defer {
                TabDragDrop.dragWasLetGoOver = savedLetGo
                TabDragDrop.dragIsHeldOver = savedHeld
            }
            TabDragDrop.dragIsHeldOver = { _ in false }
            TabDragDrop.dragWasLetGoOver = { _ in true }
            let drag = info(window, sequence: 48)
            defer { drag.draggingPasteboard.releaseGlobally() }
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            #expect(!tab.dragDrop.contentDragUpdated(drag, entry: alpha).isEmpty)
            #expect(tab.dragDrop.contentPerformDrop(drag, entry: alpha))
            let session = window.operations.session(for: try #require(tab.group))
            // Keeps a card up, as a long copy does: the fixture's real small copy ends too quickly.
            for _ in 0..<40 {
                if session.card == nil {
                    session.applyCard(
                        WriteOperationCardState(
                            action: .copyTo, stage: .running, targetPath: alpha.path,
                            currentSourcePath: "/Users/demo/Photos"))
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(toasts(tab).allSatisfy { !$0.hasPrefix("Can") }, "\(toasts(tab))")
            session.applyCard(nil)
            await window.close()
        }
    }
}
