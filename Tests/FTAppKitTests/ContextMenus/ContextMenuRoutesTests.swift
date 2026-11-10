// Each test right-clicks and chooses the item, so a route that refuses on the way or acts on something else fails it
import AppKit
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor @Suite struct ContextMenuRoutesTests: SidebarTesting {
        /// A tab with the app's file operations, on the folder as the tree names it, and the tree rooted there.
        private func open() async throws -> WritingWindow {
            PreparingSheet.isEnabled = false
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(listed(harness, ""))
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            let recorder = DialogRecorder()
            operations.dialogs = recorder.dialogs
            tab.perform(.viewAsDetails)
            _ = await waitUntil { !tab.content.entries.isEmpty }
            harness.layout(tab)
            await rooted(tab, harness)
            _ = await waitUntil { self.labels(self.sidebar(tab)).contains("Beta") }
            return WritingWindow(
                harness: harness, tab: tab, operations: operations, recorder: recorder,
                folder: URL(fileURLWithPath: listed(harness, "")))
        }

        private func path(_ window: WritingWindow, _ name: String) -> String {
            window.folder.appendingPathComponent(name).path
        }

        /// A right-click on a row of the tree, as AppKit asks for its menu: the tree takes the keyboard.
        private func treeMenu(_ window: WritingWindow, _ name: String) throws -> NSMenu {
            let controller = sidebar(window.tab)
            let cell = try #require(cells(controller).first { label($0) == name })
            let outline = controller.tree.outline
            let point = outline.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), from: cell)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: outline.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.tab.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            let menu = try #require(outline.menu(for: event))
            #expect(window.tab.focusedPane == .tree)
            return menu
        }

        private func contentMenu(_ window: WritingWindow, _ names: [String]) throws -> NSMenu {
            let entries = try names.map { name in
                try #require(window.tab.content.entries.first { $0.name == name })
            }
            return try #require(window.tab.contextMenus.contentMenu(for: entries))
        }

        private func backgroundMenu(_ window: WritingWindow) throws -> NSMenu {
            try #require(window.tab.contextMenus.contentMenu(for: nil))
        }

        private func favoriteMenu(_ window: WritingWindow, _ path: String) throws -> NSMenu {
            let request = SidebarContextMenuRequest(
                item: TreePresentationItem(
                    id: .favorite(path), kind: .favorite, label: "Favorite", depth: 0, path: path, parentID: nil,
                    expanded: false, canExpand: false),
                subview: .favorites, kind: .favorite)
            return try #require(window.tab.contextMenus.sidebarMenu(for: request))
        }

        private func choose(_ title: String, in menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title }, "\(title)")
            _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }

        // An item chosen after an operation began says the app is busy, and does nothing.
        @Test func anItemChosenOnceAnOperationBeganSaysItIsBusy() async throws {
            let window = try await open()
            let menu = try contentMenu(window, ["note.txt"])
            let actions = try #require(window.tab.writeActions)
            actions.session.applyCard(
                WriteOperationCardState(
                    action: .paste, stage: .starting, targetPath: nil, totalItemCount: 1, totalBytes: nil,
                    currentSourcePath: nil))
            try choose("Move to Trash", in: menu)
            #expect(window.recorder.shown.map(\.message) == [WriteDialogs.busyMessage])
            #expect(FileManager.default.fileExists(atPath: path(window, "note.txt")))
            actions.session.applyCard(nil)
            await window.close()
        }

        // A tab opened while another window's operation runs leaves the writes out of its menus, as the tabs open
        // before it do.
        @Test func aTabOpenedDuringAnotherWindowsOperationLeavesTheWritesOut() async throws {
            let window = try await open()
            let actions = try #require(window.tab.writeActions)
            actions.session.otherWindowProgress(
                WriteOperationEvent(operationId: "other-op", action: .copyTo, status: .running, totalItemCount: 1))
            #expect(window.tab.isWriteLocked)
            let group = try #require(window.tab.group)
            window.tab.perform(.newTab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let new = try #require(group.tabs.first { $0 !== window.tab })
            let note = path(window, "note.txt")
            let subject = ContextMenuSubject(
                surface: .content, scope: .selection, paths: [note], targetPath: note,
                entries: [CommandEntry(path: note, kind: .file)])
            let menu = try #require(new.contextMenus.menu(for: subject))
            #expect(!menu.items.contains { $0.title == "Move to Trash" })
            actions.session.releaseEndedForeign()
            await window.close()
        }

        /// A size is known for the folder; then something is added to it that a stored size wouldn't know of.
        private func measured(_ window: WritingWindow, _ path: String) async throws -> Int64 {
            let sizes = window.tab.folderSizes
            sizes.calculate(path)
            #expect(await waitUntil { sizes.readySize(path) != nil })
            let size = try #require(sizes.readySize(path))
            try Data(count: 64 * 1024).write(to: URL(fileURLWithPath: path).appendingPathComponent("added.bin"))
            return size
        }

        // MARK: Duplicate and Move of the tree

        // The copy goes next to the folder, whatever is selected in the list, and is selected in the tree.
        @Test func aTreeFoldersDuplicateMakesTheCopyNextToItAndSelectsItInTheTree() async throws {
            let window = try await open()
            window.select(["note.txt"])
            try choose("Duplicate", in: try treeMenu(window, "Beta"))
            #expect(await waitUntil { window.exists("Beta copy") })
            #expect(await waitUntil { sidebar(window.tab).selectedTreeTargetPath == path(window, "Beta copy") })
            #expect(!window.exists("note copy.txt"))
            await window.close()
        }

        // A folder deep in the tree goes into its own parent, not the folder on screen.
        @Test func aNestedTreeFoldersCopyGoesIntoItsParentNotTheFolderOnScreen() async throws {
            let window = try await open()
            let inner = window.folder.appendingPathComponent("Alpha/Inner")
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            let subject = ContextMenuSubject(
                surface: .treeFolder, scope: .selection, paths: [inner.path], targetPath: inner.path,
                entries: [CommandEntry(path: inner.path, kind: .directory)])
            window.tab.contextMenus.contextMenu(perform: .duplicate, subject: subject)
            #expect(await waitUntil { window.exists("Alpha/Inner copy") })
            #expect(!window.exists("Inner copy"))
            await window.close()
        }

        // The tree's Move to… moves the folder right-clicked, not the list's selection.
        @Test func aTreeFoldersMoveMovesThatFolder() async throws {
            let window = try await open()
            window.select(["note.txt"])
            try choose("Move to…", in: try treeMenu(window, "Beta"))
            let box = try #require(window.tab.goToBox)
            window.tab.window?.contentView?.layoutSubtreeIfNeeded()
            DialogKeys.type(path(window, "Alpha"), into: box)
            DialogKeys.press(36, "\r", in: window.tab.window)
            #expect(await waitUntil { window.exists("Alpha/Beta") })
            #expect(window.exists("note.txt"))
            await window.close()
        }

        // The list's Duplicate and Move act on what the menu was opened on, with the tree holding the keyboard too.
        @Test func aListItemsDuplicateAndMoveAreNotRefusedWithTheTreeFocused() async throws {
            let window = try await open()
            let menu = try contentMenu(window, ["note.txt"])
            let outline = sidebar(window.tab).tree.outline
            window.tab.window?.makeFirstResponder(outline)
            #expect(window.tab.focusedPane == .tree)
            try choose("Duplicate", in: menu)
            #expect(await waitUntil { window.exists("note copy.txt") })
            #expect(await waitUntil { !window.tab.isWriteLocked })
            window.tab.window?.makeFirstResponder(outline)
            try choose("Move to…", in: try contentMenu(window, ["note.txt"]))
            #expect(window.tab.goToBox != nil)
            await window.close()
        }

        // MARK: Show Info

        // The panel opens on the item right-clicked, not the selection.
        @Test func showInfoOnARowDescribesThatRow() async throws {
            let window = try await open()
            let info = try #require(window.tab.infoController)
            window.select(["note.txt"])
            try choose("Show Info", in: try contentMenu(window, ["Alpha"]))
            #expect(window.tab.panels.propertiesOpen)
            #expect(info.targetOverride == path(window, "Alpha"))
            #expect(await waitUntil { info.resolvedItemPath == path(window, "Alpha") })
            await window.close()
        }

        // A sidebar folder's, a favorite's and the background's describe that folder.
        @Test func showInfoFromTheSidebarAndTheBackgroundDescribesThatFolder() async throws {
            let window = try await open()
            let info = try #require(window.tab.infoController)
            window.select(["note.txt"])
            try choose("Show Info", in: try treeMenu(window, "Beta"))
            #expect(window.tab.panels.propertiesOpen)
            #expect(await waitUntil { info.resolvedItemPath == path(window, "Beta") })
            try choose("Show Info", in: try favoriteMenu(window, path(window, "Alpha")))
            #expect(await waitUntil { info.resolvedItemPath == path(window, "Alpha") })
            try choose("Show Info", in: try backgroundMenu(window))
            #expect(info.targetOverride == window.tab.shownFolderPath)
            #expect(await waitUntil { info.resolvedItemPath == window.tab.shownFolderPath })
            await window.close()
        }

        // MARK: Calculate Size of the menus

        // One item is measured again, past a size already known.
        @Test func aRowsCalculateSizeMeasuresAgain() async throws {
            let window = try await open()
            let alpha = path(window, "Alpha")
            let before = try await measured(window, alpha)
            try choose("Calculate Size", in: try contentMenu(window, ["Alpha"]))
            #expect(await waitUntil { (window.tab.folderSizes.readySize(alpha) ?? 0) > before })
            #expect(!window.tab.panels.propertiesOpen)
            await window.close()
        }

        // So is the folder on screen, from empty space.
        @Test func theBackgroundsCalculateSizeMeasuresTheFolderOnScreenAgain() async throws {
            let window = try await open()
            let folder = window.tab.shownFolderPath
            let before = try await measured(window, folder)
            try choose("Calculate Size", in: try backgroundMenu(window))
            #expect(await waitUntil { (window.tab.folderSizes.readySize(folder) ?? 0) > before })
            #expect(!window.tab.panels.propertiesOpen)
            await window.close()
        }

        // A sidebar folder in the Size column is measured again and leaves the panel closed.
        @Test func aSidebarFolderInTheSizeColumnMeasuresAgainWithThePanelClosed() async throws {
            let window = try await open()
            let beta = path(window, "Beta")
            let before = try await measured(window, beta)
            try choose("Calculate Size", in: try treeMenu(window, "Beta"))
            #expect(await waitUntil { (window.tab.folderSizes.readySize(beta) ?? 0) > before })
            #expect(!window.tab.panels.propertiesOpen)
            await window.close()
        }

        // The sidebar's folder on screen shows in the status bar: the panel stays closed.
        @Test func theSidebarsFolderOnScreenLeavesThePanelClosed() async throws {
            let window = try await open()
            let folder = window.tab.shownFolderPath
            let request = SidebarContextMenuRequest(
                item: TreePresentationItem(
                    id: .filesystem(folder), kind: .filesystem, label: "Here", depth: 0, path: folder, parentID: nil,
                    expanded: true, canExpand: true),
                subview: .tree, kind: .treeFolder)
            try choose("Calculate Size", in: try #require(window.tab.contextMenus.sidebarMenu(for: request)))
            #expect(await waitUntil { window.tab.folderSizes.readySize(folder) != nil })
            #expect(!window.tab.panels.propertiesOpen)
            await window.close()
        }

        // A sidebar folder nothing else on screen shows opens the Info panel on it.
        @Test func aSidebarFolderNothingElseShowsOpensTheInfoPanelOnIt() async throws {
            let window = try await open()
            let info = try #require(window.tab.infoController)
            let inner = window.folder.appendingPathComponent("Alpha/Inner").path
            try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
            window.select(["note.txt"])
            try choose("Calculate Size", in: try favoriteMenu(window, inner))
            #expect(window.tab.panels.propertiesOpen)
            #expect(await waitUntil { info.resolvedItemPath == inner })
            #expect(await waitUntil { window.tab.folderSizes.readySize(inner) != nil })
            await window.close()
        }

        // MARK: The Calculate Size command

        // With the tree on a location row it measures the folder on screen, not the list's selection.
        @Test func theCommandOnALocationRowMeasuresTheFolderOnScreen() async throws {
            let window = try await open()
            let tab = window.tab
            window.select(["Alpha"])
            let model = sidebar(tab).model
            model.restoreView(nodes: model.nodes, selected: .location(NSHomeDirectory()), subview: model.subview)
            tab.window?.makeFirstResponder(sidebar(tab).tree.outline)
            #expect(tab.focusedPane == .tree)
            #expect(sidebar(tab).selectedTreeTargetPath == nil)
            tab.perform(.calculateSize)
            #expect(await waitUntil { tab.folderSizes.readySize(tab.shownFolderPath) != nil })
            await window.close()
        }

        // On a tree folder it measures that folder again, and opens no panel.
        @Test func theCommandOnATreeFolderMeasuresAgainAndOpensNoPanel() async throws {
            let window = try await open()
            let tab = window.tab
            let beta = path(window, "Beta")
            let before = try await measured(window, beta)
            sidebar(tab).revealFavoriteInTree(beta)
            #expect(await waitUntil { sidebar(tab).selectedTreeTargetPath == beta })
            tab.window?.makeFirstResponder(sidebar(tab).tree.outline)
            #expect(tab.focusedPane == .tree)
            tab.perform(.calculateSize)
            #expect(await waitUntil { (tab.folderSizes.readySize(beta) ?? 0) > before })
            #expect(!tab.panels.propertiesOpen)
            await window.close()
        }
    }
}
