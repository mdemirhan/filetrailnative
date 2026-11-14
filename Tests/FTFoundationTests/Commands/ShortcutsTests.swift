import Testing

@testable import FTFoundation

struct ShortcutsTests {
    static func keyEvent(
        key: String = "", code: String = "", meta: Bool = false, ctrl: Bool = false, alt: Bool = false,
        shift: Bool = false
    ) -> ShortcutKeyEvent {
        ShortcutKeyEvent(key: key, code: code, metaKey: meta, ctrlKey: ctrl, altKey: alt, shiftKey: shift)
    }

    static let defaults = ShortcutCommands.defaultBindings

    // MARK: Shortcut commands

    // ⇧= types + on most keyboards: a key given as ⌘⇧= clashes with Make Bigger's ⌘+, however either is written.
    @Test func takesShiftEqualsAsThePlusKeyWhenAKeyIsGiven() {
        #expect(Shortcuts.plusForShiftEquals("Cmd+Shift+=") == "Cmd+Plus")
        #expect(Shortcuts.plusForShiftEquals("Ctrl+Shift+=") == "Ctrl+Plus")
        // ⌥ types another character.
        #expect(Shortcuts.plusForShiftEquals("Cmd+Option+Shift+=") == "Cmd+Option+Shift+=")
        #expect(Shortcuts.plusForShiftEquals("Cmd+=") == "Cmd+=")
        #expect(ShortcutCommands.checkAssignment(Self.defaults, .newFolder, "Cmd+Shift+=") == .conflict(.increaseSize))
        #expect(ShortcutCommands.checkAssignment(Self.defaults, .increaseSize, "Cmd+Shift+=") == .unchanged)
        let moved = ShortcutCommands.assign(Self.defaults, .newFolder, slot: 1, "Cmd+Shift+=")
        #expect(moved[.increaseSize] == ["Cmd+="])
    }

    // A key recorded as ⌘+ runs its command when ⌘⇧= is pressed, which is how most keyboards type it; a command that
    // has ⌘⇧= itself keeps it.
    @Test func aPressOfCommandShiftEqualsRunsTheCommandThatHasCommandPlus() {
        let moved = ShortcutCommands.resolve(
            .object(["newFolder": .array([.string("Cmd+Shift+N"), .string("Cmd+Plus")])]))
        #expect(moved.commandByShortcut["Cmd+Shift+="] == nil)
        #expect(moved.command(pressed: "Cmd+Shift+=") == .newFolder)
        #expect(moved.command(pressed: "Cmd+Plus") == .newFolder)
        let own = ShortcutCommands.resolve(.object(["newFolder": .array([.string("Cmd+Shift+=")])]))
        #expect(own.command(pressed: "Cmd+Shift+=") == .newFolder)
        #expect(own.command(pressed: "Cmd+Plus") == .increaseSize)
    }

    @Test func namesEveryCommandOnceAndGivesNoKeyToTwoCommands() {
        let ids = ShortcutCommands.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        let keys = ShortcutCommands.all.flatMap { Self.defaults[$0.id] ?? [] }
        #expect(Set(keys).count == keys.count)
        for command in ShortcutCommands.all {
            // Every default is written the one way shortcuts are written, and none was dropped.
            #expect(Self.defaults[command.id] == command.defaults, "\(command.id)")
            #expect(ShortcutCommands.defaultResolved.bindings[command.id] == command.defaults, "\(command.id)")
        }
    }

