// Checks that what a tab shares between its two panes (the toolbar, the tree, the Info Row, a write's end, the saved
// tab) follows the right pane, on windows that are never shown
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit
@testable import FTOperations

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TwoPanesInStepTests {
        /// The real path of `name` in the harness's folder: what listings and the tree call it.
        private func real(_ harness: ExplorerHarness, _ name: String = "") -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        /// The pane has read its folder, and what follows in the sidebar has been told.
        private func arrived(_ pane: BrowserPane) async {
            #expect(await waitUntil { pane.loaded && pane.hasShownFolder && !pane.isNavigating })
            await settle()
        }

        private func twoPanes(_ harness: ExplorerHarness, right: String? = nil) async throws -> (
            MainWindowController, BrowserPane, BrowserPane
        ) {
            let tab = try await harness.open()
            let left = tab.activePane
            let second = tab.openSecondPane(at: right.map { real(harness, $0) })
            await arrived(second)
            harness.layout(tab)
            return (tab, left, second)
        }

        /// The app's file operations for the harness's windows, with nothing asked or shown.
        private func writes(_ harness: ExplorerHarness) -> AppWriteOperations {
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, emptyTrash: { (true, nil) }, log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            return operations
        }

        // MARK: A name typed, a write's end

        // A click on the other pane ends the name field and makes that pane active while the name is still being
        // checked: the pane that had the field closes it.
        @Test func aRenameEndedByGoingToTheOtherPaneClosesItsFieldInThePaneItWasIn() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            let note = real(harness, "note.txt")
            let held = LocalWritesInWindowTests.Held()
            tab.renameItem = { _, _ in
                await held.wait()
                return .started
            }
            left.content.focusList()
            left.content.select(paths: [note])
            tab.renameSelected()
            #expect(left.content.inlineRename?.path == note)

            left.content.renameSubmitted("renamed.txt")
            tab.activate(right)
            held.open()

            #expect(await waitUntil { left.content.inlineRename == nil })
            // Its folder is read again from then on.
            let made = real(harness) + "/made.txt"
            try "x".write(toFile: made, atomically: true, encoding: .utf8)
            harness.services.directoryService.cache.clear()
            left.reload(changedPaths: [made])
            #expect(await waitUntil { left.content.listed.contains { $0.path == made } })
        }

        // Both panes are read when a write ends. The other pane's listing may land first: the folder just made is
        // still selected, and its name opened, by the read of the pane it was made in.
        @Test func whatAWriteMadeIsSelectedAndNamedByItsOwnPanesReadWhicheverLandsFirst() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, _) = try await twoPanes(harness)
            let operations = writes(harness)
            defer { withExtendedLifetime(operations) {} }
            let session = operations.session(for: try #require(tab.group))
            let made = real(harness) + "/untitled folder"
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)
            harness.services.directoryService.cache.clear()
            session.pendingInlineRenamePath = made

            tab.applyWriteEnd(
                WriteEndRefresh(path: real(harness), selecting: [made], treeSelectionPath: nil, treeReloadPaths: []))
            // The other pane's read, landing before the active pane's.
            tab.notify(.folder)

            #expect(await waitUntil { left.content.inlineRename?.path == made })
            #expect(left.content.selection.paths == [made])
            #expect(session.pendingInlineRenamePath == nil)
        }

        // What a write made waits for its pane's read. A pane that opens another folder before that read lands lets go
        // of it: coming back to the folder later, nothing of it is selected.
        @Test func whatAWriteMadeIsNotSelectedLaterInAPaneThatLeftTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (_, _, right) = try await twoPanes(harness, right: "Gamma")
            let gamma = real(harness, "Gamma")
            let made = gamma + "/made.txt"
            try "x".write(toFile: made, atomically: true, encoding: .utf8)
            harness.services.directoryService.cache.clear()

            right.readAgain(selecting: [made])
            await right.navigate(to: real(harness, "Alpha"))
            await settle()
            await right.navigate(to: gamma)
            #expect(right.content.selection.paths.isEmpty)

            let later = gamma + "/later.txt"
            try "x".write(toFile: later, atomically: true, encoding: .utf8)
            harness.services.directoryService.cache.clear()
            right.reload(changedPaths: [later])
            #expect(await waitUntil { right.content.listed.contains { $0.path == later } })
            await settle()
            #expect(right.content.selection.paths.isEmpty)
        }

        // A write's end reads the other pane again only when the write had to do with its folder.
        @Test func aWritesEndLeavesAPaneOnAFolderItDidntTouchUnread() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Beta")
            let made = real(harness) + "/made.txt"
            let outside = real(harness, "Beta") + "/outside.txt"
            try "x".write(toFile: made, atomically: true, encoding: .utf8)
            try "x".write(toFile: outside, atomically: true, encoding: .utf8)
            harness.services.directoryService.cache.clear()
            var refresh = WriteEndRefresh(
                path: real(harness), selecting: nil, treeSelectionPath: nil, treeReloadPaths: [])
            refresh.touched = AfterWrite.Touched(
                targetPath: real(harness),
                items: [WriteOperationItem(sourcePath: nil, destinationPath: made, status: .completed)], aside: [])

            tab.applyWriteEnd(refresh)
            #expect(await waitUntil { tab.content.listed.contains { $0.path == made } })
            try await Task.sleep(for: .milliseconds(200))
            #expect(!right.content.listed.contains { $0.path == outside })

            // A write that doesn't say what it touched reads it, as one that went into its folder does.
            refresh.touched = nil
            tab.applyWriteEnd(refresh)
            #expect(await waitUntil { right.content.listed.contains { $0.path == outside } })
        }

        // MARK: What follows the active pane

        @Test func theInfoRowShowsInTheActivePaneOnly() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            func open(_ pane: BrowserPane) -> Bool { pane.content.contentShell.infoRow.isOpen }
            tab.updatePanels { $0.detailRowOpen = false }
            #expect(!open(left) && !open(right))

            tab.updatePanels { $0.detailRowOpen = true }
            #expect(open(left))
            #expect(!open(right))

            tab.focusPane(right)
            #expect(open(right))
            #expect(!open(left))

            tab.perform(.swapPanes)
            #expect(open(right))
            #expect(!open(left))

            // The pane that isn't active closes; the one left keeps its row, and a pane opened beside it has none.
            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(open(right))
            tab.perform(.toggleTwoPanes)
            let other = try #require(tab.otherPane)
            #expect(open(right))
            #expect(!open(other))

            tab.updatePanels { $0.detailRowOpen = false }
            #expect(!open(right) && !open(other))
        }

        // Hidden Files is the tab's: turned on or off from either pane, both panes and the tree follow, a pane switch
        // leaves the tree as it is, and a pane opened again where it was closed shows them as the tab does now.
        @Test func hiddenFilesAreTheTabsInBothPanesAndTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            try "x".write(to: URL(fileURLWithPath: real(harness, ".secret")), atomically: true, encoding: .utf8)
            try "x".write(to: URL(fileURLWithPath: real(harness, "Beta/.shade")), atomically: true, encoding: .utf8)
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            let model = tab.sidebarController.model
            func names(_ pane: BrowserPane) -> [String] { pane.content.entries.map(\.name) }
            #expect(!model.includeHidden)

            tab.focusPane(right)
            tab.perform(.toggleHiddenFiles)
            #expect(left.includeHidden && right.includeHidden && model.includeHidden)
            #expect(await waitUntil { names(left).contains(".secret") && names(right).contains(".shade") })

            tab.focusPane(left)
            #expect(model.includeHidden)
            tab.perform(.toggleHiddenFiles)
            #expect(!left.includeHidden && !right.includeHidden && !model.includeHidden)
            #expect(await waitUntil { !names(left).contains(".secret") && !names(right).contains(".shade") })

            // The right pane closes with them off, they are turned on, and it opens again with them.
            tab.perform(.toggleTwoPanes)
            tab.perform(.toggleHiddenFiles)
            tab.perform(.toggleTwoPanes)
            let reopened = try #require(tab.otherPane)
            #expect(reopened.includeHidden)
            await arrived(reopened)
            #expect(names(reopened).contains(".shade"))
        }

        // The toolbar's one search field is the active pane's: the other pane opening a folder leaves what is typed.
        @Test func aFolderOpeningInThePaneThatIsntActiveLeavesTheSearchFieldAlone() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            // Each pane has had the field.
            tab.focusPane(right)
            tab.focusPane(left)
            let field = try #require(tab.searchField)
            field.stringValue = "a"
            left.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(left.search.session.draftQuery == "a")

            await right.navigate(to: real(harness, "Beta/Inner"))
            #expect(field.stringValue == "a")
            #expect(left.search.session.draftQuery == "a")

            // The active pane's own folder still empties it.
            await left.navigate(to: real(harness, "Alpha"))
            #expect(field.stringValue.isEmpty)
        }

        @Test func theTabsMagnifierShowsForSearchResultsInEitherPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            tab.focusPane(right)
            tab.focusPane(left)
            #expect(tab.window?.tab.accessoryView == nil)

            right.search.session.submit("Inner")
            #expect(await waitUntil { right.searchRootPath != nil })
            #expect(tab.activePane === left)
            #expect(tab.window?.tab.accessoryView is SearchTabMagnifier)

            // The pane with the results closes: the magnifier goes with it.
            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(tab.window?.tab.accessoryView == nil)
        }

        // A search option saved from elsewhere (another window's choice) reaches neither pane's search: each keeps
        // its own.
        @Test func aSearchOptionSavedElsewhereReachesNeitherPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            tab.focusPane(right)
            tab.focusPane(left)
            let recursive = left.search.session.recursive
            #expect(right.search.session.recursive == recursive)

            tab.updatePreferences { $0.searchRecursive = !recursive }

            #expect(await waitUntil { tab.preferences.searchRecursive == !recursive })
            for _ in 0..<5 { await Task.yield() }
            #expect(left.search.session.recursive == recursive)
            #expect(right.search.session.recursive == recursive)
        }

        @Test func aRenamedStartupDiskIsSaidInBothPanesPathBars() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            let disk = StartupDisk()
            var services = harness.services
            services.startupDisk = disk
            tab.servicesOverride = services
            func label(_ pane: BrowserPane) -> String? {
                pane.content.contentShell.pathBarRow.pathBar.segments.first?.label
            }

            disk.set("Data")
            #expect(label(left) == "Data")
            #expect(label(right) == "Data")
        }

        // A closed pane's search no longer listens for Esc in the window.
        @Test func aClosedPanesSearchLetsGoOfTheWindowsKeys() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Beta")
            tab.focusPane(right)
            let search = right.search
            #expect(search.listensForEscape)
            tab.focusPane(left)

            tab.perform(.toggleTwoPanes)
            #expect(tab.panes.count == 1)
            #expect(!search.listensForEscape)
            #expect(left.search.listensForEscape)
        }

        // MARK: The disk under a pane

        // A disk that goes takes the pane on it Home; the tab stays for the pane that is elsewhere.
        @Test func aPaneOnAnUnmountedDiskGoesHomeAndItsTabStaysForTheOtherPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma/Inner")
            let disk = real(harness, "Gamma")
            harness.windows.home = real(harness)
            harness.windows.volumeRoot = { path in
                path == disk || path.hasPrefix(disk + "/") ? disk : ExplorerTabs.volumeRootPath(path)
            }
            let group = try #require(tab.group)
            // A tab at the back with a pane on the disk too.
            group.duplicateTab(tab)
            #expect(await waitUntil { group.tabs.count == 2 && group.selected !== tab })
            let front = try #require(group.selected)
            #expect(await waitUntil { front.panes.count == 2 && front.panes.allSatisfy { $0.loaded } })

            harness.windows.disksUnmounted([disk])

            #expect(group.tabs.count == 2)
            // The tab on screen: its pane on the disk opens Home.
            #expect(await waitUntil { front.panes[1].shownFolderPath == real(harness) })
            #expect(front.panes[0].shownFolderPath == real(harness))
            // The tab at the back: its pane takes Home as its place, and reads it when the tab is shown.
            #expect(right.folderPath == real(harness))
            #expect(right.navigationHistory.paths == [real(harness)])
            #expect(left.shownFolderPath == real(harness))

            // With both panes on the disk, nothing of the tab is left: it closes.
            await front.panes[0].navigate(to: disk)
            await front.panes[1].navigate(to: disk + "/Inner")
            harness.windows.disksUnmounted([disk])
            #expect(await waitUntil { group.tabs.count == 1 })
            #expect(group.tabs.first === tab)
        }

        // A tab at the back follows a folder renamed or moved in both of its panes.
        @Test func aTabAtTheBackFollowsARenamedFolderInItsSecondPaneToo() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Alpha/Inner")
            let group = try #require(tab.group)
            group.openTab(path: real(harness, "Beta"), from: tab)
            #expect(await waitUntil { group.tabs.count == 2 && group.selected !== tab })
            let alpha = real(harness, "Alpha")
            let moved = real(harness) + "/Moved"
            try FileManager.default.moveItem(atPath: alpha, toPath: moved)

            let rename = WriteOperationOutcome(
                action: .rename, mode: nil, items: [WriteEffectItem(sourcePath: alpha, destinationPath: moved)])
            harness.windows.writeOperationProgress(WriteOperationProgress(status: .completed, result: rename))

            #expect(right.folderPath == moved + "/Inner")
            #expect(right.navigationHistory.paths == [moved + "/Inner"])
            #expect(right.stale)
            #expect(left.folderPath == real(harness))
            #expect(!left.stale)

            group.select(tab)
            #expect(await waitUntil { !right.stale && !right.isNavigating })
            #expect(right.shownFolderPath == moved + "/Inner")
        }

        // MARK: Kept with the tab

        @Test func theDividerIsSavedWhenItIsDraggedOrThePanesAreMadeEqual() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, _) = try await twoPanes(harness)
            let group = try #require(tab.group)
            func saved() -> Double? { harness.store.windowPreferences(group.recordID).openTabs.first?.paneSplit }
            let column = tab.workspace.contentColumn
            let divider = column.divider

            divider.onDrag(column.bounds.width * 0.7)
            divider.onDragEnd()
            let dragged = tab.workspace.paneSplit
            #expect(dragged > 0.6)
            #expect(saved() == dragged)

            tab.perform(.equalizePanes)
            #expect(saved() == PaneSplit.even)

            divider.onDrag(column.bounds.width * 0.3)
            divider.onDragEnd()
            #expect(saved() == tab.workspace.paneSplit)
            divider.onDoubleClick()
            #expect(saved() == PaneSplit.even)
        }

        // The tree's row is the active pane's: a tab made from one whose second pane is on a favorite doesn't take
        // its first pane's folder for the favorite.
        @Test func aTabMadeFromOneWithTheSecondPaneOnAFavoriteKeepsTheFavoriteOffItsFirstPane() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            var snapshot = tab.snapshot
            let beta = real(harness, "Beta")
            snapshot.selectedTreeItemID = "favorite:\(beta)"
            snapshot.secondPane = PaneSnapshot(
                pane: tab.savedPane(tab.activePane), historyPaths: [beta], historyIndex: 0)
            snapshot.secondPane?.pane.path = beta
            snapshot.activePane = 1
            snapshot.view = nil

            let copy = MainWindowController(snapshot: snapshot, frame: nil)
            copy.servicesOverride = tab.servicesOverride
            defer { copy.window?.close() }

            #expect(copy.panes.count == 2)
            #expect(copy.activePaneIndex == 1)
            #expect(copy.openTab.favoritePath == nil)
            #expect(copy.openTab.path == real(harness))
            #expect(copy.openTab.secondPane?.path == beta)
        }

        // New Tab opens one pane, on the active pane's folder.
        @Test func aNewTabHasOnePaneOnTheActivePanesFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Beta")
            tab.focusPane(right)
            let group = try #require(tab.group)

            tab.perform(.newTab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let new = group.tabs[1]
            #expect(new.panes.count == 1)
            #expect(await waitUntil { new.shownFolderPath == real(harness, "Beta") })
        }

        // MARK: Across the panes

        // Nothing is pasted into the Trash, and nothing is copied or moved into a pane that shows it.
        @Test func copyAndMoveToOtherPaneAreRefusedWhileTheOtherPaneShowsTheTrash() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            let operations = writes(harness)
            defer { withExtendedLifetime(operations) {} }
            let trash = real(harness) + "/.Trash"
            try FileManager.default.createDirectory(atPath: trash + "/Old", withIntermediateDirectories: true)
            tab.trashHomePath = real(harness)
            let note = real(harness, "note.txt")
            left.content.focusList()
            left.content.select(paths: [note])
            #expect(tab.canPerform(.copyToOtherPane))

            for folder in [trash, trash + "/Old"] {
                await right.navigate(to: folder)
                #expect(right.shownFolderPath == folder)
                #expect(!tab.canPerform(.copyToOtherPane))
                #expect(!tab.canPerform(.moveToOtherPane))
                // The right-click menu dims them too, and keeps its shape.
                let entry = try #require(left.content.entries.first { $0.path == note })
                let submenu = try #require(
                    tab.contextMenus.contentMenu(for: [entry])?.items
                        .first { $0.identifier?.rawValue == "otherPane" }?.submenu)
                #expect(submenu.items.map(\.title) == ["Open", "Copy", "Move"])
                // Open shows the file there; Copy and Move go nowhere while it shows the Trash.
                #expect(submenu.items.map(\.isEnabled) == [true, false, false])
                tab.sendToOtherPane([note], copying: true)
                tab.sendToOtherPane([note], copying: false)
                await settle()
                #expect(!tab.isWriteLocked)
                #expect(FileManager.default.fileExists(atPath: note))
                #expect(!FileManager.default.fileExists(atPath: folder + "/note.txt"))
            }
        }

        // Undo takes a move between the panes back, and both panes show it.
        @Test func undoTakesAMoveToTheOtherPaneBackInBothPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, left, right) = try await twoPanes(harness, right: "Gamma")
            let operations = writes(harness)
            defer { withExtendedLifetime(operations) {} }
            let note = real(harness, "note.txt")
            let moved = real(harness, "Gamma") + "/note.txt"
            left.content.focusList()
            left.content.select(paths: [note])

            tab.perform(.moveToOtherPane)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: moved) })
            #expect(await waitUntil { right.content.listed.contains { $0.path == moved } })
            #expect(await waitUntil { !left.content.listed.contains { $0.path == note } })
            #expect(await waitUntil { !tab.isWriteLocked })

            tab.perform(.undo)
            #expect(await waitUntil { FileManager.default.fileExists(atPath: note) })
            #expect(!FileManager.default.fileExists(atPath: moved))
            #expect(await waitUntil { left.content.listed.contains { $0.path == note } })
            #expect(await waitUntil { !right.content.listed.contains { $0.path == moved } })
            #expect(tab.activePane === left)
        }

        // MARK: Windows

        @Test func moveTabToNewWindowKeepsBothPanesTheActiveOneAndTheDivider() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let (tab, _, right) = try await twoPanes(harness, right: "Beta")
            tab.focusPane(right)
            tab.workspace.setPaneSplit(0.6)
            let group = try #require(tab.group)
            group.openTab(path: real(harness, "Alpha"), from: tab)
            #expect(await waitUntil { group.tabs.count == 2 })

            group.moveTabToNewWindow(tab)

            #expect(await waitUntil { harness.windows.count == 2 && group.tabs.count == 1 })
            let moved = try #require(harness.windows.newestGroup?.selected)
            #expect(moved !== tab)
            #expect(moved.panes.count == 2)
            #expect(moved.activePaneIndex == 1)
            #expect(moved.workspace.paneSplit == 0.6)
            #expect(await waitUntil { moved.panes.allSatisfy { $0.loaded && !$0.isNavigating } })
            #expect(moved.panes[0].shownFolderPath == real(harness))
            #expect(moved.panes[1].shownFolderPath == real(harness, "Beta"))
        }

        @Test func mergeAllWindowsBringsATabWithBothOfItsPanes() async throws {
            let harness = try ExplorerHarness.windowless()
            defer { Task { await harness.close() } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openNewWindow(from: tab, path: real(harness, "Alpha"))
            #expect(await waitUntil { harness.windows.count == 2 })
            let other = try #require(harness.windows.newestGroup?.selected)
            #expect(other !== tab)
            #expect(await waitUntil { other.loaded && !other.isNavigating })
            let second = other.openSecondPane(at: real(harness, "Beta"))
            await arrived(second)
            other.focusPane(second)

            group.mergeAllWindows(into: tab)

            #expect(await waitUntil { harness.windows.count == 1 && group.tabs.count == 2 })
            let merged = group.tabs[1]
            #expect(merged.panes.count == 2)
            #expect(merged.activePaneIndex == 1)
            #expect(merged.panes[0].folderPath == real(harness, "Alpha"))
            #expect(merged.panes[1].folderPath == real(harness, "Beta"))
        }
    }
}
