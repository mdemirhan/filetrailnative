// The keys of the file list: type-to-filter, the raw key bindings, and the inline rename's commit rules
import Testing

@testable import FTFoundation

struct ListFilterTypingTests {
    @Test func typingAppendsTheTextAsTyped() {
        var filter = ListFilterTyping()
        #expect(!filter.isActive)
        filter.type("M")
        filter.type("y")
        filter.type(" ")
        filter.type("d")
        // The text is not trimmed and keeps its case.
        #expect(filter.query == "My d")
        #expect(filter.isActive)
    }

    // An emoji set from the search field's filter goes whole: half of it would match nothing.
    @Test func backspaceTakesAnEmojiBackWhole() {
        var filter = ListFilterTyping()
        filter.set("a\u{1F600}")
        filter.eraseCharacter()
        #expect(filter.query == "a")
    }

    @Test func backspaceTakesACharacterBackAndEscClears() {
        var filter = ListFilterTyping()
        filter.type("tr")
        filter.eraseCharacter()
        #expect(filter.query == "t")
        filter.eraseCharacter()
        #expect(filter.query == "")
        filter.eraseCharacter()
        #expect(filter.query == "")
        filter.type("abc")
        filter.clear()
        #expect(filter.query == "")
    }

    // While there is a filter Space is its text, however long ago the last key was; without one Space is no key of
    // the filter's.
    @Test func spaceBelongsToTheTextWhileThereIsAFilter() {
        var filter = ListFilterTyping()
        #expect(ListFilterKey.from(key: " ", filter: filter) == nil)
        filter.type("my")
        #expect(ListFilterKey.from(key: " ", filter: filter) == .type(" "))
        // A filter set at once, as the results' field and a tab brought back set it, takes Space too.
        var set = ListFilterTyping()
        set.set("abc")
        #expect(ListFilterKey.from(key: " ", filter: set) == .type(" "))
        filter.clear()
        #expect(ListFilterKey.from(key: " ", filter: filter) == nil)
    }

    @Test func onlyPrintableNonWhitespaceCharactersAreTypeahead() {
        #expect(Typeahead.isCharacterKey("a"))
        #expect(Typeahead.isCharacterKey("A"))
        #expect(Typeahead.isCharacterKey("é"))
        #expect(!Typeahead.isCharacterKey(" "))
        #expect(!Typeahead.isCharacterKey("Enter"))
        #expect(!Typeahead.isCharacterKey("ArrowDown"))
        #expect(!Typeahead.isCharacterKey("Tab"))
    }
}

struct ContentKeysTests {
    private let shortcuts = ShortcutCommands.defaultResolved

    private func action(
        _ key: String, code: String = "", meta: Bool = false, ctrl: Bool = false, alt: Bool = false,
        shift: Bool = false, filter: ListFilterTyping = ListFilterTyping(), entries: Bool = true, selected: Bool = true,
        pinned: Bool = false
    ) -> ContentKeyAction? {
        ContentKeys.action(
            for: ShortcutKeyEvent(key: key, code: code, metaKey: meta, ctrlKey: ctrl, altKey: alt, shiftKey: shift),
            shortcuts: shortcuts, filter: filter, hasEntries: entries, hasSelection: selected, pinned: pinned)
    }

    @Test func withThePinTypingSelectsNamesAndLeavesTheFilterAlone() {
        #expect(action("s", code: "KeyS", pinned: true) == .typeToSelect("s"))
        #expect(action("S", code: "KeyS", shift: true, pinned: true) == .typeToSelect("S"))
        // Esc lets go of the letters; Backspace and ⌥⌫ have nothing to take back.
        #expect(action("Escape", code: "Escape", pinned: true) == .typeToSelect(nil))
        #expect(action("Backspace", code: "Backspace", pinned: true) == nil)
        #expect(action("Backspace", code: "Backspace", alt: true, pinned: true) == nil)
        // Space stays Open in Viewer, the arrows move, and ⌘ with a letter is still its command.
        #expect(action(" ", code: "Space", pinned: true) == .command(.viewFile))
        #expect(action("ArrowDown", code: "ArrowDown", pinned: true) == .move(.down, extend: false))
        #expect(action("t", code: "KeyT", meta: true, pinned: true) == .command(.newTab))
    }