    // The standard commands' keys stay fixed; the others can be changed.
    @Test func keepsTheStandardCommandsFixed() {
        let fixed = ShortcutCommands.all.filter(\.fixed)
        #expect(
            fixed.map(\.id) == [
                .undo, .redo, .cut, .copy, .paste, .selectAll, .settings, .closeWindow, .minimize, .fullScreen, .hide,
                .hideOthers, .quit,
            ])
        #expect(fixed.allSatisfy { $0.group == .standard })
    }

    @Test func coversEveryCommandTheMenusAndToolbarsCanSend() {
        // These have a fixed key of their own (⌘C, ⌘,) under another name.
        let fixedElsewhere: Set<AppCommand> = [
            .editCut, .editCopy, .editPaste, .editSelectAll, .openSettings, .copySelection, .cutSelection,
            .pasteSelection,
        ]
        let ids = Set(ShortcutCommands.all.map(\.id.rawValue))
        for command in AppCommand.allCases {
            #expect(ids.contains(command.rawValue) || fixedElsewhere.contains(command), "\(command)")
        }
    }

    // MARK: Normalizing a shortcut

    @Test func writesAShortcutOneWayWhateverOrderAndNamesItCameIn() {
        #expect(Shortcuts.normalize("shift+cmd+g") == "Cmd+Shift+G")
        #expect(Shortcuts.normalize("Alt+CommandOrControl+T") == "Cmd+Option+T")
        #expect(Shortcuts.normalize("Shift+Option+Cmd+Ctrl+F5") == "Ctrl+Cmd+Option+Shift+F5")
        #expect(Shortcuts.normalize("Cmd++") == "Cmd+Plus")
        #expect(Shortcuts.normalize("Cmd+-") == "Cmd+-")
        #expect(Shortcuts.normalize("cmd+escape") == "Cmd+Esc")
        #expect(Shortcuts.normalize("Ctrl+Enter") == "Ctrl+Return")
        #expect(Shortcuts.normalize("space") == "Space")
        #expect(Shortcuts.normalize("Shift+?") == "?")
    }

    @Test func refusesTextThatNamesNoShortcut() {
        for value in ["", "Cmd", "Cmd+", "Cmd+Shift", "Hyper+K", "Cmd+F25", "Cmd+?", "Cmd+ab"] {
            #expect(Shortcuts.normalize(value) == nil, "\(value)")
        }
    }

    // MARK: Page keys

    @Test func movesHalfAPageWithCtrlDAndCtrlUAndAPageWithThePageKeysAnyOfThemChangeable() {
        #expect(Self.defaults[.halfPageDown] == ["Ctrl+D"])
        #expect(Self.defaults[.halfPageUp] == ["Ctrl+U"])
        #expect(Self.defaults[.pageDown] == ["PageDown"])
        #expect(Self.defaults[.pageUp] == ["PageUp"])
        for id in [ShortcutCommandID.halfPageDown, .halfPageUp, .pageDown, .pageUp] {
            #expect(!ShortcutCommands.definition(id).fixed, "\(id)")
            #expect(ShortcutCommands.checkAssignment(Self.defaults, id, "Ctrl+Option+J") == .ok)
        }
    }

    @Test func letsGoOfShiftInAShortcutForShiftWithAPageKeyToExtendTheSelection() {
        #expect(Shortcuts.withoutShift("Ctrl+Shift+D") == "Ctrl+D")
        #expect(Shortcuts.withoutShift("Shift+PageDown") == "PageDown")
        #expect(Shortcuts.withoutShift("Ctrl+Cmd+Option+Shift+Up") == "Ctrl+Cmd+Option+Up")
        #expect(Shortcuts.withoutShift("Ctrl+D") == nil)
        #expect(Shortcuts.withoutShift("not a shortcut") == nil)
    }

    // MARK: A shortcut from a key press

    @Test func readsLettersFromTheCharacterSoTheKeyboardLayoutIsFollowed() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "d", code: "KeyD", meta: true)) == "Cmd+D")
        // Dvorak: the key at the QWERTY "D" position types "e".
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "e", code: "KeyD", meta: true)) == "Cmd+E")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "N", code: "KeyN", meta: true, shift: true))
                == "Cmd+Shift+N")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "u", code: "KeyU", ctrl: true)) == "Ctrl+U")
    }

    @Test func readsTheKeyItselfWhenOptionOrShiftChangesTheCharacter() {
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "ç", code: "KeyC", meta: true, alt: true))
                == "Cmd+Option+C")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: ">", code: "Period", meta: true, shift: true))
                == "Cmd+Shift+.")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "}", code: "BracketRight", meta: true, shift: true))
                == "Cmd+Shift+]")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: " ", code: "Space", alt: true)) == "Option+Space")
    }

    @Test func namesTheKeysThatHaveNoCharacter() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "ArrowUp", meta: true)) == "Cmd+Up")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Backspace", meta: true)) == "Cmd+Backspace")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Tab", ctrl: true, shift: true)) == "Ctrl+Shift+Tab")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "F2")) == "F2")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: " ", code: "Space")) == "Space")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Enter")) == "Return")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Escape")) == "Esc")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "+", code: "NumpadAdd", meta: true)) == "Cmd+Plus")
    }

    @Test func takesAQuestionMarkAsTheCharacterHoweverItIsTyped() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "?", code: "Slash", shift: true)) == "?")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "?", code: "Slash", meta: true, shift: true))
                == "Cmd+Shift+/")
    }

    @Test func isNothingWhileOnlyModifiersAreDownOrForAKeyItHasNoNameFor() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Meta", code: "MetaLeft", meta: true)) == nil)
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Shift", code: "ShiftLeft", shift: true)) == nil)
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "ö", code: "", meta: true)) == nil)
    }

    // MARK: Refused shortcuts

    @Test func needsCommandOrControlOnAKeyThatTypes() {
        for shortcut in ["D", "Shift+D", "Option+D", "7", "Space", "Shift+Space", "/"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == .needsCommandOrControl, "\(shortcut)")
        }
        for shortcut in ["Cmd+D", "Ctrl+D", "Ctrl+Option+7", "Cmd+Shift+Space"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    @Test func needsAModifierOnAKeyThatMovesAroundOrEditsTheList() {
        for shortcut in ["Up", "Shift+Down", "Home", "Tab", "Return", "Esc", "Backspace"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == .needsModifier, "\(shortcut)")
        }
        for shortcut in ["Option+Left", "Cmd+Return", "Ctrl+Tab", "Option+Backspace"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    @Test func allowsFunctionKeysForwardDeleteAndThePageKeysOnTheirOwn() {
        for shortcut in ["F2", "F12", "Shift+F5", "Delete", "PageUp", "PageDown"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    @Test func keepsTheKeysOfTheFixedCommandsOfCancellingAndOfMacOS() {
        #expect(ShortcutCommands.refusal(for: "Cmd+C") == .fixedCommand(.copy))
        #expect(ShortcutCommands.refusal(for: "Cmd+Shift+Z") == .fixedCommand(.redo))
        #expect(ShortcutCommands.refusal(for: "Cmd+Q") == .fixedCommand(.quit))
        #expect(ShortcutCommands.refusal(for: "Cmd+,") == .fixedCommand(.settings))
        #expect(ShortcutCommands.refusal(for: "Ctrl+Cmd+F") == .fixedCommand(.fullScreen))
        #expect(ShortcutCommands.refusal(for: "Cmd+.") == .cancelsDialogs)
        for shortcut in ["Cmd+Tab", "Cmd+Space", "Cmd+`", "Cmd+Shift+4", "Cmd+Option+Esc"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == .macOS, "\(shortcut)")
        }
    }

    @Test func warnsAboutButAllowsKeysMacOSUsesUntilTheyAreSwitchedOff() {
        #expect(ShortcutCommands.refusal(for: "Ctrl+Up") == nil)
        #expect(ShortcutCommands.isUsedByMacOSByDefault("Ctrl+Up"))
        #expect(ShortcutCommands.isUsedByMacOSByDefault("F11"))
        #expect(!ShortcutCommands.isUsedByMacOSByDefault("Cmd+Up"))
    }

    // MARK: Resolving the shortcuts

    @Test func givesEveryCommandItsDefaultKeysWhenNothingWasSaved() {
        let saved: [JSONNode?] = [nil, .null, .string("x"), .array([]), .object([:])]
        for value in saved {
            #expect(ShortcutCommands.resolve(value).bindings == Self.defaults)
        }
        let resolved = ShortcutCommands.defaultResolved
        #expect(resolved.commandByShortcut["Cmd+D"] == .duplicateSelection)
        #expect(resolved.commandByShortcut["Cmd+Left"] == .goBack)
        #expect(resolved.commandByShortcut["Space"] == .quickLookSelection)
        #expect(resolved.commandByShortcut["?"] == .openHelp)
        // Fixed commands have handlers of their own.
        #expect(resolved.commandByShortcut["Cmd+C"] == nil)
    }

    @Test func replacesTheKeysOfTheCommandsThatWereChangedAndLeavesTheRest() {
        let resolved = ShortcutCommands.resolve([
            "newTab": ["Cmd+Option+N"], "showInFinder": ["Cmd+Shift+J", "F5"], "duplicateSelection": [],
        ])
        #expect(resolved.bindings[.newTab] == ["Cmd+Option+N"])
        #expect(resolved.bindings[.showInFinder] == ["Cmd+Shift+J", "F5"])
        #expect(resolved.bindings[.duplicateSelection] == [])
        #expect(resolved.bindings[.closeTab] == ["Cmd+W"])
        #expect(resolved.commandByShortcut["Cmd+T"] == nil)
        #expect(resolved.commandByShortcut["Cmd+D"] == nil)
        #expect(resolved.commandByShortcut["F5"] == .showInFinder)
    }

    @Test func givesAKeyTwoCommandsClaimToTheOneThatWasGivenIt() {
        // New Folder was given ⌘D; Duplicate only has it by default.
        let given = ShortcutCommands.resolve(["newFolder": ["Cmd+Shift+N", "Cmd+D"]]).bindings
        #expect(given[.newFolder] == ["Cmd+Shift+N", "Cmd+D"])
        #expect(given[.duplicateSelection] == [])

        // Both were given it: the first command in the list keeps it.
        let both = ShortcutCommands.resolve(["newTab": ["Cmd+J"], "closeTab": ["Cmd+J", "Cmd+W"]]).bindings
        #expect(both[.newTab] == ["Cmd+J"])
        #expect(both[.closeTab] == ["Cmd+W"])
    }

    @Test func dropsWhatMakesNoSenseUnknownCommandsUnusableKeysAThirdKey() {
        let bindings = ShortcutCommands.resolve(
            .object([
                "noSuchCommand": .array([.string("Cmd+J")]),
                "copy": .array([.string("Cmd+J")]),
                "newTab": .array(
                    [
                        "Cmd+C", "D", "Cmd+Tab", nil, "cmd+shift+y", "Cmd+Shift+Y", "Cmd+U", "Cmd+Y",
                    ].map { $0.map(JSONNode.string) ?? .number(7) }),
                "closeTab": .string("Cmd+J"),
            ])
        ).bindings
        #expect(bindings[.copy] == ["Cmd+C"])
        #expect(bindings[.newTab] == ["Cmd+Shift+Y", "Cmd+U"])
        #expect(bindings[.closeTab] == ["Cmd+W"])
    }

    @Test func letsACommandKeepAKeyOfItsOwnDefaultsThatCouldNotBeGivenOutToday() {
        #expect(
            ShortcutCommands.resolve(["quickLookSelection": ["Cmd+Y", "Space"]]).bindings[.quickLookSelection]
                == ["Cmd+Y", "Space"])
        #expect(ShortcutCommands.resolve(["openHelp": ["F1", "?"]]).bindings[.openHelp] == ["F1", "?"])
        // Space is Quick Look's alone.
        #expect(ShortcutCommands.resolve(["newTab": ["Space"]]).bindings[.newTab] == [])
    }

    // MARK: Saving shortcuts

    @Test func savesOnlyTheCommandsThatDifferFromTheirDefaults() {
        #expect(ShortcutCommands.overrides(for: Self.defaults) == [:])
        let saved = ShortcutCommands.sanitizeOverrides(
            .object([
                "newTab": .array([.string("option+cmd+n")]), "closeTab": .array([.string("Cmd+W")]),
                "duplicateSelection": .array([]), "noSuchCommand": .array([.string("Cmd+J")]),
            ]))
        #expect(saved == ["newTab": ["Cmd+Option+N"], "duplicateSelection": []])
    }

    @Test func writesDownTheKeyACommandLostToAnotherSoItStaysLost() {
        let saved = ShortcutCommands.sanitizeOverrides(.object(["newFolder": .array([.string("Cmd+D")])]))
        #expect(saved == ["newFolder": ["Cmd+D"], "duplicateSelection": []])
    }

    // MARK: Changing shortcuts

    @Test func saysWhetherAKeyCanBeGivenToACommand() {
        let bindings = Self.defaults
        #expect(ShortcutCommands.checkAssignment(bindings, .showInFinder, "Cmd+Shift+J") == .ok)
        #expect(ShortcutCommands.checkAssignment(bindings, .goBack, "Cmd+Left") == .unchanged)
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "Cmd+D") == .conflict(.duplicateSelection))
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "Cmd+V") == .refused(.fixedCommand(.paste)))
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "N") == .refused(.needsCommandOrControl))
        // Quick Look can have Space back; nothing else can have it.
        let withoutSpace = ShortcutCommands.remove(bindings, .quickLookSelection, slot: 1)
        #expect(ShortcutCommands.checkAssignment(withoutSpace, .quickLookSelection, "Space") == .ok)
        let other = ShortcutCommands.checkAssignment(withoutSpace, .newTab, "Space")
        if case .refused = other {} else { Issue.record("Space should be refused for New Tab") }
    }

    @Test func putsAKeyInTheMainOrTheAlternatePlace() {
        let bindings = Self.defaults
        let main = ShortcutCommands.assign(bindings, .duplicateSelection, slot: 0, "Cmd+Shift+D")
        #expect(main[.duplicateSelection] == ["Cmd+Shift+D"])

        let alternate = ShortcutCommands.assign(bindings, .duplicateSelection, slot: 1, "Cmd+Shift+D")
        #expect(alternate[.duplicateSelection] == ["Cmd+D", "Cmd+Shift+D"])

        // The alternate place of a command without keys is its main place.
        #expect(ShortcutCommands.assign(bindings, .showInFinder, slot: 1, "F5")[.showInFinder] == ["F5"])
        // Replacing the main key keeps the alternate.
        #expect(ShortcutCommands.assign(bindings, .goBack, slot: 0, "Cmd+J")[.goBack] == ["Cmd+J", "Cmd+Left"])
        #expect(ShortcutCommands.isCustomized(main, .duplicateSelection))
        #expect(!ShortcutCommands.isCustomized(main, .newFolder))
    }

    @Test func takesAReassignedKeyAwayFromTheCommandThatHadIt() {
        let next = ShortcutCommands.assign(Self.defaults, .newFolder, slot: 1, "Cmd+D")
        #expect(next[.newFolder] == ["Cmd+Shift+N", "Cmd+D"])
        #expect(next[.duplicateSelection] == [])
        #expect(
            ShortcutCommands.overrides(for: next) == ["newFolder": ["Cmd+Shift+N", "Cmd+D"], "duplicateSelection": []])
    }

    @Test func makesTheAlternateTheMainKeyWhenTheMainKeyIsRemoved() {
        #expect(ShortcutCommands.remove(Self.defaults, .goBack, slot: 0)[.goBack] == ["Cmd+Left"])
        #expect(ShortcutCommands.remove(Self.defaults, .goBack, slot: 1)[.goBack] == ["Cmd+["])
    }

    @Test func resetsACommandToItsDefaultsTakingThemBackFromACommandGivenOneSince() {
        let reassigned = ShortcutCommands.assign(Self.defaults, .newFolder, slot: 1, "Cmd+D")
        let result = ShortcutCommands.reset(reassigned, .duplicateSelection)
        #expect(result.takenFrom == [.newFolder])
        #expect(result.bindings == Self.defaults)
        let untouched = ShortcutCommands.reset(Self.defaults, .goBack)
        #expect(untouched.bindings == Self.defaults)
        #expect(untouched.takenFrom == [])
    }

    // MARK: Shortcuts in the application menu

    @Test func givesTheMenuTheFirstKeyThatHasCommandOrControl() {
        #expect(Shortcuts.menuShortcut(["Cmd+[", "Cmd+Left"]) == "Cmd+[")
        #expect(Shortcuts.menuShortcut(["Space", "Cmd+Y"]) == "Cmd+Y")
        #expect(Shortcuts.menuShortcut(["F2"]) == nil)
        #expect(Shortcuts.menuShortcut(["?"]) == nil)
        #expect(Shortcuts.menuShortcut([]) == nil)
    }

    @Test func writesAShortcutAsAMenuAccelerator() {
        #expect(Shortcuts.menuAccelerator("Cmd+Option+T") == "Command+Alt+T")
        #expect(Shortcuts.menuAccelerator("Ctrl+Shift+Tab") == "Control+Shift+Tab")
        #expect(Shortcuts.menuAccelerator("Cmd+Plus") == "Command+Plus")
        #expect(Shortcuts.menuAccelerator("Cmd+Esc") == "Command+Escape")
        #expect(Shortcuts.menuAccelerator("Cmd+Backspace") == "Command+Backspace")
        #expect(Shortcuts.menuAccelerator("?") == nil)
        #expect(Shortcuts.menuAccelerator("nonsense") == nil)
    }

    @Test func knowsTheKeysATextFieldUsesForItself() {
        for shortcut in ["Cmd+Up", "Cmd+Backspace", "Option+Left", "Ctrl+A", "Delete"] {
            #expect(Shortcuts.isTextEditingShortcut(shortcut), "\(shortcut)")
        }
        for shortcut in ["Cmd+D", "Cmd+[", "Ctrl+Cmd+A", "F2"] {
            #expect(!Shortcuts.isTextEditingShortcut(shortcut), "\(shortcut)")
        }
    }

    // MARK: Default keys of the table (the Settings list)

    @Test func theTableHoldsTheDocumentedDefaultKeys() {
        let expected: [(ShortcutCommandID, [String])] = [
            (.goBack, ["Cmd+[", "Cmd+Left"]), (.goForward, ["Cmd+]", "Cmd+Right"]), (.goEnclosingFolder, ["Cmd+Up"]),
            (.goHomeRootTree, ["Cmd+Shift+H"]), (.openLocationSheet, ["Cmd+K", "Cmd+Shift+G"]),
            (.rootTreeAtSelection, ["Cmd+Shift+R"]), (.refreshOrApplySearchSort, ["Cmd+R"]),
            (.goDocuments, []), (.goDesktop, []), (.goDownloads, []), (.goLibrary, []), (.goMacintoshHD, []),
            (.goApplications, []), (.goTrash, []), (.focusTreePane, []), (.focusContentPane, []),
            (.newWindow, ["Cmd+N"]), (.newTab, ["Cmd+T"]), (.duplicateTab, []), (.closeTab, ["Cmd+W"]),
            (.reopenClosedTab, ["Cmd+Shift+T"]),
            (.selectNextTab, ["Ctrl+Tab", "Cmd+Shift+]"]), (.selectPreviousTab, ["Ctrl+Shift+Tab", "Cmd+Shift+["]),
            (.openSelectionInNewTab, []), (.openSelectionInNewWindow, []), (.moveTabToNewWindow, []),
            (.mergeAllWindows, []), (.openSelection, ["Cmd+O"]), (.openSelectedItem, ["Cmd+Down"]),
            (.editSelection, ["Cmd+Shift+E"]), (.quickLookSelection, ["Cmd+Y", "Space"]), (.renameSelection, ["F2"]),
            (.duplicateSelection, ["Cmd+D"]), (.moveSelection, ["Cmd+Shift+M"]), (.newFolder, ["Cmd+Shift+N"]),
            (.trashSelection, ["Cmd+Backspace"]), (.ejectVolume, ["Cmd+E"]), (.emptyTrash, ["Cmd+Shift+Backspace"]),
            (.copyPath, ["Cmd+Option+C"]), (.openInTerminal, ["Cmd+Option+T"]), (.calculateSize, []),
            (.showClipboard, []), (.clearClipboard, []), (.showInFinder, []), (.toggleFavorite, []),
            (.focusFileSearch, ["Cmd+F"]), (.showLastSearchResults, ["Cmd+Shift+F"]), (.revealInFolder, []),
            (.viewAsIcons, ["Cmd+1"]), (.viewAsDetails, ["Cmd+2"]), (.viewAsList, ["Cmd+3"]),
            (.increaseSize, ["Cmd+Plus", "Cmd+="]), (.decreaseSize, ["Cmd+-"]), (.resetSize, ["Cmd+0"]),
            (.toggleHiddenFiles, ["Cmd+Shift+."]), (.toggleFolderTree, ["Ctrl+Cmd+S"]), (.toggleInfoPanel, ["Cmd+I"]),
            (.toggleInfoRow, ["Cmd+Shift+I"]), (.openHelp, ["?"]), (.sortByName, []), (.sortByKind, []),
            (.sortByModified, []), (.sortBySize, []), (.toggleFoldersFirst, []), (.customizeToolbar, []),
            (.openKeyboardShortcuts, []), (.pageUp, ["PageUp"]), (.pageDown, ["PageDown"]), (.halfPageUp, ["Ctrl+U"]),
            (.halfPageDown, ["Ctrl+D"]), (.undo, ["Cmd+Z"]), (.redo, ["Cmd+Shift+Z"]), (.cut, ["Cmd+X"]),
            (.copy, ["Cmd+C"]), (.paste, ["Cmd+V"]), (.selectAll, ["Cmd+A"]), (.settings, ["Cmd+,"]),
            (.closeWindow, ["Cmd+Shift+W"]), (.minimize, ["Cmd+M"]), (.fullScreen, ["Ctrl+Cmd+F"]),
            (.hide, ["Cmd+H"]), (.hideOthers, ["Cmd+Option+H"]), (.quit, ["Cmd+Q"]),
        ]
        #expect(expected.count == ShortcutCommands.all.count)
        for (id, keys) in expected {
            #expect(Self.defaults[id] == keys, "\(id)")
        }
    }

    // There is no zoom of the whole window. ⌘+, ⌘- and ⌘0 change the size of the icons or the columns; ⌘+ is pressed
    // as ⌘= on most keyboards, which is its other key.
    @Test func zoomHasNoCommandsAndItsKeysSizeTheView() {
        #expect(ShortcutCommandID(rawValue: "zoomIn") == nil)
        #expect(ShortcutCommandID(rawValue: "zoomOut") == nil)
        #expect(ShortcutCommandID(rawValue: "resetZoom") == nil)
        #expect(AppCommand(rawValue: "zoomIn") == nil)
        #expect(Shortcuts.normalize("Cmd+Plus") == "Cmd+Plus")
        let keys = ShortcutCommands.defaultResolved.commandByShortcut
        #expect(keys["Cmd+Plus"] == .increaseSize && keys["Cmd+="] == .increaseSize)
        #expect(keys["Cmd+-"] == .decreaseSize && keys["Cmd+0"] == .resetSize)
        // The menu shows and listens for ⌘+; the window takes ⌘=.
        #expect(Shortcuts.menuShortcut(ShortcutCommands.defaultBindings[.increaseSize] ?? []) == "Cmd+Plus")
        #expect(ShortcutDisplay.defaults.label(.increaseSize) == "⌘+")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "=", code: "Equal", meta: true)).flatMap { keys[$0] }
                == .increaseSize)
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "-", code: "Minus", meta: true)).flatMap { keys[$0] }
                == .decreaseSize)
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "0", code: "Digit0", meta: true)).flatMap { keys[$0] }
                == .resetSize)
        // A keyboard with + on a key of its own.
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "+", code: "BracketRight", meta: true)).flatMap {
                keys[$0]
            } == .increaseSize)
    }
}
