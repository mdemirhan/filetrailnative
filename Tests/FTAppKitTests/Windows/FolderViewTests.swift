import AppKit
import FTFileSystem
import FTFoundation
import FTTestSupport
import Foundation
import Testing

@testable import FTAppKit

/// The disk, with one read of a folder, by its number among the reads of that folder, refused or held until the test
/// lets it go: a folder reached through a link is read twice, and the second read is the one to fail or to wait.
private final class NumberedReads: ExplorerFileSystem, @unchecked Sendable {
    private struct Refused: Error {}

    private let real = NativeFileSystem()
    private let condition = NSCondition()
    private var counts: [String: Int] = [:]
    private var refused: (path: String, read: Int)?
    private var held: (path: String, read: Int)?
    private var waiting = false

    func refuse(_ path: String, read: Int) { condition.withLock { refused = (path, read) } }
    func hold(_ path: String, read: Int) { condition.withLock { held = (path, read) } }

    func letGo() {
        condition.withLock {
            held = nil
            condition.broadcast()
        }
    }

    var isHolding: Bool { condition.withLock { waiting } }
    func reads(of path: String) -> Int { condition.withLock { counts[path] ?? 0 } }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        try condition.withLock {
            counts[path, default: 0] += 1
            let number = counts[path] ?? 0
            if let refused, refused.path == path, refused.read == number { throw Refused() }
            guard let held, held.path == path, held.read == number else { return }
            waiting = true
            while self.held != nil { condition.wait() }
            waiting = false
        }
        return try real.readDirectory(path)
    }

    func stat(_ path: String) throws -> FileStats { try real.stat(path) }
    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}

extension ExplorerWindowlessTests {
    /// A folder's own view (View ▸ Folder View): laid over what the pane carries while it shows the folder, changed on
    /// screen until Update, and covering the folders inside when asked.
    @MainActor
    @Suite struct FolderViewTests {
        private func real(_ harness: ExplorerHarness, _ name: String) -> String {
            let path = name.isEmpty ? harness.folder.path : harness.folder.path + "/" + name
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        private func go(_ tab: MainWindowController, _ harness: ExplorerHarness, _ name: String) async {
            await tab.navigate(to: URL(fileURLWithPath: real(harness, name)))
            #expect(await waitUntil { !tab.isNavigating })
        }

        @Test func aRememberedFolderShowsItsViewAndLeavingItPutsBackWhatThePaneCarries() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            #expect(pane.shownFolderView?.use.own == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .own)

            // Leaving: Previews was chosen in Alpha before Alpha was customized, so it is Alpha's alone; the pane shows
            // what it carried as it came into Alpha.
            await go(tab, harness, "Beta")
            #expect(pane.viewMode == .icons)
            #expect(pane.content.mode == .icons)
            #expect(pane.shownFolderView == nil)
            // The symbol stays, faint, and opens the options.
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .noView)
            tab.setMode(.details)
            await go(tab, harness, "Alpha")
            #expect(pane.shownMode == .previews)
            #expect(pane.content.mode == .previews)
            await go(tab, harness, "Gamma")
            #expect(pane.content.mode == .details)
        }

        @Test func aChangeIsOnScreenUntilUpdateAndLeavingDropsIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.perform(.rememberFolderView)
            tab.setMode(.details)
            #expect(pane.shownFolderView?.unsaved == [.view])
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            #expect(tab.canPerform(.updateFolderView))
            // The pane carries nothing of it.
            #expect(pane.viewMode == .icons)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .icons)

