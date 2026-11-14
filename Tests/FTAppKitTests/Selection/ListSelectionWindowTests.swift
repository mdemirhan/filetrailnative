// A List selection made from outside reaches the window, Edit › Select All selects the list, Space is the filter's text
// while typing, the filter pill's ✕ clears it, and a filter nothing matches is said in place of the whole view
import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct ListSelectionWindowTests {
        func path(_ tab: MainWindowController, _ name: String) -> String? {
            tab.content.entries.first { $0.name == name }?.path
        }

        // Rows selected in the table from outside (the capture's select step, accessibility) are the
        // window's selection: the status line, the selection commands and the Info views read them.
        @Test func aSelectionMadeInTheTableReachesTheWindow() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let table = try #require(list.table)
            table.selectRowIndexes(IndexSet([1, 3]), byExtendingSelection: false)
            #expect(list.selectedNames == ["Beta", "note.txt"])
            #expect(tab.selectedPaths == [path(tab, "Beta"), path(tab, "note.txt")].compactMap { $0 })
            #expect(tab.content.selection.anchorPath == path(tab, "Beta"))
            #expect(tab.content.selection.leadPath == path(tab, "note.txt"))
            #expect(table.selectedRowIndexes == IndexSet([1, 3]))
            #expect(tab.content.contentShell.pathBarRow.status.stringValue.hasPrefix("2 of 4 selected"))
            #expect(tab.canPerform(.copySelection))
            // Extending adds to it; deselecting clears the model too.
            table.selectRowIndexes(IndexSet([0]), byExtendingSelection: true)
            #expect(list.selectedNames == ["Alpha", "Beta", "note.txt"])
            table.deselectAll(nil)
            #expect(tab.content.selection.isEmpty)
            #expect(table.selectedRowIndexes.isEmpty)
            await harness.close()
        }

        // Edit › Select All selects every entry while the list has the keyboard, whether or
        // not the window is the key window; with the tree focused it leaves the list alone.
        @Test func selectAllFromTheMenuSelectsTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.content.focusList()
            tab.perform(.editSelectAll)
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma", "note.txt"])
            #expect(tab.content.selection.anchorPath == path(tab, "Alpha"))
            #expect(tab.content.selection.leadPath == path(tab, "note.txt"))
            #expect(list.table?.selectedRowIndexes.count == 4)
            tab.content.selectionChanged(.empty)
            tab.perform(.focusTreePane)
            tab.perform(.editSelectAll)
            #expect(tab.content.selection.isEmpty)
            await harness.close()
        }

        // Space sent through the window is the
        // filter's text just after typing, not Quick Look; nothing matching hides the column header and says so in
        // place of the view; the ✕ brings the list back and leaves it the keyboard; Space after a pause is Quick Look.
        @Test func spaceIsTheFiltersAndTheClearButtonClearsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Files", files: 0)
            for name in ["Report.txt", "my doc.txt", "Readme.md", "notes.txt", "Amy.txt"] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let quickLook = QuickLookController.shared
            let system = quickLook.panel
            let fake = FakeQuickLookPanel()
            quickLook.panel = fake
            defer { quickLook.panel = system }
            let (tab, list) = try await harness.openList(folder.path)
            tab.content.focusList()
            list.type("my")
            list.key("Space")
            list.type("d")
            #expect(tab.content.filter == "my d")
            #expect(list.rowNames == ["my doc.txt"])
            #expect(fake.presented == 0)
            #expect(!identified("list.header", in: tab.content.container).isEmpty)
            list.type("zzz")
            #expect(list.rowNames.isEmpty)
            #expect(list.selectedNames.isEmpty)
            #expect(tab.content.container.stateView.kind == .noMatches(query: "my dzzz"))
            #expect(identified("list.header", in: tab.content.container).isEmpty)
            #expect(tab.content.container.topInset == 0)
            let clear = try #require(identified("listFilter.clear", in: tab.content.container).first as? ClearButton)
            clear.perform()
            #expect(tab.content.filter.isEmpty)
            #expect(list.rowNames.count == 5)
            #expect(list.hasKeyboard)
            #expect(!identified("list.header", in: tab.content.container).isEmpty)
            #expect(tab.content.container.topInset > 0)
            // With no filter typed, Space previews the selected item.
            tab.content.select(paths: [path(tab, "notes.txt")].compactMap { $0 })
            tab.content.focusList()
            list.key("Space")
            #expect(fake.presented == 1)
            quickLook.close()
            await harness.close()
        }

        // The state a filter nothing matches shows: the title at the body size in the primary color,
        // centered in the whole pane, and Search Subfolders centered under it, 4 below the line.
        @Test func theNoMatchStateIsLaidOut() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.content.focusList()
            list.type("zzz")
            let state = tab.content.container.stateView
            #expect(state.kind == .noMatches(query: "zzz"))
            state.frame = NSRect(x: 0, y: 0, width: 912, height: 679)
            state.layoutSubtreeIfNeeded()
            let title = try #require(identified("emptyState.title", in: state).first as? ThemedText)
            #expect(title.font?.pointSize == CGFloat(DesignTokens.typeScale.body))
            let line = try #require(identified("content.state.empty", in: state).first)
            let button = try #require(identified("content.state.button", in: state).first)
            #expect(abs(button.frame.midX - 912 / 2) <= 1)
            #expect(button.frame.minY == line.frame.maxY + 8 + 4)
            let top = title.frame.minY
            let bottom = button.frame.maxY
            #expect(abs((top + bottom) / 2 - 679 / 2) < 1)
            await harness.close()
        }
    }
}
