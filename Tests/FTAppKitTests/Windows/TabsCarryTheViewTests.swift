import AppKit
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabsCarryTheViewTests {
        /// The real path of `name` in the harness's folder: what listings and the tree call it.
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func firstRead(_ tab: MainWindowController) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                tab.whenFirstReadFinished { _ in done.resume() }
            }
            // The sidebar hears of the folder in a task of its own.
            await settle()
        }

        /// The tab has read its folder, and what follows the reading in the sidebar has been told.
        private func arrived(_ tab: MainWindowController) async {
            #expect(await waitUntil { !tab.isNavigating })
            await settle()
        }

        /// A tab with Alpha open in the tree though it shows the folder above it.
        private func tabWithAlphaOpen(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            await tab.navigate(to: harness.folder.appending("Alpha/Inner"))
            let alpha = real(harness, "Alpha")
            #expect(await waitUntil { tab.sidebarController.model.nodes[alpha]?.expanded == true })
            await tab.navigate(to: URL(fileURLWithPath: real(harness, "")), history: .back)
            await arrived(tab)
            return tab
        }

        private func opened(_ tab: MainWindowController, after count: Int) async throws -> MainWindowController {
            let group = try #require(tab.group)
            #expect(await waitUntil { group.tabs.count == count + 1 })
            let index = try #require(group.tabs.firstIndex { $0 === tab })
            let new = group.tabs[index + 1]
            new.servicesOverride = tab.servicesOverride
            await firstRead(new)
            return new
        }

        @Test func duplicateTabCarriesTheSelectionFilterScrollMemoriesAndOpenedBranches() async throws {
            let harness = try ExplorerHarness.windowless()
            for index in 100..<400 {
                try "x".write(to: harness.folder.appending("f\(index).txt"), atomically: false, encoding: .utf8)
            }
            let tab = try await tabWithAlphaOpen(harness)
            harness.layout(tab)
            let chosen = real(harness, "f150.txt")
            tab.content.select(paths: [chosen])
            tab.content.setFilter("f1")
            harness.layout(tab)
            tab.content.pane?.scrollPosition = (top: 60, left: 0)
            let scroll = try #require(tab.content.pane?.scrollPosition)
            #expect(scroll.top > 0)
            #expect(!tab.folderMemories.isEmpty)
            let group = try #require(tab.group)

            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)
            harness.layout(copy)

            #expect(copy.shownFolderPath == tab.shownFolderPath)
            #expect(copy.selectedPaths == [chosen])
            #expect(copy.content.filter == "f1")
            #expect(copy.content.pane?.scrollPosition.top == scroll.top)
            #expect(copy.folderMemories == tab.folderMemories)
            #expect(copy.navigationHistory == tab.navigationHistory)
            let alpha = real(harness, "Alpha")
            #expect(copy.sidebarController.model.nodes[alpha]?.expanded == true)
            await harness.close()
        }

        @Test func aNewTabKeepsTheOpenedBranchesAndNotTheSelectionFilterOrMemories() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await tabWithAlphaOpen(harness)
            let note = real(harness, "note.txt")
            tab.content.select(paths: [note])
            let group = try #require(tab.group)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            let alpha = real(harness, "Alpha")
            #expect(new.sidebarController.model.nodes[alpha]?.expanded == true)
            #expect(new.selectedPaths.isEmpty)
            #expect(new.content.filter.isEmpty)
            #expect(new.folderMemories.isEmpty)
            #expect(new.navigationHistory.paths == [real(harness, "")])
            #expect(group.selected === new)
            await harness.close()
        }

        // The tree's scroll goes along with its rows.
        @Test func aNewTabKeepsWhereTheTreeWasScrolled() async throws {
            let harness = try ExplorerHarness.windowless()
            let many = URL(fileURLWithPath: real(harness, "")).appending(path: "Many")
            for index in 0..<80 {
                try FileManager.default.createDirectory(
                    at: many.appending(path: "D\(index)"), withIntermediateDirectories: true)
            }
            let tab = try await harness.open(many.path)
            let model = tab.sidebarController.model
            #expect(await waitUntil { model.nodes[many.path] != nil })
            await model.loadChildren(many.path, expandOnSuccess: true)
            #expect(await waitUntil { model.nodes[many.path]?.expanded == true })
            harness.layout(tab)
            tab.sidebarController.tree.scrollTop = 200
            harness.layout(tab)
            let top = tab.sidebarController.tree.scrollTop
            #expect(top > 0)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)
            harness.layout(new)

            #expect(new.sidebarController.tree.scrollTop == top)
            await harness.close()
        }

        /// A tab on a tree longer than the window, with a favorite on its last folder, scrolled part of the way.
        private func tabWithLongTree(_ harness: ExplorerHarness) async throws -> (
            MainWindowController, favorite: String
        ) {
            for index in 0..<80 {
                try FileManager.default.createDirectory(
                    at: harness.folder.appending(String(format: "f%02d", index)), withIntermediateDirectories: true)
            }
            let root = real(harness, "")
            let tab = try await harness.open(root)
            tab.perform(.rootTreeAtSelection)
            let controller = tab.sidebarController
            let favorite = real(harness, "f79")
            #expect(await waitUntil { controller.treeRootPath == root && controller.model.nodes[favorite] != nil })
            controller.toggleFavorite(favorite)
            harness.layout(tab)
            controller.tree.scrollTop = 300
            harness.layout(tab)
            #expect(controller.tree.scrollTop == 300)
            return (tab, favorite)
        }

        /// The tab just opened after `tab`, its first read not yet run, laid out as it is for its first frame.
        private func justOpened(_ tab: MainWindowController, _ harness: ExplorerHarness) throws -> MainWindowController
        {
            let group = try #require(tab.group)
            let index = try #require(group.tabs.firstIndex { $0 === tab })
            let new = group.tabs[index + 1]
            new.servicesOverride = tab.servicesOverride
            harness.layout(new)
            return new
        }

        // The tree is where it goes from the tab's first frame, not at its top until the folder has been read.
        @Test(arguments: [false, true])
        func aNewTabOnAFavoriteDrawsTheTreeWhereItWasScrolled(selectFavorite: Bool) async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, favorite) = try await tabWithLongTree(harness)
            if selectFavorite {
                tab.sidebarController.model.selectItem(.favorite(favorite))
                #expect(await waitUntil { tab.shownFolderPath == favorite })
                await arrived(tab)
                tab.sidebarController.tree.scrollTop = 300
                harness.layout(tab)
            }

            tab.perform(.newTab)
            let new = try justOpened(tab, harness)
            #expect(new.sidebarController.tree.scrollTop == 300)

            await firstRead(new)
            harness.layout(new)
            #expect(new.sidebarController.tree.scrollTop == 300)
            await harness.close()
        }

        // ⌘-click on a favorite: the tab's first frame has the whole tree, with the folder's row in view.
        @Test func aFolderOpenedInANewTabDrawsTheTreeWithItsRowInView() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, favorite) = try await tabWithLongTree(harness)
            let source = tab.sidebarController

            source.openInNewTab(favorite)
            let new = try justOpened(tab, harness)
            let controller = new.sidebarController
            #expect(controller.model.selected == .filesystem(favorite))
            // By the folders alone: a tab in the harness reads its favorites from the app's until it is given the harness's.
            #expect(controller.tree.rowCount > 80)
            let row = try #require(controller.tree.index(ofItem: .filesystem(favorite)))
            #expect(controller.tree.isFullyVisible(row))
            let top = controller.tree.scrollTop
            #expect(top > 0)

            await firstRead(new)
            harness.layout(new)
            #expect(new.shownFolderPath == favorite)
            #expect(controller.tree.scrollTop == top)
            await harness.close()
        }

        // A folder that can't be read (the Trash, without Full Disk Access) stays in a new or duplicated tab, showing
        // the same error, on the same sidebar row.
        @Test(arguments: [false, true])
        func aNewTabOrACopyStaysOnAFolderThatCannotBeRead(duplicate: Bool) async throws {
            let harness = try ExplorerHarness.windowless()
            let locked = URL(fileURLWithPath: real(harness, "")).appending(path: "Locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            let tab = try await harness.open()
            let model = tab.sidebarController.model
            model.selectItem(.favorite(locked.path))
            #expect(await waitUntil { tab.shownFolderPath == locked.path })
            await arrived(tab)
            guard case .failed = tab.content.loadState else {
                Issue.record("the folder should show its error")
                return
            }
            let group = try #require(tab.group)

            if duplicate { group.duplicateTab(tab) } else { tab.perform(.newTab) }
            let new = try await opened(tab, after: 1)

            #expect(new.shownFolderPath == locked.path)
            #expect(new.content.loadState == tab.content.loadState)
            #expect(new.sidebarController.model.selected == .favorite(locked.path))
            #expect(new.navigationHistory.current == locked.path)
            await harness.close()
        }

        // A Go To that failed left its message over the folder on screen, and the new tab shows the same.
        @Test(arguments: [false, true])
        func aNewTabOrACopyKeepsTheMessageOverTheFolder(duplicate: Bool) async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let locked = URL(fileURLWithPath: real(harness, "")).appending(path: "Locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            var failure: String?
            await tab.navigate(to: locked, goToFailure: { failure = $0 })
            let message = try #require(failure)
            #expect(tab.content.readError?.message == message)
            let group = try #require(tab.group)

            if duplicate { group.duplicateTab(tab) } else { tab.perform(.newTab) }
            let new = try await opened(tab, after: 1)

            #expect(new.shownFolderPath == tab.shownFolderPath)
            #expect(new.content.readError?.message == message)
            #expect(new.content.loadState == .loaded)
            #expect(!new.content.listed.isEmpty)
            await harness.close()
        }

        /// A tab showing search results for `names`, Details being the view of both its folder and its results.
        private func tabWithResults(_ harness: ExplorerHarness, _ names: [String]) async throws
            -> MainWindowController
        {
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            tab.perform(.viewAsDetails)
            harness.layout(tab)
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { tab.content.searchDisplay?.results.count == names.count })
            return tab
        }

        // A duplicate takes the selection, filter and scroll whether results are showing or not, and leaves the search
        // out: they narrow, select and scroll the copy's folder.
        @Test func duplicateTabOverResultsCarriesTheirSelectionFilterAndScrollToTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let names = (100..<400).map { "f\($0).txt" }
            for name in names {
                try "x".write(to: harness.folder.appending(name), atomically: false, encoding: .utf8)
            }
            let tab = try await tabWithResults(harness, names)
            tab.content.setSearchFilter("f1")
            let chosen = real(harness, "f150.txt")
            tab.content.applySelection(.single(chosen))
            harness.layout(tab)
            tab.content.pane?.scrollPosition = (top: 60, left: 0)
            let scroll = try #require(tab.content.pane?.scrollPosition)
            #expect(scroll.top > 0)
            let group = try #require(tab.group)

            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)
            harness.layout(copy)

            #expect(copy.searchRootPath == nil)
            #expect(copy.selectedPaths == [chosen])
            #expect(copy.content.filter == "f1")
            // Fuzzy, the default: f100 to f199, and the f2… and f3… names with a 1 after the f.
            #expect(copy.content.entries.count == 138)
            #expect(copy.content.pane?.scrollPosition.top == scroll.top)
            // The results stay in the tab they are in.
            #expect(tab.searchRootPath != nil)
            await harness.close()
        }

        // A selected result the folder's filter hides brings the whole list back.
        @Test func duplicateTabOverResultsClearsAFilterThatHidesTheSelectedResult() async throws {
            let harness = try ExplorerHarness.windowless()
            let names = ["f1.txt", "f2.txt"]
            for name in names {
                try "x".write(to: harness.folder.appending(name), atomically: false, encoding: .utf8)
            }
            let tab = try await tabWithResults(harness, names)
            tab.content.setSearchFilter("f1")
            let hidden = real(harness, "f2.txt")
            tab.content.applySelection(.single(hidden))
            #expect(tab.content.filter == "f1")
            let group = try #require(tab.group)

            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)

            #expect(copy.selectedPaths == [hidden])
            #expect(copy.content.filter.isEmpty)
            await harness.close()
        }

        // A selected result that isn't in the folder is not among the copy's selected items.
        @Test func duplicateTabOverResultsLeavesOutAResultThatIsNotInTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await tabWithResults(harness, ["Alpha/Inner"])
            let inner = real(harness, "Alpha/Inner")
            tab.content.applySelection(.single(inner))
            #expect(tab.selectedPaths == [inner])
            let group = try #require(tab.group)

            group.duplicateTab(tab)
            let copy = try await opened(tab, after: 1)

            #expect(copy.searchRootPath == nil)
            #expect(copy.selectedPaths.isEmpty)
            #expect(copy.content.filter.isEmpty)
            await harness.close()
        }

        // openNewTab drops all of it, results or not.
        @Test func aNewTabOverResultsStartsWithNothingSelectedOrTyped() async throws {
            let harness = try ExplorerHarness.windowless()
            let names = ["f1.txt", "f2.txt"]
            for name in names {
                try "x".write(to: harness.folder.appending(name), atomically: false, encoding: .utf8)
            }
            let tab = try await tabWithResults(harness, names)
            tab.content.setSearchFilter("f1")
            #expect(!tab.selectedPaths.isEmpty)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            #expect(new.searchRootPath == nil)
            #expect(new.selectedPaths.isEmpty)
            #expect(new.content.filter.isEmpty)
            await harness.close()
        }

        // The row that was selected stays, a favorite's among them.
        @Test func aNewTabKeepsTheFavoriteRowSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open()
            let model = tab.sidebarController.model
            model.selectItem(.favorite(alpha.path))
            #expect(await waitUntil { tab.shownFolderPath == alpha.path })
            await arrived(tab)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            #expect(new.sidebarController.model.selected == .favorite(alpha.path))
            await harness.close()
        }

        // Hiding the tree while it has the keyboard gives the keyboard to the list.
        @Test func hidingTheTreeWithTheKeyboardInItGivesTheKeyboardToTheList() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusTreePane)
            #expect(tab.focusedPane == .tree)

            tab.perform(.toggleFolderTree)

            #expect(tab.panels.folderTreeOpen == false)
            #expect(tab.focusedPane == .content)
            #expect(tab.content.paneHasKeyboard)
            await harness.close()
        }

        @Test func hidingTheTreeLeavesAKeyboardElsewhereWhereItIs() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.window?.makeFirstResponder(nil)

            tab.perform(.toggleFolderTree)

            #expect(tab.focusedPane == nil)
            await harness.close()
        }

        // The keyboard goes to the pane the tab had it in, and each tab keeps its own: a new tab, a folder opened in
        // a new tab and `duplicateTab` from the tree keep it in the tree, and a new tab from the list keeps it there.
        @Test func aTabOpenedFromATabKeepsTheKeyboardInItsPane() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusTreePane)
            let group = try #require(tab.group)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)
            #expect(new.focusedPane == .tree)
            new.perform(.focusContentPane)
            #expect(new.focusedPane == .content)
            #expect(tab.focusedPane == .tree)

            group.openTab(path: real(harness, "Alpha"), from: tab)
            let path = try await opened(tab, after: 2)
            #expect(path.focusedPane == .tree)
            // A tab opened on a folder starts from the other tab's tree, with the folder's own row selected.
            #expect(path.sidebarController.model.selected == .filesystem(real(harness, "Alpha")))

            path.perform(.focusTreePane)
            group.duplicateTab(path)
            let copy = try await opened(path, after: 3)
            #expect(copy.focusedPane == .tree)

            // From the list.
            #expect(new.focusedPane == .content)
            new.perform(.newTab)
            let fromList = try await opened(new, after: 4)
            #expect(fromList.focusedPane == .content)
            await harness.close()
        }

        // MARK: Refresh

        // Refresh reads the root, the folders above and the folder again.
        @Test func refreshReadsTheTreeAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open(alpha.path)
            let model = tab.sidebarController.model
            #expect(await waitUntil { model.nodes[alpha.path] != nil })
            await arrived(tab)

            let added = URL(fileURLWithPath: real(harness, "")).appending(path: "Added")
            try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
            let below = alpha.appending(path: "Below")
            try FileManager.default.createDirectory(at: below, withIntermediateDirectories: true)
            tab.perform(.refreshOrApplySearchSort)

            #expect(await waitUntil { model.nodes[real(harness, "")]?.childPaths.contains(added.path) == true })
            #expect(await waitUntil { model.nodes[alpha.path]?.childPaths.contains(below.path) == true })
            #expect(model.selected == .filesystem(alpha.path))
            await harness.close()
        }

        // With a favorite's row selected the tree isn't touched by a refresh. A sort change, `toggleFoldersFirst` and
        // `toggleHiddenFiles` take one path here, `viewChanged`, and hidden files adds to it: the favorite's row and
        // the tree stay where they are.
        @Test func refreshingOrChangingTheViewKeepsAFavoriteRowAndTheTreeWhereItIs() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open(real(harness, "Beta"))
            let model = tab.sidebarController.model
            model.selectItem(.favorite(alpha.path))
            #expect(await waitUntil { tab.shownFolderPath == alpha.path })
            // The favorite's own opening brought the tree along: that is over before the view changes.
            #expect(await waitUntil { model.nodes[alpha.path] != nil && model.selected == .favorite(alpha.path) })
            #expect(await waitUntil { model.nodes[real(harness, "")]?.loaded == true })
            await arrived(tab)

            let added = URL(fileURLWithPath: real(harness, "")).appending(path: "Added")
            try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
            tab.perform(.refreshOrApplySearchSort)
            try? await Task.sleep(for: .milliseconds(100))

            #expect(model.nodes[real(harness, "")]?.childPaths.contains(added.path) != true)
            #expect(model.selected == .favorite(alpha.path))

            await arrived(tab)
            let root = model.rootPath
            let nodes = model.nodes[alpha.path]

            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { !tab.isNavigating })
            try? await Task.sleep(for: .milliseconds(100))

            #expect(model.selected == .favorite(alpha.path))
            #expect(tab.favoritePath == alpha.path)
            #expect(model.rootPath == root)
            #expect(model.nodes[alpha.path] == nodes)
            await harness.close()
        }

        // A link's row stays on a change of the view, and a folder's on a new order.
        @Test func changingTheViewKeepsALinkRowAndANewOrderAFolderRow() async throws {
            let harness = try ExplorerHarness.windowless()
            let link = URL(fileURLWithPath: real(harness, "")).appending(path: "Link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: harness.folder.appending("Beta"))
            let tab = try await harness.open()
            let model = tab.sidebarController.model
            #expect(await waitUntil { model.nodes[real(harness, "")] != nil })
            await model.loadChildren(real(harness, ""), expandOnSuccess: true)
            #expect(await waitUntil { model.nodes[link.path]?.isSymlink == true })
            model.selectItem(.filesystem(link.path))
            #expect(await waitUntil { tab.folder.lastPathComponent == "Beta" })
            await arrived(tab)

            tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { !tab.isNavigating })
            try? await Task.sleep(for: .milliseconds(100))

            #expect(model.selected == .filesystem(link.path))

            let alpha = real(harness, "Alpha")
            await tab.navigate(to: URL(fileURLWithPath: alpha))
            await arrived(tab)
            #expect(model.selected == .filesystem(alpha))
            tab.setSort(.size, .desc)
            #expect(await waitUntil { !tab.isNavigating })
            await arrived(tab)

            #expect(model.selected == .filesystem(alpha))
            await harness.close()
        }
    }
}
