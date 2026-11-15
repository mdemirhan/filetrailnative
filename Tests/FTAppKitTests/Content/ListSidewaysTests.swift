// The List scrolled sideways: the header with the rows, a folder opened, Back, a divider dragged and a rename
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ListSidewaysTests: ListTesting {
        /// A List in a pane narrower than its columns, on a folder with a few files and the folders `Inner` (files)
        /// and `Empty`.
        private func openNarrow() async throws -> (ExplorerHarness, MainWindowController, ListViewController) {
            let harness = try ExplorerHarness.windowless()
            let folder = harness.folder
            for name in ["Inner", "Empty"] {
                try FileManager.default.createDirectory(
                    at: folder.url.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for index in 0..<3 {
                try "x".write(
                    to: folder.url.appendingPathComponent("Inner/file\(index).txt"), atomically: true, encoding: .utf8)
            }
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !bars(tab).isEmpty })
            tab.window?.setContentSize(NSSize(width: 640, height: 500))
            harness.layout(tab)
            let list = try #require(tab.content.pane as? ListViewController)
            #expect(list.table.frame.width > list.scroll.contentView.bounds.width)
            return (harness, tab, list)
        }

        private func scrollSideways(_ list: ListViewController, to left: Double) {
            list.scrollPosition = (top: list.scrollPosition.top, left: left)
        }

        /// How far the Size column's header cell is from the first row's Size cell, in the window.
        private func headerToRow(_ tab: MainWindowController) throws -> CGFloat {
            let cell = try #require(header(tab)?.cell(for: .size))
            let bar = try #require(bars(tab).first)
            return cell.convert(cell.bounds, to: nil).minX - bar.sizeCell.convert(bar.sizeCell.bounds, to: nil).minX
        }

        private func go(_ tab: MainWindowController, _ path: String, _ harness: ExplorerHarness) async {
            tab.go(to: URL(fileURLWithPath: path))
            #expect(await waitUntil { tab.shownFolderPath == path && !tab.isNavigating })
            harness.layout(tab)
        }

        // Scrolled sideways, the header moves with the rows.
        @Test func theHeaderStaysOverItsColumnsAtAnOffset() async throws {
            let (harness, tab, list) = try await openNarrow()
            let atStart = try headerToRow(tab)
            scrollSideways(list, to: 120)
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX == 120)
            #expect(try headerToRow(tab) == atStart)
            await harness.close()
        }

        // Another folder opens at the left, an empty one too; Back and Forward put back where it was scrolled.
        @Test func anotherFolderStartsAtTheLeftAndBackRestoresTheOffset() async throws {
            let (harness, tab, list) = try await openNarrow()
            let outer = tab.folder.path
            scrollSideways(list, to: 120)
            await go(tab, outer + "/Inner", harness)
            #expect(list.scroll.contentView.bounds.minX == 0)
            scrollSideways(list, to: 80)
            await go(tab, outer + "/Empty", harness)
            #expect(list.scroll.contentView.bounds.minX == 0)
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath == outer + "/Inner" && !tab.isNavigating })
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX == 80)
            tab.perform(.goBack)
            #expect(await waitUntil { tab.shownFolderPath == outer && !tab.isNavigating })
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX == 120)
            await harness.close()
        }

        // The same folder put in another order, or shown with hidden files, stays where it was scrolled sideways.
        @Test func aNewOrderKeepsTheOffset() async throws {
            let (harness, tab, list) = try await openNarrow()
            try "x".write(to: harness.folder.url.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
            scrollSideways(list, to: 120)
            let first = tab.content.entries.first?.name
            tab.setSort(.name, .desc)
            #expect(await waitUntil { tab.content.entries.first?.name != first && !tab.isNavigating })
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX == 120)
            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { tab.content.entries.contains { $0.name == ".hidden" } && !tab.isNavigating })
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX == 120)
            await harness.close()
        }

        // A divider dragged past the pane's edge scrolls the list; dragged back, it stays under the pointer.
        @Test func aDividerFollowsThePointerAfterTheListScrolled() async throws {
            let (harness, tab, list) = try await openNarrow()
            let window = try #require(tab.window)
            let clip = list.scroll.contentView
            // Size, which has Kind after it: the list can scroll further.
            let separator = try #require(header(tab)?.cell(for: .size)?.separator)
            // Its divider 30 inside the pane's right edge.
            let inList = separator.convert(NSPoint(x: separator.bounds.midX, y: 0), to: clip).x
            scrollSideways(list, to: Double(inList - (clip.bounds.width - 30)))
            harness.layout(tab)
            let scrolledTo = clip.bounds.minX
            let dividerX = { separator.convert(NSPoint(x: separator.bounds.midX, y: 0), to: nil).x }
            let start = NSPoint(x: dividerX(), y: separator.convert(separator.bounds, to: nil).midY)
            separator.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: start, in: window)))
            // Past the edge (within Size's widths): the list scrolls to keep the divider in view.
            let far = NSPoint(x: start.x + 60, y: start.y)
            separator.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: far, in: window)))
            harness.layout(tab)
            #expect(clip.bounds.minX > scrolledTo)
            // Back inside the pane: the divider is under the pointer.
            let back = NSPoint(x: start.x - 50, y: start.y)
            separator.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: back, in: window)))
            harness.layout(tab)
            #expect(abs(dividerX() - back.x) <= 1)
            separator.mouseUp(with: try #require(MouseEvents.event(.leftMouseUp, at: back, in: window)))
            await harness.close()
        }

        // The list scrolled to its right end, a divider dragged left: the column narrows by as much as the pointer
        // moved and stays so while the pointer rests, the divider under it. The list keeps the room it shows to the
        // right, during the drag and after it, so nothing moves under the pointer or when it lets go; scrolled back,
        // the list gives the room up, and it never shows more of it than was left.
        @Test func aColumnNarrowedAtTheListsRightEndFollowsThePointer() async throws {
            let (harness, tab, list) = try await openNarrow()
            let window = try #require(tab.window)
            let clip = list.scroll.contentView
            scrollSideways(list, to: 10_000)
            harness.layout(tab)
            let end = clip.bounds.minX
            let fitted = list.table.frame.width
            #expect(end > 0 && clip.bounds.maxX == fitted)
            let cell = try #require(header(tab)?.cell(for: .size))
            let separator = cell.separator
            let width = cell.frame.width
            let dividerX = { separator.convert(NSPoint(x: separator.bounds.midX, y: 0), to: nil).x }
            let start = NSPoint(x: dividerX(), y: separator.convert(separator.bounds, to: nil).midY)
            func drag(to offset: CGFloat) throws {
                let point = NSPoint(x: start.x + offset, y: start.y)
                separator.mouseDragged(with: try #require(MouseEvents.event(.leftMouseDragged, at: point, in: window)))
                harness.layout(tab)
            }
            separator.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: start, in: window)))
            // The pointer moves once and then rests: the events that follow say the same place.
            for _ in 0..<6 { try drag(to: -10) }
            #expect(cell.frame.width == width - 10)
            #expect(abs(dividerX() - (start.x - 10)) <= 1)
            #expect(clip.bounds.minX == end)
            #expect(list.table.frame.width == fitted)
            // Further in, back out to where it began, which it takes again, and past it: the divider stays under the
            // pointer and the list where it was, growing only once the columns need more than it has.
            let steps: [(CGFloat, CGFloat)] = [
                (-30, fitted), (-10, fitted), (0, fitted), (6, fitted + 6), (-10, fitted),
            ]
            for (offset, wide) in steps {
                try drag(to: offset)
                let expected = width + offset
                #expect(cell.frame.width == expected, "\(offset)")
                #expect(abs(dividerX() - (start.x + offset)) <= 1, "\(offset)")
                #expect(clip.bounds.minX == end, "\(offset)")
                #expect(list.table.frame.width == wide, "\(offset)")
            }
            let left = NSPoint(x: start.x - 10, y: start.y)
            separator.mouseUp(with: try #require(MouseEvents.event(.leftMouseUp, at: left, in: window)))
            harness.layout(tab)
            // Let go: nothing moves, and the room is still there.
            #expect(cell.frame.width == width - 10)
            #expect(clip.bounds.minX == end)
            #expect(list.table.frame.width == fitted)
            // Scrolled back by less than the room, the list gives up that much; scrolled back further, all of it, and
            // it then ends at its columns as before.
            scrollSideways(list, to: Double(end) - 4)
            harness.layout(tab)
            #expect(list.table.frame.width == fitted - 4)
            scrollSideways(list, to: Double(end) - 50)
            harness.layout(tab)
            #expect(list.table.frame.width == fitted - 10)
            scrollSideways(list, to: 10_000)
            harness.layout(tab)
            #expect(clip.bounds.minX == end - 10)
            await harness.close()
        }

        // Renaming with Name scrolled out of view brings Name back first: the field opens where it can be seen.
        @Test func renameBringsNameIntoViewFirst() async throws {
            let (harness, tab, list) = try await openNarrow()
            let item = try #require(tab.content.entries.first { $0.name == "Inner" })
            tab.content.select(paths: [item.path])
            scrollSideways(list, to: 400)
            harness.layout(tab)
            #expect(list.scroll.contentView.bounds.minX > 300)
            #expect(tab.content.beginRename(path: item.path))
            harness.layout(tab)
            let field = try #require(list.renameField)
            let visible = list.scroll.contentView.bounds
            #expect(field.frame.minX >= visible.minX && field.frame.minX < visible.maxX)
            // At an offset, the field stays over the name it replaces.
            let bar = try #require(bars(tab).first { $0.entry?.path == item.path })
            let label = bar.nameLabel.convert(bar.nameLabel.bounds, to: list.table)
            #expect(field.frame.minX < label.minX && label.minX - field.frame.minX < 10)
            tab.content.renameCancelled()
            await harness.close()
        }
    }
}
