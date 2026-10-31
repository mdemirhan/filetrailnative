// Ports what a tab takes along of apps/desktop/src/renderer/hooks/useExplorerTabs.ts (captureLiveTab, openNewTab,
// duplicateTab, openPathInNewTab), and App.tsx's rule for a tree that is hidden with the keyboard in it
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
            try? await Task.sleep(for: .milliseconds(100))
        }

        /// A tab with Alpha open in the tree though it shows the folder above it.
        private func tabWithAlphaOpen(_ harness: ExplorerHarness) async throws -> MainWindowController {
            let tab = try await harness.open()
            await tab.navigate(to: harness.folder.appending("Alpha/Inner"))
            let alpha = real(harness, "Alpha")
            #expect(await waitUntil { tab.sidebarController.model.nodes[alpha]?.expanded == true })
            await tab.navigate(to: URL(fileURLWithPath: real(harness, "")), history: .back)
            try? await Task.sleep(for: .milliseconds(100))
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

        // B-NAV-054 B-NAV-172 B-NAV-192 B-SEL-121 B-VIEW-164
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

        // F-673
        // B-NAV-010 B-NAV-054 B-SEL-086 T-aa6d3211
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

        // F-673: the tree's scroll goes along with its rows.
        // B-TREE-139 B-TREE-140 T-01c23ea5
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

        // captureLiveTab's directoryError, openNewTab's and duplicateTab's mode "none": a folder that can't be read (the
        // Trash, without Full Disk Access) stays in the new tab, showing the same error, on the same sidebar row.
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
            try? await Task.sleep(for: .milliseconds(100))
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

        // captureLiveTab's directoryError: a Go To that failed left its message over the folder on screen, and the new
        // tab shows the same.
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
            #expect(tab.content.readError == message)
            let group = try #require(tab.group)

            if duplicate { group.duplicateTab(tab) } else { tab.perform(.newTab) }
            let new = try await opened(tab, after: 1)

            #expect(new.shownFolderPath == tab.shownFolderPath)
            #expect(new.content.readError == message)
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

        // captureLiveTab takes the selection, filter and scroll whether results are showing or not, and duplicateTab only
        // sets `search: null`: they narrow, select and scroll the copy's folder.
        // B-SRCH-165
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
            #expect(copy.content.entries.count == 100)
            #expect(copy.content.pane?.scrollPosition.top == scroll.top)
            // The results stay in the tab they are in.
            #expect(tab.searchRootPath != nil)
            await harness.close()
        }

        // useExplorerNavigationController.ts:668: a selected result the folder's filter hides brings the whole list back.
        // B-NAV-173 B-SEL-028
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

        // applyContentSelection: a selected result that isn't in the folder is not among the copy's selected items.
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
        // B-SEL-086 B-SRCH-165
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

        // F-673: the row that was selected stays, a favorite's among them.
        // T-6c54c49c T-d4d05739
        @Test func aNewTabKeepsTheFavoriteRowSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open()
            let model = tab.sidebarController.model
            model.selectItem(.favorite(alpha.path))
            #expect(await waitUntil { tab.shownFolderPath == alpha.path })
            try? await Task.sleep(for: .milliseconds(100))

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            #expect(new.sidebarController.model.selected == .favorite(alpha.path))
            await harness.close()
        }

        // App.tsx: "Hiding the tree while it has the keyboard gives the keyboard to the list".
        // B-NAV-101 B-NAV-224 B-TREE-018
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

        // T-2ddaf09f F-673: the keyboard goes to the pane the tab had it in, and each tab keeps its own.
        // B-NAV-191 B-SEL-121 B-TREE-119 B-TREE-121 T-2c22c9b4 T-c0704916
        @Test func aNewTabOpenedFromTheTreeKeepsTheKeyboardInTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusTreePane)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            #expect(new.focusedPane == .tree)
            new.perform(.focusContentPane)
            #expect(new.focusedPane == .content)
            #expect(tab.focusedPane == .tree)
            await harness.close()
        }

        // `openPathInNewTab` and `duplicateTab` keep the pane too.
        // B-NAV-191 B-NAV-224 B-TREE-058
        @Test func openingAFolderOrDuplicatingFromTheTreeKeepsTheKeyboardInTheTree() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusTreePane)
            let group = try #require(tab.group)

            group.openTab(path: real(harness, "Alpha"), from: tab)
            let path = try await opened(tab, after: 1)
            #expect(path.focusedPane == .tree)
            // `view: null`: the tree isn't carried by a tab opened on a folder, and the folder's own row is selected.
            #expect(path.sidebarController.model.selected == .filesystem(real(harness, "Alpha")))

            path.perform(.focusTreePane)
            group.duplicateTab(path)
            let copy = try await opened(path, after: 2)
            #expect(copy.focusedPane == .tree)
            await harness.close()
        }

        // App.tsx:1662, `focusContent`: a folder opened by another app gives the list the keyboard.
        // B-NAV-191
        @Test func aFolderFromAnotherAppGivesTheListTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusTreePane)
            let group = try #require(tab.group)

            group.openTab(path: real(harness, "Alpha"), from: tab, openedItem: .folder)
            let new = try await opened(tab, after: 1)

            #expect(new.focusedPane == .content)
            await harness.close()
        }

        // B-NAV-191
        @Test func aNewTabWithTheKeyboardInTheListKeepsItThere() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.perform(.focusContentPane)

            tab.perform(.newTab)
            let new = try await opened(tab, after: 1)

            #expect(new.focusedPane == .content)
            await harness.close()
        }

        // MARK: Refresh

        // useExplorerNavigationController.ts `refreshDirectory`: the root, the folders above and the folder are read again.
        // B-NAV-124
        @Test func refreshReadsTheTreeAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open(alpha.path)
            let model = tab.sidebarController.model
            #expect(await waitUntil { model.nodes[alpha.path] != nil })
            try? await Task.sleep(for: .milliseconds(100))

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

        // `getSelectedTreeReloadOptions`: with a favorite's row selected the tree isn't touched.
        // B-TREE-181
        @Test func refreshLeavesTheTreeAloneWithAFavoriteRowSelected() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open()
            let model = tab.sidebarController.model
            model.selectItem(.favorite(alpha.path))
            #expect(await waitUntil { tab.shownFolderPath == alpha.path })
            #expect(await waitUntil { model.nodes[real(harness, "")]?.loaded == true })
            try? await Task.sleep(for: .milliseconds(100))

            let added = URL(fileURLWithPath: real(harness, "")).appending(path: "Added")
            try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
            tab.perform(.refreshOrApplySearchSort)
            try? await Task.sleep(for: .milliseconds(200))

            #expect(model.nodes[real(harness, "")]?.childPaths.contains(added.path) != true)
            #expect(model.selected == .favorite(alpha.path))
            await harness.close()
        }

        // MARK: A new order, Folders First and hidden files

        private func changeTheView(_ tab: MainWindowController, _ change: Int) {
            switch change {
            case 0: tab.setSort(.size, .desc)
            case 1: tab.perform(.toggleFoldersFirst)
            default: tab.perform(.toggleHiddenFiles)
            }
        }

        // useExplorerNavigationController.ts `handleSortChange`, `toggleFoldersFirst`, `toggleHiddenFiles`.
        // B-NAV-130 T-bae92ca4
        @Test(arguments: 0..<3)
        func changingTheViewKeepsAFavoriteRowAndTheTreeWhereItIs(change: Int) async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = URL(fileURLWithPath: real(harness, "Alpha"))
            let tab = try await harness.open(real(harness, "Beta"))
            let model = tab.sidebarController.model
            model.selectItem(.favorite(alpha.path))
            #expect(await waitUntil { tab.shownFolderPath == alpha.path })
            // The favorite's own opening brought the tree along: that is over before the view changes.
            #expect(await waitUntil { model.nodes[alpha.path] != nil && model.selected == .favorite(alpha.path) })
            try? await Task.sleep(for: .milliseconds(100))
            let root = model.rootPath
            let nodes = model.nodes[alpha.path]

            changeTheView(tab, change)
            #expect(await waitUntil { !tab.isNavigating })
            try? await Task.sleep(for: .milliseconds(200))

            #expect(model.selected == .favorite(alpha.path))
            #expect(tab.favoritePath == alpha.path)
            #expect(model.rootPath == root)
            #expect(model.nodes[alpha.path] == nodes)
            await harness.close()
        }

        // B-NAV-130
        @Test(arguments: 0..<3)
        func changingTheViewKeepsALinkRow(change: Int) async throws {
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
            try? await Task.sleep(for: .milliseconds(100))

            changeTheView(tab, change)
            #expect(await waitUntil { !tab.isNavigating })
            try? await Task.sleep(for: .milliseconds(200))

            #expect(model.selected == .filesystem(link.path))
            await harness.close()
        }

        // T-4023bc38
        @Test func aNewOrderKeepsAFolderRowOnTheFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = real(harness, "Alpha")
            let tab = try await harness.open(alpha)
            let model = tab.sidebarController.model

            tab.setSort(.size, .desc)
            #expect(await waitUntil { !tab.isNavigating })
            try? await Task.sleep(for: .milliseconds(100))

            #expect(model.selected == .filesystem(alpha))
            await harness.close()
        }
    }
}
