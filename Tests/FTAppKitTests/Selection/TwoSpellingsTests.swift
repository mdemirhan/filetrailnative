// A folder holding one name twice, its accent composed in one and decomposed in the other: two rows, each selected,
// renamed and acted on by itself
import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// "café.txt" with its "é" as one scalar, and as an "e" and its accent.
private let composedName = "caf\u{E9}.txt"
private let decomposedName = "cafe\u{301}.txt"

/// A disk that keeps the two spellings of an accent as two names in one folder, as FAT can and a share from Linux
/// does. This Mac's own disk takes them for one name, so the listing of `folder` is given the second name here;
/// whatever else is asked of either name the real disk answers, for the one file it has.
private struct BothSpellingsDisk: ExplorerFileSystem {
    let folder: String
    private let real = NativeFileSystem()

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        let records = try real.readDirectory(path)
        guard DiskPath(path) == DiskPath(folder) else { return records }
        return records.flatMap { record -> [DirectoryRecord] in
            guard DiskPath(record.name) == DiskPath(composedName) else { return [record] }
            var other = record
            other.name = decomposedName
            return [record, other]
        }
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(path) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

/// The views of the folder the rows are tried in.
enum TwoSpellingsView: String, CaseIterable, Sendable {
    case list, icons, compactList

    var command: AppCommand {
        switch self {
        case .list: .viewAsDetails
        case .icons: .viewAsIcons
        case .compactList: .viewAsList
        }
    }
}

/// A window on a folder that lists "café.txt" under both spellings, and "plain.txt".
@MainActor
private struct TwoSpellingsWindow {
    let harness: ExplorerHarness
    let tab: MainWindowController
    let view: TwoSpellingsView
    let composed: String
    let decomposed: String
    let plain: String

    var content: ContentPaneController { tab.content }
    var list: ListProbe { ListProbe(tab: tab) }
    var grid: GridProbe { GridProbe(tab: tab) }

    static func open(_ view: TwoSpellingsView) async throws -> TwoSpellingsWindow {
        let harness = try ExplorerHarness.windowless()
        let tab = try await harness.open()
        let folder = NodePath.join(tab.folderPath, "Both")
        #expect(mkdir(folder, 0o755) == 0)
        // open(2) keeps the name as given; Foundation would decompose it.
        for name in [composedName, "plain.txt"] {
            let file = Darwin.open(folder + "/" + name, O_CREAT | O_WRONLY, 0o644)
            #expect(file >= 0)
            close(file)
        }
        tab.servicesOverride = ExplorerServices(
            directoryService: DirectoryService(fileSystem: BothSpellingsDisk(folder: folder)),
            iconStore: TestServices.icons, clipboard: harness.windows.clipboard, preferences: harness.channel)
        tab.perform(view.command)
        tab.go(to: folder)
        #expect(await waitUntil { !tab.isNavigating && tab.content.entries.count == 3 && tab.content.pane != nil })
        harness.layout(tab)
        let window = TwoSpellingsWindow(
            harness: harness, tab: tab, view: view, composed: folder + "/" + composedName,
            decomposed: folder + "/" + decomposedName, plain: folder + "/plain.txt")
        window.layout()
        return window
    }

    func layout() {
        harness.layout(tab)
        if view != .list { grid.layout() }
    }

    /// Where the entry spelled exactly so stands among the entries shown.
    func index(_ path: String) throws -> Int {
        try #require(content.entries.firstIndex { DiskPath($0.path) == DiskPath(path) })
    }

    /// The spelling shown second, and the one shown first: the second is the one a lookup that takes them for one
    /// name never finds.
    func inOrder() throws -> (first: String, second: String) {
        try index(composed) < index(decomposed) ? (composed, decomposed) : (decomposed, composed)
    }

    private func item(_ index: Int) -> NSCollectionViewItem? {
        grid.grid?.item(at: IndexPath(item: index, section: 0))
    }

