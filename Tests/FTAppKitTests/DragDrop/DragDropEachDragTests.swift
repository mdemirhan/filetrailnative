// Port by feature of App.dragIn.test.tsx and App.dragOut.test.tsx (useExplorerDragAndDrop's clearDragSession,
// settleSprings, springWhenHeld and the drop's destination check; App.tsx's startFileDrag and external drop focus):
// what each drag asks again, where it springs and what it leaves behind, on a window that is never shown
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite(.windowlessAlone) struct DragDropEachDragTests {
        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        private func external(_ paths: [String]) -> DragSession {
            DragSession(
                sourceSurface: .external, sourceItems: paths.map { DragItem(path: $0, kind: .file) },
                leadPath: paths[0], leadKind: .file)
        }

        // B-CLIP-162: the disks are asked again for each drag; an earlier drag's answer decides nothing.
        @Test func eachDragAsksTheDisksAgain() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let saved = TabDragDrop.readDiskIds
            defer { TabDragDrop.readDiskIds = saved }
            let alpha = path(window, "Alpha")
            let note = path(window, "note.txt")
            TabDragDrop.readDiskIds = { $0.map { _ -> Int64? in 1 } }
            let first = external([note])
            _ = drags.onSameDisk(first, alpha)
            #expect(await waitUntil { drags.onSameDisk(first, alpha) == true })
            drags.clearTargets()
            // Another disk is at Alpha's path now.
            TabDragDrop.readDiskIds = { paths in paths.map { $0 == alpha ? Int64?(2) : Int64?(1) } }
            let second = external([note])
            _ = drags.onSameDisk(second, alpha)
            #expect(await waitUntil { drags.onSameDisk(second, alpha) == false })
            await window.close()
        }

        // B-CLIP-162: a path no disk could read in one drag is asked about again in the next, which then moves.
        // T-62d562b1
        @Test func aDiskThatCouldntBeReadIsAskedAgain() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let saved = TabDragDrop.readDiskIds
            defer { TabDragDrop.readDiskIds = saved }
            let alpha = path(window, "Alpha")
            let note = path(window, "note.txt")
            let target = TabDragDrop.Target(surface: .content, path: alpha, supportsMove: true)
            TabDragDrop.readDiskIds = { $0.map { _ in nil } }
            #expect(drags.drop(session: external([note]), target: target, offersMove: true, modifiers: [], sequence: 1))
            #expect(await waitUntil { window.recorder.shown.first?.title == "Couldn\u{2019}t Drop" })
            TabDragDrop.readDiskIds = { $0.map { _ -> Int64? in 1 } }
            #expect(drags.drop(session: external([note]), target: target, offersMove: true, modifiers: [], sequence: 2))
            #expect(await waitUntil { window.exists("Alpha/note.txt") && !window.exists("note.txt") })
            await window.close()
        }

        // B-CLIP-166: while the tab shows search results nothing springs open, not even under a drag from another app.
        // B-CLIP-168 B-NAV-214 B-SRCH-146
        @Test func nothingSpringsInSearchResults() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            let session = external([path(window, "note.txt")])
            let target = try #require(drags.contentTarget(session, entry: alpha))
            #expect(drags.canSpring(session, into: alpha, target: target, refusal: nil))
            tab.searchRootPath = window.folder.path
            defer { tab.searchRootPath = nil }
            let inResults = try #require(drags.contentTarget(session, entry: alpha))
            #expect(!drags.canSpring(session, into: alpha, target: inResults, refusal: nil))
            await window.close()
        }

        // B-VIEW-075: a drag from another app over search results has no background to go into: no ring and no drop on
        // the empty space or on a file's row, while a folder of the results still takes it.
        @Test func searchResultsTakeNoBackgroundDrops() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let drags = tab.dragDrop
            let inner = path(window, "Alpha/outside.txt")
            try "o".write(toFile: inner, atomically: true, encoding: .utf8)
            let drag = StubDraggingInfo(paths: [inner], window: tab.window)
            #expect(drags.contentDragUpdated(drag, entry: nil) != [])
            #expect(!tab.content.container.dropRing.isHidden)
            tab.searchRootPath = window.folder.path
            defer { tab.searchRootPath = nil }
            #expect(drags.contentDragUpdated(drag, entry: nil) == [])
            #expect(tab.content.container.dropRing.isHidden)
            #expect(!drags.contentPerformDrop(drag, entry: nil))
            #expect(window.exists("Alpha/outside.txt") && !window.exists("outside.txt"))
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            #expect(drags.contentTarget(external([inner]), entry: alpha) != nil)
            await window.close()
        }

        // B-CLIP-169: the app's own drag that sprang a folder open and was dropped on another window brings the tab
        // back to where the drag started.
        @Test func aDropOnAnotherWindowBringsTheSprungTabBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            tab.dragDrop.springOpen(path(window, "Alpha"), sequence: 9)
            #expect(await waitUntil { samePath(tab.folder.path, path(window, "Alpha")) })
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .anotherWindow)
            #expect(await waitUntil { samePath(tab.folder.path, start) })
            await window.close()
        }

        // B-CLIP-169: the tab comes back history and all: the Forward steps the springs cut are there again, and the
        // sprung folders are not.
        // B-NAV-198 T-de734148
        @Test func aSprungDragBringsTheHistoryBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let alpha = path(window, "Alpha")
            await tab.navigate(to: URL(fileURLWithPath: alpha))
            tab.perform(.goBack)
            #expect(await waitUntil { samePath(tab.folder.path, start) && !tab.isNavigating })
            let before = tab.historyPaths
            #expect(tab.canGoForward)
            tab.dragDrop.springOpen(path(window, "Beta"), sequence: 9)
            #expect(await waitUntil { samePath(tab.folder.path, path(window, "Beta")) })
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .elsewhere)
            #expect(await waitUntil { samePath(tab.folder.path, start) && tab.historyPaths == before })
            #expect(tab.historyIndex == 0)
            #expect(tab.navigationHistory.forwardTarget == before[1])
            await window.close()
        }

        // B-CLIP-169: the sidebar's row comes back too: a favorite stays selected, not the tree's row of its folder.
        // B-NAV-198 T-bb5a1863
        @Test func aSprungDragBringsTheSidebarRowBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let model = tab.sidebarController.model
            model.selectItem(.favorite(start))
            #expect(await waitUntil { model.selected == .favorite(start) && !tab.isNavigating })
            let alpha = path(window, "Alpha")
            tab.dragDrop.springOpen(alpha, sequence: 9)
            #expect(await waitUntil { samePath(tab.folder.path, alpha) && model.selected == .filesystem(alpha) })
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .elsewhere)
            #expect(await waitUntil { samePath(tab.folder.path, start) && model.selected == .favorite(start) })
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.selected == .favorite(start))
            await window.close()
        }

        // useExplorerDragAndDrop.ts:936: a drag from another app that sprang a folder open and went away (its drag-overs
        // stopped) brings the tab back too.
        // B-CLIP-174 T-df38568f
        @Test func anExternalDragThatWentAwayBringsTheSprungTabBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let alpha = path(window, "Alpha")
            let info = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 77, window: tab.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            _ = tab.dragDrop.contentDragUpdated(info, entry: nil)
            tab.dragDrop.springOpen(alpha, sequence: 77)
            #expect(await waitUntil { samePath(tab.folder.path, alpha) })
            #expect(await waitUntil { samePath(tab.folder.path, start) && tab.historyPaths == [start] })
            await window.close()
        }

        // useExplorerDragAndDrop.ts:363, :929: drags from other apps are seen by the whole window, so one resting where no
        // target hears it (the path bar, the toolbar, the Info panel) keeps the tab in the sprung folder until it goes.
        // B-CLIP-174 T-df38568f
        @Test func anExternalDragHeldOverTheRestOfTheWindowKeepsTheSprungTabThere() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let alpha = path(window, "Alpha")
            let saved = TabDragDrop.dragIsHeldOver
            defer { TabDragDrop.dragIsHeldOver = saved }
            var held = true
            TabDragDrop.dragIsHeldOver = { $0 === tab.window && held }
            let info = StubDraggingInfo(paths: [path(window, "note.txt")], sequence: 78, window: tab.window)
            defer { info.draggingPasteboard.releaseGlobally() }
            _ = tab.dragDrop.contentDragUpdated(info, entry: nil)
            tab.dragDrop.springOpen(alpha, sequence: 78)
            #expect(await waitUntil { samePath(tab.folder.path, alpha) })
            try await Task.sleep(for: .milliseconds(1000))
            #expect(samePath(tab.folder.path, alpha))
            held = false
            #expect(await waitUntil { samePath(tab.folder.path, start) && tab.historyPaths == [start] })
            await window.close()
        }

        // useExplorerDragAndDrop.ts:1315: where the tab was is noted first, to come back to even if the drag ends before
        // the folder is on screen: the read still pending is overtaken, whether or not it has begun.
        @Test(arguments: [false, true])
        func aDragThatEndsBeforeTheSprungFolderArrivesLeavesTheTabWhereItWas(readBegan: Bool) async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let before = tab.historyPaths
            tab.dragDrop.springOpen(path(window, "Alpha"), sequence: 9)
            if readBegan { await Task.yield() }
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .elsewhere)
            try await Task.sleep(for: .milliseconds(500))
            #expect(await waitUntil { !tab.isNavigating })
            #expect(samePath(tab.folder.path, start))
            #expect(tab.historyPaths == before)
            await window.close()
        }

        // useExplorerDragAndDrop.ts:1341: a sprung folder that can't be read leaves the tab where it was, with nothing
        // to bring back.
        @Test func aFolderOnScreenTakesTheDragOnlyOnceItsSpringArrived() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let own = TabDragDrop.OwnDrag(
                session: DragSession(
                    sourceSurface: .content, sourceItems: [DragItem(path: path(window, "note.txt"), kind: .file)],
                    leadPath: path(window, "note.txt"), leadKind: .file),
                windowNumber: 0, tab: tab)
            TabDragDrop.ownDrag = own
            defer { TabDragDrop.ownDrag = nil }
            // T-5de0804d: one that couldn't be read leaves the folder there, which an Option-drop would duplicate into.
            tab.dragDrop.springOpen(path(window, "gone"), sequence: 9)
            #expect(tab.dragDrop.contentTarget(own.session, entry: nil) == nil)
            #expect(await waitUntil { !tab.isNavigating })
            try await Task.sleep(for: .milliseconds(50))
            #expect(tab.dragDrop.contentTarget(own.session, entry: nil) == nil)
            // One that opens takes it, and still does after a later one fails.
            tab.dragDrop.springOpen(path(window, "Alpha"), sequence: 9)
            #expect(await waitUntil { tab.dragDrop.contentTarget(own.session, entry: nil) != nil })
            tab.dragDrop.springOpen(path(window, "gone"), sequence: 9)
            #expect(await waitUntil { !tab.isNavigating })
            try await Task.sleep(for: .milliseconds(50))
            #expect(tab.dragDrop.contentTarget(own.session, entry: nil) != nil)
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .elsewhere)
            await window.close()
        }

        // T-9c4c006c: a question about a drop brings forward a window that isn't in front, in another app or this one.
        @Test func aWindowInFrontOfAnActiveAppIsTheOnlyOneLeftWhereItIs() {
            #expect(!TabDragDrop.needsBringingForward(appActive: true, windowIsKey: true))
            #expect(TabDragDrop.needsBringingForward(appActive: true, windowIsKey: false))
            #expect(TabDragDrop.needsBringingForward(appActive: false, windowIsKey: true))
            #expect(TabDragDrop.needsBringingForward(appActive: false, windowIsKey: false))
        }

        @Test func aSpringThatCouldntOpenBringsNothingBack() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let start = tab.folder.path
            let before = tab.historyPaths
            tab.dragDrop.springOpen(path(window, "gone"), sequence: 9)
            #expect(await waitUntil { !tab.isNavigating })
            try await Task.sleep(for: .milliseconds(50))
            #expect(samePath(tab.folder.path, start))
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .move, over: .elsewhere)
            try await Task.sleep(for: .milliseconds(100))
            #expect(samePath(tab.folder.path, start))
            #expect(tab.historyPaths == before)
            await window.close()
        }

        // B-CLIP-169: one dropped in the folder it sprang into keeps the tab there.
        // T-58f2b940
        @Test func aDropInTheSprungFolderKeepsTheTabThere() async throws {
            let window = try await WritingWindow.open()
            let tab = window.tab
            let alpha = path(window, "Alpha")
            tab.dragDrop.springOpen(alpha, sequence: 9)
            #expect(await waitUntil { samePath(tab.folder.path, alpha) })
            let target = TabDragDrop.Target(surface: .content, path: alpha, supportsMove: true)
            let session = external([path(window, "note.txt")])
            #expect(
                tab.dragDrop.drop(session: session, target: target, offersMove: true, modifiers: [.option], sequence: 9)
            )
            tab.dragDrop.ownDragEnded(paths: [path(window, "note.txt")], operation: .copy, over: .thisWindow)
            #expect(await waitUntil { window.exists("Alpha/note.txt") })
            #expect(samePath(tab.folder.path, alpha))
            await window.close()
        }

        // B-TREE-159: a drop on a favorite that is a link to a folder is refused, as the destination check of every
        // drop refuses one (an accepted risk: the favorite showed the drop as taken). Nothing is moved.
        // T-0f30452a T-26eb6e20 T-89efd829
        @Test func aDropOnAFavoriteThatIsALinkToAFolderIsRefused() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let link = window.folder.appendingPathComponent("BetaLink")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: window.folder.appendingPathComponent("Beta"))
            let note = path(window, "note.txt")
            let target = TabDragDrop.Target(
                surface: .favorite, path: link.path, supportsMove: true, selectsInTree: true)
            _ = drags.drop(
                session: external([note]), target: target, offersMove: true, modifiers: [.command], sequence: 7)
            #expect(await waitUntil { !window.recorder.shown.isEmpty })
            #expect(window.recorder.shown.first?.message == "Destination must be an existing folder.")
            #expect(window.exists("note.txt"))
            #expect(!window.exists("Beta/note.txt"))
            await window.close()
        }

        // B-CLIP-178: an error about a drop from another app, found before it starts, brings the window forward.
        @Test func aDropRefusedBeforeItStartsBringsTheWindowForward() async throws {
            let window = try await WritingWindow.open()
            let drags = window.tab.dragDrop
            let saved = TabDragDrop.bringForward
            var broughtForward = 0
            TabDragDrop.bringForward = { _ in broughtForward += 1 }
            defer { TabDragDrop.bringForward = saved }
            let locked = window.folder.appendingPathComponent("locked.txt")
            try "x".write(to: locked, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
            let target = TabDragDrop.Target(surface: .content, path: path(window, "Beta"), supportsMove: true)
            #expect(
                drags.drop(
                    session: external([locked.path]), target: target, offersMove: true, modifiers: [.option],
                    sequence: 3))
            #expect(await waitUntil { broughtForward == 1 })
            // The failed copy's result sheet (P6-02) tells it.
            let sheet = CopyPasteResultPresenter.shared.sheet
            #expect(sheet?.window === window.tab.window)
            #expect(sheet?.text.title == "Copied 0 of 1 item into \u{201C}Beta\u{201D}")
            await window.close()
        }

        // B-CLIP-178: a drop from another app that started is still in flight: the question it runs into and the
        // result sheet it ends with bring the window forward; another operation's don't, nor a quiet end.
        @Test func aQueuedDropsQuestionAndResultBringTheWindowForward() async throws {
            let window = try await WritingWindow.open()
            let saved = TabDragDrop.bringForward
            var broughtForward = 0
            TabDragDrop.bringForward = { _ in broughtForward += 1 }
            defer {
                TabDragDrop.bringForward = saved
                TabDragDrop.externalDropOperations = []
            }
            let session = try #require(window.tab.writeActions?.session)
            let ui = try #require(WindowWriteUI.attached(to: session))
            TabDragDrop.externalDropOperations = ["drop-op"]
            ui.handle(
                .progress(WriteOperationEvent(operationId: "drop-op", action: .copyTo, status: .awaitingResolution)))
            #expect(broughtForward == 1)
            ui.handle(.progress(WriteOperationEvent(operationId: "drop-op", action: .copyTo, status: .running)))
            ui.handle(
                .progress(WriteOperationEvent(operationId: "other-op", action: .copyTo, status: .awaitingResolution)))
            #expect(broughtForward == 1)
            func ended(_ operationId: String, _ status: WriteOperationStatus) -> WindowWriteEvent {
                let result = LocalWriteResults.result(
                    operationId: operationId, action: .copyTo, targetPath: window.folder.path,
                    startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
                    totalItemCount: 1, completedItemCount: status == .completed ? 1 : 0, items: [], status: status,
                    error: status == .failed ? "The disk is full." : nil)
                return .ended(
                    WriteOperationEvent(
                        operationId: operationId, action: .copyTo, status: status, totalItemCount: 1, result: result),
                    inTabOnScreen: true)
            }
            ui.handle(ended("drop-op", .failed))
            #expect(broughtForward == 2)
            // The failed copy's result sheet (P6-02) says why.
            #expect(CopyPasteResultPresenter.shared.sheet?.text.message == "The disk is full.")
            #expect(!TabDragDrop.externalDropOperations.contains("drop-op"))
            TabDragDrop.externalDropOperations = ["quiet-op"]
            ui.handle(ended("quiet-op", .completed))
            #expect(broughtForward == 2)
            await window.close()
        }

        // F-688 B-CLIP-149: a drag image draws the Quick Look picture the item shows, and the file icon otherwise.
        @Test func dragImagesUseTheThumbnailsShown() {
            let picture = NSImage(size: NSSize(width: 8, height: 8))
            let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
            func image(_ index: Int, thumbnail: Bool) -> FileDragImage {
                FileDragImage(
                    index: index, iconRect: rect, nameRect: rect, nameFontSize: 12, nameCentered: true,
                    thumbnail: thumbnail)
            }
            let thumbnails = TabDragDrop.dragThumbnails(
                ["/a.jpg", "/b.jpg", "/c.jpg"],
                images: [image(0, thumbnail: true), image(1, thumbnail: false), image(2, thumbnail: true)]
            ) { $0 == "/c.jpg" || $0 == "/b.jpg" ? picture : nil }
            #expect(thumbnails.count == 1)
            #expect(thumbnails[2] === picture)
        }

        // B-CLIP-148: folders, links to folders and apps or packages go on the drag's pasteboard as folders.
        @Test func linksToFoldersAndPackagesAreDraggedAsFolders() {
            let kinds: [FTFoundation.EntryKind] = [.directory, .symlinkDirectory, .bundle, .file, .symlinkFile, .other]
            let items = kinds.enumerated().map { DragItem(path: "/x\($0.offset)", kind: $0.element) }
            #expect(TabDragDrop.dragDirectories(items) == [true, true, true, false, false, false])
        }
    }
}
