// Ports by behavior row (App.search.test.tsx, App.folderOrder.test.tsx, App.folderWatch.test.tsx) the routes into a search
// in a real tab: the keys through the window, the field's commands, ⌘R, ⌘F, opening results, and what becomes of the list's
// filter, over the stand-in fd runtime
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations
import Foundation
import Testing

@testable import FTAppKit

/// Reads one folder slowly, so a test can do something while it is being read.
private struct SlowReads: ExplorerFileSystem {
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

/// Whether the cache has this listing; if not, it holds it from now on.
private func holds(_ cache: ResponseCache, _ key: ListingKey, _ snapshot: DirectorySnapshot) async -> Bool {
    var held = true
    _ = await cache.directorySnapshot(key) {
        held = false
        return snapshot
    }
    return held
}

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SearchRoutesTests {
        private struct Opened {
            let harness: ExplorerHarness
            let tab: MainWindowController
            let list: ListProbe
            let engine: FakeSearchEngine
            let timers: ManualTimers
        }

        private func open() async throws -> Opened {
            let harness = try ExplorerHarness.windowless()
            let (tab, list) = try await harness.openList()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            return Opened(harness: harness, tab: tab, list: list, engine: engine, timers: timers)
        }

        private func search(_ text: String, _ opened: Opened) throws {
            let field = try #require(opened.tab.searchField)
            field.stringValue = text
            opened.tab.search.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            opened.timers.advance(0.4)
        }

        /// A command of the field's editor, with the field holding the keyboard as it does when the key is pressed.
        private func command(_ selector: Selector, _ tab: MainWindowController) throws {
            let field = try #require(tab.searchField)
            let window = try #require(tab.window)
            if window.firstResponder as? NSTextView == nil { window.makeFirstResponder(field) }
            let editor = try #require(window.firstResponder as? NSTextView)
            _ = tab.search.control(field, textView: editor, doCommandBy: selector)
        }

        private func escape(in window: NSWindow) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                    keyCode: 53))
        }

        private func names(_ tab: MainWindowController) -> [String] { tab.content.entries.map(\.name) }

        /// Waits for the folder read again.
        private func readingAgain(_ tab: MainWindowController, _ start: () -> Void) async -> Bool {
            var read = false
            let watching = tab.observe { if $0 == .folder { read = true } }
            start()
            let done = await waitUntil { read }
            withExtendedLifetime(watching) {}
            return done
        }

        // MARK: Esc in the results

        // B-NAV-213 B-SEL-092: Esc through the window with the list focused and no filter hides the results, empties the
        // field and leaves the list the keyboard; the results stay cached for ⇧⌘F.
        @Test func escapeThroughTheWindowHidesTheResults() async throws {
            let opened = try await open()
            let (tab, list) = (opened.tab, opened.list)
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            tab.content.focusList()
            list.key("Escape")
            #expect(tab.searchRootPath == nil)
            #expect(tab.searchField?.stringValue == "")
            #expect(tab.window?.firstResponder === tab.content.focusView)
            #expect(tab.search.session.hasCachedSearch)
            #expect(tab.canPerform(.showLastSearchResults))
            await opened.harness.close()
        }

        // B-SRCH-117 B-NAV-213: typing in the results goes into their filter, which the bar's field mirrors; Backspace takes
        // a character back; Esc clears the whole filter and keeps the results, the next hides them.
        @Test func typingInTheResultsFiltersThemAndEscapeClearsFirst() async throws {
            let opened = try await open()
            let (tab, list) = (opened.tab, opened.list)
            opened.engine.finds = { _ in (["rot.txt", "Alpha/other.md", "Alpha/oth.txt"], false, false) }
            try search("ot", opened)
            #expect(names(tab).count == 3)
            let header = tab.search.header
            tab.content.focusList()
            list.type("oth")
            #expect(tab.content.filter == "oth")
            #expect(header.filter.text == "oth")
            #expect(Set(names(tab)) == ["other.md", "oth.txt"])
            list.key("Backspace")
            #expect(tab.content.filter == "ot")
            #expect(header.filter.text == "ot")
            list.key("Escape")
            #expect(tab.content.filter.isEmpty)
            #expect(header.filter.text.isEmpty)
            #expect(names(tab).count == 3)
            #expect(tab.search.session.isSearchMode)
            list.key("Escape")
            #expect(!tab.search.session.isSearchMode)
            await opened.harness.close()
        }

        // B-SRCH-190: Esc in an open rename field is the field's: the results stay.
        @Test func escapeInARenameFieldLeavesTheResults() async throws {
            let opened = try await open()
            let tab = opened.tab
            let window = try #require(tab.window)
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            let result = try #require(tab.content.entryPaths.first)
            #expect(tab.content.beginRename(path: result))
            #expect(!WindowEventRouting.intercept(try escape(in: window), in: window))
            #expect(tab.search.session.isSearchMode)
            await opened.harness.close()
        }

        // B-SRCH-190: and so is Esc in the results' filter field.
        @Test func escapeInTheFilterFieldLeavesTheResults() async throws {
            let opened = try await open()
            let tab = opened.tab
            let window = try #require(tab.window)
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            window.makeFirstResponder(tab.search.header.filter.input)
            #expect(!WindowEventRouting.intercept(try escape(in: window), in: window))
            #expect(tab.search.session.isSearchMode)
            await opened.harness.close()
        }

        // MARK: ⌘R

        // T-1d9870a1 B-NAV-125 B-SRCH-140: ⌘R on results runs the same search again from the same place, the old results
        // going at its start; the folder isn't read and its cached listing stays.
        @Test func refreshOnResultsRunsTheSearchAgainAndLeavesTheFolderAlone() async throws {
            let opened = try await open()
            let (tab, engine) = (opened.tab, opened.engine)
            engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            #expect(names(tab) == ["note.txt"])
            // A listing the cache holds: forgetting them is what the folder's Refresh does.
            let cache = tab.services.directoryService.cache
            let key = ListingKey(path: "/kept-by-the-test")
            let kept = try JSONDecoder().decode(
                DirectorySnapshot.self, from: Data(#"{"path":"/kept-by-the-test","entries":[]}"#.utf8))
            #expect(await !holds(cache, key, kept))
            let folderReads = await counting(tab) {
                engine.finds = { _ in ([], true, false) }
                tab.perform(.refreshOrApplySearchSort)
                #expect(engine.starts.count == 2)
                #expect(engine.starts.last?.query == "no")
                #expect(engine.starts.last?.rootPath == engine.starts.first?.rootPath)
                #expect(names(tab).isEmpty)
                #expect(tab.search.session.isSearchMode)
            }
            #expect(folderReads == 0)
            #expect(await holds(cache, key, kept))
            await opened.harness.close()
        }

        /// How many times the tab says its folder was read while `work` runs and for a moment after.
        private func counting(_ tab: MainWindowController, _ work: () -> Void) async -> Int {
            var reads = 0
            let watching = tab.observe { if $0 == .folder { reads += 1 } }
            work()
            try? await Task.sleep(for: .milliseconds(150))
            withExtendedLifetime(watching) {}
            return reads
        }

        // B-NAV-215: a hidden-files change reads the folder again under the results, which stay on screen.
        // B-VIEW-193 T-1017295b T-c05f1d45
        @Test func aHiddenFilesChangeKeepsTheResultsOnceTheFolderIsRead() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            #expect(await readingAgain(tab) { tab.perform(.toggleHiddenFiles) })
            #expect(tab.searchRootPath != nil)
            #expect(tab.content.contentShell.searchHeader === tab.search.header)
            #expect(names(tab) == ["note.txt"])
            await opened.harness.close()
        }

        // MARK: ⌘F

        // T-21dd6904 B-SEL-083 B-VIEW-232: ⌘F with text typed into the list: the filter goes, the field holds the text and
        // the keyboard, and a live search of the folder on screen starts for it.
        @Test func findFilesCarriesTheFilterIntoTheSearch() async throws {
            let opened = try await open()
            let (tab, list, engine) = (opened.tab, opened.list, opened.engine)
            engine.finds = { _ in (["source.txt"], true, false) }
            tab.content.focusList()
            list.type("no")
            #expect(tab.content.filter == "no")
            tab.perform(.focusFileSearch)
            #expect(tab.content.filter.isEmpty)
            #expect(tab.searchField?.stringValue == "no")
            #expect(engine.starts.map(\.query) == ["no"])
            #expect(engine.starts.first?.rootPath == tab.shownFolderPath)
            #expect(tab.search.session.startedLive)
            #expect(tab.searchField?.isActive == true)
            // B-SRCH-052: the caret follows the text, so the next key adds to it.
            #expect(tab.searchField?.currentEditor()?.selectedRange == NSRange(location: 2, length: 0))
            await opened.harness.close()
        }

        // B-SRCH-048: ⌘F on a finished search brings it back with the field's text selected.
        @Test func findFilesBringsTheCachedResultsBackWithTheTextSelected() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("note", opened)
            tab.search.session.hideResults()
            tab.content.focusList()
            #expect(tab.searchField?.stringValue == "")
            tab.perform(.focusFileSearch)
            #expect(tab.search.session.isSearchMode)
            #expect(opened.engine.starts.count == 1)
            let field = try #require(tab.searchField)
            #expect(field.stringValue == "note")
            #expect(field.isActive)
            let editor = try #require(field.currentEditor())
            #expect(editor.selectedRange == NSRange(location: 0, length: 4))
            // With the field already holding the keyboard, too.
            editor.selectedRange = NSRange(location: 2, length: 0)
            tab.perform(.focusFileSearch)
            #expect(editor.selectedRange == NSRange(location: 0, length: 4))
            await opened.harness.close()
        }

        // MARK: The field

        // B-SRCH-044: the field taking the keyboard brings the results back, and no pane has the focus.
        @Test func focusingTheFieldBringsTheResultsBack() async throws {
            let opened = try await open()
            let tab = opened.tab
            let window = try #require(tab.window)
            opened.engine.finds = { _ in (["note.txt"], false, false) }
            try search("no", opened)
            tab.search.session.hideResults()
            tab.content.focusList()
            #expect(tab.focusedPane == .content)
            window.makeFirstResponder(tab.searchField)
            #expect(tab.search.session.isSearchMode)
            #expect(tab.searchField?.stringValue == "no")
            #expect(tab.focusedPane == nil)
            await opened.harness.close()
        }

        // B-SRCH-012: Return on results already on screen selects the first at once, if nothing is selected.
        @Test func returnSelectsTheFirstResultOnlyIfNothingIs() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["note.txt", "notes.md"], false, false) }
            try search("no", opened)
            let paths = tab.content.entryPaths
            #expect(tab.content.selection.isEmpty)
            try command(#selector(NSResponder.insertNewline(_:)), tab)
            #expect(tab.content.selection.paths == [paths[0]])
            #expect(tab.window?.firstResponder === tab.content.focusView)

            tab.content.applySelection(.single(paths[1]))
            try command(#selector(NSResponder.insertNewline(_:)), tab)
            #expect(tab.content.selection.paths == [paths[1]])
            #expect(opened.engine.starts.count == 1)
            await opened.harness.close()
        }

        // B-SRCH-050 B-VIEW-129: ↓ in the field hands off to the results, selecting the first if nothing is.
        @Test func downInTheFieldGoesIntoTheResults() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["note.txt", "notes.md"], false, false) }
            try search("no", opened)
            let paths = tab.content.entryPaths
            try command(#selector(NSResponder.moveDown(_:)), tab)
            #expect(tab.window?.firstResponder === tab.content.focusView)
            #expect(tab.content.selection.paths == [paths[0]])

            tab.content.applySelection(.single(paths[1]))
            try command(#selector(NSResponder.moveDown(_:)), tab)
            #expect(tab.content.selection.paths == [paths[1]])
            await opened.harness.close()
        }

        // B-SRCH-050: with no results it does nothing else: the keyboard stays and nothing is selected.
        @Test func downInTheFieldWithoutResultsStaysThere() async throws {
            let opened = try await open()
            let tab = opened.tab
            let selected = tab.content.selection
            try command(#selector(NSResponder.moveDown(_:)), tab)
            #expect(tab.window?.firstResponder is NSTextView)
            #expect(tab.searchField?.isActive == true)
            #expect(tab.content.selection == selected)
            await opened.harness.close()
        }

        // MARK: The filter on results

        // B-SRCH-038 B-SRCH-123: a filter typed into the results goes with the list it was typed in: when the query is
        // refined, and when the results are put away.
        @Test func theResultsFilterGoesWithTheirQuery() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["note.txt", "Alpha/notes.md"], false, false) }
            try search("no", opened)
            let filter = tab.search.header.filter
            func filterBy(_ text: String) {
                filter.input.stringValue = text
                filter.controlTextDidChange(
                    Notification(name: NSControl.textDidChangeNotification, object: filter.input))
            }
            filterBy("alpha")
            #expect(names(tab) == ["notes.md"])
            // Refined: narrowed without a search.
            let field = try #require(tab.searchField)
            field.stringValue = "not"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(opened.engine.starts.count == 1)
            #expect(tab.content.filter.isEmpty)
            #expect(filter.text.isEmpty)
            #expect(Set(names(tab)) == ["note.txt", "notes.md"])

            filterBy("alpha")
            #expect(names(tab) == ["notes.md"])
            tab.search.session.hideResults()
            #expect(tab.content.filter.isEmpty)
            tab.search.session.showCachedResults()
            #expect(Set(names(tab)) == ["note.txt", "notes.md"])
            await opened.harness.close()
        }

        // B-SEL-079: the filter of a folder's list isn't dropped by a refresh, a new order or a selection.
        @Test func theFiltersStaysThroughARefreshASortAndASelection() async throws {
            let opened = try await open()
            let (tab, list) = (opened.tab, opened.list)
            tab.content.focusList()
            list.type("al")
            #expect(tab.content.filter == "al")
            #expect(names(tab) == ["Alpha"])
            #expect(await readingAgain(tab) { tab.refresh() })
            #expect(tab.content.filter == "al")
            #expect(names(tab) == ["Alpha"])
            #expect(await readingAgain(tab) { tab.perform(.sortByKind) })
            #expect(tab.content.filter == "al")
            tab.content.applySelection(.empty)
            #expect(tab.content.filter == "al")
            // And the folder changing does drop it.
            _ = await tab.navigate(to: URL(fileURLWithPath: tab.folder.path + "/Beta"))
            #expect(tab.content.filter.isEmpty)
            await opened.harness.close()
        }

        // MARK: Opening results

        // B-NAV-074 B-SEL-093 B-SRCH-147: with Double-click set to Edit a result still opens, by the activation the list's
        // own double-click uses; in the folder's list the same press edits.
        @Test func aResultNeverEdits() async throws {
            let opened = try await open()
            let (tab, list) = (opened.tab, opened.list)
            let spy = OpenSpy()
            tab.opener = spy.opener
            var files: [String] = []
            tab.openFile = { files.append($0.lastPathComponent) }
            tab.updatePreferences(["fileActivationAction": .string("edit")])
            #expect(tab.preferences.fileActivationAction == .edit)
            opened.engine.finds = { _ in (["note.txt"], false, false) }

            let inFolder = try #require(tab.content.entries.first { $0.name == "note.txt" })
            tab.open([inFolder])
            #expect(await waitUntil { spy.all.contains { $0.hasPrefix("open -a") } })
            #expect(files.isEmpty)

            let edits = spy.all.count
            try search("no", opened)
            harnessLayout(opened)
            await list.click(name: "note.txt", count: 2)
            #expect(files == ["note.txt"])
            #expect(spy.all.count == edits)
            #expect(tab.search.session.isSearchMode)
            await opened.harness.close()
        }

        private func harnessLayout(_ opened: Opened) {
            opened.harness.layout(opened.tab)
        }

        // B-SEL-093 B-SRCH-147: one folder result navigates into it, which ends search mode.
        @Test func aFolderResultEndsTheSearch() async throws {
            let opened = try await open()
            let tab = opened.tab
            opened.engine.finds = { _ in (["Alpha/"], false, false) }
            try search("al", opened)
            let alpha = try #require(tab.content.entries.first { $0.name == "Alpha" })
            tab.open([alpha])
            #expect(await waitUntil { tab.searchRootPath == nil && tab.folder.lastPathComponent == "Alpha" })
            #expect(tab.searchField?.stringValue == "")
            await opened.harness.close()
        }

        // MARK: Other tabs

        // B-SRCH-138: closing a tab cancels its running search.
        @Test func closingATabCancelsItsSearch() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let group = try #require(tab.group)
            group.openTab(path: harness.folder.appending("Alpha").path, from: tab)
            let other = try #require(group.tabs.last)
            other.ensureLoaded()
            #expect(await waitUntil { other.workspace.isReady && other.loaded })
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            other.search.session.engine = engine
            other.search.session.timers = timers
            engine.finds = { _ in ([], true, false) }
            other.search.session.submit("no")
            let job = try #require(other.search.session.jobID)
            #expect(engine.cancels.isEmpty)
            group.closeTab(other)
            #expect(engine.cancels == [job])
            await harness.close()
        }

        // T-a03d3600: a folder being read again when the user goes elsewhere: the tab stays where the user went.
        @Test func aQuietReadOfTheFolderLeftDoesNotComeBack() async throws {
            let harness = try ExplorerHarness.windowless()
            let watches = FolderWatches(
                FolderWatches.Dependencies(
                    watchFolder: { _, _, _ in {} }, readModifiedTime: { _ in nil }, onFolderChanged: { _, _ in },
                    forgetCachedListings: { _, _ in }))
            harness.windows.folderWatches = watches
            let alpha = harness.folder.appending("Alpha").path
            let beta = harness.folder.appending("Beta").path
            let tab = try await harness.open(alpha)
            let shownAlpha = tab.shownFolderPath
            tab.servicesOverride = ExplorerServices(
                directoryService: DirectoryService(fileSystem: SlowReads(slow: shownAlpha)), folderWatches: nil,
                iconStore: nil, volumeWatcher: nil, clipboard: harness.windows.clipboard, preferences: harness.channel)
            tab.reload()
            try await Task.sleep(for: .milliseconds(100))
            tab.go(to: URL(fileURLWithPath: beta))
            #expect(await waitUntil { samePath(tab.shownFolderPath, beta) })
            try await Task.sleep(for: .milliseconds(600))
            #expect(samePath(tab.shownFolderPath, beta))
            #expect(tab.content.entries.allSatisfy { $0.path.hasSuffix("/Beta/\($0.name)") })
            #expect(samePath(try #require(watches.watchedPaths[tab.windowID]), beta))
            await harness.close()
        }
    }

    /// What replaces a global: the tab on screen last, and the app's file operations.
    @MainActor
    @Suite(.windowlessAlone) struct SearchAcrossTheWindowTests {
        // B-SRCH-092: a new tab starts with the options and order of the search on screen, and nothing searched.
        @Test func aNewTabTakesTheOptionsOfTheTabOnScreen() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            let session = tab.search.session
            session.setPatternMode(.regex)
            session.setMatchScope(.path)
            session.setRecursive(false)
            session.setSkipGitIgnored(true)
            session.setSort(.name, .desc)
            let group = try #require(tab.group)
            group.openTab(path: harness.folder.path, from: tab)
            let other = try #require(group.tabs.last)
            #expect(other !== tab)
            let new = other.search.session
            #expect(new.patternMode == .regex)
            #expect(new.matchScope == .path)
            #expect(!new.recursive)
            #expect(new.skipGitIgnored)
            #expect(new.sortBy == .name && new.sortDirection == .desc)
            #expect(!new.hasCachedSearch)
            // Those of a fresh launch, in the tab that was there.
            #expect(tab.preferences.searchPatternMode == .text)
            await harness.close()
        }

        // B-SRCH-092: a new window reads the saved options; those of another window's search stay there.
        @Test func aNewWindowStartsWithTheSavedOptions() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            tab.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            tab.search.session.setPatternMode(.regex)
            let group = try #require(tab.group)
            group.openNewWindow(from: tab, path: harness.folder.path)
            let other = try #require(harness.windows.front as? MainWindowController)
            #expect(other.group !== group)
            #expect(other.preferences.searchPatternMode == .text)
            #expect(other.search.session.patternMode == .text)
            await harness.close()
        }

        private func searching(
            _ harness: ExplorerHarness, names: [String]
        ) async throws -> (tab: MainWindowController, operations: AppWriteOperations, engine: FakeSearchEngine) {
            let tab = try await harness.open()
            let operations = AppWriteOperations(
                userData: harness.folder.url, directoryService: harness.services.directoryService,
                windows: harness.windows, trash: .standIn, log: { _ in })
            operations.dialogs.show = { _, _, _ in }
            operations.dialogs.confirm = { _, _ in false }
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.search.session.engine = engine
            tab.search.session.timers = timers
            engine.finds = { _ in (names, false, false) }
            let field = try #require(tab.searchField)
            field.stringValue = "no"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            timers.advance(0.4)
            #expect(engine.starts.count == 1)
            return (tab, operations, engine)
        }

        // B-SRCH-141: a write from results that changed something runs the search again, one that changed
        // nothing doesn't.
        @Test func aWriteFromTheResultsFindsThemAgain() async throws {
            let harness = try ExplorerHarness.windowless()
            try "x".write(to: harness.folder.appending("Alpha/notes.md"), atomically: true, encoding: .utf8)
            let (tab, operations, engine) = try await searching(harness, names: ["Alpha/notes.md"])
            let group = try #require(tab.group)
            var ended = 0
            let watching = operations.session(for: group).observe { event in
                if case .ended = event { ended += 1 }
            }
            let result = harness.folder.path + "/Alpha/notes.md"
            tab.content.applySelection(.single(result))
            tab.content.focusList()
            tab.perform(.duplicateSelection)
            #expect(await waitUntil { ended == 1 })
            #expect(await waitUntil { engine.starts.count == 2 })
            #expect(engine.starts.last?.query == "no")

            // The folder takes nothing now: nothing completes.
            let alpha = harness.folder.appending("Alpha").path
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: alpha)
            tab.content.applySelection(.single(result))
            tab.content.focusList()
            tab.perform(.duplicateSelection)
            #expect(await waitUntil { ended == 2 })
            try await Task.sleep(for: .milliseconds(100))
            #expect(engine.starts.count == 2)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: alpha)
            withExtendedLifetime(watching) {}
            withExtendedLifetime(operations) {}
            await harness.close()
        }

        // B-SRCH-141: a move dragged out of the results finds them again and shows them, though Esc put them away
        // before it ended; a drag from the folder, with results put away, searches nothing.
        @Test func aMoveDraggedOutOfTheResultsFindsThemAgainThoughTheyWerePutAway() async throws {
            let harness = try ExplorerHarness.windowless()
            let alpha = harness.folder.appending("Alpha").path
            let beta = harness.folder.appending("Beta").path
            for name in ["first.md", "second.md"] {
                try "x".write(to: harness.folder.appending("Alpha/\(name)"), atomically: true, encoding: .utf8)
            }
            let (tab, operations, engine) = try await searching(harness, names: ["Alpha/first.md"])
            let group = try #require(tab.group)
            let search = tab.search.session
            var ended = 0
            var hidesAsItStarts = true
            let watching = operations.session(for: group).observe { event in
                switch event {
                case .card(.some) where hidesAsItStarts && search.isSearchMode: search.hideResults()
                case .ended: ended += 1
                default: break
                }
            }
            let target = TabDragDrop.Target(surface: .tree, path: beta, supportsMove: true)
            func drag(_ name: String, from surface: DragSourceSurface) -> DragSession {
                let path = alpha + "/" + name
                return DragSession(
                    sourceSurface: surface, sourceItems: [DragItem(path: path, kind: .file)], leadPath: path,
                    leadKind: .file)
            }

            #expect(
                tab.dragDrop.drop(
                    session: drag("first.md", from: .search), target: target, offersMove: true, modifiers: [],
                    sequence: 1))
            #expect(await waitUntil { ended == 1 })
            #expect(FileManager.default.fileExists(atPath: beta + "/first.md"))
            #expect(await waitUntil { engine.starts.count == 2 })
            #expect(engine.starts.last?.query == "no")
            #expect(search.isSearchMode)

            search.hideResults()
            hidesAsItStarts = false
            #expect(
                tab.dragDrop.drop(
                    session: drag("second.md", from: .content), target: target, offersMove: true, modifiers: [],
                    sequence: 2))
            #expect(await waitUntil { ended == 2 })
            #expect(FileManager.default.fileExists(atPath: beta + "/second.md"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(engine.starts.count == 2)
            #expect(!search.isSearchMode)
            withExtendedLifetime(watching) {}
            withExtendedLifetime(operations) {}
            await harness.close()
        }
    }
}