    // Over search results the results' own field may hold a filter while one is pinned: the list's keys leave that
    // text alone too.
    @Test func withThePinTheKeysLeaveTheResultsFilterAlone() {
        var typed = ListFilterTyping()
        typed.set("rep")
        #expect(action("Backspace", code: "Backspace", filter: typed) == .filter(.erase))
        #expect(action("Backspace", code: "Backspace", filter: typed, pinned: true) == nil)
        #expect(action("Backspace", code: "Backspace", alt: true, filter: typed, pinned: true) == nil)
        #expect(action("Escape", code: "Escape", filter: typed, pinned: true) == .typeToSelect(nil))
        #expect(action("s", code: "KeyS", filter: typed, pinned: true) == .typeToSelect("s"))
        // Space types into the field's text, and with the pin it is Open in Viewer.
        #expect(action(" ", code: "Space", filter: typed) == .filter(.type(" ")))
        #expect(action(" ", code: "Space", filter: typed, pinned: true) == .command(.viewFile))
    }

    @Test func arrowsHomeAndEndMoveTheSelectionAndShiftExtendsIt() {
        #expect(action("ArrowDown", code: "ArrowDown") == .move(.down, extend: false))
        #expect(action("ArrowUp", code: "ArrowUp", shift: true) == .move(.up, extend: true))
        #expect(action("Home", code: "Home") == .move(.home, extend: false))
        #expect(action("End", code: "End", shift: true) == .move(.end, extend: true))
        // With no entries on screen the keys do nothing and are not taken.
        #expect(action("ArrowDown", code: "ArrowDown", entries: false) == nil)
        // ⌥ with an arrow is not a move.
        #expect(action("ArrowDown", code: "ArrowDown", alt: true) == nil)
    }

    @Test func pageKeysMoveAPageOrHalfAPageAndShiftExtends() {
        #expect(action("PageDown", code: "PageDown") == .page(forward: true, size: .full, extend: false))
        #expect(action("PageUp", code: "PageUp") == .page(forward: false, size: .full, extend: false))
        #expect(action("d", code: "KeyD", ctrl: true) == .page(forward: true, size: .half, extend: false))
        #expect(action("u", code: "KeyU", ctrl: true) == .page(forward: false, size: .half, extend: false))
        #expect(action("PageDown", code: "PageDown", shift: true) == .page(forward: true, size: .full, extend: true))
    }

    // ⇧ with a paging key extends unless that chord is a command's own.
    @Test func shiftWithAPageKeyRunsTheCommandWhenItIsBoundToOne() {
        var overrides = ShortcutOverrides()
        overrides["focusTreePane"] = ["Shift+PageDown"]
        let custom = ShortcutCommands.resolve(overrides)
        let event = ShortcutKeyEvent(key: "PageDown", code: "PageDown", shiftKey: true)
        let result = ContentKeys.action(
            for: event, shortcuts: custom, filter: ListFilterTyping(), hasEntries: true, hasSelection: true)
        #expect(result == .command(.focusTreePane))
    }

    @Test func typingFiltersAndQuestionMarkIsHelp() {
        #expect(action("t", code: "KeyT") == .filter(.type("t")))
        #expect(action("T", code: "KeyT", shift: true) == .filter(.type("T")))
        // ⌘, ⌃ and ⌥ with a letter are not typing: ⌘T is New Tab.
        #expect(action("t", code: "KeyT", meta: true) == .command(.newTab))
        #expect(action("z", code: "KeyZ", alt: true) == nil)
        // ? opens Help, as the key of that command.
        #expect(action("?", code: "Slash", shift: true) == .command(.openHelp))
    }

    @Test func optionBackspaceTakesTheFiltersLastWordBack() {
        var filter = ListFilterTyping()
        #expect(action("Backspace", code: "Backspace", alt: true, filter: filter) == nil)
        filter.type("annual rep")
        #expect(action("Backspace", code: "Backspace", alt: true, filter: filter) == .filter(.eraseWord))
        // ⌘⌫ stays Move to Trash.
        #expect(action("Backspace", code: "Backspace", meta: true, filter: filter) == .command(.trashSelection))
        filter.eraseWord()
        #expect(filter.query == "annual ")
        filter.eraseWord()
        #expect(filter.query == "")
        filter.type("c++ notes")
        filter.eraseWord()
        filter.eraseWord()
        #expect(filter.query == "")
    }

    @Test func backspaceEscapeAndSpaceEditTheFilterOnlyWhileThereIsOne() {
        var filter = ListFilterTyping()
        #expect(action("Backspace", code: "Backspace", filter: filter) == nil)
        #expect(action("Escape", code: "Escape", filter: filter) == nil)
        filter.type("my")
        #expect(action("Backspace", code: "Backspace", filter: filter) == .filter(.erase))
        #expect(action("Escape", code: "Escape", filter: filter) == .filter(.clear))
        #expect(action(" ", code: "Space", filter: filter) == .filter(.type(" ")))
        // ⇧⌘E is Open in Viewer, ⌘E Edit in Text Editor and ⌘Y Quick Look while the filter is there.
        #expect(action("E", code: "KeyE", meta: true, shift: true, filter: filter) == .command(.viewFile))
        #expect(action("e", code: "KeyE", meta: true, filter: filter) == .command(.editSelection))
        #expect(action("y", code: "KeyY", meta: true, filter: filter) == .command(.quickLookSelection))
        // With no filter (Esc ended it) Space is Open in Viewer.
        filter.clear()
        #expect(action(" ", code: "Space", filter: filter) == .command(.viewFile))
    }

