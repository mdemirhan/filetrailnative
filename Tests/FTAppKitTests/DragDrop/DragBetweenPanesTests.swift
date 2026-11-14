// Drags from one pane of a tab to the other, through the drop seams the capture uses, with the app's real file
// operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

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

        // A search result dragged to the other pane's folder goes there: only the results' own list refuses it.
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
            #expect(
                DragRules.validate(
                    session: session, blocked: false, targetSurface: .content, targetPath: target.path,
                    targetSupportsMove: true) == .unsupportedTarget)
            await window.close()
        }
    }
}