            // Changed back by hand: no change.
            tab.setMode(.icons)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)
            tab.setMode(.details)
            await go(tab, harness, "Beta")
            await go(tab, harness, "Alpha")
            #expect(pane.shownMode == .icons)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)

            tab.setMode(.details)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .details)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)
            tab.setMode(.list)
            tab.perform(.revertFolderView)
            #expect(pane.shownMode == .details)
        }

        @Test func aViewCoversTheFoldersInsideAndKeepForThisFolderOnlyGivesOneItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            pane.setFolderViewSubfolders(true)
            #expect(pane.shownFolderView?.subfoldersUnsaved == true)
            tab.perform(.updateFolderView)

            await go(tab, harness, "Alpha/Inner")
            #expect(pane.shownFolderView?.use.own == false)
            #expect(pane.shownMode == .previews)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .above)
            // Reset does nothing in a folder with no view of its own.
            #expect(!tab.canPerform(.resetFolderView))

            // Apply to Subfolders is Alpha's: off here until changed. Nothing changed, Save does nothing.
            #expect(pane.shownFolderView?.shownSubfolders == false)
            pane.updateFolderView()
            #expect(pane.folderViews.views.own(real(harness, "Alpha/Inner")) == nil)
            // A change here is Inner's own once saved; Alpha is changed in Alpha.
            tab.setMode(.details)
            #expect(pane.shownFolderView?.hasUnsavedChanges == true)
            pane.updateFolderView()
            let inner = try #require(pane.folderViews.views.own(real(harness, "Alpha/Inner")))
            #expect(inner.keeps.view == .details)
            #expect(!inner.subfolders)
            // Alpha's own is as it was.
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .previews)
            #expect(pane.shownFolderView?.use.own == true)

            // Reset: Inner uses Alpha's again.
            tab.perform(.resetFolderView)
            #expect(pane.shownFolderView?.use.own == false)
            #expect(pane.shownMode == .previews)
        }

        @Test func aKeptOrderIsTheOrderTheFolderIsReadIn() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["b.txt", "a.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending("Beta/\(name)"), atomically: false, encoding: .utf8)
            }
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Beta")
            pane.setFolderViewValue(.sort) { $0.sort = FolderViewSort(by: .name, direction: .desc) }
            pane.setFolderViewValue(.foldersFirst) { $0.foldersFirst = false }
            #expect(pane.shownFolderView?.isDraft == true)
            // Read again in that order.
            #expect(await waitUntil { pane.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"] })
            // The pane's own order is still Name, ascending.
            #expect(pane.sortBy == .name && pane.sortDirection == .asc)
            tab.perform(.updateFolderView)
            #expect(pane.shownFolderView?.isOwnSaved == true)
            await go(tab, harness, "Alpha")
            await go(tab, harness, "Beta")
            #expect(pane.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"])
        }

        @Test func aColumnShownInAFolderThatKeepsItsColumnsIsAChangeOfItsView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            #expect(!tab.preferences.detailColumns.permissions)
            tab.perform(.showPermissionsColumn)
            // No folder view here: every folder's columns change.
            #expect(tab.preferences.detailColumns.permissions)
            tab.perform(.showPermissionsColumn)

            tab.keepColumns(true, in: pane)
            tab.perform(.showPermissionsColumn)
            #expect(!tab.preferences.detailColumns.permissions)
            #expect(pane.shownFolderView?.unsaved == [.columns])
            #expect(tab.shownColumns.contains(.permissions))
            await go(tab, harness, "Beta")
            #expect(!tab.shownColumns.contains(.permissions))
        }

        @Test func sizesAndColumnWidthsSetInAFolderThatKeepsThemAreItsOwn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            pane.setFolderViewKeeps(.size, true)
            pane.setFolderViewKeeps(.columns, true)
            pane.content.onIconSizeChanged?(.standard, 96)
            pane.content.onCompactListWidthChanged?(.standard, 400)
            var widths = Dictionary(uniqueKeysWithValues: DetailColumn.allCases.map { ($0, 150.0) })
            widths[.name] = 333
            pane.content.onColumnWidthsChanged?(widths)
            #expect(Set(pane.shownFolderView?.unsaved ?? []) == [.size, .columns])
            // The app's and the pane's are as they were.
            #expect(tab.preferences.iconSizes[.standard] != 96)
            #expect(tab.preferences.detailColumnWidths[.name] != 333)
            tab.perform(.updateFolderView)

            let saved = try #require(pane.folderViews.views.own(real(harness, "Alpha")))
            #expect(saved.keeps.size?.iconSizes[.standard] == 96)
            #expect(saved.keeps.size?.compactListWidths[.standard] == 400)
            #expect(saved.keeps.columns?.widths[.name] == 333)
            await go(tab, harness, "Beta")
            #expect(pane.shownPreferences(tab.preferences).iconSizes[.standard] != 96)
            await go(tab, harness, "Alpha")
            let shown = pane.shownPreferences(tab.preferences)
            #expect(shown.iconSizes[.standard] == 96 && shown.compactListWidths[.standard] == 400)
            #expect(shown.detailColumnWidths[.name] == 333)
        }

        @Test func aViewSavedInOneTabShowsInAnotherOnTheSameFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            await go(first, harness, "Alpha")
            first.setMode(.icons)
            let group = try #require(first.group)
            group.duplicateTab(first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = group.tabs[1]
            second.servicesOverride = first.servicesOverride
            #expect(await waitUntil { second.activePane.loaded && !second.isNavigating })
            harness.services.folderViews.onChanged = { [weak first, weak second] _ in
                first?.folderViewsChanged()
                second?.folderViewsChanged()
            }
            first.setMode(.previews)
            first.perform(.rememberFolderView)
            #expect(second.activePane.shownFolderView?.use.own == true)
            #expect(second.activePane.shownMode == .previews)
        }

        /// Search results over the pane's folder, as typing in the search field and Return bring them.
        private func search(_ tab: MainWindowController, for text: String) async throws {
            tab.search.session.engine = FakeSearchEngine()
            tab.search.session.timers = ManualTimers()
            let field = try #require(tab.searchField)
            field.stringValue = text
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            _ = tab.search.session.submit(text)
            #expect(await waitUntil { tab.search.showsResults })
        }

        /// The item of the List header's menu titled `title`, chosen as a click chooses it.
        private func choose(_ title: String, in menu: NSMenu) throws {
            let index = try #require(menu.items.firstIndex { $0.title == title }, "\(title) is in the menu")
            #expect(menu.items[index].isEnabled, "\(title) is on")
            menu.performActionForItem(at: index)
        }

        // A view is found by the path alone, so the path a folder is asked for by finds nothing where it isn't the
        // folder's real one; its listing gives that, and the view saved for it shows, in its order.
        @Test func aFolderOpenedThroughALinkShowsTheViewOfItsRealPath() async throws {
            let harness = try ExplorerHarness.windowless()
            for name in ["b.txt", "a.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending("Beta/\(name)"), atomically: false, encoding: .utf8)
            }
            let tab = try await harness.open()
            let pane = tab.activePane
            let beta = real(harness, "Beta")
            let link = real(harness, "") + "/Link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: beta)
            pane.folderViews.update(from: nil) {
                $0.set(
                    FolderView(
                        path: beta,
                        keeps: FolderViewKeeps(
                            view: .icons, sort: FolderViewSort(by: .name, direction: .desc), foldersFirst: false)))
            }
            #expect(pane.folderViewUse(for: link) == nil)
            await tab.navigate(to: URL(fileURLWithPath: link))
            #expect(await waitUntil { !tab.isNavigating })
            #expect(pane.shownFolderPath == beta)
            #expect(pane.shownFolderView?.use.own == true)
            #expect(pane.content.mode == .icons)
            // Read in the order the view keeps, though the first read had only the pane's to go by.
            #expect(pane.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"])
            #expect(pane.sortBy == .name && pane.sortDirection == .asc)
        }

        /// A tab on the harness's folder that reads through `disk`, Beta holding three files and a view that keeps
        /// Icons and names from Z to A, and a link to Beta beside it.
        private func openBesideALink(_ harness: ExplorerHarness) async throws -> (
            tab: MainWindowController, disk: NumberedReads, beta: String, link: String
        ) {
            for name in ["b.txt", "a.txt", "c.txt"] {
                try "x".write(to: harness.folder.appending("Beta/\(name)"), atomically: false, encoding: .utf8)
            }
            let tab = try await harness.open()
            let disk = NumberedReads()
            tab.servicesOverride = ExplorerServices(
                directoryService: DirectoryService(fileSystem: disk), iconStore: TestServices.icons,
                clipboard: harness.windows.clipboard, preferences: harness.channel)
            let beta = real(harness, "Beta")
            let link = real(harness, "") + "/Link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: beta)
            tab.activePane.folderViews.update(from: nil) {
                $0.set(
                    FolderView(
                        path: beta,
                        keeps: FolderViewKeeps(
                            view: .icons, sort: FolderViewSort(by: .name, direction: .desc), foldersFirst: false)))
            }
            return (tab, disk, beta, link)
        }

        // The second read of a folder reached through a link can fail though the first one worked (the folder went
        // in between, a share stopped answering). The folder then didn't open, as when any read fails: the folder
        // before stays, with the read's message over it, nothing of the first read shows, and the next try opens it.
        @Test func aSecondReadThroughALinkThatFailsLeavesTheFolderBeforeAsAnyReadThatFails() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, disk, beta, link) = try await openBesideALink(harness)
            let pane = tab.activePane
            let root = pane.shownFolderPath
            let listed = tab.content.entries.map(\.name)
            let history = tab.navigationHistory.paths
            let mode = pane.content.mode
            disk.refuse(beta, read: 2)

            let opened = await pane.navigate(to: URL(fileURLWithPath: link))
            #expect(!opened && !tab.isNavigating)
            #expect(disk.reads(of: beta) == 2)
            #expect(pane.shownFolderPath == root && tab.content.entries.map(\.name) == listed)
            #expect(tab.content.readError != nil)
            #expect(pane.shownFolderView == nil && pane.content.mode == mode)
            #expect(tab.navigationHistory.paths == history)

            #expect(await pane.navigate(to: URL(fileURLWithPath: link)))
            #expect(tab.content.readError == nil)
            #expect(pane.shownFolderPath == beta && pane.shownFolderView?.use.own == true)
            #expect(tab.content.entries.map(\.name) == ["Inner", "c.txt", "b.txt", "a.txt"])
            await harness.close()
        }

        // While the second read is under way the folder before is still on screen, as it was, in the pane's own view:
        // the first read's order never shows. A folder opened meanwhile takes its place, and the read that comes in
        // late changes nothing.
        @Test func theSecondReadThroughALinkShowsNothingUntilItEndsAndAnotherFolderOpenedMeanwhileWins() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, disk, beta, link) = try await openBesideALink(harness)
            let pane = tab.activePane
            let root = pane.shownFolderPath
            let listed = tab.content.entries.map(\.name)
            let mode = pane.content.mode
            disk.hold(beta, read: 2)
            pane.go(to: URL(fileURLWithPath: link))
            #expect(await waitUntil { disk.isHolding })
            #expect(pane.shownFolderPath == root && tab.content.entries.map(\.name) == listed)
            #expect(pane.folderView == nil && pane.content.mode == mode)
            #expect(tab.content.sortDirection == .asc)
            #expect(tab.isNavigating)

            let gamma = real(harness, "Gamma")
            #expect(await tab.navigate(to: URL(fileURLWithPath: gamma)))
            disk.letGo()
            #expect(await waitUntil { !disk.isHolding && !tab.isNavigating })
            await settle()
            #expect(pane.shownFolderPath == gamma && tab.content.entries.map(\.name) == ["Inner"])
            #expect(pane.folderView == nil && pane.content.mode == mode && tab.content.readError == nil)
            #expect(tab.navigationHistory.paths == [root, gamma])
            await harness.close()
        }

        // A view is found by its folder's real path alone, and the app saves one under no other. One put under a
        // link's path by hand is no folder's: the folder shows the pane's settings by either path, and so do the
        // folders inside it.
        @Test func aViewPutUnderALinksPathByHandIsNoFoldersView() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _, beta, link) = try await openBesideALink(harness)
            let pane = tab.activePane
            let mode = pane.content.mode
            pane.folderViews.update(from: nil) {
                $0.remove(beta)
                $0.set(
                    FolderView(
                        path: link, subfolders: true,
                        keeps: FolderViewKeeps(
                            view: .previews, sort: FolderViewSort(by: .name, direction: .desc), foldersFirst: false)))
            }
            for path in [link, beta] {
                #expect(await tab.navigate(to: URL(fileURLWithPath: path)))
                #expect(pane.shownFolderPath == beta && pane.shownFolderView == nil && pane.content.mode == mode)
                #expect(tab.content.entries.map(\.name) == ["Inner", "a.txt", "b.txt", "c.txt"])
                await go(tab, harness, "Gamma")
            }
            #expect(await tab.navigate(to: URL(fileURLWithPath: link + "/Inner")))
            #expect(pane.shownFolderPath == beta + "/Inner" && pane.shownFolderView == nil)
            // Remember there saves the folder's view under its real path, where it is found.
            tab.perform(.rememberFolderView)
            #expect(pane.folderViews.views.own(beta + "/Inner") != nil)
            await harness.close()
        }

        // Nothing ties a view to a disk: a folder the app moves to another disk has its view there, and finding it
        // asks nothing of the disk (none of these folders is anywhere).
        @Test func aFolderMovedInTheAppToAnotherDiskTakesItsViewAlong() {
            let shared = SharedFolderViews()
            shared.update(from: nil) {
                $0.set(
                    FolderView(
                        path: "/Users/me/Pictures", subfolders: true, keeps: FolderViewKeeps(view: .previews)))
                $0.set(FolderView(path: "/Users/me/Pictures/Scans", keeps: FolderViewKeeps(view: .details)))
            }
            shared.followMoves([PathMove(from: "/Users/me/Pictures", to: "/Volumes/Photos/Pictures")])
            #expect(shared.use(for: "/Volumes/Photos/Pictures")?.own == true)
            #expect(shared.use(for: "/Volumes/Photos/Pictures/Scans")?.view.keeps.view == .details)
            #expect(shared.use(for: "/Volumes/Photos/Pictures/Trips/2026")?.view.path == "/Volumes/Photos/Pictures")
            #expect(shared.use(for: "/Users/me/Pictures") == nil)
            #expect(shared.use(for: "/Users/me/Pictures/Scans") == nil)
        }

        @Test func aColumnMovedInSearchResultsMovesTheSearchsOwnColumnAndAFoldersStaysAsItWas() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let pane = tab.activePane
            // In a folder, a title dragged moves the folder List's column.
            pane.content.columnMoved(.size, before: .modified)
            let folderOrder = tab.preferences.detailColumnOrder
            #expect(folderOrder.prefix(2) == [.size, .modified])
            let searchOrder = tab.preferences.searchColumnOrder
            #expect(searchOrder == AppPreferenceLimits.defaultSearchColumnOrder)

            try await search(tab, for: "note")
            // In search results it moves theirs: Size before Folder, right after Name.
            pane.content.columnMoved(.size, before: .folder)
            #expect(tab.preferences.detailColumnOrder == folderOrder)
            #expect(tab.preferences.searchColumnOrder.prefix(3) == [.size, .folder, .modified])
            #expect(pane.columns(from: tab.preferences).columns == [.name, .size, .folder, .modified])

            // The header's menu moves the title clicked, and has no Keep item.
            var menu = tab.headerMenu(for: .size, in: pane)
            #expect(!menu.items.contains { $0.title.hasPrefix("Keep Columns") })
            #expect(menu.items.first { $0.title == "Move “Size” Left" }?.isEnabled == false)
            try choose("Move “Size” Right", in: menu)
            #expect(tab.preferences.searchColumnOrder.prefix(3) == [.folder, .size, .modified])
            menu = tab.headerMenu(for: .modified, in: pane)
            #expect(menu.items.first { $0.title == "Move “Date Modified” Right" }?.isEnabled == false)
            try choose("Move “Date Modified” Left", in: menu)
            #expect(tab.preferences.searchColumnOrder.prefix(3) == [.folder, .modified, .size])
            // Folder moves as any other; Name has no Move items.
            try choose("Move “Folder” Right", in: tab.headerMenu(for: .folder, in: pane))
            #expect(pane.columns(from: tab.preferences).columns == [.name, .modified, .folder, .size])
            #expect(!tab.headerMenu(for: .name, in: pane).items.contains { $0.title.hasPrefix("Move") })
            #expect(tab.preferences.detailColumnOrder == folderOrder)

            // Back in the folder, a drag is the folder's again.
            tab.search.session.hideResults()
            #expect(await waitUntil { !tab.search.showsResults })
            pane.content.columnMoved(.kind, before: .size)
            #expect(tab.preferences.detailColumnOrder.prefix(3) == [.kind, .size, .modified])
            #expect(tab.preferences.searchColumnOrder.prefix(3) == [.modified, .folder, .size])
            await harness.close()
        }

        // What a pane puts back once its folder keeps a setting is what it changed there itself: a column shown from
        // another tab meanwhile is every folder's, and stays.
        @Test func rememberPutsBackOnlyWhatThePaneChangedItselfAndLeavesWhatAnotherTabChanged() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            await go(first, harness, "Alpha")
            let group = try #require(first.group)
            group.duplicateTab(first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = group.tabs[1]
            second.servicesOverride = first.servicesOverride
            #expect(await waitUntil { second.activePane.loaded && !second.isNavigating })
            #expect(!first.preferences.detailColumns[.added] && !first.preferences.detailColumns[.permissions])

            // The first shows Permissions in Alpha; the second then shows Date Added.
            first.toggleColumn(.permissions, in: first.activePane)
            second.toggleColumn(.added, in: second.activePane)
            #expect(first.preferences.detailColumns[.added] && first.preferences.detailColumns[.permissions])
            first.perform(.rememberFolderView)
            // Alpha keeps the columns that were on screen; the pane's own change goes back, the other tab's stays.
            let kept = try #require(first.activePane.folderViews.views.own(real(harness, "Alpha"))?.keeps.columns)
            #expect(kept.visibility.permissions && kept.visibility.added)
            #expect(!first.preferences.detailColumns[.permissions])
            #expect(first.preferences.detailColumns[.added])
            #expect(first.preferences.detailColumnOrder.contains(.added))
        }

        // A size the pane set here goes back as the folder comes to keep it, unless it was set again elsewhere since.
        @Test func aSizeSetAgainElsewhereSinceThePaneSetItIsNotPutBack() {
            var changes = SharedSettingChanges()
            var before = AppPreferences.defaults()
            before.iconSizes[.standard] = 64
            var after = before
            after.iconSizes[.standard] = 96
            after.detailColumns.permissions = true
            changes.note(from: before, to: after)
            // Still as the pane left them: both go back.
            #expect(changes.sizesPutBack(in: after).iconSizes[.standard] == 64)
            #expect(!changes.columnsPutBack(in: after).detailColumns.permissions)
            // Set again elsewhere, and another column shown there: neither is the pane's to undo.
            var elsewhere = after
            elsewhere.iconSizes[.standard] = 112
            elsewhere.detailColumns.added = true
            #expect(changes.sizesPutBack(in: elsewhere).iconSizes[.standard] == 112)
            let columns = changes.columnsPutBack(in: elsewhere).detailColumns
            #expect(columns.added && !columns.permissions)
            // Heard of while it was set elsewhere, the size is forgotten, and stays when it is later set as the pane
            // had left it; the column nobody else touched still goes back.
            var heard = changes
            heard.forgetWhatChangedElsewhere(now: elsewhere)
            #expect(heard.sizesPutBack(in: after).iconSizes[.standard] == 96)
            #expect(!heard.columnsPutBack(in: after).detailColumns.permissions)
            // Changed back by hand, it is no change of the pane's any more.
            changes.note(from: after, to: before)
            #expect(changes == SharedSettingChanges())
        }

        // A dimmed item's key still reaches the command: it does nothing where the item is dimmed.
        @Test func theFolderViewAndColumnCommandsDoNothingOverSearchResultsOrWithNoFolder() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let pane = tab.activePane
            try await search(tab, for: "note")
            // Commands do arrive: the view is the results' own to change.
            tab.perform(.viewAsIcons)
            #expect(pane.searchViewMode == .icons)

            let columns = tab.preferences.detailColumns
            #expect(!tab.canPerform(.folderViewOptions) && !tab.canPerform(.showPermissionsColumn))
            tab.perform(.folderViewOptions)
            #expect(tab.folderViewPopover == nil)
            tab.perform(.showPermissionsColumn)
            tab.perform(.showSizeColumn)
            #expect(tab.preferences.detailColumns == columns)
            tab.perform(.rememberFolderView)
            #expect(pane.folderViews.views.isEmpty)
            tab.perform(.updateFolderView)
            tab.perform(.revertFolderView)
            tab.perform(.resetFolderView)
            #expect(pane.folderViews.views.isEmpty && pane.folderView == nil)

            // With no folder on screen there is none to customize.
            tab.search.session.hideResults()
            #expect(await waitUntil { !tab.search.showsResults })
            pane.showNoFolder()
            #expect(!tab.canPerform(.folderViewOptions) && !tab.canPerform(.rememberFolderView))
            tab.perform(.folderViewOptions)
            #expect(tab.folderViewPopover == nil)
            tab.perform(.rememberFolderView)
            #expect(pane.folderViews.views.isEmpty)
            await harness.close()
        }

        @Test func keepColumnsUnderAViewFromAboveThatKeepsColumnsGivesTheFolderItsOwnAtSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            tab.perform(.viewAsDetails)
            tab.perform(.rememberFolderView)
            pane.setFolderViewSubfolders(true)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.columns != nil)

            await go(tab, harness, "Alpha/Inner")
            let inner = real(harness, "Alpha/Inner")
            #expect(pane.shownFolderView?.use.own == false && pane.folderViewKeeps(.columns))
            let keep = "Keep Columns for “Inner”"
            var menu = tab.headerMenu(for: .size, in: pane)
            #expect(menu.items.first?.title == keep && menu.items.first?.state == .off)
            #expect(menu.items[1].title == "Changes go to “Alpha” view, until Save")
            try choose(keep, in: menu)
            // A change on screen as any other: checked, the dot shows, nothing is saved until Save.
            menu = tab.headerMenu(for: .size, in: pane)
            #expect(menu.items.first?.state == .on)
            #expect(menu.items[1].title == "Changes go to this folder's view, until Save")
            #expect(pane.shownFolderView?.hasUnsavedChanges == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            #expect(tab.canPerform(.updateFolderView))
            #expect(pane.folderViews.views.own(inner) == nil)
            // Chosen again, it is unchosen: nothing is changed.
            try choose(keep, in: menu)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false)
            #expect(tab.headerMenu(for: .size, in: pane).items.first?.state == .off)
            // Revert drops it too.
            try choose(keep, in: tab.headerMenu(for: .size, in: pane))
            tab.perform(.revertFolderView)
            #expect(pane.shownFolderView?.hasUnsavedChanges == false && !pane.keepsOwnColumns)

            try choose(keep, in: tab.headerMenu(for: .size, in: pane))
            tab.perform(.updateFolderView)
            let own = try #require(pane.folderViews.views.own(inner))
            #expect(own.keeps.columns == pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.columns)
            #expect(!own.subfolders)
            #expect(pane.shownFolderView?.isOwnSaved == true && pane.shownFolderView?.hasUnsavedChanges == false)
            #expect(tab.headerMenu(for: .size, in: pane).items.first?.state == .on)
        }

        @Test func folderCustomizationClosesWhenItsPaneIsClosedOrReplaced() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let left = tab.activePane
            var right = tab.openSecondPane(at: real(harness, "Alpha"))
            #expect(await waitUntil { right.loaded && !right.isNavigating })
            #expect(tab.activePane === left)
            // Open on the pane that stays, it stays.
            tab.folderViewPopover = FolderViewPopover(pane: left, tab: tab, dismiss: {})
            tab.toggleTwoPanes()
            #expect(!tab.showsTwoPanes && tab.folderViewPopover?.pane === left)

            // Open on the pane ⌘\ closes, it closes with it.
            right = tab.openSecondPane(at: real(harness, "Alpha"))
            #expect(await waitUntil { right.loaded && !right.isNavigating })
            tab.folderViewPopover = FolderViewPopover(pane: right, tab: tab, dismiss: {})
            tab.toggleTwoPanes()
            #expect(tab.folderViewPopover == nil)

            // Duplicate Pane puts a copy of the active pane in the other one's place: that one is gone too.
            right = tab.openSecondPane(at: real(harness, "Beta"))
            #expect(await waitUntil { right.loaded && !right.isNavigating })
            tab.folderViewPopover = FolderViewPopover(pane: right, tab: tab, dismiss: {})
            tab.duplicatePane()
            #expect(tab.showsTwoPanes && tab.otherPane !== right)
            #expect(tab.folderViewPopover == nil)
            #expect(await waitUntil { tab.panes.allSatisfy { $0.loaded && !$0.isNavigating } })
            await harness.close()
        }

        // A tab or a window closed takes its Folder Customization with it: each tab is a window, and closing one
        // tells it so.
        @Test func folderCustomizationClosesWhenItsTabOrWindowIsClosed() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.folderViewPopover = FolderViewPopover(pane: tab.activePane, tab: tab, dismiss: {})
            tab.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            #expect(tab.folderViewPopover == nil)
            await harness.close()
        }

        // Search results are no folder: over a customized folder they show in the search's own view and columns, the
        // Folder View commands are off, and the folder's view is back when they close.
        @Test func searchResultsOverACustomizedFolderUseTheSearchsOwnViewAndTheFoldersComesBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.details)
            tab.toggleColumn(.permissions, in: pane)
            tab.perform(.rememberFolderView)
            // The pane carries Icons, and Permissions is Alpha's alone.
            #expect(pane.viewMode == .icons && !tab.preferences.detailColumns.permissions)
            let folderColumns = pane.columns(from: tab.preferences).columns
            #expect(folderColumns.contains(.permissions) && !folderColumns.contains(.folder))
            tab.setSearchViewMode(.list)
            // Folder Customization, open as the results come up, closes: its folder is no longer on screen.
            tab.folderViewPopover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})

            try await search(tab, for: "note")
            #expect(tab.folderViewPopover == nil)
            #expect(pane.content.mode == .list && tab.menuState.viewMode == .list)
            #expect(pane.columns(from: tab.preferences).columns == [.name, .folder, .modified, .size])
            #expect(pane.shownFolderView == nil)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark == nil)
            for command: AppCommand in [
                .rememberFolderView, .updateFolderView, .revertFolderView, .folderViewOptions, .resetFolderView,
                .showPermissionsColumn,
            ] {
                #expect(!tab.canPerform(command), "\(command)")
            }
            // The view chosen over the results is theirs: Alpha's view isn't changed by it.
            tab.setMode(.previews)
            #expect(pane.searchViewMode == .previews && pane.folderView?.hasUnsavedChanges == false)

            tab.search.session.hideResults()
            #expect(await waitUntil { !tab.search.showsResults })
            #expect(pane.content.mode == .details)
            #expect(pane.shownFolderView?.isOwnSaved == true && pane.shownFolderView?.hasUnsavedChanges == false)
            #expect(pane.columns(from: tab.preferences).columns == folderColumns)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .own)
            #expect(tab.canPerform(.folderViewOptions) && tab.canPerform(.resetFolderView))
            await harness.close()
        }

        @Test func aColumnShownTakesItsStandardPlaceAmongThoseShown() {
            // The order saved before the standard one changed: Date Created after Kind.
            let saved: [OptionalDetailColumnKey] = [
                .modified, .size, .kind, .created, .added, .lastOpened, .permissions,
            ]
            var shown: Set<OptionalDetailColumnKey> = [.modified, .size, .kind]
            func show(_ key: OptionalDetailColumnKey, in order: [OptionalDetailColumnKey]) -> [OptionalDetailColumnKey]
            {
                shown.insert(key)
                return ColumnOrder.showing(
                    key, in: order, isShown: { shown.contains($0) }, standard: OptionalDetailColumnKey.menuOrder)
            }
            var order = show(.created, in: saved)
            order = show(.lastOpened, in: order)
            order = show(.added, in: order)
            #expect(order.filter(shown.contains) == [.modified, .created, .lastOpened, .added, .size, .kind])
            // Moved by hand, Size stays first; a column shown later goes right after its standard neighbour.
            shown = [.modified, .size]
            order = ColumnOrder.placing(.size, before: .modified, in: OptionalDetailColumnKey.menuOrder)
            order = show(.kind, in: order)
            #expect(order.filter(shown.contains) == [.size, .kind, .modified])
            // With none before it shown, it comes first, after Name.
            shown = [.kind]
            #expect(show(.modified, in: [.kind, .modified]).filter(shown.contains) == [.modified, .kind])
        }

        @Test func aSettingTheFolderKeepsFromNowGoesBackToWhatThePaneCarriedAsItCameIn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            // Changed here with no customization: the pane's, until Alpha keeps it.
            tab.setMode(.details)
            #expect(pane.viewMode == .details)
            pane.setFolderViewKeeps(.view, true)
            // Not saved yet: the pane still carries it.
            #expect(pane.viewMode == .details)
            tab.perform(.updateFolderView)
            // Alpha keeps List; the pane carries Icons again.
            #expect(pane.viewMode == .icons)
            #expect(pane.shownMode == .details)
            await go(tab, harness, "Beta")
            #expect(pane.content.mode == .icons)
        }

        @Test func columnOrderMovesAmongTheColumnsShownAndNameStaysFirst() {
            let order: [OptionalDetailColumnKey] = [.modified, .size, .kind, .created, .permissions]
            var visible = DetailColumnVisibility.defaults
            visible.permissions = true
            // Created is hidden: Kind and Permissions are neighbours.
            #expect(
                ColumnOrder.moving(.kind, by: 1, in: order, visible: visible)
                    == [.modified, .size, .permissions, .created, .kind])
            #expect(ColumnOrder.moving(.modified, by: -1, in: order, visible: visible) == nil)
            #expect(ColumnOrder.moving(.permissions, by: 1, in: order, visible: visible) == nil)
            #expect(
                ColumnOrder.placing(.kind, before: .modified, in: order) == [
                    .kind, .modified, .size, .created, .permissions,
                ])
            #expect(
                ColumnOrder.placing(.modified, before: nil, in: order) == [
                    .size, .kind, .created, .permissions, .modified,
                ])
        }

        @Test func theFolderViewsWindowListsEachFolderUnderTheOneAboveAndRemovesTheOnesSelected() throws {
            _ = NSApplication.shared
            let shared = SharedFolderViews()
            let home = NSHomeDirectory()
            let app = home + "/Projects/App"
            shared.update(from: nil) {
                $0.set(
                    FolderView(
                        path: home, subfolders: true,
                        keeps: FolderViewKeeps(view: .previews, sort: FolderViewSort(by: .modified, direction: .desc))))
                $0.set(FolderView(path: "/nowhere/Old Scans", keeps: FolderViewKeeps(foldersFirst: false)))
                $0.set(FolderView(path: app + "/Sources", keeps: FolderViewKeeps(view: .details)))
                $0.set(FolderView(path: app, keeps: FolderViewKeeps(view: .list)))
            }
            var opened: [String] = []
            let window = FolderViewsWindowController(views: shared, open: { opened.append($0) })
            window.reload()
            // Each under the nearest customized folder above it; the home folder's first.
            #expect(window.shownRows.map(\.path) == [home, app, app + "/Sources", "/nowhere/Old Scans"])
            #expect(window.shownLevels == [0, 1, 2, 0])
            let tree = FolderViewNode.tree(shared.views.all)
            let summaries = [
                FolderViewsWindowController.summary(tree[0].view),
                FolderViewsWindowController.summary(tree[0].children[0].view),
                FolderViewsWindowController.summary(tree[1].view),
            ]
            #expect(summaries[0].path == "~" && summaries[0].tags == ["View", "Sort"] && summaries[0].subfolders)
            #expect(summaries[0].missing == nil)
            #expect(summaries[1].name == "App" && summaries[1].path == "~/Projects/App")
            #expect(summaries[2].name == "Old Scans" && summaries[2].tags == ["Folders First"])
            #expect(summaries[2].missing == "Not Found")
            #expect(!window.removeButton.isEnabled)

            window.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            #expect(window.showButton.isEnabled)
            window.pressShow()
            #expect(opened == [home])
            // A folder that isn't there can't be shown, only removed.
            window.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
            #expect(!window.showButton.isEnabled)
            window.pressRemove()
            #expect(shared.views.all.map(\.path) == [home, app, app + "/Sources"])
            // The window follows the views however they change: with the home folder's gone, App is at the top.
            window.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window.pressRemove()
            #expect(window.shownRows.map(\.path) == [app, app + "/Sources"])
            #expect(window.shownLevels == [0, 1])
        }

        @Test func removeLeavesTheFoldersInsideAndRemoveWithSubfoldersTakesOnlyThoseInsideTheSelected() throws {
            _ = NSApplication.shared
            let shared = SharedFolderViews()
            let paths = [
                "/nowhere/r1", "/nowhere/r1/a", "/nowhere/r1/a/b", "/nowhere/r1/z", "/nowhere/r1x", "/nowhere/r2",
                "/nowhere/r2/c", "/nowhere/r3",
            ]
            shared.update(from: nil) { views in
                for path in paths { views.set(FolderView(path: path, keeps: FolderViewKeeps(view: .list))) }
            }
            let window = FolderViewsWindowController(views: shared, open: { _ in })
            window.reload()
            func select(_ selected: [String]) {
                let rows = window.shownRows.enumerated().filter { selected.contains($0.element.path) }.map(\.offset)
                window.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            }
            // A folder with nothing customized inside it: Remove with Subfolders has nothing more to do.
            select(["/nowhere/r3"])
            #expect(window.removeButton.isEnabled && !window.removeWithSubfoldersButton.isEnabled)

            // Remove: the folders inside keep theirs, and move up a level.
            select(["/nowhere/r2"])
            #expect(window.removeWithSubfoldersButton.isEnabled)
            window.pressRemove()
            #expect(shared.views.all.map(\.path).contains("/nowhere/r2/c"))
            #expect(!shared.views.all.map(\.path).contains("/nowhere/r2"))

            // Two selected under different roots: each with what is inside it, and nothing above, beside or merely
            // named alike (r1x is not inside r1).
            select(["/nowhere/r1/a", "/nowhere/r2/c"])
            window.pressRemoveWithSubfolders()
            #expect(
                shared.views.all.map(\.path) == ["/nowhere/r1", "/nowhere/r1/z", "/nowhere/r1x", "/nowhere/r3"])
        }

        @Test func escClosesTheFolderViewsWindow() throws {
            _ = NSApplication.shared
            let window = FolderViewsWindowController(views: SharedFolderViews(), open: { _ in })
            window.window?.orderFront(nil)
            #expect(window.window?.isVisible == true)
            window.window?.cancelOperation(nil)
            #expect(window.window?.isVisible == false)
            window.window?.orderFront(nil)
            let esc = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            window.tableView.keyDown(with: esc)
            #expect(window.window?.isVisible == false)
        }

        @Test func whatIsChangedInFolderCustomizationIsSavedOnlyWithSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            let alpha = real(harness, "Alpha")
            // A folder with no view: a Keep box makes one on screen, not saved.
            pane.setFolderViewKeeps(.view, true)
            pane.setFolderViewValue(.view) { $0.view = .previews }
            #expect(pane.shownMode == .previews)
            #expect(pane.shownFolderView?.isDraft == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(!tab.canPerform(.resetFolderView) && tab.canPerform(.updateFolderView))
            // Revert lets it go.
            tab.perform(.revertFolderView)
            #expect(pane.shownFolderView == nil)
            #expect(pane.shownMode == .icons)

            // Leaving drops it too.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            await go(tab, harness, "Beta")
            await go(tab, harness, "Alpha")
            #expect(pane.shownFolderView == nil && pane.shownMode == .icons)

            // Save saves it, Apply to Subfolders with it.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            pane.setFolderViewSubfolders(true)
            tab.perform(.updateFolderView)
            let saved = try #require(pane.folderViews.views.own(alpha))
            #expect(saved.keeps.view == .previews && saved.subfolders)
            #expect(pane.shownFolderView?.isOwnSaved == true && pane.shownFolderView?.hasUnsavedChanges == false)

            // Unchecking every box and Apply to Subfolders, then Save, removes it.
            pane.setFolderViewKeeps(.view, false)
            pane.setFolderViewSubfolders(false)
            #expect(pane.folderViews.views.own(alpha) != nil)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(pane.shownFolderView == nil)
        }

        // Apply to Subfolders with nothing kept is a change only where the folders inside would look different: where
        // a view from above that keeps something is there for them to stop using.
        @Test func applyToSubfoldersWithNothingKeptIsAChangeOnlyUnderAViewFromAboveThatKeepsSomething() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            let alpha = real(harness, "Alpha")
            let inner = real(harness, "Alpha/Inner")

            // Nothing above, nothing kept: it can't be turned on, and trying changes nothing.
            #expect(!pane.canApplyToSubfolders)
            pane.setFolderViewSubfolders(true)
            #expect(pane.shownFolderView == nil)
            #expect(!tab.canPerform(.updateFolderView))

            // With a setting kept it can; unchecking the last setting takes it off again, and nothing is left to save.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            #expect(pane.canApplyToSubfolders)
            pane.setFolderViewSubfolders(true)
            #expect(pane.shownFolderView?.shownSubfolders == true)
            pane.setFolderViewKeeps(.view, false)
            #expect(pane.shownFolderView == nil)

            // Alpha keeps Previews for the folders inside: in Inner, keeping nothing and covering its own folders is
            // a change, as they would stop using Alpha's view.
            pane.setFolderViewValue(.view) { $0.view = .previews }
            pane.setFolderViewSubfolders(true)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha)?.subfolders == true)
            await go(tab, harness, "Alpha/Inner")
            #expect(pane.shownFolderView?.use.own == false)
            pane.setFolderViewKeeps(.view, false)
            #expect(pane.viewStoppedForSubfolders?.path == alpha && pane.canApplyToSubfolders)
            pane.setFolderViewSubfolders(true)
            #expect(pane.shownFolderView?.shownSubfolders == true)
            tab.perform(.updateFolderView)
            let stop = try #require(pane.folderViews.views.own(inner))
            #expect(stop.keeps.isEmpty && stop.subfolders)
            await harness.close()
        }

        @Test func folderCustomizationShowsEachChangeMadeInIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            let popover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})
            tab.folderViewPopover = popover
            defer { tab.folderViewPopover = nil }
            func control<T: NSView>(_ id: String, as type: T.Type) -> T? {
                func find(_ view: NSView) -> NSView? {
                    if view.accessibilityIdentifier() == id { return view }
                    return view.subviews.lazy.compactMap(find).first
                }
                return find(popover.contentView) as? T
            }
            func says(_ words: String) -> Bool {
                func find(_ view: NSView) -> Bool {
                    (view as? NSTextField)?.stringValue.contains(words) == true || view.subviews.contains(where: find)
                }
                return find(popover.contentView)
            }
            // Nothing kept: the View pop-up is dimmed until its box is checked, by a click as a person makes it; and
            // with nothing to apply, Apply to Subfolders is dimmed and says what it waits for.
            #expect(control("folderViewPopover.view", as: NSPopUpButton.self)?.isEnabled == false)
            #expect(control("folderViewPopover.subfolders", as: NSSwitch.self)?.isEnabled == false)
            #expect(says("Check a setting above"))
            #expect(control("folderViewPopover.update", as: NSButton.self)?.isEnabled == false)
            let keepView = try #require(control("folderViewPopover.keep.view", as: NSButton.self))
            keepView.performClick(nil)
            #expect(control("folderViewPopover.view", as: NSPopUpButton.self)?.isEnabled == true)
            #expect(control("folderViewPopover.subfolders", as: NSSwitch.self)?.isEnabled == true)
            #expect(says("look the same, unless"))
            #expect(control("folderViewPopover.update", as: NSButton.self)?.isEnabled == true)
            // A value chosen there is shown, and Save saves it.
            let views = try #require(control("folderViewPopover.view", as: NSPopUpButton.self))
            views.selectItem(withTitle: ExplorerViewMode.previews.menuName)
            _ = views.target?.perform(views.action, with: views)
            #expect(pane.shownMode == .previews)
            #expect(
                control("folderViewPopover.view", as: NSPopUpButton.self)?.titleOfSelectedItem
                    == ExplorerViewMode.previews.menuName)
            try #require(control("folderViewPopover.update", as: NSButton.self)).performClick(nil)
            #expect(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.view == .previews)
            #expect(control("folderViewPopover.update", as: NSButton.self)?.isEnabled == false)
        }

        @Test func resetInFolderCustomizationWaitsForSave() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            let alpha = real(harness, "Alpha")
            pane.clearFolderViewOnScreen()
            // The pane's settings show, and the customization is still saved.
            #expect(pane.shownMode == .icons)
            #expect(pane.folderViews.views.own(alpha) != nil)
            #expect(pane.shownFolderView?.hasUnsavedChanges == true)
            tab.perform(.revertFolderView)
            #expect(pane.shownMode == .previews)
            pane.clearFolderViewOnScreen()
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha) == nil)
            #expect(pane.shownFolderView == nil && pane.shownMode == .icons)
        }

        @Test func folderCustomizationKeepsItsHeightWhateverTheView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            tab.perform(.rememberFolderView)
            let popover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})
            var heights: Set<Double> = []
            for mode in ExplorerViewMode.menuOrder {
                pane.setFolderViewValue(.view) { $0.view = mode }
                popover.refresh()
                heights.insert(popover.contentView.frame.height)
                #expect(FolderViewPopover.settings(for: mode).count == 4)
            }
            #expect(heights.count == 1)
        }

        @Test func aChangedSizeSaysWhichOfItsSizesIsSaved() {
            let saved = FolderViewSizes(
                iconSizes: .iconDefaults, compactListWidths: .compactListDefaults, previewCounts: .previewCountDefaults)
            var shown = saved
            shown.previewCounts[.standard] = 9
            var view = FolderViewOnScreen(
                FolderViewUse(view: FolderView(path: "/a", keeps: FolderViewKeeps(size: saved)), own: true))
            view.shown.size = shown
            // In Icons, the icon size is the same: the Previews count is what changed.
            let text = FolderViewText.saved(.size, of: view, mode: .icons, density: .standard)
            #expect(text == "Saved: Previews \(saved.previewCounts[.standard]) at a time")
        }

        @Test func theSizeIsChosenFromEveryStepAndPreviewsByHowManyFit() {
            let previews = FolderViewPopover.sizeChoices(.previews, current: 4)
            #expect(
                previews.map(\.title) == [
                    "9 at a time (3 \u{00D7} 3)", "4 at a time (2 \u{00D7} 2)", "2 at a time (2 \u{00D7} 1)",
                    "1 at a time",
                ])
            let icons = FolderViewPopover.sizeChoices(.icons, current: 64)
            #expect(icons.first?.value == 32 && icons.last?.value == 128 && icons.count == 13)
            // A width between two steps (the Compact List's default) is among them.
            let widths = FolderViewPopover.sizeChoices(.list, current: 292).map(\.value)
            #expect(widths.contains(292) && widths.first == 160 && widths.last == 600)
            #expect(FolderViewPopover.sizeChoices(.details, current: 0).isEmpty)
        }

        /// The widths of every column as a drag reports them, Name at `name`.
        private func draggedWidths(name: Double) -> [DetailColumn: Double] {
            var widths: [DetailColumn: Double] = [:]
            for key in DetailColumnKey.allCases {
                widths[DetailColumn(rawValue: key.rawValue) ?? .name] = Double(DetailColumnWidths.defaults[key])
            }
            widths[.name] = name
            return widths
        }

        /// A second tab on the first one's folder, with its services, once it has read its folder.
        private func secondTab(of first: MainWindowController, _ harness: ExplorerHarness) async throws
            -> MainWindowController
        {
            let group = try #require(first.group)
            group.duplicateTab(first)
            #expect(await waitUntil { group.tabs.count == 2 })
            let second = group.tabs[1]
            second.servicesOverride = first.servicesOverride
            // Its first folder shown: a folder opened before that would be replaced by it.
            #expect(await waitUntil { second.activePane.hasShownFolder && !second.isNavigating })
            harness.services.folderViews.onChanged = { [weak first, weak second] _ in
                first?.folderViewsChanged()
                second?.folderViewsChanged()
            }
            return second
        }

        // Reading a view checks its widths and sizes against their limits. What a drag, the slider and the size
        // commands leave in a view is within them already, at the least and at the greatest too, so the file read
        // back holds the views as they were saved.
        @Test func theWidthsAndSizesTheWindowSavesAreReadBackAsTheyWere() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let pane = tab.activePane
            // Set before the folder keeps them, far past the limits and between two points.
            await go(tab, harness, "Alpha")
            var widths = draggedWidths(name: 5000.4)
            widths[.size] = 1
            widths[.kind] = 152.5
            widths[.permissions] = 5000
            tab.content.onColumnWidthsChanged?(widths)
            tab.perform(.viewAsIcons)
            tab.content.iconSizeChanged(37, save: true)
            tab.perform(.viewAsList)
            tab.content.compactListWidthChanged(601.4, save: true)
            tab.perform(.rememberFolderView)
            // And in a folder that keeps them, where they are the view's own.
            await go(tab, harness, "Beta")
            tab.perform(.viewAsDetails)
            tab.perform(.rememberFolderView)
            widths[.name] = 0
            tab.content.onColumnWidthsChanged?(widths)
            tab.perform(.viewAsIcons)
            tab.content.iconSizeChanged(1000, save: true)
            tab.perform(.viewAsList)
            tab.content.compactListWidthChanged(3, save: true)
            tab.perform(.increaseSize)
            tab.perform(.updateFolderView)

            let views = pane.folderViews.views
            let alpha = try #require(views.own(real(harness, "Alpha"))?.keeps)
            #expect(alpha.columns?.widths.name == 1000 && alpha.columns?.widths.size == 60)
            #expect(alpha.size?.iconSizes.standard == 40 && alpha.size?.compactListWidths.standard == 600)
            let beta = try #require(views.own(real(harness, "Beta"))?.keeps)
            #expect(beta.columns?.widths.name == 140)
            #expect(beta.size?.iconSizes.standard == 128 && beta.size?.compactListWidths.standard == 200)
            #expect(try FolderViews.read(Data(views.serialize().utf8)) == views)
            await harness.close()
        }

        // What a pane changed of every folder's columns goes back at Remember only where nobody changed it since. A
        // width set here and then set again in another tab stays as that tab set it; and a column shown here, then
        // hidden and shown again in another tab, stays shown: it is as this pane left it, but it was that tab that
        // showed it last.
        @Test func whatAnotherTabChangedSinceStaysThoughItIsAsThisPaneLeftIt() async throws {
            let harness = try ExplorerHarness.windowless()
            let (first, _) = try await harness.openList()
            await go(first, harness, "Alpha")
            let second = try await secondTab(of: first, harness)
            let pane = first.activePane
            let alpha = real(harness, "Alpha")
            #expect(first.preferences.detailColumnWidths.name == 320 && !first.preferences.detailColumns.permissions)

            first.content.onColumnWidthsChanged?(draggedWidths(name: 400))
            second.content.onColumnWidthsChanged?(draggedWidths(name: 500))
            first.toggleColumn(.permissions, in: pane)
            second.toggleColumn(.permissions, in: second.activePane)
            #expect(!first.preferences.detailColumns.permissions)
            second.toggleColumn(.permissions, in: second.activePane)
            #expect(first.preferences.detailColumns.permissions)
            // Shown here and left alone elsewhere: this one is the pane's to put back.
            first.toggleColumn(.created, in: pane)

            first.perform(.rememberFolderView)
            let kept = try #require(pane.folderViews.views.own(alpha)?.keeps.columns)
            #expect(kept.widths.name == 400 && kept.visibility.permissions && kept.visibility.created)
            #expect(first.preferences.detailColumnWidths.name == 500)
            #expect(first.preferences.detailColumns.permissions)
            #expect(!first.preferences.detailColumns.created)
            // The pane's own width is the one it came in with.
            #expect(pane.viewSizes?.detailColumnWidths.name == 320)
            await harness.close()
        }

        // Reset Columns in a folder with no view is a change of every folder's columns, as any other made there:
        // once the folder keeps its columns, they are the first columns for it alone, and every other folder has
        // back the columns, the order and the widths the pane came in with.
        @Test func resetColumnsThenRememberGivesEveryOtherFolderItsColumnsBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let (tab, _) = try await harness.openList()
            let pane = tab.activePane
            await go(tab, harness, "Beta")
            tab.toggleColumn(.lastOpened, in: pane)
            tab.content.onColumnWidthsChanged?(draggedWidths(name: 444))
            tab.moveColumn(.size, by: -1, in: pane)
            let carried = tab.preferences
            #expect(carried.detailColumnOrder != AppPreferenceLimits.defaultDetailColumnOrder)

            await go(tab, harness, "Alpha")
            tab.resetColumns(in: pane)
            #expect(tab.preferences.detailColumns == .defaults && tab.preferences.detailColumnWidths == .defaults)
            tab.perform(.rememberFolderView)
            let kept = try #require(pane.folderViews.views.own(real(harness, "Alpha"))?.keeps.columns)
            #expect(
                kept
                    == FolderViewColumns(
                        visibility: .defaults, order: AppPreferenceLimits.defaultDetailColumnOrder, widths: .defaults))
            #expect(tab.preferences.detailColumns == carried.detailColumns)
            #expect(tab.preferences.detailColumnOrder == carried.detailColumnOrder)
            #expect(tab.preferences.detailColumnWidths == carried.detailColumnWidths)
            #expect(pane.viewSizes?.detailColumnWidths.name == 444)
            await go(tab, harness, "Beta")
            #expect(pane.columns(from: tab.preferences).columns.contains(.lastOpened))
            await harness.close()
        }

        // Keep Columns chosen in a folder that uses a view from above waits for Save as any change: Folder
        // Customization shows it, a read in place keeps it, and leaving the folder drops it. While it waits, the view
        // above saved again in another tab shows here with the choice still made; the folder given a view of its own
        // there has it, with nothing left to save here; and the view above removed there leaves no view to keep.
        @Test func keepColumnsThatWaitsForSaveFollowsWhatAnotherTabSaves() async throws {
            let harness = try ExplorerHarness.windowless()
            let first = try await harness.open()
            let pane = first.activePane
            await go(first, harness, "Alpha")
            first.perform(.viewAsDetails)
            first.perform(.rememberFolderView)
            pane.setFolderViewSubfolders(true)
            first.perform(.updateFolderView)
            let alpha = real(harness, "Alpha")
            let inner = real(harness, "Alpha/Inner")
            await go(first, harness, "Alpha/Inner")
            let second = try await secondTab(of: first, harness)
            let other = second.activePane

            let popover = FolderViewPopover(pane: pane, tab: first, dismiss: {})
            first.folderViewPopover = popover
            defer { first.folderViewPopover = nil }
            func saveIsOn() -> Bool? {
                func find(_ view: NSView) -> NSView? {
                    if view.accessibilityIdentifier() == "folderViewPopover.update" { return view }
                    return view.subviews.lazy.compactMap(find).first
                }
                return (find(popover.contentView) as? NSButton)?.isEnabled
            }
            #expect(saveIsOn() == false)
            pane.keepOwnColumns(true)
            #expect(pane.folderView?.becomesOwn == true && pane.keepsOwnColumns)
            #expect(saveIsOn() == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            // A read in place keeps it.
            first.refresh()
            #expect(await waitUntil { !first.isNavigating })
            #expect(pane.folderView?.becomesOwn == true)

            // The view above, saved again elsewhere with another column: it shows here, the choice still made.
            await go(second, harness, "Alpha")
            second.toggleColumn(.permissions, in: other)
            second.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha)?.keeps.columns?.visibility.permissions == true)
            #expect(pane.folderView?.becomesOwn == true && pane.folderView?.use.own == false)
            #expect(pane.folderView?.shown.columns?.visibility.permissions == true)
            #expect(saveIsOn() == true)
            first.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(inner)?.keeps.columns?.visibility.permissions == true)
            #expect(pane.folderView?.isOwnSaved == true && pane.folderView?.hasUnsavedChanges == false)
            #expect(saveIsOn() == false)

            // The folder given a view of its own elsewhere: it has one, and nothing waits here.
            first.perform(.resetFolderView)
            #expect(pane.folderViews.views.own(inner) == nil && pane.folderView?.use.own == false)
            pane.keepOwnColumns(true)
            await go(second, harness, "Alpha/Inner")
            second.perform(.rememberFolderView)
            #expect(pane.folderView?.isOwnSaved == true && pane.folderView?.hasUnsavedChanges == false)
            #expect(pane.keepsOwnColumns && saveIsOn() == false)

            // The view above removed elsewhere: no view is left to give the folder, and nothing waits.
            first.perform(.resetFolderView)
            pane.keepOwnColumns(true)
            #expect(pane.folderView?.becomesOwn == true)
            await go(second, harness, "Alpha")
            second.perform(.resetFolderView)
            #expect(pane.folderView == nil && !pane.keepsOwnColumns && !first.canPerform(.updateFolderView))
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == false)

            // Leaving the folder drops it.
            second.perform(.rememberFolderView)
            other.setFolderViewSubfolders(true)
            second.perform(.updateFolderView)
            #expect(pane.folderView?.use.own == false)
            pane.keepOwnColumns(true)
            await go(first, harness, "Beta")
            await go(first, harness, "Alpha/Inner")
            #expect(pane.folderView?.becomesOwn == false && pane.folderView?.hasUnsavedChanges == false)
            #expect(pane.folderViews.views.own(inner) == nil)
            await harness.close()
        }

        // A tab in the background whose folder is renamed is read at the new place when it is next shown, and its view
        // went there first: the folder shows it, and the pane's settings count from that arrival.
        @Test func aBackgroundTabThatFollowsARenamedFolderShowsTheFoldersView() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            await go(tab, harness, "Beta")
            tab.setMode(.details)
            await go(tab, harness, "Alpha")
            #expect(pane.shownMode == .previews)

            let alpha = real(harness, "Alpha")
            let renamed = real(harness, "") + "/Alpha2"
            try FileManager.default.moveItem(atPath: alpha, toPath: renamed)
            let moves = [PathMove(from: alpha, to: renamed)]
            harness.services.folderViews.followMoves(moves)
            tab.folderViewsChanged()
            tab.takePlace(ExplorerTabs.followMovedItems(tab.snapshot, moves))
            #expect(pane.stale)
            pane.ensureLoaded()
            #expect(await waitUntil { !pane.stale && !tab.isNavigating && pane.shownFolderPath == renamed })
            #expect(pane.shownFolderView?.use.own == true)
            #expect(pane.shownFolderView?.use.view.path == renamed)
            #expect(pane.shownMode == .previews && pane.content.mode == .previews)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .own)
            // Save from there adds to the folder's view, and doesn't put a new one in its place.
            pane.setFolderViewKeeps(.foldersFirst, true)
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(renamed)?.keeps.view == .previews)
            #expect(pane.folderViews.views.own(renamed)?.keeps.foldersFirst != nil)
            await harness.close()
        }

        // A tab in the background sent elsewhere (its disk went) shows the folder it was sent to as that folder is,
        // not under the view of the folder it was on.
        @Test func aBackgroundTabSentToAnotherFolderLeavesTheViewOfTheOneItWasOn() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.details)
            await go(tab, harness, "Alpha")
            tab.setMode(.previews)
            tab.perform(.rememberFolderView)
            #expect(pane.shownMode == .previews && pane.viewMode == .details)

            let alpha = real(harness, "Alpha")
            let beta = real(harness, "Beta")
            tab.takePlace(
                ExplorerTabs.leaveUnmountedDisks(
                    tab.snapshot, unmounted: [alpha], homePath: beta, volumeRoot: { $0 == alpha ? alpha : "/" }))
            #expect(pane.stale)
            pane.ensureLoaded()
            #expect(await waitUntil { !pane.stale && !tab.isNavigating && pane.shownFolderPath == beta })
            #expect(pane.shownFolderView == nil)
            #expect(pane.shownMode == .details && pane.content.mode == .details)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.whose == .noView)
            await harness.close()
        }

        // With no folder on screen there is none to customize: the status bar's symbol goes, Folder Customization
        // doesn't open, and Update, Revert and Reset leave the view of the folder let go of as it is saved.
        @Test func withNoFolderOnScreenTheSymbolGoesAndNothingActsOnTheFolderLetGoOf() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            await go(tab, harness, "Alpha")
            tab.setMode(.details)
            tab.perform(.rememberFolderView)
            tab.setMode(.icons)
            let alpha = real(harness, "Alpha")
            let bar = pane.content.contentShell.pathBarRow
            #expect(bar.folderViewMark?.changed == true)
            // Folder Customization, open as the folder is let go of, closes with the symbol.
            tab.folderViewPopover = FolderViewPopover(pane: pane, tab: tab, dismiss: {})

            pane.showNoFolder()
            #expect(tab.folderViewPopover == nil)
            #expect(bar.folderViewMark == nil)
            #expect(bar.folderViewButton.isHidden)
            bar.onFolderViewClick(bar.folderViewButton)
            #expect(tab.folderViewPopover == nil)
            tab.showFolderViewPopover(for: pane, from: nil)
            #expect(tab.folderViewPopover == nil)
            tab.closeFolderViewPopover()
            tab.perform(.updateFolderView)
            #expect(pane.folderViews.views.own(alpha)?.keeps.view == .details)
            pane.updateFolderView()
            #expect(pane.folderViews.views.own(alpha)?.keeps.view == .details)
            tab.perform(.revertFolderView)
            #expect(pane.folderView?.shown.view == .icons)
            tab.perform(.resetFolderView)
            pane.resetFolderView()
            #expect(pane.folderViews.views.own(alpha)?.keeps.view == .details)
            await harness.close()
        }

        // A view is found by its folder's real path: a folder moved into a folder named through a link has its view
        // under where it really is, and every view inside it too.
        @Test func aFolderMovedIntoAFolderNamedThroughALinkKeepsItsView() throws {
            let folder = try TemporaryDirectory(prefix: "filetrail-folder-views")
            defer { folder.remove() }
            let root = FolderIdentity.realPath(folder.path)
            let files = FileManager.default
            try files.createDirectory(atPath: root + "/Alpha/Inner", withIntermediateDirectories: true)
            try files.createDirectory(atPath: root + "/Beta", withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: root + "/Link", withDestinationPath: root + "/Beta")
            let shared = SharedFolderViews()
            shared.update(from: nil) {
                $0.set(FolderView(path: root + "/Alpha", keeps: FolderViewKeeps(view: .icons)))
                $0.set(FolderView(path: root + "/Alpha/Inner", keeps: FolderViewKeeps(view: .details)))
            }
            try files.moveItem(atPath: root + "/Alpha", toPath: root + "/Beta/Alpha")
            shared.followMoves([PathMove(from: root + "/Alpha", to: root + "/Link/Alpha")])
            #expect(shared.views.all.map(\.path) == [root + "/Beta/Alpha", root + "/Beta/Alpha/Inner"])
            #expect(shared.use(for: root + "/Beta/Alpha")?.view.keeps.view == .icons)
            #expect(shared.use(for: root + "/Beta/Alpha/Inner")?.view.keeps.view == .details)
        }

        // The disk is asked where a folder really is only when a view goes with it: a move that carries none asks
        // nothing, and one that carries several asks once.
        @Test func onlyAMoveThatCarriesAViewAsksTheDiskWhereItWent() {
            var asked: [String] = []
            let shared = SharedFolderViews(realPath: {
                asked.append($0)
                return $0 == "/b/Pictures" ? "/real/Pictures" : $0
            })
            shared.update(from: nil) {
                $0.set(FolderView(path: "/a/Pictures", subfolders: true, keeps: FolderViewKeeps(view: .previews)))
                $0.set(FolderView(path: "/a/Pictures/Scans", keeps: FolderViewKeeps(view: .details)))
            }
            shared.followMoves([PathMove(from: "/a/Music", to: "/b/Music"), PathMove(from: "/a/Movies", to: "/b/M")])
            #expect(asked.isEmpty)
            _ = shared.use(for: "/a/Pictures/Scans")
            #expect(asked.isEmpty)
            shared.followMoves([
                PathMove(from: "/a/Music", to: "/b/Music"), PathMove(from: "/a/Pictures", to: "/b/Pictures"),
            ])
            #expect(asked == ["/b/Pictures"])
            #expect(shared.views.all.map(\.path) == ["/real/Pictures", "/real/Pictures/Scans"])
        }

        // A batch rename hands names along (1 to 2, 2 to 3) or swaps them: each folder's view goes where that folder
        // went, and none is carried on by the move of the folder whose name it took.
        @Test func foldersThatPassTheirNamesAlongOrSwapThemEachKeepTheirOwnView() {
            let shared = SharedFolderViews()
            shared.update(from: nil) {
                $0.set(FolderView(path: "/d/A1", keeps: FolderViewKeeps(view: .icons)))
                $0.set(FolderView(path: "/d/A2", keeps: FolderViewKeeps(view: .details)))
            }
            shared.followMoves([PathMove(from: "/d/A1", to: "/d/A2"), PathMove(from: "/d/A2", to: "/d/A3")])
            #expect(shared.views.all.map(\.path) == ["/d/A2", "/d/A3"])
            #expect(shared.views.own("/d/A2")?.keeps.view == .icons)
            #expect(shared.views.own("/d/A3")?.keeps.view == .details)

            shared.followMoves([PathMove(from: "/d/A2", to: "/d/A3"), PathMove(from: "/d/A3", to: "/d/A2")])
            #expect(shared.views.own("/d/A3")?.keeps.view == .icons)
            #expect(shared.views.own("/d/A2")?.keeps.view == .details)
        }

        // What is changed in Folder Customization in a folder with no view waits for Save: a view saved or removed
        // for some other folder meanwhile leaves it on screen.
        @Test func anUnsavedViewOfAFolderWithNoneStaysWhenAnotherFoldersViewChanges() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let pane = tab.activePane
            tab.setMode(.icons)
            await go(tab, harness, "Alpha")
            pane.setFolderViewKeeps(.view, true)
            #expect(pane.folderView?.isDraft == true)
            pane.folderViews.update(from: nil) {
                $0.set(FolderView(path: "/x", keeps: FolderViewKeeps(view: .details)))
            }
            tab.folderViewsChanged()
            #expect(pane.folderView?.isDraft == true)
            #expect(pane.folderView?.shown.view == .icons && pane.folderView?.hasUnsavedChanges == true)
            #expect(pane.content.contentShell.pathBarRow.folderViewMark?.changed == true)
            pane.folderViews.update(from: nil) { $0.remove("/x") }
            tab.folderViewsChanged()
            #expect(pane.folderView?.isDraft == true)

            // The folder given a view of its own meanwhile: that is the one it uses, with what is changed here.
            let alpha = real(harness, "Alpha")
            pane.folderViews.update(from: nil) {
                $0.set(FolderView(path: alpha, keeps: FolderViewKeeps(foldersFirst: false)))
            }
            tab.folderViewsChanged()
            #expect(pane.folderView?.isOwnSaved == true)
            #expect(pane.folderView?.shown.view == .icons && pane.folderView?.unsaved == [.view])
            await harness.close()
        }
    }
}