    /// A point on the part of the item that takes clicks, in window coordinates.
    func point(_ path: String) throws -> NSPoint {
        let index = try index(path)
        switch view {
        case .list: return list.center(ofRow: index)
        case .icons: return grid.point(in: try #require(item(index) as? IconItem).tile)
        case .compactList: return grid.point(in: try #require(item(index) as? CompactListItem).root)
        }
    }

    func press(_ path: String, moves: [NSPoint] = [], modifiers: NSEvent.ModifierFlags = []) throws {
        let point = try point(path)
        if view == .list {
            list.press(at: point, moves: moves, modifiers: modifiers)
        } else {
            grid.press(at: point, moves: moves, modifiers: modifiers)
        }
        layout()
    }

    func key(_ name: String, modifiers: NSEvent.ModifierFlags = []) {
        if view == .list {
            list.window.makeFirstResponder(list.table)
            list.key(name, modifiers: modifiers)
        } else {
            grid.key(name, modifiers: modifiers)
        }
        layout()
    }

    /// The menu a right-click on the item asks for.
    func rightClick(_ path: String) throws {
        let point = try point(path)
        if view == .list {
            let table = try #require(list.table)
            _ = (content.pane as? ListViewController)?.menu(forEventAt: table.convert(point, from: nil))
        } else {
            let collection = try #require(grid.grid)
            _ = grid.pane?.menu(forEventAt: collection.convert(point, from: nil))
        }
    }

    /// The paths of the rows drawn as selected, in the order shown.
    var drawnSelected: [DiskPath] {
        content.entries.indices.filter { index in
            switch view {
            case .list: list.table?.selectedRowIndexes.contains(index) == true
            case .icons: (item(index) as? IconItem)?.pill.isHidden == false
            case .compactList: (item(index) as? CompactListItem)?.selectedMarker.isHidden == false
            }
        }.map { DiskPath(content.entries[$0].path) }
    }

    /// The paths of the rows whose name is hidden under a rename field.
    var namesHidden: [DiskPath] {
        content.entries.indices.filter { index in
            switch view {
            case .list: (content.pane as? ListViewController)?.bar(atRow: index)?.nameLabel.isHidden == true
            case .icons: (item(index) as? IconItem)?.label.isHidden == true
            case .compactList: (item(index) as? CompactListItem)?.label.isHidden == true
            }
        }.map { DiskPath(content.entries[$0].path) }
    }

    /// The paths of the rows drawn as what a drag would drop into.
    var drawnAsDropTarget: [DiskPath] {
        content.entries.indices.filter { index in
            switch view {
            case .list:
                !identified("list.row.dropTarget", in: (content.pane as? ListViewController)?.bar(atRow: index))
                    .isEmpty
            case .icons: (item(index) as? IconItem)?.dropMarker.isHidden == false
            case .compactList: (item(index) as? CompactListItem)?.dropMarker.isHidden == false
            }
        }.map { DiskPath(content.entries[$0].path) }
    }

    /// Whether the rename field is over the row of the entry spelled so.
    func renameFieldIsOver(_ path: String) throws -> Bool {
        let index = try index(path)
        switch view {
        case .list:
            let pane = try #require(content.pane as? ListViewController)
            let field = try #require(pane.renameField)
            return pane.table.rect(ofRow: index).contains(NSPoint(x: field.frame.midX, y: field.frame.midY))
        case .icons, .compactList:
            let pane = try #require(grid.pane)
            let field = try #require(pane.renameField)
            return field.frame == pane.renameFrame(at: index)
        }
    }
}

private func bytes(_ paths: [String]) -> [DiskPath] { paths.map(DiskPath.init) }

extension ExplorerWindowlessTests {
    /// Some disks keep the two spellings of an accent as two names in one folder. Each is a row of its own: selected,
    /// renamed and handed to a command by itself, never as the other.
    @MainActor
    @Suite struct TwoSpellingsTests {
        @Test(arguments: TwoSpellingsView.allCases)
        func bothSpellingsAreRowsOfTheirOwn(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            #expect(
                Set(bytes(content.entries.map(\.path)))
                    == Set(bytes([window.composed, window.decomposed, window.plain])))
            #expect(bytes(content.entryPaths) == bytes(content.entries.map(\.path)))
            // Each is found where it stands, and by its own entry.
            for path in [window.composed, window.decomposed, window.plain] {
                #expect(content.position(of: path) == (try window.index(path)))
                #expect(content.listedEntry(at: path).map { DiskPath($0.path) } == DiskPath(path))
            }
            #expect(window.drawnSelected.isEmpty)
            await window.harness.close()
        }

        @Test(arguments: TwoSpellingsView.allCases)
        func aPressSelectsTheSpellingPressedAndNoOther(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            let order = try window.inOrder()
            for path in [order.second, order.first, order.second] {
                try window.press(path)
                #expect(bytes(content.selection.paths) == bytes([path]))
                #expect(content.selection.anchorPath.map(DiskPath.init) == DiskPath(path))
                #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(path))
                #expect(window.drawnSelected == bytes([path]))
                #expect(bytes(content.selectedEntries.map(\.path)) == bytes([path]))
                #expect(bytes(window.tab.selectedPaths) == bytes([path]))
            }
            await window.harness.close()
        }

        @Test(arguments: TwoSpellingsView.allCases)
        func selectAllTakesBothSpellings(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            content.selectAllEntries()
            window.layout()
            let all = bytes(content.entries.map(\.path))
            #expect(all.count == 3)
            #expect(bytes(content.selection.paths) == all)
            #expect(bytes(content.selectedEntries.map(\.path)) == all)
            #expect(window.drawnSelected == all)
            // Inverted, nothing; the one deselected alone, inverted again.
            content.invertSelection()
            #expect(content.selection.isEmpty)
            content.selectAllEntries()
            try window.press(window.decomposed, modifiers: .command)
            #expect(bytes(content.selection.paths) == all.filter { $0 != DiskPath(window.decomposed) })
            content.invertSelection()
            window.layout()
            #expect(bytes(content.selection.paths) == bytes([window.decomposed]))
            #expect(window.drawnSelected == bytes([window.decomposed]))
            await window.harness.close()
        }

        @Test(arguments: TwoSpellingsView.allCases)
        func extendingAndTogglingGoRowByRow(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            let order = try window.inOrder()
            // ⇧ from one spelling to the other: the two, the anchor where the range began and the lead where it ended.
            try window.press(order.first)
            try window.press(order.second, modifiers: .shift)
            #expect(bytes(content.selection.paths) == bytes([order.first, order.second]))
            #expect(content.selection.anchorPath.map(DiskPath.init) == DiskPath(order.first))
            #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(order.second))
            #expect(window.drawnSelected == bytes([order.first, order.second]))
            #expect(bytes(content.selectedEntries.map(\.path)) == bytes([order.first, order.second]))
            // ⌘ takes one out and puts it back, the other left as it is.
            try window.press(order.first, modifiers: .command)
            #expect(bytes(content.selection.paths) == bytes([order.second]))
            #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(order.second))
            #expect(window.drawnSelected == bytes([order.second]))
            try window.press(order.first, modifiers: .command)
            #expect(bytes(content.selection.paths) == bytes([order.first, order.second]))
            #expect(content.selection.anchorPath.map(DiskPath.init) == DiskPath(order.first))
            #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(order.first))
            #expect(window.drawnSelected == bytes([order.first, order.second]))
            await window.harness.close()
        }

        // The arrow keys go from the lead, which is the row of its own spelling.
        @Test func theArrowKeysMoveFromTheSpellingThatLeads() async throws {
            let window = try await TwoSpellingsWindow.open(.list)
            let content = window.content
            let order = try window.inOrder()
            let second = try window.index(order.second)
            #expect(second == (try window.index(order.first)) + 1)
            try window.press(order.second)
            window.key("ArrowDown")
            #expect(content.position(of: content.selection.leadPath) == second + 1)
            window.key("ArrowUp")
            #expect(bytes(content.selection.paths) == bytes([order.second]))
            window.key("ArrowUp")
            #expect(bytes(content.selection.paths) == bytes([order.first]))
            #expect(window.drawnSelected == bytes([order.first]))
            window.key("ArrowDown", modifiers: .shift)
            #expect(bytes(content.selection.paths) == bytes([order.first, order.second]))
            #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(order.second))
            await window.harness.close()
        }

        // A drag-to-select takes the rows its box touches, the second spelling without the first; ⇧ then adds the
        // first beside it.
        @Test func aDragToSelectTakesTheSpellingItsBoxTouches() async throws {
            let window = try await TwoSpellingsWindow.open(.list)
            let content = window.content
            let list = window.list
            let paths = content.entries.map(\.path)
            #expect(bytes(Array(paths.prefix(2))).sorted() == bytes([window.composed, window.decomposed]).sorted())
            let below = list.emptyPoint(belowRows: 3)
            await list.drag(from: below, to: list.center(ofRow: 1))
            #expect(bytes(content.selection.paths) == bytes(Array(paths[1...])))
            #expect(window.drawnSelected == bytes(Array(paths[1...])))
            #expect(content.selection.leadPath.map(DiskPath.init) == DiskPath(paths[1]))
            await list.drag(from: below, to: list.center(ofRow: 0), modifiers: .shift)
            #expect(bytes(content.selection.paths) == bytes(paths))
            // ⌘ flips the last two out.
            await list.drag(from: below, to: list.center(ofRow: 1), modifiers: .command)
            #expect(bytes(content.selection.paths) == bytes([paths[0]]))
            #expect(window.drawnSelected == bytes([paths[0]]))
            await window.harness.close()
        }

        @Test(arguments: TwoSpellingsView.allCases)
        func aRenameOpensOnTheRowAskedFor(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            let order = try window.inOrder()
            for path in [order.second, order.first] {
                content.select(paths: [path])
                #expect(content.beginRename(path: path))
                window.layout()
                #expect(content.inlineRename.map { DiskPath($0.path) } == DiskPath(path))
                #expect(try window.renameFieldIsOver(path))
                #expect(window.namesHidden == bytes([path]))
                content.renameCancelled()
                window.layout()
                #expect(content.inlineRename == nil)
                #expect(window.namesHidden.isEmpty)
            }
            await window.harness.close()
        }

        // What a command is handed is the selected file itself: the menu's items, a drag's, Copy's, and the paths
        // Move to Trash and Rename take.
        @Test(arguments: TwoSpellingsView.allCases)
        func aCommandIsHandedTheSelectedFileItself(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            let tab = window.tab
            // Copy goes through the app's file operations, which act while this is kept.
            let operations = try window.harness.writeOperations()
            defer { withExtendedLifetime(operations) {} }
            let order = try window.inOrder()
            for path in [order.second, order.first] {
                try window.press(path)
                // The paths the tab hands a write (Move to Trash, Rename, Duplicate).
                #expect(bytes(tab.selectedPaths) == bytes([path]))
                // Copy.
                tab.perform(.copySelection)
                #expect(bytes(tab.services.clipboard.contents.sourcePaths) == bytes([path]))
                tab.services.clipboard.set(.empty, from: nil)
                // The right-click menu, on the selected item.
                var menuFor: [String]?
                content.contextMenuProvider = { entries in
                    menuFor = entries?.map(\.path)
                    return nil
                }
                try window.rightClick(path)
                #expect(menuFor.map(bytes) == bytes([path]))
                #expect(bytes(content.selection.paths) == bytes([path]))
                // A drag from it.
                var carried: [String] = []
                content.dragHooks.beginDrag = { entries, _, _ in
                    carried = entries.map(\.path)
                    return true
                }
                let start = try window.point(path)
                try window.press(path, moves: [NSPoint(x: start.x + 40, y: start.y)])
                #expect(bytes(carried) == bytes([path]))
                content.dragHooks.beginDrag = nil
            }
            // A right-click on the other spelling selects it alone, and the menu is for it.
            var menuFor: [String]?
            content.contextMenuProvider = { entries in
                menuFor = entries?.map(\.path)
                return nil
            }
            try window.press(order.first)
            try window.rightClick(order.second)
            #expect(bytes(content.selection.paths) == bytes([order.second]))
            #expect(menuFor.map(bytes) == bytes([order.second]))
            await window.harness.close()
        }

        // A row told to draw itself again is the one spelled so: the row a drag is over shows it, and no other.
        @Test(arguments: TwoSpellingsView.allCases)
        func aRowIsDrawnAgainByItsOwnSpelling(_ view: TwoSpellingsView) async throws {
            let window = try await TwoSpellingsWindow.open(view)
            let content = window.content
            let order = try window.inOrder()
            for path in [order.second, order.first, order.second] {
                content.setDropTarget(path, .valid, background: nil)
                window.layout()
                #expect(window.drawnAsDropTarget == bytes([path]))
            }
            content.setDropTarget(nil, nil, background: nil)
            window.layout()
            #expect(window.drawnAsDropTarget.isEmpty)
            await window.harness.close()
        }

        // Quick Look zooms out of the row of the item it shows, and the status counts each spelling selected.
        @Test func whatIsShownOfTheSelectionIsTheSpellingSelected() async throws {
            let window = try await TwoSpellingsWindow.open(.list)
            let content = window.content
            let order = try window.inOrder()
            let frames = [order.first, order.second].map {
                QuickLookItemFrame.screenFrame(of: $0, entries: content.entries, in: content.view)
            }
            #expect(frames[0] != nil && frames[1] != nil && frames[0] != frames[1])
            // Both selected, the lead the second: the status counts two.
            try window.press(order.first)
            try window.press(order.second, modifiers: .shift)
            #expect(content.contentShell.pathBarRow.status.stringValue.hasPrefix("2 of 3 selected"))
            await window.harness.close()
        }
    }
}

/// The content pane by itself, given rows that spell one name both ways.
@MainActor
struct TwoSpellingsRowsTests {
    private let composed = "/f/" + composedName
    private let decomposed = "/f/" + decomposedName

