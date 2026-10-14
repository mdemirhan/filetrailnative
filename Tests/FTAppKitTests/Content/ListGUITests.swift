// Covers the List view and the content pane's states in a window, by feature row (ContentPane.test.tsx and
// ContentPane.items.test.tsx, ContentPane.rowRenders.test.tsx, App.folderOrder.test.tsx, App.folderWatch.test.tsx and the
// hooks' tests)
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

@MainActor
private func views(_ id: String, in root: NSView?) -> [NSView] {
    guard let root else { return [] }
    var found: [NSView] = root.accessibilityIdentifier() == id && !root.isHidden ? [root] : []
    for child in root.subviews where !child.isHidden { found += views(id, in: child) }
    return found
}

extension ExplorerWindowGUITests {
    @MainActor
    @Suite struct ListGUITests {
        func bars(_ tab: MainWindowController) -> [DetailsBarView] {
            views("list.row", in: tab.window?.contentView).compactMap { $0 as? DetailsBarView }
                .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
        }

        func header(_ tab: MainWindowController) -> DetailsHeaderView? {
            views("list.header", in: tab.window?.contentView).first as? DetailsHeaderView
        }

        func texts(_ bar: DetailsBarView) -> [String] {
            bar.subviews.flatMap { view -> [String] in
                if let label = view as? NSTextField { return [label.stringValue] }
                return view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            }
        }

