// Covers how far the List view scrolls, in an explorer window that is never shown (ContentPane.tsx's .details-table: the
// rows and nothing below them)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ListTesting {
    /// The document is the rows, or the pane when they are fewer; at the end the last row sits on the pane's bottom.
    func expectEndsAtLastRow(
        _ tab: MainWindowController, rows: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let table = try #require(
            Views.all(ListTableView.self, in: tab.workspace).first, sourceLocation: sourceLocation)
        let clip = try #require(table.enclosingScrollView?.contentView, sourceLocation: sourceLocation)
        #expect(table.numberOfRows == rows, sourceLocation: sourceLocation)
        let height = CGFloat(rows) * table.rowHeight
        #expect(table.frame.height == max(height, clip.bounds.height), sourceLocation: sourceLocation)
        // As the scroller and the wheel do: the clip view keeps the bounds inside the document.
        let far = NSRect(x: 0, y: 1_000_000, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(far).origin)
        #expect(clip.bounds.minY == max(0, height - clip.bounds.height), sourceLocation: sourceLocation)
        if height >= clip.bounds.height {
            #expect(table.rect(ofRow: rows - 1).maxY == clip.bounds.maxY, sourceLocation: sourceLocation)
        }
        clip.scroll(to: .zero)
    }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ListScrollExtentTests: ListTesting {
        private func openLong(_ count: Int = 300) async throws -> (ExplorerHarness, MainWindowController) {
            let harness = try ExplorerHarness.windowless()
            for index in 0..<count {
                try "x".write(to: harness.folder.appending("file\(index).txt"), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !bars(tab).isEmpty })
            harness.layout(tab)
            return (harness, tab)
        }

        private func searching(_ text: String, in tab: MainWindowController, _ timers: ManualTimers) throws {
            let field = try #require(tab.searchField)
            field.stringValue = text
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
        }

        @Test func aFolderEndsAtItsLastRow() async throws {
            let (harness, tab) = try await openLong()
            try expectEndsAtLastRow(tab, rows: tab.content.entries.count)
            await harness.close()
        }

        // The panels, the tree and a resize change the pane's size, which must not add to the document.
        @Test func thePanelsAndAResizeLeaveTheEndWhereItIs() async throws {
            let (harness, tab) = try await openLong()
            let rows = tab.content.entries.count
            let commands: [RendererCommand] = [
                .toggleInfoRow, .toggleInfoRow, .toggleInfoPanel, .toggleInfoPanel, .toggleFolderTree,
                .toggleFolderTree,
            ]
            for command in commands {
                tab.perform(command)
                harness.layout(tab)
                try expectEndsAtLastRow(tab, rows: rows)
            }
            let window = try #require(tab.window)
            let size = try #require(window.contentView?.frame.size)
            window.setContentSize(NSSize(width: size.width - 100, height: size.height - 200))
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: rows)
            window.setContentSize(NSSize(width: size.width + 100, height: size.height + 150))
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: rows)
            await harness.close()
        }

        // A second tab's list is laid out from nothing too.
        @Test func aNewTabEndsAtItsLastRow() async throws {
            let (harness, tab) = try await openLong()
            let rows = tab.content.entries.count
            tab.perform(.newTab)
            let added = try #require(harness.windows.front as? MainWindowController)
            added.perform(.viewAsDetails)
            #expect(await waitUntil { added.content.entries.count == rows && !bars(added).isEmpty })
            harness.layout(added)
            try expectEndsAtLastRow(added, rows: rows)
            await harness.close()
        }

        @Test func theSearchResultsEndAtTheirLastRowAndAShorterListFollows() async throws {
            let (harness, tab) = try await openLong()
            try expectEndsAtLastRow(tab, rows: tab.content.entries.count)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            let names = (0..<400).map { "Alpha/result\($0).txt" }
            engine.finds = { _ in (names, false, false) }
            try searching("result", in: tab, timers)
            #expect(await waitUntil { tab.content.entries.count == 400 && !bars(tab).isEmpty })
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: 400)
            engine.finds = { _ in (["note.txt", "Alpha/Inner"], false, false) }
            try searching("no", in: tab, timers)
            #expect(await waitUntil { tab.content.entries.count == 2 })
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: 2)
            await harness.close()
        }
    }
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ListScrollExtentGUITests: ListTesting {
        // On screen the window's safe area and the title bar are real, and shutting the Info Row grows the pane.
        @Test func aFolderOnScreenEndsAtItsLastRow() async throws {
            let harness = try ExplorerHarness()
            for index in 0..<300 {
                try "x".write(to: harness.folder.appending("file\(index).txt"), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !bars(tab).isEmpty })
            harness.layout(tab)
            let rows = tab.content.entries.count
            try expectEndsAtLastRow(tab, rows: rows)
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: rows)
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            try expectEndsAtLastRow(tab, rows: rows)
            await harness.close()
        }
    }
}
