// Ports the window-level cases of apps/desktop/src/renderer/App.search.test.tsx, components/SearchBar.test.tsx,
// components/SearchOptionsMenu.test.tsx and the search-field case of App.commands.test.tsx (by feature row F-713,
// F-714, F-750, F-751, F-754, F-775, F-807) on a real tab whose window is never shown, over the stand-in fd runtime
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

        // F-807: the field's ✕ is the system's: it clears the search and leaves the keyboard in the field, and the
        // system's item doesn't take the keyboard away with it.
        // B-SRCH-053 B-SRCH-054
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
            field.onClear()
            #expect(tab.search.session.draftQuery.isEmpty)
            await harness.close()
        }

        // F-807 F-713 (ExplorerWorkspace.tsx: `searchDraftQuery.trim().length > 0`): text of only spaces has no ✕.
        // B-SRCH-053
        @Test func theClearButtonWaitsForTrimmedText() async throws {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.open()
            let field = try #require(tab.searchField)
            #expect(!field.clearButtonShows)
            field.stringValue = "   "
            #expect(!field.clearButtonShows)
            field.stringValue = " a "
            #expect(field.clearButtonShows)
            field.stringValue = ""
            await harness.close()
        }

        // T-b49c92ba T-06c0cfba F-713 F-750
        // B-INFO-100 B-SRCH-059 B-SRCH-109 T-fb71ed4a
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

        // T-0d7af669 T-e6c30f5d B-SRCH-062 F-714
        // App.tsx:2761: only the input's own focus shows cached results, and a toolbar button dimming doesn't focus it.
        @Test func aToolbarButtonThatDimsWithTheKeyboardBringsNoFinishedSearchBack() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            try type("no", in: tab)
            timers.advance(0.4)
            tab.search.session.hideResults()
            tab.content.focusList()
            tab.updatePreferences(["topToolbarItems": .array([ToolbarItemID.up, .search].map { .string($0.rawValue) })])
            harness.layout(tab)
            let up = try #require(tab.explorerToolbar.button(.up))
            up.isEnabled = true
            #expect(up.takeKeyboard())

            up.isEnabled = false
            #expect(!tab.search.session.isSearchMode)
            await harness.close()
        }

        // B-SRCH-071 B-SRCH-072 T-e23e16c1
        @Test func escapeEndsSearchModeAndTheFolderComesBack() async throws {
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

        // B-SRCH-061 B-NAV-210: results have a view of their own.
        // B-VIEW-003
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

        // F-751 F-754 T-2aaf9a83 T-c08713b3
        // B-VIEW-066
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

        // T-f31f663b: with the search field focused, the edit commands are the field's.
        // B-CLIP-008 B-NAV-218 B-VIEW-229 T-b9bc9308
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

        // T-bb52ae88 T-73242d97 F-807
        // B-SRCH-079 B-SRCH-083
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

        // T-4fdb6b39 T-89efb9bf T-ada18c17 F-807: the arrows and Return are the system menu's while it is open (D-022).
        // Opened from the keyboard, the first item is marked; chosen, it does what it says; Escape and a press close it.
        // B-SRCH-085 B-SRCH-088
        @Test func theOptionsMenuOpensMarkedFromTheKeyboard() async throws {
            let (harness, tab, _, _) = try await open()
            let window = try #require(tab.window)
            tab.search.openOptions(fromKeyboard: true)
            let menu = try #require(AppMenuPresenter.shared.menu)
            let marked = try #require(menu.markedIndex)
            #expect(menu.items[marked].title == "Name")
            let skip = try #require(menu.items.firstIndex { $0.title == "Skip Files Ignored by Git" })
            menu.onChoose(skip)
            #expect(!AppMenuPresenter.shared.isOpen)
            #expect(tab.search.session.skipGitIgnored)
            tab.search.openOptions()
            let escape = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
            #expect(AppMenuPresenter.shared.intercept(escape, in: window))
            #expect(!AppMenuPresenter.shared.isOpen)
            tab.search.openOptions()
            let press = try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: NSPoint(x: 600, y: 200), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            _ = AppMenuPresenter.shared.intercept(press, in: window)
            #expect(!AppMenuPresenter.shared.isOpen)
            await harness.close()
        }

        // T-8b5cf7e7: covered-by-feature F-807. The native toolbar measures its items without a copy of them, so there
        // is no copy whose magnifier could open a menu: the one options button is the field's own.
        @Test func theFieldHasOneOptionsButton() async throws {
            let (harness, tab, _, _) = try await open()
            let field = try #require(tab.searchField)
            let buttons = field.subviews.filter { $0.accessibilityIdentifier() == "toolbar.search.options" }
            #expect(buttons.count == 1)
            #expect(field.optionsButton.toolTip == "Search Options")
            await harness.close()
        }

        // T-5615383e T-bccba4a0 F-750
        // B-SRCH-063 B-SRCH-124
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

        // T-6de3068b T-24fd84fd: Esc in the filter field clears it, then gives the keyboard back to the results.
        // B-SEL-087 B-SEL-088 B-SRCH-116 B-SRCH-119 B-SRCH-121
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

        // B-SRCH-069 B-NAV-211: opening a folder puts the results away and empties the field.
        // B-TREE-104 B-TREE-188
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