    // Space never starts a filter. While one is typed it always types a space, whether Open in Viewer has it, Quick
    // Look was given it or Settings took it off (no other command can have it).
    @Test func spaceTypesIntoAFilterWhateverCommandHasIt() {
        func action(_ overrides: ShortcutOverrides, filter: ListFilterTyping) -> ContentKeyAction? {
            ContentKeys.action(
                for: ShortcutKeyEvent(key: " ", code: "Space"), shortcuts: ShortcutCommands.resolve(overrides),
                filter: filter, hasEntries: true, hasSelection: true)
        }
        var typed = ListFilterTyping()
        typed.type("my")
        var unassigned = ShortcutOverrides()
        unassigned["viewFile"] = ["Cmd+Shift+E"]
        #expect(action(unassigned, filter: ListFilterTyping()) == nil)
        #expect(action(unassigned, filter: typed) == .filter(.type(" ")))
        let quickLook: ShortcutOverrides = ["quickLookSelection": ["Cmd+Y", "Space"]]
        #expect(action(quickLook, filter: typed) == .filter(.type(" ")))
        #expect(action(quickLook, filter: ListFilterTyping()) == .command(.quickLookSelection))
        #expect(action([:], filter: typed) == .filter(.type(" ")))
        #expect(action([:], filter: ListFilterTyping()) == .command(.viewFile))
    }

    @Test func returnWithAnItemSelectedAndTabSwitchesPanes() {
        #expect(action("Enter", code: "Enter") == .enter)
        #expect(action("Enter", code: "Enter", shift: true) == .enter)
        // ⌘↩ is not Return (⌘↓ opens).
        #expect(action("Enter", code: "Enter", meta: true) == nil)
        #expect(action("Enter", code: "Enter", selected: false) == nil)
        #expect(action("Tab", code: "Tab") == .tab)
        // ⌃Tab moves between tabs.
        #expect(action("Tab", code: "Tab", ctrl: true) == .command(.selectNextTab))
    }

    // Keys the menu does not listen for run their command.
    @Test func aKeyTheMenuDoesNotListenForRunsItsCommand() {
        #expect(action("F2", code: "F2") == .command(.renameSelection))
        #expect(action("ArrowLeft", code: "ArrowLeft", meta: true) == .command(.goBack))
        #expect(action("ArrowRight", code: "ArrowRight", meta: true) == .command(.goForward))
        #expect(action("ArrowDown", code: "ArrowDown", meta: true) == .command(.openSelectedItem))
    }
}

struct InlineRenameRulesTests {
    @Test func anUnchangedOrEmptyNameCancels() {
        func decide(_ draft: String, trigger: InlineRenameRules.Trigger = .enter) -> InlineRenameRules.Decision {
            InlineRenameRules.decide(draft: draft, original: "a.txt", refused: nil, trigger: trigger)
        }
        #expect(decide("a.txt") == .cancel)
        #expect(decide("") == .cancel)
        #expect(decide("   ") == .cancel)
        #expect(decide("b.txt") == .submit)
        #expect(decide("b.txt", trigger: .blur) == .submit)
    }

    // A refused name is not sent again until it has been edited.
    @Test func aRefusedNameIsNotSentAgainUntilEdited() {
        func decide(_ draft: String, trigger: InlineRenameRules.Trigger) -> InlineRenameRules.Decision {
            InlineRenameRules.decide(draft: draft, original: "a.txt", refused: "b/c", trigger: trigger)
        }
        #expect(decide("b/c", trigger: .enter) == .keepOpen)
        #expect(decide("b/c", trigger: .blur) == .cancel)
        #expect(decide("b-c", trigger: .enter) == .submit)
    }

    @Test func aNameThatBeginsWithADotAsksFirstWhileHiddenFilesAreHidden() {
        #expect(InlineRenameRules.needsDotConfirmation(name: ".env", hiddenFilesShown: false))
        #expect(!InlineRenameRules.needsDotConfirmation(name: ".env", hiddenFilesShown: true))
        #expect(!InlineRenameRules.needsDotConfirmation(name: "env", hiddenFilesShown: false))
        #expect(InlineRenameRules.trimmedName("  name.txt \n") == "name.txt")
    }
}
