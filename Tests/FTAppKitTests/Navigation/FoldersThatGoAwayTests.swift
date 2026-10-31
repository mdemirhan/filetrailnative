// What the window does with folders that can't be read or have gone: useExplorerNavigationController.ts (navigateTo,
// navigateToNearestExistingFolder, reloadFolderInPlace), useExplorerTabs.ts and the startup of App.tsx
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

/// A tab just made shows its folder's name before it has read it.
@MainActor
private func firstFolderRead(_ tab: MainWindowController) async -> Bool {
    var read = false
    tab.whenFirstReadFinished { _ in read = true }
    return await waitUntil { read }
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct FoldersThatGoAwayTests {
        private func path(_ harness: ExplorerHarness, _ name: String) -> String {
            harness.folder.appending(name).path
        }

        private func entry(_ tab: MainWindowController, _ name: String) throws -> DirectoryEntry {
            try #require(tab.content.listed.first { $0.name == name })
        }

        private func chmod(_ path: String, _ mode: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }

        /// The listing read a moment ago is not asked for again (the cache keeps answers for 3 s, as the original's does).
        private func forgetListings(_ harness: ExplorerHarness) {
            harness.services.directoryService.cache.clear()
        }

        private func opening(
            _ harness: ExplorerHarness, _ tab: MainWindowController, _ path: String
        ) async -> Bool {
            tab.go(to: URL(fileURLWithPath: path))
            return await waitUntil { tab.shownFolderPath == path && !tab.isNavigating }
        }

        // B-NAV-006: a double-click on a folder that can't be read: the folder on screen stays, its history too, with why.
        @Test func anUnreadableFolderFromTheListLeavesTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let alpha = path(harness, "Alpha")
            try chmod(alpha, 0o000)
            defer { try? chmod(alpha, 0o755) }
            forgetListings(harness)
            let history = tab.historyPaths
            tab.open([try entry(tab, "Alpha")])
            let message = "EACCES: permission denied, scandir '\(alpha)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == harness.folder.path)
            #expect(tab.historyPaths == history)
            #expect(tab.window?.title == harness.folder.url.lastPathComponent)
            #expect(!tab.content.listed.isEmpty)
            await harness.close()
        }

        // B-NAV-006: Enclosing Folder to a parent that can't be read.
        // B-NAV-055
        @Test func anUnreadableEnclosingFolderLeavesTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(path(harness, "Alpha/Inner"))
            let alpha = path(harness, "Alpha")
            try chmod(alpha, 0o311)
            defer { try? chmod(alpha, 0o755) }
            forgetListings(harness)
            tab.perform(.goEnclosingFolder)
            let message = "EACCES: permission denied, scandir '\(alpha)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == path(harness, "Alpha/Inner"))
            #expect(tab.historyPaths == [path(harness, "Alpha/Inner")])
            await harness.close()
        }

        // B-NAV-022: Back to a folder that is gone tells it on the card, with no sheet to dismiss; the history has moved.
        @Test func backToAGoneFolderShowsTheCard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let alpha = path(harness, "Alpha")
            #expect(await opening(harness, tab, alpha))
            #expect(await opening(harness, tab, path(harness, "Beta")))
            try FileManager.default.removeItem(atPath: alpha)
            forgetListings(harness)
            tab.perform(.goBack)
            let message = "ENOENT: no such file or directory, stat '\(alpha)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.window?.attachedSheet == nil)
            #expect(tab.shownFolderPath == path(harness, "Beta"))
            #expect(tab.historyIndex == 1)
            await harness.close()
        }

        // B-NAV-007: a favorite whose folder is gone opens with its error, and its row is selected.
        // B-NAV-080 B-TREE-048 B-TREE-102
        @Test func aGoneFavoriteOpensWithItsError() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let gone = path(harness, "Gone")
            let model = tab.sidebarController.model
            model.selectItem(.favorite(gone))
            let message = "ENOENT: no such file or directory, stat '\(gone)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == gone)
            #expect(tab.content.listed.isEmpty)
            #expect(tab.historyPaths.last == gone)
            #expect(await waitUntil { model.selected == .favorite(gone) && model.optimistic == nil })
            await harness.close()
        }

        // B-NAV-007: a location too, its tree going back to its top.
        // B-NAV-081 B-TREE-102
        @Test func aGoneLocationOpensWithItsError() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let gone = "/Volumes/No Such Disk \(UUID().uuidString)"
            let model = tab.sidebarController.model
            model.selectItem(.location(gone))
            #expect(await waitUntil { tab.shownFolderPath == gone && !tab.isNavigating })
            #expect(await waitUntil { model.selected == .location(gone) })
            #expect(tab.historyPaths.last == gone)
            let top = TreePaths.resolveRootPath(for: gone, homePath: model.homePath)
            #expect(await waitUntil { tab.treeRootPath == top })
            await harness.close()
        }

        // A row of the tree stays selected when its folder doesn't open, as the original's does: it isn't given way to.
        // B-TREE-102
        @Test func aTreeRowThatDoesNotOpenLeavesTheFolderOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let gone = path(harness, "Gone")
            tab.sidebarController.model.selectItem(.filesystem(gone))
            let message = "ENOENT: no such file or directory, stat '\(gone)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == harness.folder.path)
            await harness.close()
        }

        // B-NAV-001 `response.path`: the folder is its real path, in the path bar, the tree and the history.
        // B-NAV-055 B-SEL-115 B-TREE-099 T-e07c2ef1
        @Test func theFolderOnScreenIsItsRealPath() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let beta = path(harness, "Beta")
            tab.go(to: URL(fileURLWithPath: path(harness, "Alpha/../Beta")))
            #expect(await waitUntil { tab.shownFolderPath == beta })
            #expect(tab.historyPaths.last == beta)
            #expect(tab.content.folderPath == beta)
            try FileManager.default.createSymbolicLink(
                atPath: path(harness, "Link"), withDestinationPath: path(harness, "Alpha"))
            tab.go(to: URL(fileURLWithPath: path(harness, "Link")))
            #expect(await waitUntil { tab.shownFolderPath == path(harness, "Alpha") })
            #expect(tab.historyPaths.last == path(harness, "Alpha"))
            tab.perform(.goEnclosingFolder)
            #expect(await waitUntil { tab.shownFolderPath == harness.folder.path })
            await harness.close()
        }

        // A tab that starts on a folder by another spelling.
        @Test func aTabOpenedByAnotherSpellingShowsTheRealPath() async throws {
            let harness = try ExplorerHarness.windowless()
            try FileManager.default.createSymbolicLink(
                atPath: path(harness, "Link"), withDestinationPath: path(harness, "Alpha"))
            let tab = try await harness.open(path(harness, "Link"))
            #expect(tab.shownFolderPath == path(harness, "Alpha"))
            #expect(tab.historyPaths == [path(harness, "Alpha")])
            await harness.close()
        }

        // T-9bca212e: the folder is read again when the tab comes back, the selection staying and the history as it was.
        // B-NAV-013 B-NAV-192 B-NAV-194 B-TREE-181 B-VIEW-166 T-aa6d3211
        @Test func aTabThatComesBackReadsItsFolderAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(path(harness, "Alpha"))
            let group = try #require(tab.group)
            let inner = try entry(tab, "Inner")
            tab.content.select(paths: [inner.path])
            group.openTab(path: path(harness, "Beta"), from: tab)
            let other = try #require(group.tabs.last)
            #expect(await waitUntil { other.shownFolderPath == path(harness, "Beta") && !other.isNavigating })
            try "x".write(toFile: path(harness, "Alpha/Made Meanwhile.txt"), atomically: true, encoding: .utf8)
            forgetListings(harness)
            let history = tab.historyPaths
            group.select(tab)
            #expect(await waitUntil { tab.content.listed.contains { $0.name == "Made Meanwhile.txt" } })
            #expect(tab.content.selection.paths == [inner.path])
            #expect(tab.historyPaths == history)
            await harness.close()
        }

        // T-d5f7b879: the folder is gone meanwhile: the nearest one above it opens, in place in the history.
        // B-NAV-120 B-NAV-195 B-SEL-176 B-TREE-182 B-VIEW-170 B-VIEW-194
        @Test func aTabWhoseFolderWentOpensTheNearestFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open(path(harness, "Alpha/Inner"))
            let group = try #require(tab.group)
            group.openTab(path: path(harness, "Beta"), from: tab)
            let other = try #require(group.tabs.last)
            #expect(await waitUntil { other.shownFolderPath == path(harness, "Beta") && !other.isNavigating })
            try FileManager.default.removeItem(atPath: path(harness, "Alpha"))
            forgetListings(harness)
            group.select(tab)
            #expect(await waitUntil { tab.shownFolderPath == harness.folder.path })
            #expect(tab.historyPaths == [harness.folder.path])
            await harness.close()
        }

        // T-e1ce4669
        // B-NAV-120 B-NAV-195 B-SEL-176 B-SEL-177 B-TREE-031 B-VIEW-170 B-VIEW-194 T-40e2d626
        @Test func aTabStaysOnAFolderItCannotReadWhenItComesBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = path(harness, "Alpha")
            let tab = try await harness.open(alpha)
            let group = try #require(tab.group)
            group.openTab(path: path(harness, "Beta"), from: tab)
            let other = try #require(group.tabs.last)
            #expect(await waitUntil { other.shownFolderPath == path(harness, "Beta") && !other.isNavigating })
            try chmod(alpha, 0o000)
            defer { try? chmod(alpha, 0o755) }
            forgetListings(harness)
            group.select(tab)
            let message = "EACCES: permission denied, scandir '\(alpha)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == alpha)
            #expect(tab.content.listed.isEmpty)
            await harness.close()
        }

        // B-INFO-008: Show Info's item doesn't outlast the tab going to the back.
        // B-NAV-206
        @Test func showInfosItemGoesWithTheTab() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let note = path(harness, "note.txt")
            tab.infoController?.showInfo(for: note)
            #expect(tab.infoController?.targetPath == note)
            group.openTab(path: path(harness, "Beta"), from: tab)
            let other = try #require(group.tabs.last)
            #expect(await waitUntil { other.shownFolderPath == path(harness, "Beta") && !other.isNavigating })
            group.select(tab)
            #expect(await waitUntil { tab.infoController?.targetPath != note })
            await harness.close()
        }

        // P5-17: a new tab on a folder gone by the time it is read opens the nearest folder above it.
        // B-NAV-138
        @Test func aNewTabOnAGoneFolderOpensTheNearestFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openTab(path: path(harness, "Gone/Deeper"), from: tab)
            let other = try #require(group.tabs.last)
            #expect(await waitUntil { other.shownFolderPath == harness.folder.path })
            #expect(other.historyPaths == [harness.folder.path])
            await harness.close()
        }

        // B-NAV-122 B-TREE-186: a window whose saved folder has gone opens Home, with the tree at Home.
        @Test func aWindowOnAGoneFolderOpensHome() async throws {
            let harness = try ExplorerHarness.windowless()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let tab = try await harness.open(path(harness, "Gone"))
            #expect(await waitUntil { tab.shownFolderPath == home })
            #expect(await waitUntil { tab.treeRootPath == home })
            #expect(tab.historyPaths == [home])
            await harness.close()
        }

        // B-NAV-122: one that can't be read too.
        @Test func aWindowOnAnUnreadableFolderOpensHome() async throws {
            let harness = try ExplorerHarness.windowless()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let alpha = path(harness, "Alpha")
            try chmod(alpha, 0o000)
            defer { try? chmod(alpha, 0o755) }
            let tab = try await harness.open(alpha)
            #expect(await waitUntil { tab.shownFolderPath == home })
            #expect(tab.treeRootPath == home)
            await harness.close()
        }

        // B-NAV-122: a favorite the window starts on shows its error instead.
        @Test func aWindowOnAGoneFavoriteShowsItsError() async throws {
            let harness = try ExplorerHarness.windowless()
            let gone = path(harness, "Gone")
            let startup = StartupTab(
                path: gone, rootPath: harness.folder.path, favoritePath: gone, viewMode: .details,
                searchViewMode: .details, sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true,
                favoritesExpanded: true, locationsExpanded: true)
            let tab = MainWindowController(tab: startup, loadNow: false, startsTheWindow: true)
            tab.servicesOverride = harness.services
            tab.ensureLoaded()
            let message = "ENOENT: no such file or directory, stat '\(gone)'"
            #expect(await waitUntil { tab.content.container(for: .error(message: message)) })
            #expect(tab.shownFolderPath == gone)
            #expect(tab.sidebarController.model.selected == .favorite(gone))
            tab.window?.close()
            await harness.close()
        }

        // B-NAV-121: the search for a folder that can be read passes one that can't.
        // B-NAV-138 B-VIEW-194 T-5a8447d3
        @Test func theNearestFolderIsOneThatCanBeRead() async throws {
            let harness = try ExplorerHarness.windowless()
            let inner = path(harness, "Alpha/Inner")
            let tab = try await harness.open(inner)
            let alpha = path(harness, "Alpha")
            try FileManager.default.removeItem(atPath: inner)
            try chmod(alpha, 0o300)
            defer { try? chmod(alpha, 0o755) }
            forgetListings(harness)
            tab.reload()
            #expect(await waitUntil { tab.shownFolderPath == harness.folder.path })
            await harness.close()
        }

        // B-NAV-121: a newer navigation takes over from the search for a folder that can be read.
        // B-NAV-023
        @Test func aNewerNavigationEndsTheSearchForANearerFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let inner = path(harness, "Alpha/Inner")
            let alpha = path(harness, "Alpha")
            let beta = path(harness, "Beta")
            let tab = try await harness.open(inner)
            tab.servicesOverride = ExplorerServices(
                directoryService: DirectoryService(fileSystem: SlowFolder(slow: alpha)), folderWatches: nil,
                iconStore: nil, volumeWatcher: nil, clipboard: harness.windows.clipboard, preferences: harness.channel)
            try FileManager.default.removeItem(atPath: inner)
            tab.reload()
            // The walk is reading Alpha; the user goes elsewhere.
            try await Task.sleep(for: .milliseconds(100))
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta })
            try await Task.sleep(for: .milliseconds(1200))
            #expect(tab.shownFolderPath == beta)
            await harness.close()
        }

        // `applyEmptyDirectorySnapshot`: letting go of the folder puts the results away, but what is typed stays.
        // B-NAV-123
        @Test func aHeadingKeepsTheTypedTextAndStopsTheSearch() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            tab.search.session.engine = engine
            let timers = ManualTimers()
            tab.search.session.timers = timers
            engine.finds = { _ in (["note.txt"], false, false) }
            let session = tab.search.session
            let field = try #require(tab.searchField)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(await waitUntil { session.resultsVisible })
            tab.sidebarController.model.clearSelection()
            #expect(!session.resultsVisible)
            #expect(session.draftQuery == "note")
            #expect(tab.shownFolderPath.isEmpty)
            await harness.close()
        }
    }

    /// The visit hook is the app's one: no other test at the same time.
    @MainActor
    @Suite(.windowlessAlone) struct FolderUseTests {
        // `noteFolderUsed`: a folder used for something before it is left counts as a stay.
        // B-NAV-071
        @Test func usingAFolderCountsAsAStay() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let alpha = harness.folder.appending("Alpha").path
            let beta = harness.folder.appending("Beta").path
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha })
            tab.onFolderUsed?()
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta })
            #expect(await waitUntil { store.folders().contains { $0.path == alpha && !$0.visits.isEmpty } })
            await harness.close()
        }

        /// Goes to Alpha, does `use`, goes on to Beta: whether Alpha counted as a stay.
        private func staysAfter(
            _ use: (MainWindowController) throws -> Void
        ) async throws -> Bool {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let alpha = harness.folder.appending("Alpha").path
            let beta = harness.folder.appending("Beta").path
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            try use(tab)
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { tab.shownFolderPath == beta && !tab.isNavigating })
            let stayed = store.folders().contains { $0.path == alpha && !$0.visits.isEmpty }
            await harness.close()
            return stayed
        }

        private func subject(_ tab: MainWindowController, _ name: String) throws -> ContextMenuSubject {
            let path = try #require(tab.content.listed.first { $0.name == name }).path
            return ContextMenuSubject(
                surface: .content, paths: [path], targetPath: path, entries: [CommandEntry(path: path, kind: .file)])
        }

        private static let zed = OpenWithAction.application(
            id: "zed", label: "Zed", appPath: "/Applications/Zed.app", appName: "Zed", always: false)

        // useExplorerActions.ts `openPathInTerminal`.
        @Test func theMenusTerminalCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                tab.contextMenus.contextMenu(perform: .terminal, subject: try subject(tab, "Inner"))
            }
            #expect(stayed)
        }

        // `openPathsWithApplication`: Open With.
        @Test func theMenusOpenWithCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                tab.contextMenus.contextMenu(
                    open: [try subject(tab, "Inner").paths[0]], with: Self.zed, kind: nil)
            }
            #expect(stayed)
        }

        // `openPathInTerminal`, from the Info panel.
        @Test func theInfoPanelsTerminalCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                try #require(tab.infoController).actions.openInTerminal(tab.shownFolderPath)
            }
            #expect(stayed)
        }

        // `editPathInTextEditor` is `openPathsWithApplication`.
        // T-8a7d2ddb
        @Test func theInfoPanelsEditCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                try #require(tab.infoController).actions.edit(tab.shownFolderPath + "/note.txt")
            }
            #expect(stayed)
        }

        // `openPathsWithApplication`, from the Info panel's Open With.
        @Test func theInfoPanelsOpenWithCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                try #require(tab.infoController).actions.runOpenWith(
                    Self.zed, paths: [tab.shownFolderPath + "/note.txt"], kind: nil)
            }
            #expect(stayed)
        }

        // `openPathExternally`, from the Info panel's Open.
        // B-NAV-071
        @Test func theInfoPanelsOpenCountsAsAStay() async throws {
            let stayed = try await staysAfter { tab in
                try #require(tab.infoController).actions.openExternally(tab.shownFolderPath + "/note.txt")
            }
            #expect(stayed)
        }

        // `showPathsInFinder` asks Finder directly: it is not a use of the folder.
        @Test func showingInFinderIsNotAStay() async throws {
            let stayed = try await staysAfter { tab in
                try #require(tab.infoController).actions.showInFinder(tab.shownFolderPath)
            }
            #expect(!stayed)
        }

        // useExplorerTabs.ts `openPathInNewTab` (mode "open", so "push"): the folder a new tab opens on is an arrival.
        // B-NAV-011
        @Test func aFolderOpenedInANewTabIsAnArrival() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let alpha = try #require(tab.content.listed.first { $0.name == "Alpha" })
            tab.open([alpha], inNewTab: true)
            #expect(await waitUntil { group.tabs.count == 2 })
            let opened = try #require(group.tabs.last)
            #expect(await firstFolderRead(opened))
            #expect(opened.shownFolderPath == alpha.path)
            #expect(opened.historyPaths == [alpha.path])
            opened.onFolderUsed?()
            #expect(store.folders().contains { $0.path == alpha.path && !$0.visits.isEmpty })
            await harness.close()
        }

        // `showing`: a folder not yet decided on is only passed through when another tab comes to the front.
        // B-DLG-067
        @Test func aFolderLeftForAnotherTabIsPassedThrough() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let alpha = harness.folder.appending("Alpha").path
            tab.go(to: URL(fileURLWithPath: alpha))
            #expect(await waitUntil { tab.shownFolderPath == alpha && !tab.isNavigating })
            group.openTab(path: harness.folder.appending("Beta").path, from: tab)
            #expect(await waitUntil { group.selected !== tab })
            tab.onFolderUsed?()
            #expect(!store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            await harness.close()
        }

        // `openNewTab` (⌘T) is mode "none": nothing is gone to.
        @Test func aNewTabOnTheSameFolderIsNoArrival() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openNewTab(from: tab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let opened = try #require(group.tabs.last)
            #expect(await firstFolderRead(opened))
            opened.onFolderUsed?()
            #expect(!store.folders().contains { $0.path == opened.shownFolderPath && !$0.visits.isEmpty })
            await harness.close()
        }

        // `navigateToNearestExistingFolder`: a folder above the one asked for opens by "replace", which is no arrival.
        @Test func theNearestFolderOfANewTabIsNoArrival() async throws {
            let harness = try ExplorerHarness.windowless()
            let store = harness.store
            MainWindowController.visitStore = { store }
            defer { MainWindowController.visitStore = { (NSApp.delegate as? AppDelegate)?.store } }
            let tab = try await harness.open()
            let group = try #require(tab.group)
            let alpha = harness.folder.appending("Alpha").path
            group.openTab(path: alpha + "/Gone", from: tab)
            #expect(await waitUntil { group.tabs.count == 2 })
            let opened = try #require(group.tabs.last)
            #expect(await firstFolderRead(opened))
            #expect(await waitUntil { opened.shownFolderPath == alpha && !opened.isNavigating })
            opened.onFolderUsed?()
            #expect(!store.folders().contains { $0.path == alpha && !$0.visits.isEmpty })
            await harness.close()
        }
    }

    /// The operations' `current` is the app's one: no other test at the same time.
    @MainActor
    @Suite(.windowlessAlone) struct TreeAfterAWriteTests {
        /// Two tabs, the one on Beta at the back with Alpha open in its tree; and the window's operations.
        private func twoTabs(
            _ harness: ExplorerHarness
        ) async throws -> (
            front: MainWindowController, back: MainWindowController, operations: AppWriteOperations,
            session: ExplorerWriteSession, alpha: String
        ) {
            let back = try await harness.open(harness.folder.appending("Beta").path)
            let group = try #require(back.group)
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: DirectoryService(), windows: harness.windows,
                trash: .standIn,
                log: { _ in })
            let session = operations.session(for: group)
            let alpha = harness.folder.appending("Alpha").path
            await back.sidebarController.model.loadChildren(alpha, expandOnSuccess: true)
            #expect(back.sidebarController.model.nodes[alpha]?.expanded == true)
            group.openTab(path: harness.folder.path, from: back)
            let front = try #require(group.tabs.last)
            #expect(await firstFolderRead(front))
            #expect(group.selected === front)
            return (front, back, operations, session, alpha)
        }

        // useExplorerTabs.ts:1063-1085 and useExplorerNavigationController.ts:1954-1959: when a write ends, a tab at the
        // back reads its open branches as it comes back.
        // B-TREE-181 B-VIEW-166 T-85ebe51d
        @Test func aTabThatComesBackAfterAWriteReadsItsOpenBranches() async throws {
            let harness = try ExplorerHarness.windowless()
            let (front, back, operations, session, alpha) = try await twoTabs(harness)
            let made = alpha + "/Made Meanwhile"
            session.applyCard(WriteOperationCardState(action: .copyTo, stage: .running, targetPath: "/x"))
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)
            #expect(!back.treeOutOfDate)
            session.applyCard(nil)
            #expect(back.treeOutOfDate)
            #expect(!front.treeOutOfDate)
            // A write's end empties the listings (`clearListings`).
            harness.services.directoryService.cache.clear()
            try #require(front.group).select(back)
            #expect(!back.treeOutOfDate)
            let model = back.sidebarController.model
            #expect(await waitUntil { model.nodes[alpha]?.childPaths.contains(made) == true })
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // The same for a write that ends in another window.
        // B-VIEW-166 T-85ebe51d
        @Test func aWriteInAnotherWindowCounts() async throws {
            let harness = try ExplorerHarness.windowless()
            let (front, back, operations, session, _) = try await twoTabs(harness)
            let event = { (status: WriteOperationStatus) in
                WriteOperationEvent(operationId: "other", action: .copyTo, status: status)
            }
            session.otherWindowProgress(event(.running))
            #expect(session.foreign != nil)
            #expect(!back.treeOutOfDate)
            session.otherWindowProgress(event(.completed))
            #expect(session.foreign == nil)
            #expect(back.treeOutOfDate)
            #expect(!front.treeOutOfDate)
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // With no write, coming back reads only the way down to the folder (`getSelectedTreeReloadOptions`).
        // B-VIEW-166
        @Test func aTabThatComesBackWithNoWriteLeavesItsOtherBranches() async throws {
            let harness = try ExplorerHarness.windowless()
            let (front, back, operations, _, alpha) = try await twoTabs(harness)
            let made = alpha + "/Made Meanwhile"
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: false)
            harness.services.directoryService.cache.clear()
            try #require(front.group).select(back)
            #expect(await waitUntil { !back.isNavigating })
            try await Task.sleep(for: .milliseconds(300))
            #expect(back.sidebarController.model.nodes[alpha]?.childPaths.contains(made) == false)
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}

/// Reads one folder slowly, so a test can do something while it is being read.
private struct SlowFolder: ExplorerFileSystem {
    let slow: String
    private let real = NativeFileSystem()

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        if path == slow { Thread.sleep(forTimeInterval: 0.4) }
        return try real.readDirectory(path)
    }

    func stat(_ path: String) throws -> FileStats {
        if path == slow { Thread.sleep(forTimeInterval: 0.4) }
        return try real.stat(path)
    }

    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}
