// A List selection made from outside reaches the window, Edit › Select All selects the list, Deselect All and Invert
// Selection act on what the list shows, Space is the filter's text while there is one, the filter bar's ✕ clears it, and a filter nothing matches is said in place of the whole view
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

        // Edit ▸ Invert Selection is on with nothing selected, as long as the list shows something, and then selects
        // all of it; an empty folder leaves it off. Deselect All needs a selection.
        // The List's rows are asked for their details with the Date Added their listing gave, each of them, one with
        // no date too (present, with none), so that none is asked for its own.
        @Test func theListsRowsAreReadWithTheDateAddedOfTheirListing() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let read = tab.content.loaders.metadata
            var asked: [DiskPath: Int64?] = [:]
            var paths: Set<String> = []
            tab.content.loaders.metadata = { folder, batch, listedAdded in
                paths.formUnion(batch)
                asked.merge(listedAdded) { _, new in new }
                return await read(folder, batch, listedAdded)
            }
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { !tab.content.entries.isEmpty })
            harness.layout(tab)
            let entries = tab.content.entries
            #expect(await waitUntil { entries.allSatisfy { tab.content.metadata(for: $0.path) != nil } })
            #expect(!paths.isEmpty && paths == Set(asked.keys.map(\.string)))
            for entry in entries where paths.contains(entry.path) {
                #expect(asked[DiskPath(entry.path)] == .some(entry.addedMs))
            }
            await harness.close()
        }

        @Test func invertSelectionIsOnWheneverTheListShowsSomething() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.content.focusList()
            #expect(tab.content.selection.isEmpty)
            #expect(tab.canPerform(.invertSelection))
            #expect(!tab.canPerform(.deselectAll))
            tab.perform(.invertSelection)
            #expect(list.selectedNames == ["Alpha", "Beta", "Gamma", "note.txt"])
            #expect(tab.canPerform(.invertSelection))
            #expect(tab.canPerform(.deselectAll))
            tab.perform(.deselectAll)
            #expect(tab.content.selection.isEmpty)
            #expect(list.table?.selectedRowIndexes.isEmpty == true)
            // Part of it selected: the rest, and only the rest.
            tab.content.select(paths: [path(tab, "Beta")].compactMap { $0 })
            tab.perform(.invertSelection)
            #expect(list.selectedNames == ["Alpha", "Gamma", "note.txt"])

            let empty = try harness.makeFolder(named: "Empty", files: 0)
            tab.go(to: empty.path)
            #expect(await waitUntil { tab.shownFolderPath == empty.path && !tab.isNavigating })
            tab.content.focusList()
            #expect(tab.focusedPane == .content)
            #expect(tab.content.entries.isEmpty)
            #expect(!tab.canPerform(.invertSelection))
            #expect(!tab.canPerform(.deselectAll))
            await harness.close()
        }

        // With a filter typed the two commands act on what the list shows: Invert selects the shown items that
        // weren't selected and drops a selected one the filter hides, and Deselect All leaves nothing selected.
        @Test func deselectAllAndInvertSelectionActOnWhatAFilterShows() async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Files", files: 0)
            for name in ["Report.txt", "Readme.md", "notes.txt", "Amy.txt"] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let (tab, list) = try await harness.openList(folder.path)
            let amy = try #require(path(tab, "Amy.txt"))
            tab.content.focusList()
            list.type("re")
            #expect(list.rowNames == ["Readme.md", "Report.txt"])
            let readme = try #require(path(tab, "Readme.md"))
            let report = try #require(path(tab, "Report.txt"))
            // Nothing selected (typing selected its first match): everything the filter shows, and nothing it hides.
            tab.content.selectionChanged(.empty)
            #expect(tab.canPerform(.invertSelection))
            tab.perform(.invertSelection)
            #expect(tab.selectedPaths == [readme, report])
            // One shown and one hidden selected: the other shown one alone.
            tab.content.applySelection(.of([report, amy]))
            tab.perform(.invertSelection)
            #expect(tab.selectedPaths == [readme])
            tab.content.applySelection(.of([readme, amy]))
            #expect(tab.canPerform(.deselectAll))
            tab.perform(.deselectAll)
            #expect(tab.content.selection.isEmpty)
            // The filter stays as typed.
            #expect(tab.content.filter == "re")
            #expect(list.rowNames == ["Readme.md", "Report.txt"])
            await harness.close()
        }

        // Search results are a list as a folder's is: the two commands act on the results.
        @Test func deselectAllAndInvertSelectionActOnSearchResults() async throws {
            let harness = try ExplorerHarness.windowless()
            let folder = try harness.makeFolder(named: "Found", files: 0)
            for name in ["one.txt", "two.txt", "three.txt"] {
                try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let (tab, list) = try await harness.openList(folder.path)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["one.txt", "two.txt", "three.txt"], false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "txt"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(
                await waitUntil {
                    timers.advance(0.2)
                    return tab.searchRootPath != nil && tab.content.entries.count == 3
                })
            tab.content.focusList()
            #expect(tab.focusedPane == .content)
            #expect(tab.content.selection.isEmpty)
            #expect(tab.canPerform(.invertSelection))
            #expect(!tab.canPerform(.deselectAll))
            tab.perform(.invertSelection)
            #expect(tab.selectedPaths == tab.content.entries.map(\.path))
            let first = try #require(tab.content.entries.first?.path)
            tab.content.applySelection(.of([first]))
            tab.perform(.invertSelection)
            #expect(tab.selectedPaths == tab.content.entries.dropFirst().map(\.path))
            #expect(list.selectedNames.count == 2)
            #expect(tab.canPerform(.deselectAll))
            tab.perform(.deselectAll)
            #expect(tab.content.selection.isEmpty)
            #expect(tab.searchRootPath != nil)
            await harness.close()
        }

        // With the folder tree focused the two commands are off, whatever the list has selected: they are the
        // list's.
        @Test func deselectAllAndInvertSelectionAreOffWithTheTreeFocused() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            tab.content.focusList()
            tab.content.select(paths: [path(tab, "Beta")].compactMap { $0 })
            #expect(tab.canPerform(.deselectAll))
            #expect(tab.canPerform(.invertSelection))
            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)
            #expect(!tab.canPerform(.deselectAll))
            #expect(!tab.canPerform(.invertSelection))
            #expect(list.selectedNames == ["Beta"])
            await harness.close()
        }

        // Space sent through the window is the filter's text while there is one, not Quick Look; nothing matching hides
        // the column header and says so in place of the view; the ✕ brings the list back and leaves it the keyboard;
        // with the filter gone Space is Quick Look.
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
