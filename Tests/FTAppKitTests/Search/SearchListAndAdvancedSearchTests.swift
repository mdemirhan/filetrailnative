// The list under the toolbar's search field and the Advanced Search box, typed into as a person types: what each lists,
// what Return, Tab and Esc do with it, and how the box reads the search back.
import AppKit
import FTFileSystem
import FTFoundation
import Foundation
import Testing

@testable import FTAppKit

extension ExplorerWindowlessTests {
    @MainActor
    @Suite struct SearchListAndAdvancedSearchTests {
        private func open() async throws -> (ExplorerHarness, MainWindowController, FakeSearchEngine, ManualTimers) {
            let harness = try ExplorerHarness.windowless()
            let tab = try await harness.openList()
            let engine = FakeSearchEngine()
            let timers = ManualTimers()
            tab.tab.search.session.engine = engine
            tab.tab.search.session.timers = timers
            return (harness, tab.tab, engine, timers)
        }

        /// The field with the keyboard, and its editor.
        private func focus(_ tab: MainWindowController) throws -> NSTextView {
            let field = try #require(tab.searchField)
            #expect(tab.window?.makeFirstResponder(field) == true)
            return try #require(field.currentEditor() as? NSTextView)
        }

        /// Typed at the caret, as keys type it.
        private func type(_ text: String, into editor: NSTextView) {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }

        private func list(_ tab: MainWindowController) -> SearchQuerySuggestions? { tab.search.dropdown.suggestions }

        // MARK: The field's list

        @Test func anEmptyFieldListsTheWordsAndHelp() async throws {
            let (harness, tab, _, _) = try await open()
            _ = try focus(tab)
            let shown = try #require(list(tab))
            #expect(shown.rows.map(\.hint).prefix(3) == ["kind:", "ext:", "size:"])
            #expect(shown.rows.allSatisfy { !$0.opensHelp })
            #expect(tab.search.dropdown.view.highlighted == -1)
            // The foot of the list has the link to Help.
            #expect(!tab.search.dropdown.view.helpLink.isHidden)
            await harness.close()
        }

        @Test func tabCompletesAValueBeingTyped() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            type("kind:pd", into: editor)
            #expect(list(tab)?.sections.first?.title == "Kind")
            #expect(tab.search.dropdown.view.highlighted == 0)
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(editor.string == "kind:pdf ")
            // After a whole condition, the words again.
            #expect(list(tab)?.rows.first?.hint == "kind:")
            await harness.close()
        }

        // A value that reads as it is isn't replaced by a row nobody chose: Return searches for what is typed.
        @Test func returnKeepsAWholeValue() async throws {
            let (harness, tab, engine, timers) = try await open()
            let editor = try focus(tab)
            type("size:1mb", into: editor)
            let shown = try #require(list(tab))
            #expect(shown.rows.map(\.hint) == ["1mb"])
            #expect(tab.search.dropdown.view.highlighted == -1)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            timers.advance(0.4)
            // The results take the keyboard; the field keeps what was typed.
            #expect(tab.searchField?.stringValue == "size:1mb")
            let rule = SearchSizeRule(comparison: .equal, value: 1, unit: .megabytes)
            #expect(engine.starts.last?.conditions == [.size(rule)])
            await harness.close()
        }

