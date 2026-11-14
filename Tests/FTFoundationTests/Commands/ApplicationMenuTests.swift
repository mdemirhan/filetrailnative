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

    static func enabledCommands(_ window: Window) -> [AppCommand] {
        AppCommand.allCases.filter { stateOf($0.rawValue, initial, window).enabled == true }
    }

    @Test func withNoExplorerWindowOpenOffersOnlyWhatOpensOneBesidesAnotherWindowsOwn() {
        let placesAndNewWindow: [AppCommand] = [
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

    // A state exists for every command the menu can send, and one only.
    @Test func hasAStateForEveryCommand() {
        let ids = ApplicationMenu.itemStates(Self.initial, window: Self.explorerWindow).map(\.id)
        #expect(ids == AppCommand.allCases.map(\.rawValue))
    }

    @Test func dimsTheCommandsTheWindowSaysCanNotRun() {
        var state = Self.initial
        state.disabledCommands = [.renameSelection, .goBack, .toggleFavorite]
        #expect(Self.stateOf("renameSelection", state).enabled == false)
        #expect(Self.stateOf("goBack", state).enabled == false)
        #expect(Self.stateOf("toggleFavorite", state).enabled == false)
        #expect(Self.stateOf("goForward", state).enabled == true)
        #expect(Self.stateOf("newTab", state).enabled == true)
    }

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
                "toggleHiddenFiles": true, "toggleInfoPanel": true, "toggleInfoRow": false, "toggleTwoPanes": false,
                "togglePinFilter": false, "viewAsPreviews": false,
            ])
    }

    @Test func offersToAddTheFolderToTheFavoritesOrToRemoveItOnceItIsOne() {
        var added = Self.initial
        added.favoriteIsSet = true
        #expect(Self.stateOf("toggleFavorite", Self.initial).title == "Add to Favorites")
        #expect(Self.stateOf("toggleFavorite", added).title == "Remove from Favorites")
    }

    @Test func offersHideFolderTreeWhileTheTreeIsShownAndShowFolderTreeWhileHidden() {
        var hidden = Self.initial
        hidden.folderTreeOpen = false
        #expect(Self.stateOf("toggleFolderTree", Self.initial).title == "Hide Folder Tree")
        #expect(Self.stateOf("toggleFolderTree", hidden).title == "Show Folder Tree")
    }

    // The size commands name what they change: the icons in the Icons view, the columns in the Compact List.
    @Test func namesTheSizeCommandsForTheViewOnScreen() {
        var state = Self.initial
        let titles = { (state: ApplicationMenuState) in
            [AppCommand.increaseSize, .decreaseSize, .resetSize].map { Self.stateOf($0.rawValue, state).title }
        }
        state.viewMode = .icons
        #expect(titles(state) == ["Make Icons Bigger", "Make Icons Smaller", "Default Icon Size"])
        state.viewMode = .list
        #expect(titles(state) == ["Make Columns Wider", "Make Columns Narrower", "Default Column Width"])
        state.viewMode = .details
        #expect(titles(state) == ["Make Bigger", "Make Smaller", "Default Size"])
        // With no explorer window to act on, they name no view.
        let none = Window(explorerFocused: false, explorerWindowCount: 0, otherWindowFocused: false)
        #expect(
            [AppCommand.increaseSize, .decreaseSize, .resetSize].map {
                Self.stateOf($0.rawValue, Self.initial, none).title
            }
                == ["Make Bigger", "Make Smaller", "Default Size"])
    }

    @Test func turnsTheFilesUndoAndRedoOnOnlyWhenThereIsSomethingToDo() {
        let window = Window(explorerFocused: true, undoAvailable: (undo: true, redo: false))
        #expect(Self.stateOf("undo", Self.initial, window).enabled == true)
        #expect(Self.stateOf("redo", Self.initial, window).enabled == false)
        // The window says no while an operation runs.
        var locked = Self.initial
        locked.disabledCommands = [.undo]
        #expect(Self.stateOf("undo", locked, window).enabled == false)
    }

    @Test func givesTheFilesUndoAndRedoItemsWhatTheyWouldDoAsTitles() {
        let window = Window(explorerFocused: true, undoLabels: (undo: "Undo Move of “a.txt”", redo: "Redo Rename"))
        #expect(Self.stateOf("undo", Self.initial, window).title == "Undo Move of “a.txt”")
        #expect(Self.stateOf("redo", Self.initial, window).title == "Redo Rename")
        #expect(Self.stateOf("undo", Self.initial).title == "Undo")
        #expect(Self.stateOf("redo", Self.initial).title == "Redo")
    }

    // The menu items themselves (their accelerators and what they send) are tested elsewhere; this is the state half.
    @Test func showsATextFieldsOwnUndoAndRedoInPlaceOfTheFilesWhileOneIsEdited() {
        let named = Window(explorerFocused: true, undoLabels: (undo: "Undo Move of “a.txt”", redo: "Redo Rename"))
        var typing = Self.initial
        typing.textEditing = true
        #expect(Self.stateOf("undo", typing, named).title == "Undo")
        #expect(Self.stateOf("redo", typing, named).title == "Redo")
        #expect(Self.stateOf("undo", Self.initial, named).title == "Undo Move of “a.txt”")
        // Another window has the keyboard: its own too.
        let settings = Window(explorerFocused: false, undoLabels: (undo: "Undo Move of “a.txt”", redo: "Redo Rename"))
        #expect(Self.stateOf("undo", Self.initial, settings).title == "Undo")
        #expect(Self.stateOf("undo", Self.initial, settings).enabled == true)
        // With no window at all there is nothing to undo.
        let none = Window(explorerFocused: false, explorerWindowCount: 0, otherWindowFocused: false)
        let textUndo = Self.stateOf("undo", Self.initial, none)
        #expect(textUndo.title == "Undo")
        #expect(textUndo.enabled == false)
    }

    @Test func keepsATextFieldsUndoAndRedoOnWithNothingToUndoInTheFiles() {
        let window = Window(explorerFocused: true, undoAvailable: (undo: false, redo: false))
        var typing = Self.initial
        typing.textEditing = true
        #expect(Self.stateOf("undo", typing, window).enabled == true)
        #expect(Self.stateOf("redo", typing, window).enabled == true)
    }

    @Test func keepsOnlyTheEditCommandsCmdWAndNewWindowWhileAnotherWindowHasTheKeyboard() {
        let settingsFocused = Window(explorerFocused: false)
        #expect(
            Self.enabledCommands(settingsFocused) == [
                .undo, .redo, .editCut, .editCopy, .editPaste, .editSelectAll, .newWindow, .closeTab,
            ])
        #expect(Self.stateOf("toggleFavorite", Self.initial, settingsFocused).enabled == false)
    }

    // MARK: Applying the states

    final class FakeItem: ApplicationMenu.ItemControl {
        var isEnabled = true
        var isChecked = false
        var title = ""

        init(checked: Bool = false) {
            isChecked = checked
        }
    }

    @Test func setsWhatChangedAndSkipsItemsTheMenuDoesNotHave() {
        let rename = FakeItem()
        let hidden = FakeItem()
        let items = ["renameSelection": rename, "toggleHiddenFiles": hidden]
        ApplicationMenu.apply(
            [
                ApplicationMenuItemState(id: "renameSelection", enabled: false),
                ApplicationMenuItemState(id: "toggleHiddenFiles", enabled: true, checked: true),
                ApplicationMenuItemState(id: "copySelection", enabled: false),
                ApplicationMenuItemState(id: "renameSelection", title: "Rename"),
            ], item: { items[$0] })
        #expect(rename.title == "Rename")
        #expect(hidden.title.isEmpty)
        #expect(!rename.isEnabled)
        #expect(!rename.isChecked)
        #expect(hidden.isEnabled)
        #expect(hidden.isChecked)
    }

    // Every mark is set from the state, off as well as on: no item switches another.
    @Test func switchesEachMarkOnOrOffAsTheStateSays() {
        let list = FakeItem(checked: true)
        let details = FakeItem(checked: false)
        let items = ["viewAsList": list, "viewAsDetails": details]
        ApplicationMenu.apply(
            [
                ApplicationMenuItemState(id: "viewAsList", checked: false),
                ApplicationMenuItemState(id: "viewAsDetails", checked: true),
            ], item: { items[$0] })
        #expect(!list.isChecked)
        #expect(details.isChecked)
    }

    // MARK: Undo and Redo labels

    @Test func namesWhatTheFilesUndoAndRedoWouldDo() {
        let named = ApplicationMenu.undoLabels(undo: "Move of “a.txt”", redo: "Rename", cantUndo: false)
        #expect(named.undo == "Undo Move of “a.txt”")
        #expect(named.redo == "Redo Rename")
        let plain = ApplicationMenu.undoLabels(undo: nil, redo: nil, cantUndo: false)
        #expect(plain.undo == "Undo")
        #expect(plain.redo == "Redo")
    }

    @Test func saysCantUndoAfterAnOperationThatCantBeUndone() {
        let labels = ApplicationMenu.undoLabels(undo: nil, redo: nil, cantUndo: true)
        #expect(labels.undo == "Can’t Undo")
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
        #expect(notEditing.disabledCommands == AppCommand.allCases)
    }
}