    private func pane() -> ContentPaneController {
        _ = NSApplication.shared
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_011), loaders: .placeholder)
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.show(
            folder: "/f", entries: [composedName, decomposedName, "plain.txt"].map { ContentModelTests.entry($0) },
            selecting: nil, keepingScroll: false)
        return content
    }

    // A path to select from outside the rows (after a write, a reveal) finds the row spelled as it is.
    @Test func aPathToSelectFindsTheRowSpelledAsItIs() {
        let content = pane()
        #expect(content.position(of: composed) == 0 && content.position(of: decomposed) == 1)
        for path in [decomposed, composed] {
            content.select(paths: [path])
            #expect(bytes(content.selection.paths) == bytes([path]))
            #expect(bytes(content.selectedEntries.map(\.path)) == bytes([path]))
        }
        content.select(paths: [decomposed, composed])
        #expect(bytes(content.selectedEntries.map(\.path)) == bytes([decomposed, composed]))
    }

    // The folder read again keeps each spelling's own selection, and a listing that asks for one selects that one.
    @Test func aListingKeepsAndSelectsEachSpellingByItself() {
        let content = pane()
        let entries = content.listed
        content.select(paths: [decomposed])
        content.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: true)
        #expect(bytes(content.selection.paths) == bytes([decomposed]))
        content.show(folder: "/f", entries: entries, selecting: [decomposed], keepingScroll: true)
        #expect(bytes(content.selectedEntries.map(\.path)) == bytes([decomposed]))
        // Back and Forward restore the spelling that was selected.
        let memory = FolderViewMemory(selection: .single(decomposed))
        content.show(folder: "/f", entries: entries, selecting: nil, keepingScroll: false, restoring: memory)
        #expect(bytes(content.selection.paths) == bytes([decomposed]))
        #expect(bytes(content.selectedEntries.map(\.path)) == bytes([decomposed]))
        // The one selected leaves the listing: the other is not selected in its place.
        content.show(
            folder: "/f", entries: entries.filter { DiskPath($0.path) != DiskPath(decomposed) }, selecting: nil,
            keepingScroll: true)
        #expect(content.selection.isEmpty)
        #expect(content.selectedEntries.isEmpty)
    }

    // What a write took away leaves the selection by its own spelling.
    @Test func whatAWriteTookLeavesTheSelectionByItsOwnSpelling() {
        let content = pane()
        content.selectAllEntries()
        content.dropFromSelection([decomposed])
        #expect(bytes(content.selection.paths) == bytes([composed, "/f/plain.txt"]))
        content.dropFromSelection([composed])
        #expect(bytes(content.selection.paths) == bytes(["/f/plain.txt"]))
    }

    // A rename asked for one spelling is that row's, and ends when that row leaves.
    @Test func aRenameIsOfTheSpellingAskedFor() {
        let content = pane()
        var lost: [String] = []
        content.onRenameLost = { path, _ in lost.append(path) }
        #expect(content.beginRename(path: decomposed))
        #expect(content.inlineRename.map { DiskPath($0.path) } == DiskPath(decomposed))
        var submitted: [String] = []
        content.onRenameSubmit = { path, _ in submitted.append(path) }
        content.renameSubmitted("tea.txt")
        #expect(bytes(submitted) == bytes([decomposed]))
        // The other spelling's row leaving is not this one's.
        let entries = content.listed
        content.show(
            folder: "/f", entries: entries.filter { DiskPath($0.path) != DiskPath(composed) }, selecting: nil,
            keepingScroll: true)
        #expect(content.inlineRename != nil)
        content.show(
            folder: "/f", entries: entries.filter { DiskPath($0.path) != DiskPath(decomposed) }, selecting: nil,
            keepingScroll: true)
        #expect(content.inlineRename == nil)
        #expect(bytes(lost) == bytes([decomposed]))
    }

    // The details of the rows on screen are asked for with each row's own Date Added, as its listing gave it.
    @Test func eachSpellingsRowIsReadWithItsOwnDateAdded() async {
        _ = NSApplication.shared
        var asked: [DiskPath: Int64?] = [:]
        var loaders = ContentLoaders.placeholder
        loaders.metadata = { _, _, listedAdded in
            asked.merge(listedAdded) { $1 }
            return []
        }
        let content = ContentPaneController(
            mode: .details, folderSizes: FolderSizeService.shared.sizes(for: 9_012), loaders: loaders)
        content.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        var first = ContentModelTests.entry(composedName)
        first.addedMs = 1_000
        var second = ContentModelTests.entry(decomposedName)
        second.addedMs = 2_000
        content.show(folder: "/f", entries: [first, second], selecting: nil, keepingScroll: false)
        content.requestMetadata(for: [first, second])
        #expect(await waitUntil { asked.count == 2 })
        #expect(asked[DiskPath(composed)] == .some(1_000))
        #expect(asked[DiskPath(decomposed)] == .some(2_000))
    }
}
