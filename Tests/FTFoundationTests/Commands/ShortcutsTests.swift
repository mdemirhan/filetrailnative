// Port of apps/desktop/src/shared/shortcuts.test.ts
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

    // T-f0344551 F-007
    @Test func namesEveryCommandOnceAndGivesNoKeyToTwoCommands() {
        let ids = ShortcutCommands.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 79)

        let keys = ShortcutCommands.all.flatMap { Self.defaults[$0.id] ?? [] }
        #expect(Set(keys).count == keys.count)
        for command in ShortcutCommands.all {
            // Every default is written the one way shortcuts are written, and none was dropped.
            #expect(Self.defaults[command.id] == command.defaults, "\(command.id)")
            #expect(ShortcutCommands.defaultResolved.bindings[command.id] == command.defaults, "\(command.id)")
        }
    }

    // T-ea83b599 F-082
    // The original lets 69 commands be changed; Zoom In, Zoom Out and Actual Size are dropped (D-005), so 66 are.
    @Test func letsSixtySixCommandsBeChangedAndKeepsTheStandardOnesFixed() {
        let fixed = ShortcutCommands.all.filter(\.fixed)
        #expect(ShortcutCommands.all.count - fixed.count == 66)
        #expect(
            fixed.map(\.id) == [
                .undo, .redo, .cut, .copy, .paste, .selectAll, .settings, .closeWindow, .minimize, .fullScreen, .hide,
                .hideOthers, .quit,
            ])
        #expect(fixed.allSatisfy { $0.group == .standard })
    }

    // T-1512badd
    @Test func coversEveryCommandTheMenusAndToolbarsCanSend() {
        // These have a fixed key of their own (⌘C, ⌘,) under another name.
        let fixedElsewhere: Set<RendererCommand> = [
            .editCut, .editCopy, .editPaste, .editSelectAll, .openSettings, .copySelection, .cutSelection,
            .pasteSelection,
        ]
        let ids = Set(ShortcutCommands.all.map(\.id.rawValue))
        for command in RendererCommand.allCases {
            #expect(ids.contains(command.rawValue) || fixedElsewhere.contains(command), "\(command)")
        }
    }

    // MARK: normalizeShortcut

    // T-ad71912c F-007
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

    // T-5638bddb
    @Test func refusesTextThatNamesNoShortcut() {
        for value in ["", "Cmd", "Cmd+", "Cmd+Shift", "Hyper+K", "Cmd+F25", "Cmd+?", "Cmd+ab"] {
            #expect(Shortcuts.normalize(value) == nil, "\(value)")
        }
    }

    // MARK: Page keys

    // T-4524620d F-075
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

    // T-d1f043f8
    @Test func letsGoOfShiftInAShortcutForShiftWithAPageKeyToExtendTheSelection() {
        #expect(Shortcuts.withoutShift("Ctrl+Shift+D") == "Ctrl+D")
        #expect(Shortcuts.withoutShift("Shift+PageDown") == "PageDown")
        #expect(Shortcuts.withoutShift("Ctrl+Cmd+Option+Shift+Up") == "Ctrl+Cmd+Option+Up")
        #expect(Shortcuts.withoutShift("Ctrl+D") == nil)
        #expect(Shortcuts.withoutShift("not a shortcut") == nil)
    }

    // MARK: shortcutFromKeyboardEvent

    // T-78e330e0
    @Test func readsLettersFromTheCharacterSoTheKeyboardLayoutIsFollowed() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "d", code: "KeyD", meta: true)) == "Cmd+D")
        // Dvorak: the key at the QWERTY "D" position types "e".
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "e", code: "KeyD", meta: true)) == "Cmd+E")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "N", code: "KeyN", meta: true, shift: true))
                == "Cmd+Shift+N")
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "u", code: "KeyU", ctrl: true)) == "Ctrl+U")
    }

    // T-dcb5f3f4
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

    // T-ebeea59d
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

    // T-7c4c4ecc
    @Test func takesAQuestionMarkAsTheCharacterHoweverItIsTyped() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "?", code: "Slash", shift: true)) == "?")
        #expect(
            Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "?", code: "Slash", meta: true, shift: true))
                == "Cmd+Shift+/")
    }

    // T-d713631e
    @Test func isNothingWhileOnlyModifiersAreDownOrForAKeyItHasNoNameFor() {
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Meta", code: "MetaLeft", meta: true)) == nil)
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "Shift", code: "ShiftLeft", shift: true)) == nil)
        #expect(Shortcuts.fromKeyboardEvent(Self.keyEvent(key: "ö", code: "", meta: true)) == nil)
    }

    // MARK: getShortcutRefusal

    // T-637c8655 F-009
    @Test func needsCommandOrControlOnAKeyThatTypes() {
        for shortcut in ["D", "Shift+D", "Option+D", "7", "Space", "Shift+Space", "/"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == .needsCommandOrControl, "\(shortcut)")
        }
        for shortcut in ["Cmd+D", "Ctrl+D", "Ctrl+Option+7", "Cmd+Shift+Space"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    // T-c778d5e2 F-009
    @Test func needsAModifierOnAKeyThatMovesAroundOrEditsTheList() {
        for shortcut in ["Up", "Shift+Down", "Home", "Tab", "Return", "Esc", "Backspace"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == .needsModifier, "\(shortcut)")
        }
        for shortcut in ["Option+Left", "Cmd+Return", "Ctrl+Tab", "Option+Backspace"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    // T-f2c50761 F-009
    @Test func allowsFunctionKeysForwardDeleteAndThePageKeysOnTheirOwn() {
        for shortcut in ["F2", "F12", "Shift+F5", "Delete", "PageUp", "PageDown"] {
            #expect(ShortcutCommands.refusal(for: shortcut) == nil, "\(shortcut)")
        }
    }

    // T-1957a02e F-009 F-082
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

    // T-3f23eb43 F-009
    @Test func warnsAboutButAllowsKeysMacOSUsesUntilTheyAreSwitchedOff() {
        #expect(ShortcutCommands.refusal(for: "Ctrl+Up") == nil)
        #expect(ShortcutCommands.isUsedByMacOSByDefault("Ctrl+Up"))
        #expect(ShortcutCommands.isUsedByMacOSByDefault("F11"))
        #expect(!ShortcutCommands.isUsedByMacOSByDefault("Cmd+Up"))
    }

    // MARK: resolveShortcuts

    // T-73ef18c3 F-008 F-074
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

    // T-971cad93 F-008
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

    // T-6fb14033 F-008
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

    // T-f7cd3e97 F-007
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

    // T-16e588fd
    @Test func letsACommandKeepAKeyOfItsOwnDefaultsThatCouldNotBeGivenOutToday() {
        #expect(
            ShortcutCommands.resolve(["quickLookSelection": ["Cmd+Y", "Space"]]).bindings[.quickLookSelection]
                == ["Cmd+Y", "Space"])
        #expect(ShortcutCommands.resolve(["openHelp": ["F1", "?"]]).bindings[.openHelp] == ["F1", "?"])
        // Space is Quick Look's alone.
        #expect(ShortcutCommands.resolve(["newTab": ["Space"]]).bindings[.newTab] == [])
    }

    // MARK: Saving shortcuts

    // T-d18debbf F-007
    @Test func savesOnlyTheCommandsThatDifferFromTheirDefaults() {
        #expect(ShortcutCommands.overrides(for: Self.defaults) == [:])
        let saved = ShortcutCommands.sanitizeOverrides(
            .object([
                "newTab": .array([.string("option+cmd+n")]), "closeTab": .array([.string("Cmd+W")]),
                "duplicateSelection": .array([]), "noSuchCommand": .array([.string("Cmd+J")]),
            ]))
        #expect(saved == ["newTab": ["Cmd+Option+N"], "duplicateSelection": []])
    }

    // T-41956293 F-008
    @Test func writesDownTheKeyACommandLostToAnotherSoItStaysLost() {
        let saved = ShortcutCommands.sanitizeOverrides(.object(["newFolder": .array([.string("Cmd+D")])]))
        #expect(saved == ["newFolder": ["Cmd+D"], "duplicateSelection": []])
    }

    // MARK: Changing shortcuts

    // T-2a45b5f7 F-009
    @Test func saysWhetherAKeyCanBeGivenToACommand() {
        let bindings = Self.defaults
        #expect(ShortcutCommands.checkAssignment(bindings, .showInFinder, "Cmd+Shift+J") == .ok)
        #expect(ShortcutCommands.checkAssignment(bindings, .goBack, "Cmd+Left") == .unchanged)
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "Cmd+D") == .conflict(.duplicateSelection))
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "Cmd+V") == .refused(.fixedCommand(.paste)))
        #expect(ShortcutCommands.checkAssignment(bindings, .newFolder, "N") == .refused(.needsCommandOrControl))
        // Quick Look can have Space back; nothing else can have it.
        let withoutSpace = ShortcutCommands.remove(bindings, .quickLookSelection, slot: 0)
        #expect(ShortcutCommands.checkAssignment(withoutSpace, .quickLookSelection, "Space") == .ok)
        let other = ShortcutCommands.checkAssignment(withoutSpace, .newTab, "Space")
        if case .refused = other {} else { Issue.record("Space should be refused for New Tab") }
    }

    // T-28cb4cb3
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

    // T-c3bff820
    @Test func takesAReassignedKeyAwayFromTheCommandThatHadIt() {
        let next = ShortcutCommands.assign(Self.defaults, .newFolder, slot: 1, "Cmd+D")
        #expect(next[.newFolder] == ["Cmd+Shift+N", "Cmd+D"])
        #expect(next[.duplicateSelection] == [])
        #expect(
            ShortcutCommands.overrides(for: next) == ["newFolder": ["Cmd+Shift+N", "Cmd+D"], "duplicateSelection": []])
    }

    // T-b864c54c
    @Test func makesTheAlternateTheMainKeyWhenTheMainKeyIsRemoved() {
        #expect(ShortcutCommands.remove(Self.defaults, .goBack, slot: 0)[.goBack] == ["Cmd+Left"])
        #expect(ShortcutCommands.remove(Self.defaults, .goBack, slot: 1)[.goBack] == ["Cmd+["])
    }

    // T-658f2c72
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

    // T-b39157ff
    @Test func givesTheMenuTheFirstKeyThatHasCommandOrControl() {
        #expect(Shortcuts.menuShortcut(["Cmd+[", "Cmd+Left"]) == "Cmd+[")
        #expect(Shortcuts.menuShortcut(["Space", "Cmd+Y"]) == "Cmd+Y")
        #expect(Shortcuts.menuShortcut(["F2"]) == nil)
        #expect(Shortcuts.menuShortcut(["?"]) == nil)
        #expect(Shortcuts.menuShortcut([]) == nil)
    }

    // T-e349b4dc
    @Test func writesAShortcutTheWayElectronsMenusDo() {
        #expect(Shortcuts.menuAccelerator("Cmd+Option+T") == "Command+Alt+T")
        #expect(Shortcuts.menuAccelerator("Ctrl+Shift+Tab") == "Control+Shift+Tab")
        #expect(Shortcuts.menuAccelerator("Cmd+Plus") == "Command+Plus")
        #expect(Shortcuts.menuAccelerator("Cmd+Esc") == "Command+Escape")
        #expect(Shortcuts.menuAccelerator("Cmd+Backspace") == "Command+Backspace")
        #expect(Shortcuts.menuAccelerator("?") == nil)
        #expect(Shortcuts.menuAccelerator("nonsense") == nil)
    }

    // T-e203ab51 F-010
    @Test func knowsTheKeysATextFieldUsesForItself() {
        for shortcut in ["Cmd+Up", "Cmd+Backspace", "Option+Left", "Ctrl+A", "Delete"] {
            #expect(Shortcuts.isTextEditingShortcut(shortcut), "\(shortcut)")
        }
        for shortcut in ["Cmd+D", "Cmd+[", "Ctrl+Cmd+A", "F2"] {
            #expect(!Shortcuts.isTextEditingShortcut(shortcut), "\(shortcut)")
        }
    }

    // MARK: Default keys of the table (the Settings list)

    // F-074 F-075 F-076 F-077 F-078 F-079 F-080 F-081 F-082
    @Test func theTableHoldsTheDocumentedDefaultKeys() {
        let expected: [(ShortcutCommandID, [String])] = [
            (.goBack, ["Cmd+[", "Cmd+Left"]), (.goForward, ["Cmd+]", "Cmd+Right"]), (.goEnclosingFolder, ["Cmd+Up"]),
            (.goHomeRootTree, ["Cmd+Shift+H"]), (.openLocationSheet, ["Cmd+K", "Cmd+Shift+G"]),
            (.rootTreeAtSelection, ["Cmd+Shift+R"]), (.refreshOrApplySearchSort, ["Cmd+R"]),
            (.goDocuments, []), (.goDesktop, []), (.goDownloads, []), (.goLibrary, []), (.goMacintoshHD, []),
            (.goApplications, []), (.goTrash, []), (.focusTreePane, []), (.focusContentPane, []),
            (.newWindow, ["Cmd+N"]), (.newTab, ["Cmd+T"]), (.closeTab, ["Cmd+W"]), (.reopenClosedTab, ["Cmd+Shift+T"]),
            (.selectNextTab, ["Ctrl+Tab", "Cmd+Shift+]"]), (.selectPreviousTab, ["Ctrl+Shift+Tab", "Cmd+Shift+["]),
            (.openSelectionInNewTab, []), (.openSelectionInNewWindow, []), (.moveTabToNewWindow, []),
            (.mergeAllWindows, []), (.openSelection, ["Cmd+O"]), (.openSelectedItem, ["Cmd+Down"]),
            (.editSelection, ["Cmd+Shift+E"]), (.quickLookSelection, ["Space"]), (.renameSelection, ["F2"]),
            (.duplicateSelection, ["Cmd+D"]), (.moveSelection, ["Cmd+Shift+M"]), (.newFolder, ["Cmd+Shift+N"]),
            (.trashSelection, ["Cmd+Backspace"]), (.ejectVolume, ["Cmd+E"]), (.emptyTrash, ["Cmd+Shift+Backspace"]),
            (.copyPath, ["Cmd+Option+C"]), (.openInTerminal, ["Cmd+Option+T"]), (.calculateSize, []),
            (.showClipboard, []), (.clearClipboard, []), (.showInFinder, []), (.toggleFavorite, []),
            (.focusFileSearch, ["Cmd+F"]), (.showLastSearchResults, ["Cmd+Shift+F"]), (.revealInFolder, []),
            (.viewAsIcons, ["Cmd+1"]), (.viewAsDetails, ["Cmd+2"]), (.viewAsList, ["Cmd+3"]),
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

    // The zoom commands and their keys (Cmd+Plus, Cmd+-, Cmd+0) are dropped by D-005.
    @Test func zoomHasNoCommandsAndNoKeys() {
        #expect(ShortcutCommandID(rawValue: "zoomIn") == nil)
        #expect(ShortcutCommandID(rawValue: "zoomOut") == nil)
        #expect(ShortcutCommandID(rawValue: "resetZoom") == nil)
        #expect(RendererCommand(rawValue: "zoomIn") == nil)
        #expect(Shortcuts.normalize("Cmd+Plus") == "Cmd+Plus")
        #expect(ShortcutCommands.defaultResolved.commandByShortcut["Cmd+Plus"] == nil)
    }
}
