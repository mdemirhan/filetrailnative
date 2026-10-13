// Port of the enable, check and label cases of apps/desktop/src/main/appMenu.test.ts (resolveApplicationMenuItemStates,
// applyApplicationMenuItemStates, undoMenuLabels). The menu's layout cases are P4-01's.
import Testing

@testable import FTFoundation

struct ApplicationMenuTests {
    typealias Window = ApplicationMenu.WindowFacts
    static let initial = ApplicationMenuState.initial
    static let explorerWindow = Window(explorerFocused: true)

    static func stateOf(
        _ id: String, _ state: ApplicationMenuState, _ window: Window = explorerWindow
    ) -> ApplicationMenuItemState {
        ApplicationMenu.itemStates(state, window: window).first { $0.id == id }
            ?? ApplicationMenuItemState(id: "missing \(id)")
    }

    static func enabledCommands(_ window: Window) -> [RendererCommand] {
        RendererCommand.allCases.filter {
            $0 != .toggleFavorite && $0 != .toggleFolderTree && stateOf($0.rawValue, initial, window).enabled == true
        }
    }

    // T-656a5201 F-083
    @Test func withNoExplorerWindowOpenOffersOnlyWhatOpensOneBesidesAnotherWindowsOwn() {
        let placesAndNewWindow: [RendererCommand] = [
            .openLocationSheet, .goHomeRootTree, .goDocuments, .goDesktop, .goDownloads, .goLibrary, .goMacintoshHD,
            .goApplications, .goTrash, .newWindow,
        ]
        #expect(
            Self.enabledCommands(Window(explorerFocused: false, explorerWindowCount: 0, otherWindowFocused: false))
                == placesAndNewWindow)
        // Settings has the keyboard: its text fields' edit commands and ⌘W work too.
        #expect(
            Self.enabledCommands(Window(explorerFocused: false, explorerWindowCount: 0, otherWindowFocused: true))
                == [.undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll]
                + placesAndNewWindow.dropLast() + [.newWindow, .closeTab])
    }

    // T-824991c2
    @Test func offersMergeAllWindowsOnlyWithAnotherExplorerWindowOpen() {
        let state = Self.initial
        #expect(Self.stateOf("mergeAllWindows", state).enabled == false)
        #expect(
            Self.stateOf("mergeAllWindows", state, Window(explorerFocused: true, explorerWindowCount: 1)).enabled
                == false)
        #expect(
            Self.stateOf("mergeAllWindows", state, Window(explorerFocused: true, explorerWindowCount: 2)).enabled
                == true)
        var disabled = state
        disabled.disabledCommands = [.mergeAllWindows]
        #expect(
            Self.stateOf("mergeAllWindows", disabled, Window(explorerFocused: true, explorerWindowCount: 2)).enabled
                == false)
    }

    // The original checks the menu template's ids against the states (P4-01 ports that); this checks that a state
    // exists for every command the menu can send.
    @Test func hasAStateForEveryCommand() {
        let ids = Set(ApplicationMenu.itemStates(Self.initial, window: Self.explorerWindow).map(\.id))
        for command in RendererCommand.allCases where command != .toggleFavorite && command != .toggleFolderTree {
            #expect(ids.contains(command.rawValue), "\(command)")
        }
        for id in [
            "undo:text", "redo:text", "toggleFavorite:add", "toggleFavorite:remove", "toggleFolderTree:hide",
            "toggleFolderTree:show",
        ] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(ids.count == RendererCommand.allCases.count - 2 + 6)
    }

    // T-0bd02d42 F-083
    @Test func dimsTheCommandsTheWindowSaysCanNotRun() {
        var state = Self.initial
        state.disabledCommands = [.renameSelection, .goBack, .toggleFavorite]
        #expect(Self.stateOf("renameSelection", state).enabled == false)
        #expect(Self.stateOf("goBack", state).enabled == false)
        #expect(Self.stateOf("toggleFavorite:add", state).enabled == false)
        #expect(Self.stateOf("toggleFavorite:remove", state).enabled == false)
        #expect(Self.stateOf("goForward", state).enabled == true)
        #expect(Self.stateOf("newTab", state).enabled == true)
    }

    // T-0b01a1ef
    @Test func checksWhatTheWindowShows() {
        var state = Self.initial
        state.viewMode = .details
        state.sortBy = .size
        state.foldersFirst = false
        state.hiddenFilesShown = true
        state.infoPanelOpen = true
        state.infoRowOpen = false
        var checked: [String: Bool] = [:]
        for item in ApplicationMenu.itemStates(state, window: Self.explorerWindow) {
            if let flag = item.checked { checked[item.id] = flag }
        }
        #expect(
            checked == [
                "viewAsIcons": false, "viewAsList": false, "viewAsDetails": true, "sortByName": false,
                "sortByModified": false, "sortBySize": true, "sortByKind": false, "toggleFoldersFirst": false,
                "toggleHiddenFiles": true, "toggleInfoPanel": true, "toggleInfoRow": false,
            ])
    }

    // T-23b75a4b
    @Test func offersToAddTheFolderToTheFavoritesOrToRemoveItOnceItIsOne() {
        var added = Self.initial
        added.favoriteIsSet = true
        #expect(Self.stateOf("toggleFavorite:add", Self.initial).visible == true)
        #expect(Self.stateOf("toggleFavorite:remove", Self.initial).visible == false)
        #expect(Self.stateOf("toggleFavorite:add", added).visible == false)
        #expect(Self.stateOf("toggleFavorite:remove", added).visible == true)
    }

    // T-ad3a5766
    @Test func offersHideFolderTreeWhileTheTreeIsShownAndShowFolderTreeWhileHidden() {
        var hidden = Self.initial
        hidden.folderTreeOpen = false
        #expect(Self.stateOf("toggleFolderTree:hide", Self.initial).visible == true)
        #expect(Self.stateOf("toggleFolderTree:show", Self.initial).visible == false)
        #expect(Self.stateOf("toggleFolderTree:hide", hidden).visible == false)
        #expect(Self.stateOf("toggleFolderTree:show", hidden).visible == true)
    }

    // T-03e46e54
    @Test func turnsTheFilesUndoAndRedoOnOnlyWhenThereIsSomethingToDo() {
        let window = Window(explorerFocused: true, undoAvailable: (undo: true, redo: false))
        #expect(Self.stateOf("undo", Self.initial, window).enabled == true)
        #expect(Self.stateOf("redo", Self.initial, window).enabled == false)
        // The window says no while an operation runs.
        var locked = Self.initial
        locked.disabledCommands = [.undo]
        #expect(Self.stateOf("undo", locked, window).enabled == false)
    }

    // T-475f0b44
    // The menu items themselves (their accelerators and what they send) are P4-01's; this is the state half.
    @Test func showsATextFieldsOwnUndoAndRedoInPlaceOfTheFilesWhileOneIsEdited() {
        var typing = Self.initial
        typing.textEditing = true
        #expect(Self.stateOf("undo", typing).visible == false)
        #expect(Self.stateOf("undo:text", typing).visible == true)
        #expect(Self.stateOf("undo", Self.initial).visible == true)
        #expect(Self.stateOf("redo:text", Self.initial).visible == false)
        // With no window at all there is nothing to undo.
        let none = Window(explorerFocused: false, explorerWindowCount: 0, otherWindowFocused: false)
        let textUndo = Self.stateOf("undo:text", Self.initial, none)
        #expect(textUndo.visible == true)
        #expect(textUndo.enabled == false)
    }

    // T-6b4c5aa9
    @Test func keepsATextFieldsUndoAndRedoOnWithNothingToUndoInTheFiles() {
        let window = Window(explorerFocused: true, undoAvailable: (undo: false, redo: false))
        var typing = Self.initial
        typing.textEditing = true
        #expect(Self.stateOf("undo", typing, window).enabled == true)
        #expect(Self.stateOf("redo", typing, window).enabled == true)
    }

    // T-49986070
    @Test func keepsOnlyTheEditCommandsCmdWAndNewWindowWhileAnotherWindowHasTheKeyboard() {
        let settingsFocused = Window(explorerFocused: false)
        #expect(
            Self.enabledCommands(settingsFocused) == [
                .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .newWindow, .closeTab,
            ])
        #expect(Self.stateOf("toggleFavorite:add", Self.initial, settingsFocused).enabled == false)
    }

    // MARK: Applying the states

    final class FakeItem: ApplicationMenu.ItemControl {
        var isEnabled = true
        var isVisible = true
        var isChecked = false
        let isRadio: Bool

        init(checked: Bool = false, radio: Bool = false) {
            isChecked = checked
            isRadio = radio
        }
    }

    // T-187b0b19
    @Test func setsWhatChangedAndSkipsItemsTheMenuDoesNotHave() {
        let rename = FakeItem()
        let hidden = FakeItem()
        let items = ["renameSelection": rename, "toggleHiddenFiles": hidden]
        ApplicationMenu.apply(
            [
                ApplicationMenuItemState(id: "renameSelection", enabled: false),
                ApplicationMenuItemState(id: "toggleHiddenFiles", enabled: true, checked: true),
                ApplicationMenuItemState(id: "copySelection", enabled: false),
            ], item: { items[$0] })
        #expect(!rename.isEnabled)
        #expect(rename.isVisible)
        #expect(!rename.isChecked)
        #expect(hidden.isEnabled)
        #expect(hidden.isChecked)
    }

    // T-363746ce
    @Test func onlyEverSwitchesARadioItemOn() {
        let list = FakeItem(checked: true, radio: true)
        let details = FakeItem(checked: false, radio: true)
        let items = ["viewAsList": list, "viewAsDetails": details]
        ApplicationMenu.apply(
            [
                ApplicationMenuItemState(id: "viewAsList", checked: false),
                ApplicationMenuItemState(id: "viewAsDetails", checked: true),
            ], item: { items[$0] })
        // The menu switches the rest of the group off when one is switched on.
        #expect(list.isChecked)
        #expect(details.isChecked)
    }

    // MARK: Undo and Redo labels

    // T-798fb5ef F-580
    @Test func namesWhatTheFilesUndoAndRedoWouldDo() {
        let named = ApplicationMenu.undoLabels(
            undo: "Move of “a.txt”", redo: "Rename", cantUndo: false, textEditing: false)
        #expect(named.undo == "Undo Move of “a.txt”")
        #expect(named.redo == "Redo Rename")
        let plain = ApplicationMenu.undoLabels(undo: nil, redo: nil, cantUndo: false, textEditing: false)
        #expect(plain.undo == "Undo")
        #expect(plain.redo == "Redo")
    }

    // T-dcc0a432 F-374 F-580
    @Test func saysCantUndoAfterAnOperationThatCantBeUndone() {
        let labels = ApplicationMenu.undoLabels(undo: nil, redo: nil, cantUndo: true, textEditing: false)
        #expect(labels.undo == "Can’t Undo")
    }

    // T-f8aba840
    @Test func saysJustUndoAndRedoWhileATextFieldHasTheKeyboard() {
        let labels = ApplicationMenu.undoLabels(
            undo: "Move of “a.txt”", redo: "Rename", cantUndo: false, textEditing: true)
        #expect(labels.undo == "Undo")
        #expect(labels.redo == "Redo")
    }

    // MARK: The menu state of the window

    @Test func buildsTheMenuStateFromWhatTheWindowCanRun() {
        let state = ApplicationMenuState.build(
            viewMode: .icons, sortBy: .kind, foldersFirst: false, hiddenFilesShown: true, folderTreeOpen: false,
            infoPanelOpen: true, infoRowOpen: true, favoriteIsSet: true, textEditing: true,
            canRun: { $0 == .newTab })
        #expect(!state.disabledCommands.contains(.newTab))
        #expect(state.disabledCommands.contains(.goBack))
        // A text field's Undo and Redo are always there.
        #expect(!state.disabledCommands.contains(.undo))
        #expect(!state.disabledCommands.contains(.redo))
        #expect(state.viewMode == .icons)
        #expect(state.sortBy == .kind)
        #expect(state.favoriteIsSet)
        let notEditing = ApplicationMenuState.build(
            viewMode: .list, sortBy: .name, foldersFirst: true, hiddenFilesShown: false, folderTreeOpen: true,
            infoPanelOpen: false, infoRowOpen: false, favoriteIsSet: false, textEditing: false, canRun: { _ in false })
        #expect(notEditing.disabledCommands == RendererCommand.allCases)
    }

    @Test func dropsCommandNamesItDoesNotKnow() {
        let state = ApplicationMenuState(
            disabledCommandNames: ["goBack", "zoomIn", "bogus", "newTab"], viewMode: .list, sortBy: .name,
            foldersFirst: true, hiddenFilesShown: false, folderTreeOpen: true, infoPanelOpen: false,
            infoRowOpen: false, favoriteIsSet: false, textEditing: false)
        #expect(state.disabledCommands == [.goBack, .newTab])
        #expect(ApplicationMenuState.initial.viewMode == .list)
        #expect(ApplicationMenuState.initial.disabledCommands == [])
    }
}