        // After a word of the name, the name goes on: nothing is listed.
        @Test func nothingAfterAWordOfTheName() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            type("report ", into: editor)
            #expect(list(tab) == nil)
            type("!draft ", into: editor)
            #expect(list(tab) == nil)
            await harness.close()
        }

        @Test func escClosesTheListUntilTheTextChanges() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            type("kind:pd", into: editor)
            #expect(list(tab) != nil)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(list(tab) == nil)
            #expect(tab.searchField?.isActive == true)
            type("f", into: editor)
            #expect(list(tab)?.rows.first?.hint == "pdf")
            await harness.close()
        }

        // In an empty field the list is only the words, shown unasked: one Esc lets the field go, as it did before the
        // list, not a first to close the list and a second for the field.
        @Test func escInAnEmptyFieldLetsItGo() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            #expect(list(tab) != nil)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(list(tab) == nil)
            #expect(tab.searchField?.currentEditor() == nil)
            await harness.close()
        }

        // The link at the list's foot opens Help and closes the list.
        @Test func theHelpLinkClosesTheList() async throws {
            let (harness, tab, _, _) = try await open()
            _ = try focus(tab)
            #expect(list(tab) != nil)
            tab.search.dropdown.view.helpLink.onPress()
            #expect(list(tab) == nil)
            await harness.close()
        }

        // MARK: The arrows, a row taken, and the list of another pane

        // A plain word that could also be a condition lists it, with no row highlighted: over results ↓ goes into
        // them as it does with no list, ↑ goes into the list, and Tab takes its first row.
        @Test func downGoesIntoTheResultsWhileNoRowIsHighlighted() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["doc-one.txt", "doc-two.txt"], false, false) }
            let editor = try focus(tab)
            type("doc", into: editor)
            timers.advance(0.4)
            #expect(tab.search.session.isSearchMode)
            #expect(list(tab)?.rows.map(\.hint).contains("kind:document") == true)
            #expect(tab.search.dropdown.view.highlighted == -1)
            // ↑ is the way into the list.
            editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
            #expect(tab.search.dropdown.view.highlighted >= 0)
            #expect(tab.searchField?.isActive == true)
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            type("s", into: editor)
            editor.deleteBackward(nil)
            #expect(list(tab) != nil)
            #expect(tab.search.dropdown.view.highlighted == -1)
            // ↓ leaves the field for the results, the first selected, and the text is as typed.
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(list(tab) == nil)
            #expect(tab.searchField?.currentEditor() == nil)
            #expect(tab.searchField?.stringValue == "doc")
            #expect(tab.content.selection.paths.count == 1)
            #expect(engine.starts.last?.conditions.isEmpty == true)
            await harness.close()
        }

        // With nothing found yet there is nowhere else for ↓ to go: it goes into the list, and Return takes the row.
        @Test func downGoesIntoTheListWithNoResultsAndReturnTakesTheRow() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            #expect(!tab.search.session.isSearchMode)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(tab.search.dropdown.view.highlighted == 0)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(tab.search.dropdown.view.highlightedRow?.hint == "ext:")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(editor.string == "ext:")
            // Its values are listed, and a click takes one as Return does.
            let values = try #require(list(tab))
            let docx = try #require(values.rows.firstIndex { $0.hint == "docx" })
            tab.search.chooseSuggestion(docx)
            #expect(editor.string == "ext:docx ")
            await harness.close()
        }

        // A row taken in the middle of the text leaves one space after its word, not two.
        @Test func aRowTakenMidTextLeavesOneSpace() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            type("alpha kind:pd beta", into: editor)
            editor.setSelectedRange(NSRange(location: 13, length: 0))
            let shown = try #require(list(tab))
            #expect(shown.rows.first?.hint == "pdf")
            editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(editor.string == "alpha kind:pdf beta")
            #expect(editor.selectedRange().location == 15)
            #expect(TabSearch.range(NSRange(location: 0, length: 3), taking: "kind:", in: "kin beta").length == 3)
            await harness.close()
        }

        // Clear Search Conditions takes the words out as typing would: ⌘Z in the field brings them back.
        @Test func clearingConditionsLeavesTheNameAndCanBeUndone() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["annual report.pdf"], false, false) }
            let editor = try focus(tab)
            editor.allowsUndo = true
            // Each step is an event of its own, as a key and a menu item are.
            let undo = try #require(editor.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            type("annual  \"big report\" kind:pdf   !draft tag:\"To Do\" size:", into: editor)
            undo.endUndoGrouping()
            timers.advance(0.4)
            #expect(engine.starts.last?.conditions.count == 2)
            #expect(tab.canPerform(.clearSearchConditions))
            undo.beginUndoGrouping()
            tab.perform(.clearSearchConditions)
            undo.endUndoGrouping()
            #expect(tab.searchField?.stringValue == "annual  \"big report\" !draft")
            #expect(engine.starts.last?.conditions.isEmpty == true)
            #expect(engine.starts.last?.query == "annual  \"big report\" !draft")
            #expect(!tab.canPerform(.clearSearchConditions))
            undo.undo()
            #expect(editor.string == "annual  \"big report\" kind:pdf   !draft tag:\"To Do\" size:")
            await harness.close()
        }

        // The words are tinted where they are: a condition's word in the accent as text takes it, the whole of it on
        // the accent's ground; a word that can't be read is underlined once the caret has left it.
        @Test func conditionWordsAreTintedWhereTheyAre() {
            let theme = AppearanceModel.shared.theme
            let spans = SearchQueryTint.spans("report kind:pdf perm:www", caret: 0, theme: theme)
            let ground = spans.filter { $0.1[.backgroundColor] != nil }.map(\.0)
            #expect(ground == [NSRange(location: 7, length: 8)])
            let word = spans.first { $0.1[.foregroundColor] != nil }
            #expect(word?.0 == NSRange(location: 7, length: 5))
            #expect(word?.1[.foregroundColor] as? NSColor == NSColor(theme.accent.batchRenameMarkText))
            #expect(spans.contains { $0.0 == NSRange(location: 16, length: 8) && $0.1[.underlineStyle] != nil })
            #expect(SearchQueryTint.spans("annual report", caret: nil, theme: theme).isEmpty)
            // A name in quotes after its word is one word, spaces and all.
            let quoted = SearchQueryTint.spans("tag:\"To Do\" x", caret: nil, theme: theme)
            #expect(quoted.first { $0.1[.backgroundColor] != nil }?.0 == NSRange(location: 0, length: 11))
        }

        // The list is the pane's whose search the field shows: another pane made active, or this one closed, takes it
        // away, as nothing of this pane's would close it after.
        @Test func thePanesListGoesWhenAnotherPaneIsActive() async throws {
            let (harness, tab, _, _) = try await open()
            tab.perform(.toggleTwoPanes)
            let first = tab.activePane
            _ = try focus(tab)
            #expect(first.search.dropdown.isShown)
            tab.perform(.switchToOtherPane)
            #expect(tab.activePane !== first)
            #expect(!first.search.dropdown.isShown)
            // Closed with its list open, the pane takes it along.
            let second = tab.activePane
            _ = try focus(tab)
            #expect(second.search.dropdown.isShown)
            tab.perform(.closePane)
            #expect(!second.search.dropdown.isShown)
            #expect(!first.search.dropdown.isShown || tab.searchField?.isActive == true)
            await harness.close()
        }

        // A condition's word not finished yet is in the field and not in the search: leaving the field for the
        // results and coming back keeps it, and so does Cancel in the Advanced Search box.
        @Test func aWordBeingTypedStaysWhenTheFieldIsComeBackTo() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["report.txt"], false, false) }
            var editor = try focus(tab)
            type("report", into: editor)
            timers.advance(0.4)
            type(" size:>10", into: editor)
            timers.advance(0.4)
            tab.content.focusList()
            #expect(tab.searchField?.currentEditor() == nil)
            editor = try focus(tab)
            #expect(editor.string == "report size:>10")
            let box = try box(tab)
            box.cancelButton.perform()
            #expect(tab.searchField?.stringValue == "report size:>10")
            #expect(tab.search.session.committedQuery == "report")
            await harness.close()
        }

        // ↓ pressed before the results have narrowed to the last key narrows them first: what it selects is one of
        // them, and stays selected.
        @Test func downRightAfterAKeyNarrowsTheResultsFirst() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["red.txt", "rep.txt"], false, false) }
            let editor = try focus(tab)
            type("re", into: editor)
            timers.advance(0.4)
            #expect(tab.content.entryPaths.count == 2)
            type("p", into: editor)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            #expect(tab.content.entryPaths.map { ($0 as NSString).lastPathComponent } == ["rep.txt"])
            #expect(tab.content.selection.paths.map { ($0 as NSString).lastPathComponent } == ["rep.txt"])
            timers.advance(SearchTiming.refineDelay)
            #expect(tab.content.selection.paths.count == 1)
            await harness.close()
        }

        // Clear Search Conditions from the results, where it is usually chosen, goes through the field too: the
        // field takes the keyboard and ⌘Z there brings the words back.
        @Test func clearingConditionsFromTheResultsCanBeUndone() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["annual report.pdf"], false, false) }
            var editor = try focus(tab)
            // Each step is an event of its own, as a key and a menu item are.
            let undo = try #require(editor.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            type("annual kind:pdf", into: editor)
            undo.endUndoGrouping()
            timers.advance(0.4)
            tab.content.focusList()
            #expect(tab.searchField?.currentEditor() == nil)
            undo.beginUndoGrouping()
            tab.perform(.clearSearchConditions)
            undo.endUndoGrouping()
            #expect(tab.searchField?.stringValue == "annual")
            #expect(engine.starts.last?.conditions.isEmpty == true)
            editor = try #require(tab.searchField?.currentEditor() as? NSTextView)
            #expect(editor.undoManager === undo)
            undo.undo()
            #expect(editor.string == "annual kind:pdf")
            await harness.close()
        }

        // The pointer passing over the list doesn't choose for Return: with no row highlighted none becomes so, and
        // with one, the pointer moves it as the arrows do.
        @Test func thePointerHighlightsOnlyWhereARowAlreadyIs() async throws {
            let (harness, tab, _, _) = try await open()
            let editor = try focus(tab)
            type("doc", into: editor)
            let view = tab.search.dropdown.view
            #expect(view.highlighted == -1)
            func sweep() throws {
                for y in stride(from: 2.0, to: view.rows.bounds.height, by: 4) {
                    let event = try #require(
                        NSEvent.mouseEvent(
                            with: .mouseMoved, location: view.rows.convert(NSPoint(x: 30, y: y), to: nil),
                            modifierFlags: [], timestamp: 0, windowNumber: tab.window?.windowNumber ?? 0,
                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                    view.rows.mouseMoved(with: event)
                }
            }
            try sweep()
            #expect(view.highlighted == -1)
            editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
            let byKey = view.highlighted
            #expect(byKey >= 0)
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            try sweep()
            #expect(view.highlighted >= 0)
            await harness.close()
        }

        // A condition chosen from the results bar of the pane that isn't active goes into that pane's search: the
        // pane is made active first, and the field is its own.
        @Test func aConditionFromTheOtherPanesBarGoesToItsOwnSearch() async throws {
            let (harness, tab, _, _) = try await open()
            tab.perform(.toggleTwoPanes)
            let first = tab.activePane
            let editor = try focus(tab)
            type("mine", into: editor)
            tab.perform(.switchToOtherPane)
            let second = tab.activePane
            #expect(second !== first)
            #expect(tab.searchField?.stringValue == "")
            first.search.typeConditionWord(.kind)
            #expect(tab.activePane === first)
            #expect(tab.searchField?.stringValue == "mine kind:")
            #expect(second.search.session.draftQuery == "")
            await harness.close()
        }

        // A glob or a regular expression is read back as the one pattern it is, and can be searched for whatever
        // words it would make.
        @Test func theBoxReadsAPatternBackWhole() async throws {
            let (harness, tab, _, _) = try await open()
            tab.search.session.setPatternMode(.regex)
            let box = try box(tab)
            typeInBox("^a !b$ kind:pdf", box)
            #expect(box.readsLabel.stringValue == "Finds: Name matches “^a !b$”  ·  Kind is PDF")
            await harness.close()
        }

        // MARK: The Advanced Search box

        private func box(_ tab: MainWindowController) throws -> AdvancedSearchBox {
            tab.search.openAdvancedSearch()
            return try #require(DialogScrim.front(in: tab.window)?.panel as? AdvancedSearchBox)
        }

        private func typeInBox(_ text: String, _ box: AdvancedSearchBox) {
            box.textView.insertText(text, replacementRange: box.textView.selectedRange())
        }

        // The words are the buttons below: the box lists only a condition's values.
        @Test func theBoxListsOnlyValues() async throws {
            let (harness, tab, _, _) = try await open()
            let box = try box(tab)
            #expect(box.window?.firstResponder === box.textView)
            #expect(box.suggestions.isHidden)
            typeInBox("pdf ", box)
            #expect(box.suggestions.isHidden)
            typeInBox("kind:pd", box)
            #expect(!box.suggestions.isHidden)
            #expect(box.suggestions.suggestions?.rows.first?.hint == "pdf")
            typeInBox("f ", box)
            #expect(box.suggestions.isHidden)
            await harness.close()
        }

        @Test func theBoxReadsTheSearchBack() async throws {
            let (harness, tab, _, _) = try await open()
            let box = try box(tab)
            typeInBox("annual report !draft kind:!pdf size:1mb tag:red,blue", box)
            #expect(
                box.readsLabel.stringValue
                    == "Finds: Name contains “annual” and “report”  ·  Name doesn’t contain “draft”  ·  Kind is not PDF"
                    + "  ·  Size is 1 MB to under 2 MB  ·  Tagged red or blue")
            await harness.close()
        }

        // A word that can't be read is marked once the caret has left it, not while it is typed.
        @Test func aWordBeingTypedIsntMarkedYet() async throws {
            let (harness, tab, _, _) = try await open()
            let box = try box(tab)
            typeInBox("file size:1", box)
            #expect(!box.readsLabel.stringValue.contains("can’t be read"))
            typeInBox(" ", box)
            #expect(box.readsLabel.stringValue.contains("“size:1” can’t be read. Not a size"))
            await harness.close()
        }

        // The notes are to read: a click doesn't turn them into text in an editor, which drew them in its own font.
        @Test func theBoxsNotesAreNotSelectable() async throws {
            let (harness, tab, _, _) = try await open()
            let box = try box(tab)
            #expect(!box.readsLabel.isSelectable)
            #expect(!box.combineLabel.isSelectable)
            #expect(box.combineLabel.stringValue.contains("Every word must match"))
            #expect(box.combineLabel.stringValue.contains("\"annual report\""))
            await harness.close()
        }

        // The box's text is edited as a field's is: ⌘A, ⌘C, ⌘V and ⌘Z go to it, not to the files behind it.
        @Test func editCommandsGoToTheBoxsText() async throws {
            let (harness, tab, _, _) = try await open()
            let box = try box(tab)
            typeInBox("report kind:pdf", box)
            #expect(tab.isTextFieldEditing)
            #expect(box.textView.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))
            #expect(box.textView.selectedRange() == NSRange(location: 0, length: 15))
            await harness.close()
        }

        // Search waits while a word can't be read; Return says every such word, the one being typed too, and the box
        // stays open.
        @Test func theBoxWontSearchWithAWordThatCantBeRead() async throws {
            let (harness, tab, engine, _) = try await open()
            let box = try box(tab)
            typeInBox("report size:1", box)
            #expect(!box.submitButton.isEnabled)
            #expect(!box.readsLabel.stringValue.contains("can’t be read"))
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            // The list's first row would complete it: closed, Return has only the word as typed.
            let escape = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(box.handleKey(escape))
            #expect(box.suggestions.isHidden)
            #expect(box.handleKey(event))
            #expect(DialogScrim.front(in: tab.window) != nil)
            #expect(engine.starts.isEmpty)
            #expect(box.readsLabel.stringValue.contains("“size:1” can’t be read. Not a size"))
            // A word nothing can save is said at once, the caret in it or not.
            box.textView.string = ""
            typeInBox("perm:www", box)
            #expect(box.readsLabel.stringValue.contains("“perm:www” can’t be read"))
            #expect(box.suggestions.suggestions?.rows.first?.tone == .problem)
            typeInBox(" ", box)
            box.textView.string = "report perm:755"
            box.render()
            #expect(box.submitButton.isEnabled)
            await harness.close()
        }

        // Emptied, the box has nothing to search for: Search is dimmed, and Return does no more than it would. The
        // search on screen stays.
        @Test func returnInAnEmptiedBoxDoesNothing() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            let editor = try focus(tab)
            type("note", into: editor)
            timers.advance(0.4)
            let box = try box(tab)
            box.textView.insertText("", replacementRange: NSRange(location: 0, length: 4))
            #expect(!box.submitButton.isEnabled)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            #expect(box.handleKey(event))
            #expect(DialogScrim.front(in: tab.window)?.panel === box)
            #expect(tab.search.session.isSearchMode)
            #expect(tab.search.session.committedQuery == "note")
            box.onClose()
            await harness.close()
        }

        // With the results closed, the box brings the pane's last search back as ⌘F does, text and results, and
        // nothing is searched again; in another folder it opens empty.
        @Test func theBoxBringsTheLastSearchBack() async throws {
            let (harness, tab, engine, timers) = try await open()
            engine.finds = { _ in (["note.txt"], false, false) }
            let editor = try focus(tab)
            type("note kind:text", into: editor)
            timers.advance(0.4)
            let starts = engine.starts.count
            tab.search.session.hideResults()
            tab.content.focusList()
            #expect(tab.searchField?.stringValue == "")
            #expect(!tab.search.session.isSearchMode)
            let box = try box(tab)
            #expect(box.textView.string == "note kind:text")
            #expect(tab.search.session.isSearchMode)
            #expect(tab.searchField?.stringValue == "note kind:text")
            #expect(engine.starts.count == starts)
            // Cancel leaves the results there, as Esc in the field after ⌘F would.
            box.onClose()
            #expect(tab.search.session.isSearchMode)
            // Text typed in the field since is what the box opens with, not the last search.
            tab.search.session.hideResults()
            tab.search.session.setDraft("other")
            tab.searchField?.stringValue = "other"
            let typed = try self.box(tab)
            #expect(typed.textView.string == "other")
            #expect(!tab.search.session.isSearchMode)
            typed.onClose()
            // In another folder the last search isn't this folder's.
            tab.search.session.abandonDraft()
            tab.searchField?.stringValue = ""
            _ = await tab.navigate(to: tab.folderPath + "/Beta")
            let empty = try self.box(tab)
            #expect(empty.textView.string == "")
            #expect(!tab.search.session.isSearchMode)
            empty.onClose()
            await harness.close()
        }

        @Test func searchInTheBoxSearchesForWhatIsTyped() async throws {
            let (harness, tab, engine, timers) = try await open()
            let box = try box(tab)
            typeInBox("report perm:?5?", box)
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            #expect(box.handleKey(event))
            timers.advance(0.4)
            #expect(DialogScrim.front(in: tab.window) == nil)
            #expect(tab.search.session.draftQuery == "report perm:?5?")
            #expect(engine.starts.last?.query == "report")
            #expect(engine.starts.last?.conditions == [.permissions([SearchPermission(mode: 0o050, mask: 0o070)])])
            await harness.close()
        }
    }
}
