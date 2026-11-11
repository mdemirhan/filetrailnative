// Drags over the list, the grid and the tree of a window that is never shown, through AppKit's dragging callbacks, with
// the app's real file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct DragDropMatrixTests {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        private func entry(_ window: WritingWindow, _ name: String) throws -> DirectoryEntry {
            try #require(window.tab.content.entries.first { $0.name == name })
        }

        private func external(_ paths: [String], kind: FTFoundation.EntryKind = .file) -> DragSession {
            DragSession(
                sourceSurface: .external, sourceItems: paths.map { DragItem(path: $0, kind: kind) },
                leadPath: paths[0], leadKind: kind)
        }

        private func folderEntry(_ path: String, kind: String = "directory") throws -> DirectoryEntry {
            let json = """
                {"path":"\(path)","name":"\((path as NSString).lastPathComponent)","fileExtension":"",
                "kind":"\(kind)","isHidden":false,"isSymlink":\(kind != "directory")}
                """
            return try JSONDecoder().decode(DirectoryEntry.self, from: Data(json.utf8))
        }

        /// No key held, whatever the Mac's keyboard says, for as long as the test lasts.
        private func noKeys() -> () -> Void {
            let saved = TabDragDrop.modifiers
            TabDragDrop.modifiers = { [] }
            return { TabDragDrop.modifiers = saved }
        }

        /// A file of a folder that is not on screen, for a drag from another app.
        private func fileInAlpha(_ window: WritingWindow, _ name: String) throws -> String {
            let file = path(window, "Alpha/\(name)")
            try "o".write(toFile: file, atomically: true, encoding: .utf8)
            return file
        }

        /// Search results on screen, of a stand-in engine that finds `names` in the folder.
        private func searching(_ window: WritingWindow, finding names: [String]) async throws -> FakeSearchEngine {
            let tab = window.tab
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(
                await waitUntil {
                    tab.searchRootPath != nil
                        && names.allSatisfy { name in
                            tab.content.entries.contains { $0.name == name.replacing("/", with: "") }
                        }
                })
            return engine
        }

        // MARK: Copy or move

        // A source that only offers a copy is copied, though the folder is on the same disk.
        @Test func aDragThatOffersOnlyACopyCopiesOnTheSameDisk() async throws {
            let window = try await WritingWindow.open()
            let restore = noKeys()
            defer { restore() }
            let drags = window.tab.dragDrop
            let alpha = try entry(window, "Alpha")
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 101, window: window.tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(drags.contentDragUpdated(drag, entry: alpha) == .copy)
            #expect(drags.contentPerformDrop(drag, entry: alpha))
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // Told by path it would be a copy; the disks say it is a move, into the items' own folder: dropped
        // without a word.
        @Test func aDropThatTurnsOutAMoveIntoTheItemsOwnFolderIsRefusedSilently() async throws {
            let window = try await WritingWindow.open()
            let saved = TabDragDrop.readDiskIds
            defer { TabDragDrop.readDiskIds = saved }
            TabDragDrop.readDiskIds = { $0.map { _ -> Int64? in 1 } }
            let session = try #require(window.tab.writeActions?.session)
            var cards = 0
            let observation = session.observe { event in
                if case .card(let card) = event, card != nil { cards += 1 }
            }
            let target = TabDragDrop.Target(surface: .content, path: "/Volumes", supportsMove: true)
            #expect(
                window.tab.dragDrop.drop(
                    session: external(["/Volumes/Backup"], kind: .directory), target: target, offersMove: true,
                    modifiers: [], sequence: 102))
            try await Task.sleep(for: .milliseconds(100))
            withExtendedLifetime(observation) {}
            #expect(cards == 0)
            #expect(window.recorder.shown.isEmpty)
            #expect(window.tab.notifications?.toasts.entries.isEmpty != false)
            await window.close()
        }

        // MARK: Which targets take it

        // A folder in the Trash, the Trash's row and a folder of the tree in it refuse, nothing moved.
        @Test func theTrashAndWhatIsInItRefuse() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            let trash = FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash"
            let note = path(window, "note.txt")
            let session = external([note])
            let content = try #require(drags.contentTarget(session, entry: try folderEntry(trash + "/Old Folder")))
            func row(_ path: String, _ kind: TreeItemKind) -> SidebarRowState {
                SidebarRowState(
                    item: TreePresentationItem(
                        id: .filesystem(path), kind: kind, label: "x", depth: 1, path: path, parentID: nil,
                        expanded: false, canExpand: true),
                    subview: .tree, selection: .none, menuTarget: false, drop: nil, ejecting: false, dragging: false,
                    dropLine: nil, showsLoading: false, density: .standard, hasDisclosure: true)
            }
            let targets = [
                content,
                try #require(drags.sidebarTarget(row(trash + "/Old Folder", .filesystem))),
                try #require(drags.sidebarTarget(row(trash, .favorite))),
                try #require(drags.sidebarTarget(row(trash, .filesystem))),
            ]
            for target in targets {
                #expect(!target.supportsMove)
                #expect(
                    drags.decide(session, target: target, offersMove: true, modifiers: []).refusal == .invalidTarget)
                #expect(!drags.drop(session: session, target: target, offersMove: true, modifiers: [], sequence: 103))
            }
            // The same row outside the Trash takes it.
            let elsewhere = try #require(drags.sidebarTarget(row(path(window, "Alpha"), .filesystem)))
            #expect(elsewhere.supportsMove)
            #expect(window.exists("note.txt"))
            // An alias of a folder takes nothing.
            let link = try #require(
                drags.contentTarget(session, entry: try folderEntry(path(window, "Link"), kind: "symlink_directory")))
            #expect(!link.supportsMove)
            await window.close()
        }

        // A folder found takes a drag from another app, and the results stay on screen.
        @Test func aFolderFoundTakesADropFromAnotherApp() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let restore = noKeys()
            defer { restore() }
            let source = path(window, "Beta/out.txt")
            try "o".write(toFile: source, atomically: true, encoding: .utf8)
            _ = try await searching(window, finding: ["Alpha/"])
            let alpha = try entry(window, "Alpha")
            let drag = StubDraggingInfo(paths: [source], sequence: 104, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(tab.dragDrop.contentDragUpdated(drag, entry: alpha) == .copy)
            #expect(tab.dragDrop.contentPerformDrop(drag, entry: alpha))
            #expect(await waitUntil { window.exists("Alpha/out.txt") })
            #expect(await waitUntil { !tab.isWriteLocked })
            #expect(tab.searchRootPath != nil)
            tab.search.session.hideResults()
            await window.close()
        }

        // The app's own drag of what was found has nowhere to go among the results.
        @Test func aDragOfResultsCantBeDroppedOnResults() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            _ = try await searching(window, finding: ["note.txt", "Alpha/"])
            _ = tab.dragDrop.automationDragStarted([try entry(window, "note.txt")])
            let own = try #require(TabDragDrop.ownDrag?.session)
            defer { TabDragDrop.ownDrag = nil }
            #expect(own.sourceSurface == .search)
            #expect(tab.dragDrop.contentTarget(own, entry: try entry(window, "Alpha")) == nil)
            #expect(tab.dragDrop.contentTarget(own, entry: nil) == nil)
            tab.search.session.hideResults()
            await window.close()
        }

        // Over a file's row the list takes the folder on screen as the target, and marks
        // nothing; over a folder's row it is that folder.
        @Test func onlyFolderRowsAreTargetsInTheList() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let list = try #require(Views.all(ListTableView.self, in: tab.workspace).first)
            func location(_ name: String) throws -> NSPoint {
                let row = try #require(tab.content.entries.firstIndex { $0.name == name })
                let rect = list.rect(ofRow: row)
                return list.convert(NSPoint(x: rect.minX + 40, y: rect.midY), to: nil)
            }
            var heard: [DirectoryEntry?] = []
            tab.content.dragHooks.dragUpdated = { _, entry in
                heard.append(entry)
                return .copy
            }
            let drag = StubDraggingInfo(
                paths: [path(window, "Beta/x.txt")], at: try location("note.txt"), sequence: 105, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            _ = list.draggingEntered(drag)
            #expect(heard.last.map { $0 == nil } == true)
            drag.draggingLocation = try location("Alpha")
            _ = list.draggingUpdated(drag)
            #expect(heard.last??.name == "Alpha")
            await window.close()
        }

        // The same in the Icons view and the Compact List.
        @Test(arguments: [AppCommand.viewAsIcons, .viewAsList])
        func onlyFolderItemsAreTargetsInTheGrids(_ view: AppCommand) async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, probe) = try await harness.openGrid(view)
            let grid = try #require(probe.grid)
            let pane = try #require(probe.pane)
            func location(_ name: String) throws -> NSPoint {
                let item =
                    view == .viewAsIcons
                    ? try #require(probe.iconItems[name]?.view) : try #require(probe.compactItems[name]?.view)
                let frame = item.frame
                return try #require(item.superview).convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            }
            let drag = StubDraggingInfo(paths: ["/tmp/x.txt"], at: try location("note.txt"), window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(pane.dropEntry(drag) == nil)
            drag.draggingLocation = try location("Alpha")
            #expect(pane.dropEntry(drag)?.name == "Alpha")
            withExtendedLifetime(grid) {}
            await harness.close()
        }

        // MARK: One drag, or the next

        // The drag is read once however long it is held, also when it leaves and comes back.
        @Test func aDragIsReadOnceThoughItLeavesAndComesBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let restore = noKeys()
            defer { restore() }
            let alpha = try entry(window, "Alpha")
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 106, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            #expect(tab.dragDrop.contentDragUpdated(drag, entry: alpha) != [])
            drag.draggingPasteboard.clearContents()
            tab.dragDrop.dragExited()
            #expect(tab.dragDrop.contentDragUpdated(drag, entry: alpha) != [])
            #expect(tab.dragDrop.contentPerformDrop(drag, entry: alpha))
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            await window.close()
        }

        // The next drag is new, whether the last one was seen to leave or not.
        @Test(arguments: [true, false]) func theNextDragIsANewOne(lastOneLeft: Bool) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let restore = noKeys()
            defer { restore() }
            let first = StubDraggingInfo(
                paths: [try fileInAlpha(window, "a.txt")], sequence: 107, window: tab.window)
            let second = StubDraggingInfo(
                paths: [try fileInAlpha(window, "b.txt")], sequence: 108, window: tab.window)
            defer {
                first.draggingPasteboard.releaseGlobally()
                second.draggingPasteboard.releaseGlobally()
            }
            #expect(tab.dragDrop.contentDragUpdated(first, entry: nil) != [])
            if lastOneLeft { tab.dragDrop.dragExited() }
            #expect(tab.dragDrop.contentDragUpdated(second, entry: nil) != [])
            #expect(tab.dragDrop.contentPerformDrop(second, entry: nil))
            #expect(await waitUntil { window.exists("b.txt") })
            #expect(!window.exists("a.txt"))
            await window.close()
        }

        // The window's own drag stays its own when it left the window and came back, without reading the
        // pasteboard, and takes nothing on the folder on screen.
        @Test func theOwnDragStaysItsOwnAcrossLeaving() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            _ = drags.automationDragStarted([try entry(window, "note.txt")])
            let own = try #require(TabDragDrop.ownDrag?.session)
            defer { TabDragDrop.ownDrag = nil }
            let drag = StubDraggingInfo(paths: [path(window, "Beta/other.txt")], sequence: 109, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            drag.draggingSource = FileDragSource(windowNumber: tab.window?.windowNumber ?? 0) { _, _ in }
            #expect(drags.session(for: drag) === own)
            drags.dragExited()
            #expect(drags.session(for: drag) === own)
            #expect(drags.contentDragUpdated(drag, entry: nil) == [])
            await window.close()
        }

        // MARK: Springing

        // Two springs in one drag, then no drop: the tab comes back from the last, its history as it was.
        @Test(arguments: [true, false])
        func twoSpringsComeBackWhenTheDragEndsWithoutADrop(firstArrived: Bool) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let before = tab.historyPaths
            tab.dragDrop.springOpen(path(window, "Alpha"), sequence: 110)
            if firstArrived {
                #expect(await waitUntil { samePath(tab.folder.path, path(window, "Alpha")) && !tab.isNavigating })
            }
            tab.dragDrop.springOpen(path(window, "Beta"), sequence: 110)
            #expect(await waitUntil { samePath(tab.folder.path, path(window, "Beta")) && !tab.isNavigating })
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .none, over: .elsewhere)
            #expect(await waitUntil { samePath(tab.folder.path, start) && tab.historyPaths == before })
            await window.close()
        }

        // The app's own drag holds a folder open: its empty space takes the drop, and the tab stays there.
        @Test func aFolderTheDragSprangIntoTakesItOnItsEmptySpace() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            let alpha = path(window, "Alpha")
            let urls = drags.automationDragStarted([try entry(window, "note.txt")])
            let own = try #require(TabDragDrop.ownDrag?.session)
            #expect(drags.contentTarget(own, entry: nil) == nil)
            drags.springOpen(alpha, sequence: 111)
            #expect(await waitUntil { samePath(tab.folder.path, alpha) && !tab.isNavigating })
            #expect(drags.automationDrop(urls, entry: nil, allowed: [.copy, .move, .generic]))
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            #expect(await waitUntil { !tab.isWriteLocked })
            #expect(samePath(tab.folder.path, alpha))
            await window.close()
        }

        // MARK: Items other apps took away

        // Looked for again after each wait: there at the first look, gone at the second.
        @Test func aMoveFinishedAfterTheDragEndedIsNoticedAtALaterLook() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            let timers = window.manualDragTimers()
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0, 400])
            timers.advance(0.1)
            #expect(tab.services.clipboard.contents.hasItems)
            try FileManager.default.removeItem(atPath: note)
            timers.advance(0.4)
            #expect(!tab.services.clipboard.contents.hasItems)
            await window.close()
        }

        // Only a drag dropped elsewhere with a move or the Dock's Trash may have left its
        // items with another app: nothing is looked for after a copy, a cancel, a drop inside the window or on another
        // window of the app.
        @Test func onlyADragAwayIsLookedFor() {
            let ends: [FileDragEnd] = [.copy, .none, .move, .delete]
            let places: [FileDragEndedOver] = [.elsewhere, .thisWindow, .anotherWindow]
            for end in ends {
                for over in places {
                    #expect(
                        TabDragDrop.looksForDraggedAway(end, over: over)
                            == (over == .elsewhere && (end == .move || end == .delete)), "\(end) \(over)")
                }
            }
        }

        // The drag's end asks that: after a copy, the item gone stays on the clipboard for as long as the looks would go on.
        @Test func nothingIsLookedForAfterADragThatLeftItsItemsAlone() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let timers = window.manualDragTimers()
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.ownDragEnded(paths: [note], operation: .copy, over: .elsewhere)
            timers.advance(120)
            #expect(tab.services.clipboard.contents.sourcePaths == [note])
            await window.close()
        }

        // Dropped elsewhere with a move or the Dock's Trash, the first look finds them gone.
        @Test(arguments: [FileDragEnd.move, .delete]) func aDragAwayIsLookedFor(_ operation: FileDragEnd) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let timers = window.manualDragTimers()
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.ownDragEnded(paths: [note], operation: operation, over: .elsewhere)
            #expect(tab.services.clipboard.contents.hasItems)
            timers.advance(DragTimings.draggedAwayChecksMs[0] / 1000)
            #expect(!tab.services.clipboard.contents.hasItems)
            await window.close()
        }

        // MARK: The tree

        /// The tab's tree rooted on its folder, ready for drags.
        private func tree(_ window: WritingWindow) async throws -> SidebarOutlineView {
            let tab = window.tab
            let model = tab.sidebarController.model
            #expect(await waitUntil { model.nodes[path(window, "Beta")] != nil })
            window.harness.layout(tab)
            return try #require(Views.all(SidebarOutlineView.self, in: tab.workspace).first)
        }

        private func row(_ name: String, _ window: WritingWindow, in tree: SidebarOutlineView) throws -> SidebarRowState
        {
            let list = try #require(tree.list)
            let wanted = path(window, name)
            for index in 0..<tree.numberOfRows {
                if case .item(let state)? = list.row(at: index), state.item.path == wanted { return state }
            }
            Issue.record("no row of \(name)")
            throw CancellationError()
        }

        // Another row takes over the wait: it is that one that opens, not the first.
        @Test func anotherRowTakesOverTheWaitOfTheHold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let tree = try await tree(window)
            let model = tab.sidebarController.model
            let timers = window.manualDragTimers()
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 112, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            _ = tab.dragDrop.sidebarDragUpdated(drag, row: try row("Alpha", window, in: tree))
            let beta = try row("Beta", window, in: tree)
            _ = tab.dragDrop.sidebarDragUpdated(drag, row: beta)
            #expect(tab.sidebarController.dropStates == [path(window, "Beta"): .valid])
            for _ in 0..<10 {
                timers.advance(0.1)
                _ = tab.dragDrop.sidebarDragUpdated(drag, row: beta)
            }
            #expect(await waitUntil { model.nodes[path(window, "Beta")]?.expanded == true })
            #expect(model.nodes[path(window, "Alpha")]?.expanded == false)
            tab.dragDrop.clearTargets()
            await window.close()
        }

        // Held for longer than the wait, a favorite, a location or a link in the tree doesn't open:
        // only a folder of the tree does; each still shows the drop.
        @Test func onlyAFolderOfTheTreeOpensUnderAHold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let tree = try await tree(window)
            let model = tab.sidebarController.model
            let alpha = path(window, "Alpha")
            let timers = window.manualDragTimers()
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 113, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            let real = try row("Alpha", window, in: tree)
            var favorite = real
            favorite.item.kind = .favorite
            var location = real
            location.item.kind = .location
            var link = real
            link.item.isSymlink = true
            var ofAList = real
            ofAList.subview = .favorites
            for row in [favorite, location, link, ofAList] {
                for _ in 0..<9 {
                    _ = tab.dragDrop.sidebarDragUpdated(drag, row: row)
                    #expect(tab.sidebarController.dropStates[alpha] != nil)
                    timers.advance(0.1)
                }
                #expect(model.nodes[alpha]?.expanded == false)
                #expect(model.nodes[alpha]?.loading == false)
            }
            tab.dragDrop.clearTargets()
            await window.close()
        }

        // A row marks whether it would take the drop, with no words, and leaving clears it; a
        // disk keeps its Eject either way.
        @Test func aRowMarksTheDropWithoutWords() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let tree = try await tree(window)
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 114, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            let alpha = path(window, "Alpha")
            let real = try row("Alpha", window, in: tree)
            _ = tab.dragDrop.sidebarDragUpdated(drag, row: real)
            #expect(tab.sidebarController.dropStates == [alpha: .valid])
            var refusing = real
            refusing.item.isSymlink = true
            #expect(tab.dragDrop.sidebarDragUpdated(drag, row: refusing) == [])
            #expect(tab.sidebarController.dropStates == [alpha: .invalid])
            tab.dragDrop.clearTargets()
            #expect(tab.sidebarController.dropStates.isEmpty)

            func cell(_ state: SidebarRowState) -> SidebarItemCell {
                let cell = SidebarItemCell(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
                cell.configure(state, width: 240)
                return cell
            }
            func shows(_ id: String, _ state: SidebarRowState) -> Bool { !findViews(id, in: cell(state)).isEmpty }
            var disk = real
            disk.item.canEject = true
            disk.item.kind = .location
            var valid = disk
            valid.drop = .valid
            var invalid = disk
            invalid.drop = .invalid
            var link = real
            link.item.isSymlink = true
            let linkBadge = findViews("sidebar.row.badge", in: cell(link)).first as? SidebarBadgeView
            #expect(linkBadge?.title == "Alias")
            #expect(shows("sidebar.row.eject", valid))
            #expect(shows("sidebar.row.eject", invalid))
            await window.close()
        }
    }
}
