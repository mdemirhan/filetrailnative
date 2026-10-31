// Port by feature of the remaining cases of App.dragIn.test.tsx, App.dragOut.test.tsx, the drag cases of
// App.fileOperations.test.tsx and App.search.test.tsx, and of entryItemEvents.ts and TreePane.rows.test.tsx: drags over
// the list, the grid and the tree of a window that is never shown, through AppKit's dragging callbacks, with the app's real
// file operations on a temporary folder
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct DragDropMatrixTests {
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

        private func folderEntry(_ path: String) throws -> DirectoryEntry {
            let json = """
                {"path":"\(path)","name":"\((path as NSString).lastPathComponent)","fileExtension":"",
                "kind":"directory","isHidden":false,"isSymlink":false}
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

        // T-2f7441b1: a source that only offers a copy is copied, though the folder is on the same disk.
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

        // T-9f4c86f0: told by path it would be a copy; the disks say it is a move, into the items' own folder: dropped
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
            try await Task.sleep(for: .milliseconds(300))
            withExtendedLifetime(observation) {}
            #expect(cards == 0)
            #expect(window.recorder.shown.isEmpty)
            #expect(window.tab.notifications?.toasts.entries.isEmpty != false)
            await window.close()
        }

        // MARK: Which targets take it

        // T-c89e355a B-CLIP-156: a folder in the Trash, the Trash's row and a folder of the tree in it refuse, nothing moved.
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
                    dropLine: nil, showsLoading: false, density: .comfortable, hasDisclosure: true)
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
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // T-87626198 B-CLIP-156: a folder found takes a drag from another app, and the results stay on screen.
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

        // T-576bf206 B-CLIP-156: the app's own drag of what was found has nowhere to go among the results.
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

        // B-SEL-019 T-4650adf5 T-b2112746: over a file's row the list takes the folder on screen as the target, and marks
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

        // T-6708b721 B-SEL-019: the same in the Icons view and the Compact List.
        @Test(arguments: [RendererCommand.viewAsIcons, .viewAsList])
        func onlyFolderItemsAreTargetsInTheGrids(_ view: RendererCommand) async throws {
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

        // T-301b8787 T-8c07cc75: the drag is read once however long it is held, also when it leaves and comes back.
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

        // T-41ce0b22 T-752d0402: the next drag is new, whether the last one was seen to leave or not.
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

        // T-f4a1c03a: the window's own drag stays its own when it left the window and came back, without reading the
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

        // T-13d47c59: two springs in one drag, then no drop: the tab comes back from the last, its history as it was.
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

        // T-cddc04fe: the app's own drag holds a folder open: its empty space takes the drop, and the tab stays there.
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

        // T-0914189a B-CLIP-165: looked for again after each wait: there at the first look, gone at the second.
        @Test func aMoveFinishedAfterTheDragEndedIsNoticedAtALaterLook() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            tab.dragDrop.checkDraggedAway([note], intoTrash: false, after: [0, 400])
            try await Task.sleep(for: .milliseconds(100))
            #expect(tab.services.clipboard.contents.hasItems)
            try FileManager.default.removeItem(atPath: note)
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        // T-f76a912e T-687aafe3 B-CLIP-165: nothing is looked for after a copy, a cancel, a drop inside the
        // window or on another window of the app.
        @Test(arguments: [
            (FileDragEnd.copy, FileDragEndedOver.elsewhere), (.none, .elsewhere), (.move, .thisWindow),
            (.move, .anotherWindow), (.delete, .thisWindow),
        ])
        func nothingIsLookedForAfterADragThatLeftItsItemsAlone(
            _ operation: FileDragEnd, _ over: FileDragEndedOver
        ) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.ownDragEnded(paths: [note], operation: operation, over: over)
            try await Task.sleep(for: .milliseconds(450))
            #expect(tab.services.clipboard.contents.sourcePaths == [note])
            await window.close()
        }

        // B-CLIP-165: dropped elsewhere with a move or the Dock's Trash, the first look finds them
        // gone; the looks come at the waits the original has.
        @Test(arguments: [FileDragEnd.move, .delete]) func aDragAwayIsLookedFor(_ operation: FileDragEnd) async throws {
            #expect(DragTimings.draggedAwayChecksMs == [250, 1000, 3000, 6000, 10000, 15000, 25000])
            let window = try await WritingWindow.open()
            let tab = window.tab
            let note = path(window, "note.txt")
            tab.services.clipboard.set(ClipboardRules.set(.copy, [note], capturedAt: "t"), from: nil)
            try FileManager.default.removeItem(atPath: note)
            tab.dragDrop.ownDragEnded(paths: [note], operation: operation, over: .elsewhere)
            #expect(await waitUntil { !tab.services.clipboard.contents.hasItems })
            await window.close()
        }

        // MARK: The tree

        /// The tab's tree rooted on its folder, ready for drags.
        private func tree(_ window: WritingWindow) async throws -> SidebarOutlineView {
            let tab = window.tab
            let model = tab.sidebarController.model
            model.rootTree(at: window.folder.path)
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

        // B-CLIP-171 B-TREE-161: another row takes over the wait: it is that one that opens, not the first.
        @Test func anotherRowTakesOverTheWaitOfTheHold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let tree = try await tree(window)
            let model = tab.sidebarController.model
            let drag = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 112, window: tab.window)
            defer { drag.draggingPasteboard.releaseGlobally() }
            _ = tab.dragDrop.sidebarDragUpdated(drag, row: try row("Alpha", window, in: tree))
            let beta = try row("Beta", window, in: tree)
            _ = tab.dragDrop.sidebarDragUpdated(drag, row: beta)
            #expect(tab.sidebarController.dropStates == [path(window, "Beta"): .valid])
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                _ = tab.dragDrop.sidebarDragUpdated(drag, row: beta)
            }
            #expect(await waitUntil { model.nodes[path(window, "Beta")]?.expanded == true })
            #expect(model.nodes[path(window, "Alpha")]?.expanded == false)
            tab.dragDrop.clearTargets()
            await window.close()
        }

        // B-CLIP-171 B-TREE-161: held for longer than the wait, a favorite, a location or a link in the tree doesn't open:
        // only a folder of the tree does; each still shows the drop.
        @Test func onlyAFolderOfTheTreeOpensUnderAHold() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let tree = try await tree(window)
            let model = tab.sidebarController.model
            let alpha = path(window, "Alpha")
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
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(model.nodes[alpha]?.expanded == false)
                #expect(model.nodes[alpha]?.loading == false)
            }
            tab.dragDrop.clearTargets()
            await window.close()
        }

        // T-e1dbe49b B-TREE-158: a row that would take the drop shows "Drop here", one refusing shows no badge, leaving
        // clears it; a disk's Eject makes way for the badge.
        @Test func aRowThatTakesTheDropShowsTheBadge() async throws {
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
            #expect(shows("sidebar.row.dropBadge", valid))
            let pill = findViews("sidebar.row.dropBadge", in: cell(valid)).first as? SidebarBadgeView
            #expect(pill?.title == "Drop here")
            var link = real
            link.item.isSymlink = true
            let linkBadge = findViews("sidebar.row.badge", in: cell(link)).first as? SidebarBadgeView
            #expect(linkBadge?.title == "Alias")
            #expect(!shows("sidebar.row.dropBadge", invalid))
            #expect(!shows("sidebar.row.dropBadge", disk))
            #expect(!shows("sidebar.row.eject", valid))
            #expect(shows("sidebar.row.eject", invalid))
            await window.close()
        }
    }
}
