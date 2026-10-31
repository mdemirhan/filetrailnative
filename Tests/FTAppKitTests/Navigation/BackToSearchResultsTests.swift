// Ports the cases "Back and Forward with search results" of apps/desktop/src/renderer/App.history.test.tsx on a real
// tab whose window is never shown, over the stand-in fd runtime
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct BackToSearchResultsTests {
        /// The tab went from the harness's folder ("B") to Alpha ("A"); `Inner` in A is what a search finds ("X").
        private struct Place {
            let harness: ExplorerHarness
            let tab: MainWindowController
            let engine: FakeSearchEngine
            let timers: ManualTimers
            var before: String { harness.folder.path }
            var searched: String { harness.folder.appending("Alpha").path }
            var found: String { harness.folder.appending("Alpha/Inner").path }
        }

        private func start() async throws -> Place {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["Inner/"], false, false) }
            let place = Place(harness: harness, tab: tab, engine: engine, timers: timers)
            #expect(await opening(place, place.searched))
            return place
        }

        private func opening(_ place: Place, _ path: String) async -> Bool {
            place.tab.go(to: URL(fileURLWithPath: path))
            return await settled(place, on: path)
        }

        private func settled(_ place: Place, on path: String) async -> Bool {
            await waitUntil { place.tab.shownFolderPath == path && !place.tab.isNavigating }
        }

        private func type(_ text: String, _ place: Place) throws {
            let field = try #require(place.tab.searchField)
            field.stringValue = text
            place.tab.search.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        private func searchInFolder(_ place: Place, _ text: String = "in") throws {
            try type(text, place)
            place.timers.advance(0.4)
            #expect(place.tab.searchRootPath != nil)
        }

        /// Selects what the search found and opens it, as a double-click does.
        private func openResult(_ place: Place, named name: String = "Inner", at path: String? = nil) async throws {
            let content = place.tab.content
            #expect(await waitUntil { content.entries.contains { $0.name == name } })
            let entry = try #require(content.entries.first { $0.name == name })
            content.applySelection(.single(entry.path))
            place.tab.open([entry])
            #expect(await settled(place, on: path ?? place.found))
            #expect(place.tab.searchRootPath == nil)
        }

        private func search(_ place: Place) async throws {
            try searchInFolder(place)
            try await openResult(place)
        }

        private func back(_ place: Place, to path: String) async -> Bool {
            place.tab.perform(.goBack)
            return await settled(place, on: path)
        }

        private func forward(_ place: Place, to path: String) async -> Bool {
            place.tab.perform(.goForward)
            return await settled(place, on: path)
        }

        private func expectResults(_ place: Place, query: String = "in", selected: String? = nil) {
            #expect(place.tab.searchRootPath != nil)
            #expect(place.tab.search.showsResults)
            #expect(place.tab.searchField?.stringValue == query)
            #expect(place.tab.content.entryPaths.contains(place.found))
            if let selected { #expect(place.tab.content.selection.paths == [selected]) }
        }

        private func expectFolder(_ place: Place, _ path: String) {
            #expect(place.tab.shownFolderPath == path)
            #expect(place.tab.searchRootPath == nil)
            #expect(!place.tab.search.showsResults)
            #expect(place.tab.searchField?.stringValue == "")
            #expect(place.tab.content.folderPath == path)
        }

        // Back brings back the results a folder was opened from, as they were left; Forward leaves them, and
        // Back from them goes on to the folder before them.
        // T-6f2fa78f B-SRCH-197 B-SRCH-198
        @Test func bringsBackTheResultsAFolderWasOpenedFromAsItWasLeft() async throws {
            let place = try await start()
            try await search(place)

            #expect(await back(place, to: place.searched))
            expectResults(place, selected: place.found)
            #expect(place.tab.content.folderPath == place.searched)

            #expect(await forward(place, to: place.found))
            expectFolder(place, place.found)
            #expect(await back(place, to: place.searched))
            expectResults(place)

            #expect(await back(place, to: place.before))
            expectFolder(place, place.before)
            #expect(await forward(place, to: place.searched))
            expectResults(place)
            #expect(place.tab.historyIndex == 1)
            // Only the first search ran: they came back as they were.
            #expect(place.engine.starts.count == 1)
            await place.harness.close()
        }

        // Esc closes them for good.
        // T-09d7d736 B-SRCH-199
        // B-SRCH-051
        @Test func showsTheFolderAfterTheResultsWereClosed() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            expectResults(place)

            let field = try #require(place.tab.searchField)
            let window = try #require(place.tab.window)
            if window.firstResponder as? NSTextView == nil { window.makeFirstResponder(field) }
            let editor = try #require(window.firstResponder as? NSTextView)
            _ = place.tab.search.control(
                field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            expectFolder(place, place.searched)

            #expect(await forward(place, to: place.found))
            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // Done closes them as Esc does.
        // B-SRCH-199
        // B-SRCH-063
        @Test func doneClosesThemToo() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            place.tab.search.header.onDone()
            expectFolder(place, place.searched)
            #expect(await forward(place, to: place.found))
            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // Choosing the folder they cover closes them.
        // B-SRCH-199
        @Test func choosingTheSearchedFolderClosesThem() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            expectResults(place)
            place.tab.go(to: URL(fileURLWithPath: place.searched))
            #expect(await waitUntil { place.tab.searchRootPath == nil && !place.tab.isNavigating })
            expectFolder(place, place.searched)
            #expect(place.tab.search.session.returnPlace == nil)
            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // A newer search over the folder opened from the results: Back shows the plain folder, not the new
        // results over it.
        // T-6e993392 B-SRCH-199
        @Test func showsTheFolderWhereOlderResultsWereLeftAfterANewerSearch() async throws {
            let place = try await start()
            try await search(place)
            place.engine.finds = { _ in (["Elsewhere/"], false, false) }
            try searchInFolder(place, "else")

            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // It is the results on screen when leaving that count: the newer ones come back where they were left, and the
        // folder of the older ones stays plain.
        // B-SRCH-198
        @Test func theNewerResultsComeBackWhereTheyWereLeft() async throws {
            let place = try await start()
            try await search(place)
            let deeper = place.found + "/Deeper"
            try FileManager.default.createDirectory(atPath: deeper, withIntermediateDirectories: true)
            place.engine.finds = { _ in (["Deeper/"], false, false) }
            try searchInFolder(place, "deep")
            try await openResult(place, named: "Deeper", at: deeper)

            #expect(await back(place, to: place.found))
            #expect(place.tab.searchRootPath == place.found)
            #expect(place.tab.searchField?.stringValue == "deep")
            #expect(place.tab.content.entryPaths == [deeper])
            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // Another folder took their place in the history: it opens as itself.
        // T-c7131e0d B-SRCH-200
        @Test func showsTheFolderWhenAnotherOneHasTakenTheResultsPlaceInTheHistory() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            expectResults(place)
            #expect(await back(place, to: place.before))
            let other = place.harness.folder.appending("Beta").path
            #expect(await opening(place, other))

            #expect(await back(place, to: place.before))
            expectFolder(place, place.before)
            #expect(await forward(place, to: other))
            expectFolder(place, other)
            await place.harness.close()
        }

        // The hold lists behave the same when they jump to that spot, from either side.
        // B-SRCH-197
        @Test func theHoldListsBringThemBackToo() async throws {
            let place = try await start()
            try await search(place)
            place.tab.goToHistoryIndex(1)
            #expect(await settled(place, on: place.searched))
            expectResults(place, selected: place.found)
            place.tab.goToHistoryIndex(0)
            #expect(await settled(place, on: place.before))
            expectFolder(place, place.before)
            place.tab.goToHistoryIndex(1)
            #expect(await settled(place, on: place.searched))
            expectResults(place)
            place.tab.goToHistoryIndex(2)
            #expect(await settled(place, on: place.found))
            expectFolder(place, place.found)
            await place.harness.close()
        }

        // Narrowing what was brought back makes those results the ones that count: the place left is forgotten.
        // B-SRCH-199
        @Test func narrowingForgetsThePlace() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            #expect(place.tab.search.session.returnPlace != nil)
            try type("inn", place)
            #expect(place.tab.search.session.committedQuery == "inn")
            #expect(place.tab.search.session.returnPlace == nil)
            #expect(place.engine.starts.count == 1)
            await place.harness.close()
        }

        // Emptying the field clears the search, and the place with it.
        // B-SRCH-199
        @Test func emptyingTheFieldForgetsThePlace() async throws {
            let place = try await start()
            try await search(place)
            #expect(await back(place, to: place.searched))
            try type("", place)
            expectFolder(place, place.searched)
            #expect(place.tab.search.session.returnPlace == nil)
            #expect(await forward(place, to: place.found))
            #expect(await back(place, to: place.searched))
            expectFolder(place, place.searched)
            await place.harness.close()
        }

        // A search still running when it was left is searched again, rather than showing what it had found.
        // B-SRCH-201
        @Test func aSearchStillRunningIsSearchedAgain() async throws {
            let place = try await start()
            place.engine.finds = { _ in (["Inner/"], true, false) }
            try await search(place)
            place.engine.finds = { _ in (["Inner/"], false, false) }

            #expect(await back(place, to: place.searched))
            expectResults(place)
            #expect(place.engine.starts.count == 2)
            #expect(place.engine.starts.last?.rootPath == place.searched)
            await place.harness.close()
        }

        // So is one found with the other hidden-files setting.
        // B-SRCH-201
        // B-NAV-131 B-SRCH-074 B-SRCH-079
        @Test func aChangedHiddenFilesSettingSearchesAgain() async throws {
            let place = try await start()
            try await search(place)
            place.tab.perform(.toggleHiddenFiles)
            #expect(await waitUntil { place.tab.includeHidden && !place.tab.isNavigating })

            #expect(await back(place, to: place.searched))
            expectResults(place)
            #expect(place.engine.starts.count == 2)
            #expect(place.engine.starts.last?.includeHidden == true)
            await place.harness.close()
        }

        // The plain folder never shows: by the time the tab tells of the folder, ahead of the window drawing, the results
        // are in the list.
        // B-SRCH-201
        @Test func thePlainFolderDoesNotFlash() async throws {
            let place = try await start()
            try await search(place)
            var showing: [Bool] = []
            let observation = place.tab.observe { [tab = place.tab] change in
                if change == .folder { showing.append(tab.search.showsResults) }
            }
            #expect(await back(place, to: place.searched))
            withExtendedLifetime(observation) {}
            #expect(showing == [true])
            await place.harness.close()
        }

        // A result that can no longer be opened leaves the results as they are: nothing is put away until the folder has
        // been read.
        // B-NAV-021
        @Test func aResultThatCannotBeOpenedLeavesTheResults() async throws {
            let place = try await start()
            try searchInFolder(place)
            let content = place.tab.content
            #expect(await waitUntil { content.entries.contains { $0.name == "Inner" } })
            let entry = try #require(content.entries.first { $0.name == "Inner" })
            content.applySelection(.single(entry.path))
            try FileManager.default.removeItem(atPath: place.found)
            place.tab.open([entry])
            #expect(await waitUntil { content.readError != nil && !place.tab.isNavigating })
            expectResults(place, selected: place.found)
            #expect(place.tab.search.session.returnPlace == nil)
            await place.harness.close()
        }

        // So does a Back that can't be read: the place in the history moved at once, the results did not go.
        // B-NAV-021
        @Test func aBackThatCannotBeReadLeavesTheResults() async throws {
            let place = try await start()
            let gone = place.harness.folder.appending("Beta/Gone").path
            try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
            #expect(await opening(place, gone))
            #expect(await opening(place, place.searched))
            try searchInFolder(place)
            #expect(await waitUntil { place.tab.content.entryPaths.contains(place.found) })
            try FileManager.default.removeItem(atPath: gone)
            place.harness.services.directoryService.cache.clear()
            place.tab.perform(.goBack)
            #expect(await waitUntil { place.tab.content.readError != nil && !place.tab.isNavigating })
            expectResults(place)
            #expect(place.tab.search.session.returnPlace == nil)
            await place.harness.close()
        }

        // The results stay until the folder arrives: the plain searched folder never shows while it is read.
        // B-NAV-021
        @Test func theResultsStayWhileTheFolderIsRead() async throws {
            let place = try await start()
            try searchInFolder(place)
            let content = place.tab.content
            #expect(await waitUntil { content.entries.contains { $0.name == "Inner" } })
            let entry = try #require(content.entries.first { $0.name == "Inner" })
            content.applySelection(.single(entry.path))
            let held = HeldFolder(held: place.found)
            place.tab.servicesOverride = ExplorerServices(
                directoryService: DirectoryService(fileSystem: held), folderWatches: nil, iconStore: nil,
                volumeWatcher: nil, clipboard: place.harness.windows.clipboard, preferences: place.harness.channel)
            place.tab.open([entry])
            #expect(await waitUntil { held.isHolding })
            expectResults(place, selected: place.found)
            #expect(content.searchDisplay != nil)
            held.letGo()
            #expect(await settled(place, on: place.found))
            expectFolder(place, place.found)
            await place.harness.close()
        }

        // Each tab has its own: a new one starts with none, and the first keeps its own.
        // B-SRCH-202
        @Test func aNewTabStartsWithNone() async throws {
            let place = try await start()
            try await search(place)
            let group = try #require(place.tab.group)
            group.openNewTab(from: place.tab)
            let other = try #require(group.tabs.first { $0 !== place.tab })
            #expect(other.search.session.returnPlace == nil)
            #expect(!other.search.session.hasCachedSearch)
            group.select(place.tab)
            #expect(place.tab.search.session.returnPlace != nil)
            #expect(await back(place, to: place.searched))
            expectResults(place)
            await place.harness.close()
        }

        // At the very start of the history Back stays disabled, and Esc closes the results.
        // B-NAV-009
        @Test func resultsAtTheStartOfTheHistoryHaveNoBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (["Alpha/"], false, false) }
            let place = Place(harness: harness, tab: tab, engine: engine, timers: timers)
            try searchInFolder(place, "al")
            #expect(!tab.canGoBack)
            tab.perform(.goBack)
            #expect(tab.searchRootPath != nil)
            tab.search.session.hideResults()
            expectFolder(place, harness.folder.path)
            await harness.close()
        }
    }
}

/// Holds the read of one folder until the test lets it go.
private final class HeldFolder: ExplorerFileSystem, @unchecked Sendable {
    private let held: String
    private let real = NativeFileSystem()
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var holding = false

    init(held: String) { self.held = held }

    var isHolding: Bool { lock.withLock { holding } }

    func letGo() { gate.signal() }

    private func wait(_ path: String) {
        guard path == held else { return }
        lock.withLock { holding = true }
        gate.wait()
        gate.signal()
    }

    func readDirectory(_ path: String) throws -> [DirectoryRecord] {
        wait(path)
        return try real.readDirectory(path)
    }

    func stat(_ path: String) throws -> FileStats {
        wait(path)
        return try real.stat(path)
    }

    func lstat(_ path: String) throws -> FileStats { try real.lstat(path) }
    func realpath(_ path: String) throws -> String { try real.realpath(path) }
}
