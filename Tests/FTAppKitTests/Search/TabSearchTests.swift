import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct TabSearchTests {
        /// A windowless tab whose search runs on the stand-in, with timers moved by hand.
        private func open() async throws -> (ExplorerHarness, MainWindowController, FakeSearchEngine, ManualTimers) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.openList()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.tab.search.session.engine = engine
            tab.tab.search.session.timers = timers
            return (harness, tab.tab, engine, timers)
        }

        private func type(_ text: String, in tab: MainWindowController) throws {
            let field = try #require(tab.searchField)
            field.stringValue = text
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        private func names(_ tab: MainWindowController) -> [String] { tab.content.entries.map(\.name) }

        // The field's ✕ is the system's: it clears the search and leaves the keyboard in the field, and the
        // system's item doesn't take the keyboard away with it.
        @Test func theClearButtonClearsTheSearchAndKeepsTheKeyboard() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let field = try #require(tab.searchField)
            let cell = try #require(field.cell as? NSSearchFieldCell)
            #expect(tab.explorerToolbar.searchItem?.resignsFirstResponderWithCancel == false)
            #expect(tab.explorerToolbar.searchItem?.searchField === field)
            #expect(cell.cancelButtonCell?.target === field)
            field.stringValue = "note"
            tab.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(tab.window?.makeFirstResponder(field) == true)
            field.onClear()
            #expect(tab.search.session.draftQuery.isEmpty)
            #expect(field.isActive)
            await harness.close()
        }

        @Test func typingSearchesTheFolderAndTheResultsTakeTheList() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { request in (request.query == "no" ? ["note.txt", "Alpha/notes.md"] : [], false, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            #expect(engine.starts.first?.rootPath == harness.folder.path)
            #expect(tab.searchRootPath == harness.folder.path)
            #expect(ExplorerToolbar.title(of: tab) == "Searching “\(TabText.folderDisplayName(harness.folder.path))”")
            #expect(Set(names(tab)) == ["note.txt", "notes.md"])
            #expect(tab.content.contentShell.searchHeader === tab.search.header)
            // The results bar: the scopes, the one searched pressed.
            let scopes = tab.search.header.scopes
            #expect(scopes.first?.title == "“\(TabText.folderDisplayName(harness.folder.path))”")
            #expect(scopes.map(\.title).contains("Home"))
            #expect(scopes.filter(\.isSelected).count == 1)
            // The status line counts results.
            #expect(tab.content.contentShell.pathBarRow.status.stringValue == "2 results")
            // Typing on narrows what was found without searching again.
            try type("not", in: tab)
            #expect(engine.starts.count == 1)
            #expect(Set(names(tab)) == ["note.txt", "notes.md"])
            try type("note.", in: tab)
            #expect(names(tab) == ["note.txt"])
            // The marks: the match in the name.
            #expect(tab.content.search?.match(in: "note.txt") == HighlightRange(start: 0, end: 5))
            await harness.close()
        }

        @Test func puttingTheResultsAwayBringsTheFolderBackAndTheCommandBringsThemBack() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            let folderNames = names(tab)
            try type("no", in: tab)
            timers.advance(0.4)
            #expect(names(tab) == ["note.txt"])
            tab.search.session.hideResults()
            #expect(tab.searchRootPath == nil)
            #expect(names(tab) == folderNames)
            #expect(tab.content.contentShell.searchHeader == nil)
            #expect(tab.searchField?.stringValue == "")
            // ⇧⌘F brings them back with their query.
            #expect(tab.canPerform(.showLastSearchResults))
            tab.perform(.showLastSearchResults)
            #expect(names(tab) == ["note.txt"])
            #expect(tab.searchField?.stringValue == "no")
            #expect(!tab.canPerform(.showLastSearchResults))
            await harness.close()
        }

        // Results have a view of their own.
        @Test func resultsShowInTheTabsSearchView() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            #expect(tab.content.mode == .details)
            try type("no", in: tab)
            timers.advance(0.4)
            tab.perform(.viewAsIcons)
            #expect(tab.content.mode == .icons)
            #expect(tab.searchViewMode == .icons)
            #expect(tab.viewMode == .details)
            tab.search.session.hideResults()
            #expect(tab.content.mode == .details)
            await harness.close()
        }

        @Test func theBarSaysHowTheSearchWent() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { request in request.query == "zz" ? ([], false, false) : (["note.txt"], false, true) }
            try type("zz", in: tab)
            timers.advance(0.4)
            #expect(tab.searchRootPath != nil)
            #expect(names(tab).isEmpty)
            let header = tab.search.header
            let before = header.height
            try type("no", in: tab)
            timers.advance(0.4)
            // Only the first matches: the banner, and the header grows by it.
            #expect(tab.search.session.truncated)
            #expect(header.height > before)
            await harness.close()
        }

        // With the search field focused, the edit commands are the field's.
        @Test func editCommandsGoToTheSearchFieldWhileItHasTheKeyboard() async throws {
            let (harness, tab, _, _) = try await open()
            let field = try #require(tab.searchField)
            field.stringValue = "hello"
            tab.window?.makeFirstResponder(field)
            #expect(tab.isTextFieldEditing)
            tab.perform(.editSelectAll)
            let editor = try #require(tab.window?.firstResponder as? NSTextView)
            #expect(editor.selectedRange().length == 5)
            await harness.close()
        }

        @Test func theOptionsMenuShowsTheOptionsAndAChoiceRunsTheSearchAgain() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            tab.search.openOptions()
            let menu = try #require(AppMenuPresenter.shared.menu)
            #expect(menu.identifier == "searchOptionsMenu")
            #expect(
                menu.rows.map(\.title) == [
                    "Name", "Full Path", "Plain Text", "Glob", "Regex", "Search Subfolders", "Skip .git Folders",
                    "Skip Files Ignored by Git",
                ])
            #expect(menu.nsMenu.items.filter(\.isSectionHeader).map(\.title) == ["Match", "Match As"])
            #expect(
                menu.nsMenu.items.filter { $0.state == .on }.map(\.title) == [
                    "Name", "Plain Text", "Search Subfolders", "Skip .git Folders",
                ])
            // Opened with the mouse, nothing is marked: the keyboard stays in the field.
            #expect(menu.markedIndex == nil)
            let glob = try #require(menu.items.firstIndex { $0.title == "Glob" })
            menu.onChoose(glob)
            #expect(!AppMenuPresenter.shared.isOpen)
            #expect(engine.starts.count == 2)
            #expect(engine.starts.last?.patternMode == .glob)
            await harness.close()
        }

        // The arrows and Return are the system menu's while it is open.
        // Opened from the keyboard, the first item is marked; chosen, it does what it says.
        @Test func theOptionsMenuOpensMarkedFromTheKeyboard() async throws {
            let (harness, tab, _, _) = try await open()
            tab.search.openOptions(fromKeyboard: true)
            let menu = try #require(AppMenuPresenter.shared.menu)
            let marked = try #require(menu.markedIndex)
            #expect(menu.items[marked].title == "Name")
            let skip = try #require(menu.items.firstIndex { $0.title == "Skip Files Ignored by Git" })
            menu.onChoose(skip)
            #expect(!AppMenuPresenter.shared.isOpen)
            #expect(tab.search.session.skipGitIgnored)
            await harness.close()
        }

        @Test func stopShowsOnlyForASearchThatRunsOnAndDoneClosesTheResults() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], true, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            let header = tab.search.header
            #expect(header.stopButton.isHidden)
            #expect(await waitUntil { !header.stopButton.isHidden })
            header.stopButton.onPress()
            #expect(tab.search.session.status == .cancelled)
            #expect(header.stopButton.isHidden)
            #expect(names(tab) == ["note.txt"])
            // Another scope searches the committed query from there.
            let home = try #require(header.scopes.first { $0.title == "Home" })
            home.onPress()
            #expect(engine.starts.last?.rootPath == FileManager.default.homeDirectoryForCurrentUser.path)
            #expect(engine.starts.last?.query == "no")
            // Done puts the results away.
            header.doneButton.onPress()
            #expect(tab.searchRootPath == nil)
            await harness.close()
        }

        // Esc in the filter field clears it, then gives the keyboard back to the results.
        @Test func theFilterFieldClearsWithEscapeThenGivesTheKeyboardBack() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt", "Alpha/notes.md"], false, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            let filter = tab.search.header.filter
            let window = try #require(tab.window)
            window.makeFirstResponder(filter.input)
            filter.input.stringValue = "alpha"
            filter.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: filter.input))
            // By the folder the result is in.
            #expect(names(tab) == ["notes.md"])
            #expect(tab.content.selection.paths == [harness.folder.path + "/Alpha/notes.md"])
            #expect(!filter.clearButton.isHidden)
            let editor = try #require(window.firstResponder as? NSTextView)
            _ = filter.control(filter.input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            #expect(filter.text.isEmpty)
            #expect(names(tab).count == 2)
            #expect(filter.isFocused)
            _ = filter.control(filter.input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            #expect(window.firstResponder === tab.content.focusView)
            await harness.close()
        }

        // Opening a folder puts the results away and empties the field.
        @Test func openingAFolderPutsTheResultsAway() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            #expect(tab.searchRootPath != nil)
            _ = await tab.navigate(to: URL(fileURLWithPath: harness.folder.path + "/Alpha"))
            #expect(tab.searchRootPath == nil)
            #expect(tab.searchField?.stringValue == "")
            #expect(tab.search.session.hasCachedSearch)
            #expect(tab.content.entries.map(\.name) == ["Inner"])
            await harness.close()
        }
    }
}

/// The search field by itself.
@MainActor
@Suite struct ToolbarSearchFieldTests {
    // : text of only spaces has no ✕.
    @Test func theClearButtonWaitsForTrimmedText() {
        let field = ToolbarSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        #expect(!field.clearButtonShows)
        field.stringValue = "   "
        #expect(!field.clearButtonShows)
        #expect(field.clearStop.isHidden)
        field.stringValue = " a "
        #expect(field.clearButtonShows)
        #expect(!field.clearStop.isHidden)
    }

    // The native toolbar measures its items without a copy of them, so there is no copy whose magnifier could open a
    // menu: the one options button is the field's own.
    @Test func theFieldHasOneOptionsButton() {
        let field = ToolbarSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        #expect(field.subviews.filter { $0.accessibilityIdentifier() == "toolbar.search.options" }.count == 1)
        #expect(field.optionsButton.toolTip == "Search Options")
    }
}