        // T-6f96314a F-764 F-765 F-766 B-VIEW-040 B-VIEW-053 B-INFO-180: the rows are 28 high and inset 10, the header
        // titles are the columns', and a folder shows "--" for its size.
        @Test func drawsTheRowsAndTheHeader() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { tab.content.entries.count == 4 && !bars(tab).isEmpty })
            harness.layout(tab)
            let rows = bars(tab)
            #expect(rows.count == 4)
            let first = try #require(rows.first)
            #expect(first.bounds.height == 28)
            let pane = tab.content.contentShell.convert(tab.content.contentShell.bounds, to: nil)
            let bar = first.convert(first.bounds, to: nil)
            #expect(bar.minX - pane.minX == 10 && pane.maxX - bar.maxX == 10)
            let header = try #require(header(tab))
            let titles = header.subviews.compactMap { ($0 as? DetailsHeaderCell)?.title.stringValue }
            #expect(titles == ["Name", "Date Modified", "Size", "Kind"])
            let alpha = try #require(rows.first { $0.entry?.name == "Alpha" })
            #expect(texts(alpha).contains("--"))
            await harness.close()
        }

        // T-bc6fc27c F-765 B-VIEW-044 B-VIEW-045: a narrow window drops columns from the right; the saved widths stay.
        @Test func aNarrowPaneDropsColumnsFromTheRight() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !bars(tab).isEmpty }
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: 760, height: 600))
            harness.layout(tab)
            let columns = try #require(header(tab)).subviews.compactMap { $0 as? DetailsHeaderCell }.filter {
                !$0.isHidden
            }
            #expect(columns.count < 4 && columns.first?.column == .name)
            #expect(tab.content.columnState.widths[.kind] == 148)
            await harness.close()
        }

        // T-f43eb8e0 T-b0215a2e F-768 F-771 B-VIEW-047 B-VIEW-048 B-VIEW-049 B-NAV-127: header clicks sort; Created and
        // Permissions can't.
        @Test func headerClicksSort() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !bars(tab).isEmpty }
            let header = try #require(header(tab))
            let cell = try #require(header.cell(for: .modified))
            #expect(cell.sortable)
            cell.onSort(.modified)
            #expect(tab.viewState.sortBy == .modified && tab.viewState.sortDirection == .desc)
            cell.onSort(.modified)
            #expect(tab.viewState.sortDirection == .asc)
            header.cell(for: .name)?.onSort(.name)
            #expect(tab.viewState.sortBy == .name && tab.viewState.sortDirection == .asc)
            tab.updatePreferences([
                "detailColumns": .object([
                    "modified": .bool(true), "size": .bool(true), "kind": .bool(true), "created": .bool(true),
                    "permissions": .bool(true),
                ])
            ])
            tab.refreshColumns()
            harness.layout(tab)
            let created = try #require(self.header(tab)?.cell(for: .created))
            #expect(!created.sortable)
            await harness.close()
        }

        // T-80505d69 F-770 B-VIEW-050 B-VIEW-051 B-VIEW-052: a drag on a separator resizes within the limits and keeps
        // the width; the arrow keys step by 12; a double-click fits.
        @Test func separatorsResizeTheColumns() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !bars(tab).isEmpty }
            let header = try #require(header(tab))
            let separator = try #require(header.cell(for: .kind)?.separator)
            let start = separator.onBegin(.kind)
            #expect(start.width == 148)
            separator.onDrag(.kind, 148 + 30, start.saved)
            #expect(tab.content.columnState.widths[.kind] == 178)
            #expect(tab.preferences.detailColumnWidths.kind == 178)
            separator.onDrag(.kind, 10, start.saved)
            #expect(tab.content.columnState.widths[.kind] == 60)
            harness.layout(tab)
            separator.onNudge(.kind, 1)
            #expect(tab.content.columnState.widths[.kind] == 72)
            separator.onFit(.kind)
            let fitted = try #require(tab.content.columnState.widths[.kind])
            #expect(fitted >= 60 && fitted < 148)
            await harness.close()
        }

        // F-756 F-828 B-VIEW-008 B-VIEW-009 B-SEL-175: a selection stays through a change made outside the app, which
        // appears without Loading….
        @Test func aChangeOutsideKeepsTheSelection() async throws {
            let harness = try ExplorerHarness()
            let tab = try await harness.open()
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !bars(tab).isEmpty }
            let note = try #require(tab.content.entries.first { $0.name == "note.txt" }).path
            tab.content.select(paths: [note])
            #expect(tab.selectedPaths == [note])
            try "y".write(to: harness.folder.appending("new.txt"), atomically: true, encoding: .utf8)
            tab.refresh()
            #expect(await waitUntil { tab.content.entries.contains { $0.name == "new.txt" } })
            #expect(tab.selectedPaths == [note])
            #expect(tab.content.container(for: .none))
            // A selected item removed outside drops out (B-VIEW-192).
            try FileManager.default.removeItem(atPath: note)
            tab.refresh()
            #expect(await waitUntil { tab.selectedPaths.isEmpty })
            await harness.close()
        }

        // T-71a43ef8 T-115ec808 T-af56cfdc T-30f649b6 T-0ab3ac42 F-752 F-778 B-VIEW-062 B-VIEW-063 B-VIEW-064
        // B-VIEW-065: the empty, error and Full Disk Access states.
        @Test func theStates() async throws {
            let harness = try ExplorerHarness()
            let empty = harness.folder.appending("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try "x".write(to: empty.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
            let tab = try await harness.open(empty.path)
            tab.perform(.viewAsDetails)
            #expect(await waitUntil { tab.content.container(for: .empty(text: "Empty folder · 1 hidden item")) })
            // A folder that can't be read shows its error, with nothing behind it.
            tab.content.showError(folder: empty.path, message: "Operation not permitted: /x")
            #expect(tab.content.container(for: .error(message: "Operation not permitted: /x")))
            #expect(tab.content.entries.isEmpty)
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
            tab.content.showError(folder: trash, message: "Operation not permitted: \(trash)")
            #expect(tab.content.container(for: .fullDiskAccess))
            tab.content.showNoFolder()
            #expect(tab.content.container(for: .empty(text: "Select a folder to see what’s in it.")))
            await harness.close()
        }
    }
}

extension ContentPaneController {
    /// Whether the pane shows this state.
    func container(for kind: ContentStateKind) -> Bool {
        view.layoutSubtreeIfNeeded()
        let stateViews = views("content", in: view).compactMap { ($0 as? ContentContainerView)?.stateView }
        return stateViews.first?.kind == kind
    }
}
