// The keys of the file list: type-to-filter, the raw key bindings, and the inline rename's commit rules
import Testing

@testable import FTFoundation

struct ListFilterTypingTests {
    @Test func typingAppendsTheTextAsTyped() {
        var filter = ListFilterTyping()
        #expect(!filter.isActive)
        filter.type("M", at: 0)
        filter.type("y", at: 0.1)
        filter.type(" ", at: 0.2)
        filter.type("d", at: 0.3)
        // The text is not trimmed and keeps its case.
        #expect(filter.query == "My d")
        #expect(filter.isActive)
    }

    // An emoji set from the search field's filter goes whole: half of it would match nothing.
    @Test func backspaceTakesAnEmojiBackWhole() {
        var filter = ListFilterTyping()
        filter.set("a\u{1F600}", at: 0)
        filter.eraseCharacter(at: 1)
        #expect(filter.query == "a")
    }

    @Test func backspaceTakesACharacterBackAndEscClears() {
        var filter = ListFilterTyping()
        filter.type("tr", at: 0)
        filter.eraseCharacter(at: 1)
        #expect(filter.query == "t")
        filter.eraseCharacter(at: 2)
        #expect(filter.query == "")
        filter.eraseCharacter(at: 3)
        #expect(filter.query == "")
        filter.type("abc", at: 4)
        filter.clear()
        #expect(filter.query == "")
    }

    // Space is part of the text for a second after the last input.
    @Test func spaceBelongsToTheTextForASecond() {
        var filter = ListFilterTyping()
        #expect(!filter.takesSpace(at: 0))
        filter.type("my", at: 10)
        #expect(filter.takesSpace(at: 10.5))
        #expect(filter.takesSpace(at: 10.999))
        #expect(!filter.takesSpace(at: 11))
        // Each input renews it.
        filter.eraseCharacter(at: 11.5)
        #expect(filter.takesSpace(at: 12.4))
        // A filter brought back with a tab treats Space as Quick Look at once.
        #expect(!ListFilterTyping(restoring: "abc").takesSpace(at: 0))
        // Without a filter Space is always Quick Look.
        filter.clear()
        #expect(!filter.takesSpace(at: 12))
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
        shift: Bool = false, filter: ListFilterTyping = ListFilterTyping(), now: Double = 0, entries: Bool = true,
        selected: Bool = true, pinned: Bool = false
    ) -> ContentKeyAction? {
        ContentKeys.action(
            for: ShortcutKeyEvent(key: key, code: code, metaKey: meta, ctrlKey: ctrl, altKey: alt, shiftKey: shift),
            shortcuts: shortcuts, filter: filter, now: now, hasEntries: entries, hasSelection: selected, pinned: pinned)
    }

    @Test func withThePinTypingSelectsNamesAndLeavesTheFilterAlone() {
        #expect(action("s", code: "KeyS", pinned: true) == .typeToSelect("s"))
        #expect(action("S", code: "KeyS", shift: true, pinned: true) == .typeToSelect("S"))
        // Esc lets go of the letters; Backspace and ⌥⌫ have nothing to take back.
        #expect(action("Escape", code: "Escape", pinned: true) == .typeToSelect(nil))
        #expect(action("Backspace", code: "Backspace", pinned: true) == nil)
        #expect(action("Backspace", code: "Backspace", alt: true, pinned: true) == nil)
        // Space stays Quick Look, the arrows move, and ⌘ with a letter is still its command.
        #expect(action(" ", code: "Space", pinned: true) == .command(.quickLookSelection))
        #expect(action("ArrowDown", code: "ArrowDown", pinned: true) == .move(.down, extend: false))
        #expect(action("t", code: "KeyT", meta: true, pinned: true) == .command(.newTab))
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
            for: event, shortcuts: custom, filter: ListFilterTyping(), now: 0, hasEntries: true, hasSelection: true)
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
        filter.type("annual rep", at: 1)
        #expect(action("Backspace", code: "Backspace", alt: true, filter: filter) == .filter(.eraseWord))
        // ⌘⌫ stays Move to Trash.
        #expect(action("Backspace", code: "Backspace", meta: true, filter: filter) == .command(.trashSelection))
        filter.eraseWord(at: 2)
        #expect(filter.query == "annual ")
        filter.eraseWord(at: 3)
        #expect(filter.query == "")
        filter.type("c++ notes", at: 4)
        filter.eraseWord(at: 5)
        filter.eraseWord(at: 6)
        #expect(filter.query == "")
    }

    @Test func backspaceEscapeAndSpaceEditTheFilterOnlyWhileThereIsOne() {
        var filter = ListFilterTyping()
        #expect(action("Backspace", code: "Backspace", filter: filter) == nil)
        #expect(action("Escape", code: "Escape", filter: filter) == nil)
        filter.type("my", at: 5)
        #expect(action("Backspace", code: "Backspace", filter: filter, now: 9) == .filter(.erase))
        #expect(action("Escape", code: "Escape", filter: filter, now: 9) == .filter(.clear))
        #expect(action(" ", code: "Space", filter: filter, now: 5.5) == .filter(.type(" ")))
        // After the pause Space is Quick Look.
        #expect(action(" ", code: "Space", filter: filter, now: 7) == .command(.quickLookSelection))
        // With no filter it is Quick Look at once.
        #expect(action(" ", code: "Space") == .command(.quickLookSelection))
    }

    // Space never starts a filter. While one is typed it types a space for a moment after each key and then is Quick
    // Look; taken off Quick Look in Settings (no other command can have it), it always types a space.
    @Test func spaceTypesIntoAFilterAlwaysWhenQuickLookDoesntHaveIt() {
        func action(_ overrides: ShortcutOverrides, filter: ListFilterTyping, now: Double) -> ContentKeyAction? {
            ContentKeys.action(
                for: ShortcutKeyEvent(key: " ", code: "Space"), shortcuts: ShortcutCommands.resolve(overrides),
                filter: filter, now: now, hasEntries: true, hasSelection: true)
        }
        var typed = ListFilterTyping()
        typed.type("my", at: 5)
        var unassigned = ShortcutOverrides()
        unassigned["quickLookSelection"] = []
        #expect(action(unassigned, filter: ListFilterTyping(), now: 0) == nil)
        #expect(action(unassigned, filter: typed, now: 5.5) == .filter(.type(" ")))
        #expect(action(unassigned, filter: typed, now: 60) == .filter(.type(" ")))
        #expect(action([:], filter: typed, now: 60) == .command(.quickLookSelection))
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
