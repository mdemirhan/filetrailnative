// Ports by feature apps/desktop/src/renderer/components/ContentPane.reveal.test.tsx over the real routes: the folder read
// again, a folder's size coming in, the window resized, the order of results chosen and a refused name
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct LeadStaysInViewTests {
        private func open(
            _ view: RendererCommand, files: Int = 400
        ) async throws -> (ExplorerHarness, MainWindowController, String) {
            let harness = try ExplorerHarness.windowless()
            let path = try harness.makeFolder(named: "Many", files: files).path
            let tab = try await harness.open(path)
            tab.perform(view)
            #expect(await waitUntil { tab.content.entries.count == files && tab.content.pane != nil })
            harness.layout(tab)
            return (harness, tab, path)
        }

        private func scroller(_ tab: MainWindowController) throws -> any RevealScroller {
            try #require(tab.content.pane as? any RevealScroller)
        }

        private func position(of path: String, _ tab: MainWindowController) throws -> Int {
            try #require(tab.content.entries.firstIndex { $0.path == path })
        }

        private func leadIsInView(_ tab: MainWindowController) throws -> Bool {
            let lead = try #require(tab.content.selection.leadPath)
            return try scroller(tab).isInView(index: position(of: lead, tab))
        }

        /// As scrolling by hand does; each view scrolls its own way.
        private func scrollAway(_ view: RendererCommand, _ tab: MainWindowController) {
            tab.content.pane?.scrollPosition = view == .viewAsList ? (top: 0, left: 2_000) : (top: 2_000, left: 0)
        }

        private func add(_ names: [String], to folder: String, _ tab: MainWindowController) async throws {
            let count = tab.content.entries.count
            for name in names {
                try "y".write(
                    toFile: (folder as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            tab.perform(.refreshOrApplySearchSort)
            #expect(await waitUntil { tab.content.entries.count == count + names.count })
        }

        // T-05301e3b F-776 B-SEL-064 B-VIEW-084 B-NAV-161: items come before the lead: where the view is scrolled it would
        // be out of view.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func keepsTheLeadInViewWhenTheListChangesAroundIt(_ view: RendererCommand) async throws {
            let (harness, tab, folder) = try await open(view)
            let lead = tab.content.entries[150].path
            tab.content.select(paths: [lead])
            let before = try scroller(tab).scrollOrigin
            #expect(try leadIsInView(tab))

            try await add((0..<200).map { "a-\($0).txt" }, to: folder, tab)

            #expect(try position(of: lead, tab) == 350)
            #expect(try leadIsInView(tab))
            #expect(try scroller(tab).scrollOrigin != before)
            await harness.close()
        }

        // T-c3144f91 B-SEL-064: a lead the view was scrolled away from doesn't bring the view back.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func staysWhereItWasScrolledWhenAnItemIsAddedAboveALeadOutOfView(_ view: RendererCommand) async throws {
            let (harness, tab, folder) = try await open(view)
            tab.content.select(paths: [tab.content.entries[5].path])
            scrollAway(view, tab)
            let before = try scroller(tab).scrollOrigin
            #expect(try !leadIsInView(tab))

            try await add(["a-new.txt"], to: folder, tab)

            #expect(try scroller(tab).scrollOrigin == before)
            await harness.close()
        }

        // T-643b6df1: a new item is selected before the folder is read again with it.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func bringsANewItemIntoViewOnceTheListHasIt(_ view: RendererCommand) async throws {
            let (harness, tab, folder) = try await open(view)
            let made = (folder as NSString).appendingPathComponent("zz-new.txt")
            tab.content.applySelection(.single(made))
            let before = try scroller(tab).scrollOrigin

            try await add(["zz-new.txt"], to: folder, tab)

            #expect(tab.content.selection.leadPath == made)
            #expect(try leadIsInView(tab))
            #expect(try scroller(tab).scrollOrigin != before)
            await harness.close()
        }

        // T-246c2213 B-NAV-161 B-SEL-064 B-VIEW-084: a folder's size comes in and moves it past the lead, in view or not.
        @Test func followsTheLeadAsSizesReSortTheList() async throws {
            let jobs = FakeJobs()
            let timers = ManualTimers()
            let sizes = WindowFolderSizes(backend: jobs, owner: 1, homePath: "/", scheduler: timers) { [timers] in
                timers.time
            }
            let content = ContentPaneController(mode: .details, folderSizes: sizes, loaders: .placeholder)
            content.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            content.setView(sortBy: .size, direction: .desc, foldersFirst: false, includeHidden: false)
            let folders = (0..<120).map { ContentModelTests.entry(String(format: "folder-%03d", $0), kind: .directory) }
            content.show(folder: "/f", entries: folders, selecting: nil, keepingScroll: false)
            content.view.layoutSubtreeIfNeeded()
            let scroller = try #require(content.pane as? any RevealScroller)
            func comeIn(_ path: String) {
                jobs.nextStart = JobStart(jobId: path, status: .ready)
                jobs.finish(path, path, size: 1_000)
                sizes.calculate(path)
                timers.advance(1)
            }

            // In view, on the last row on screen: a size coming in for a folder further down puts it ahead.
            let lead = content.entries[60].path
            content.select(paths: [lead])
            let before = scroller.scrollOrigin
            #expect(before.y > 0)
            comeIn(content.entries[100].path)
            let moved = try #require(content.entries.firstIndex { $0.path == lead })
            #expect(moved == 61)
            #expect(scroller.isInView(index: moved))
            #expect(scroller.scrollOrigin.y > before.y)

            // Out of view: the list stays where it was scrolled.
            content.pane?.scrollPosition = (top: 0, left: 0)
            comeIn(content.entries[110].path)
            #expect(content.entries.firstIndex { $0.path == lead } == 62)
            #expect(scroller.scrollOrigin == .zero)
        }

        // F-776 B-VIEW-085 B-NAV-162: the pane is made smaller, by the window or a panel: the lead stays on screen.
        @Test func theListKeepsTheLeadInViewOnAResize() async throws {
            let (harness, tab, _) = try await open(.viewAsDetails)
            tab.content.select(paths: [tab.content.entries[150].path])
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.frame.width, height: window.frame.height - 200))
            harness.layout(tab)
            #expect(try leadIsInView(tab))
            tab.perform(.toggleInfoRow)
            harness.layout(tab)
            #expect(try leadIsInView(tab))
            await harness.close()
        }

        // F-776 B-VIEW-085 B-NAV-162: rows of another height move the lead away.
        @Test func theListKeepsTheLeadInViewOnADensityChange() async throws {
            let (harness, tab, _) = try await open(.viewAsDetails)
            tab.updatePreferences(["compactDetailsView": .bool(true)])
            tab.refreshColumns()
            harness.layout(tab)
            tab.content.select(paths: [tab.content.entries[150].path])
            tab.updatePreferences(["compactDetailsView": .bool(false)])
            tab.refreshColumns()
            #expect(try leadIsInView(tab))
            scrollAway(.viewAsDetails, tab)
            let away = try scroller(tab).scrollOrigin
            tab.updatePreferences(["compactDetailsView": .bool(true)])
            tab.refreshColumns()
            #expect(try scroller(tab).scrollOrigin == away)
            await harness.close()
        }

        // T-8ab8cdc7: scrolled away since: the view stays where it was scrolled.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func staysWhereItWasScrolledWhenTheWindowIsResized(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            tab.content.select(paths: [tab.content.entries[5].path])
            scrollAway(view, tab)
            let before = try scroller(tab).scrollOrigin
            let window = try #require(tab.window)
            window.setContentSize(NSSize(width: window.frame.width + 100, height: window.frame.height))
            harness.layout(tab)
            #expect(try scroller(tab).scrollOrigin == before)
            await harness.close()
        }

        // T-03a4c1d0 B-NAV-160 B-SEL-063: the first result goes last when the order of the results is turned around.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func aNewOrderOfResultsBringsTheLeadIntoView(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(.viewAsDetails)
            let names = tab.content.entries.map(\.name)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "item"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.search != nil && tab.content.entries.count == names.count })
            tab.perform(view)
            harness.layout(tab)
            let lead = tab.content.entries[0].path
            tab.content.select(paths: [lead])
            let before = try scroller(tab).scrollOrigin

            // By name first, which is the order they are in, and then the other way.
            tab.content.search?.requestSort(.name)
            tab.content.search?.requestSort(.name)

            #expect(await waitUntil { tab.content.entries.first?.path != lead })
            #expect(tab.content.selection.leadPath == lead)
            #expect(try position(of: lead, tab) == names.count - 1)
            #expect(try leadIsInView(tab))
            #expect(try scroller(tab).scrollOrigin != before)
            await harness.close()
        }

        // B-VIEW-092 B-SEL-066: the item being renamed, and a refused name, come into view in the List and the Icons view;
        // the Compact List follows only the lead (ContentPane.tsx:1236).
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func theItemBeingRenamedIsBroughtIntoViewButNotInTheCompactList(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            let taken = tab.content.entries[6].name
            tab.content.select(paths: [tab.content.entries[5].path])
            let renamed = tab.content.entries[150].path
            let index = try position(of: renamed, tab)

            #expect(tab.content.beginRename(path: renamed))
            #expect(try scroller(tab).isInView(index: index) == (view != .viewAsList))

            tab.content.pane?.scrollPosition = (top: 0, left: 0)
            tab.content.renameSubmitted(taken)
            #expect(await waitUntil { tab.content.inlineRename?.error != nil })
            #expect(try scroller(tab).isInView(index: index) == (view != .viewAsList))
            await harness.close()
        }

        // B-SEL-134: the explanation of a refused name stays under the field when the window changes size.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsIcons])
        func theRenameErrorBoxFollowsItsFieldWhenTheWindowResizes(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            let taken = tab.content.entries[6].name
            #expect(tab.content.beginRename(path: tab.content.entries[5].path))
            tab.content.renameSubmitted(taken)
            #expect(await waitUntil { tab.content.inlineRename?.error != nil })
            let host = try #require(tab.window?.contentView)
            let box = try #require(findViews("rename.error", in: host).first)
            let field = try #require(findViews("rename.field", in: host).first)
            func gap() -> CGFloat {
                let frame = host.convert(field.bounds, from: field)
                return host.isFlipped ? box.frame.minY - frame.maxY : frame.minY - box.frame.maxY
            }
            #expect(abs(gap() - CGFloat(SelectionLayout.Rename.errorGap)) < 1)
            let size = host.frame.size
            tab.window?.setContentSize(NSSize(width: size.width + 120, height: size.height + 120))
            harness.layout(tab)
            #expect(!box.isHidden)
            #expect(abs(gap() - CGFloat(SelectionLayout.Rename.errorGap)) < 1)
            await harness.close()
        }

        // B-VIEW-081: the wheel scrolls the list during a marquee, and the box follows.
        // (A list long enough to scroll has no empty space to start one in; Icons has its margins.)
        @Test(.windowlessAlone) func theWheelScrollsDuringAMarquee() async throws {
            let (harness, tab, _) = try await open(.viewAsIcons)
            let window = try #require(tab.window)
            let grid = try #require(tab.content.pane as? ItemGridPane)
            let surface: NSView = grid.collection
            let first = grid.collection.frameForItem(at: 0)
            let start = surface.convert(NSPoint(x: first.midX, y: max(0, first.minY - 1)), to: nil)
            let wheel = try #require(
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0))
            let end = NSPoint(x: start.x, y: start.y - 20)
            var queue = [
                try #require(MouseEvents.event(.leftMouseDragged, at: end, in: window)),
                try #require(NSEvent(cgEvent: wheel)),
                try #require(MouseEvents.event(.leftMouseUp, at: end, in: window)),
            ]
            let original = PointerTracker.source
            defer { PointerTracker.source = original }
            // As the window's queue does: an event of a kind not asked for never arrives.
            PointerTracker.source = { _, mask, _ in
                while !queue.isEmpty {
                    let next = queue.removeFirst()
                    if mask.contains(NSEvent.EventTypeMask(rawValue: 1 << next.type.rawValue)) { return next }
                }
                return nil
            }
            let before = grid.scrollPosition.top
            surface.mouseDown(with: try #require(MouseEvents.event(.leftMouseDown, at: start, in: window)))
            #expect(grid.scrollPosition.top > before)
            await harness.close()
        }

        // The item to show stays the same when the lead's name starts being edited: a lead scrolled away stays away.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func renamingALeadScrolledAwayLeavesTheViewWhereItIs(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            tab.content.select(paths: [tab.content.entries[5].path])
            scrollAway(view, tab)
            let away = try scroller(tab).scrollOrigin
            tab.renameSelected()
            #expect(tab.content.inlineRename != nil)
            #expect(try scroller(tab).scrollOrigin == away)
            tab.content.renameCancelled()
            #expect(try scroller(tab).scrollOrigin == away)
            await harness.close()
        }

        // B-SEL-064 B-CLIP-140: what a paste made is selected with its last item as the lead, and that is what ends up in
        // view, however far from the first item it is (useExplorerNavigationController.ts:942-950).
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func aSelectionOfItemsFarApartShowsTheLead(_ view: RendererCommand) async throws {
            let (harness, tab, folder) = try await open(view)
            let picked = [tab.content.entries[5].path, tab.content.entries[300].path]
            tab.content.show(folder: folder, entries: tab.content.entries, selecting: picked, keepingScroll: true)
            #expect(tab.content.selection.leadPath == picked[1])
            #expect(try leadIsInView(tab))
            await harness.close()
        }

        // B-SEL-064 B-CLIP-140: the same by the route a write ends on.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func aWriteEndingWithItemsFarApartShowsTheLead(_ view: RendererCommand) async throws {
            let (harness, tab, folder) = try await open(view)
            let picked = [tab.content.entries[5].path, tab.content.entries[300].path]
            tab.applyWriteEnd(
                WriteEndRefresh(path: folder, selecting: picked, treeSelectionPath: nil, treeReloadPaths: []))
            #expect(await waitUntil { tab.content.selection.leadPath == picked[1] })
            #expect(try leadIsInView(tab))
            await harness.close()
        }

        // B-VIEW-083: results that arrive ahead of the lead, as a search goes on, leave it in view.
        @Test func resultsArrivingAheadOfTheLeadKeepItInView() async throws {
            let (harness, tab, _) = try await open(.viewAsDetails)
            let names = tab.content.entries.map(\.name)
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, true, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "item"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.search != nil && tab.content.entries.count == names.count })
            harness.layout(tab)
            tab.content.search?.requestSort(.name)
            let lead = tab.content.entries[200].path
            tab.content.select(paths: [lead])
            #expect(try leadIsInView(tab))

            let job = try #require(engine.jobs.keys.first)
            engine.progress(job, add: (0..<60).map { String(format: "!first-%02d", $0) })
            #expect(
                await waitUntil {
                    timers.advance(1)
                    return tab.content.entries.count == names.count + 60
                })
            #expect(try position(of: lead, tab) == 260)
            #expect(try leadIsInView(tab))
            await harness.close()
        }

        // B-NAV-140 B-SEL-026: what a write took away leaves the selection before the read comes in, keeping its place.
        @Test func itemsAWriteTookAwayLeaveTheSelectionAtOnce() async throws {
            let (harness, tab, _) = try await open(.viewAsDetails, files: 10)
            let gone = tab.content.entries[3].path
            tab.content.select(paths: [gone])
            try FileManager.default.removeItem(atPath: gone)
            tab.services.directoryService.cache.clear()
            tab.applyWriteEnd(
                WriteEndRefresh(
                    path: tab.folder.path, selecting: nil, treeSelectionPath: nil, treeReloadPaths: [],
                    leftPaths: [gone]))
            #expect(tab.content.selection.isEmpty)
            #expect(tab.content.selection.gapIndex == 3)
            #expect(await waitUntil { tab.content.entries.count == 9 })
            #expect(tab.content.selection.gapIndex == 3)
            await harness.close()
        }

        // A read begun before a write ended can land first, with the old listing: what the write made is still selected
        // when the read asked for comes in.
        @Test func aReadOlderThanTheWriteLeavesItsSelectionWaiting() async throws {
            let (harness, tab, _) = try await open(.viewAsDetails, files: 10)
            let folder = NodePath.dirname(tab.content.entries[0].path)
            let made = folder + "/made.txt"
            var created = false
            // Heard before the write's own observer: the old read has come in, and then the file is made.
            let token = tab.observe { change in
                guard change == .folder, !created else { return }
                created = true
                FileManager.default.createFile(atPath: made, contents: Data())
                tab.services.directoryService.cache.clear()
            }
            defer { withExtendedLifetime(token) {} }
            tab.reload()
            tab.applyWriteEnd(
                WriteEndRefresh(path: tab.folder.path, selecting: [made], treeSelectionPath: nil, treeReloadPaths: []))
            #expect(await waitUntil { tab.content.selection.leadPath == made })
            await harness.close()
        }

        // B-SEL-064 B-NAV-161: the same lead selected again asks for nothing: a lead scrolled away stays away.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func selectingTheLeadAgainLeavesTheViewWhereItWasScrolled(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            let lead = tab.content.entries[5].path
            tab.content.select(paths: [lead])
            scrollAway(view, tab)
            let before = try scroller(tab).scrollOrigin
            tab.content.select(paths: [lead])
            tab.content.applySelection(.single(lead))
            #expect(try scroller(tab).scrollOrigin == before)
            await harness.close()
        }

        // B-SEL-064 B-NAV-161: the whole list coming back is a change of the list: a lead scrolled away stays away.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func clearingTheFilterLeavesALeadScrolledAwayAlone(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            tab.content.setFilter("1")
            #expect(await waitUntil { tab.content.entries.count < 400 && tab.content.entries.count > 50 })
            harness.layout(tab)
            tab.content.select(paths: [tab.content.entries[1].path])
            tab.content.pane?.scrollPosition = view == .viewAsList ? (top: 0, left: 1_500) : (top: 1_500, left: 0)
            let before = try scroller(tab).scrollOrigin
            #expect(try !leadIsInView(tab))
            tab.content.applyFilterKey(.clear)
            #expect(tab.content.filter.isEmpty)
            #expect(try scroller(tab).scrollOrigin == before)
            await harness.close()
        }

        // B-SEL-064 B-NAV-161: a lead in view moves with the list and stays in view.
        @Test(arguments: [RendererCommand.viewAsDetails, .viewAsList, .viewAsIcons])
        func clearingTheFilterKeepsALeadInViewInView(_ view: RendererCommand) async throws {
            let (harness, tab, _) = try await open(view)
            tab.content.setFilter("1")
            #expect(await waitUntil { tab.content.entries.count < 400 && tab.content.entries.count > 50 })
            harness.layout(tab)
            tab.content.select(paths: [tab.content.entries[30].path])
            #expect(try leadIsInView(tab))
            tab.content.applyFilterKey(.clear)
            #expect(tab.content.entries.count == 400)
            #expect(try leadIsInView(tab))
            await harness.close()
        }
    }
}
