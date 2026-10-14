// Port of apps/desktop/src/renderer/lib/rendererCommandAvailability.test.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct CommandAvailabilityTests {
    typealias Context = CommandAvailabilityContext

    static func file(_ path: String) -> CommandEntry { CommandEntry(path: path, kind: .file) }
    static func directory(_ path: String) -> CommandEntry { CommandEntry(path: path, kind: .directory) }

    static func shortcutContext(
        focusedPane: FocusedPane? = .content, mainView: MainView = .explorer, copyPasteModalOpen: Bool = false,
        selectedTreeTargetKind: SelectedTreeTargetKind? = nil
    ) -> ShortcutContext {
        ShortcutContext(
            copyPasteModalOpen: copyPasteModalOpen, focusedPane: focusedPane, mainView: mainView,
            selectedTreeTargetKind: selectedTreeTargetKind)
    }

    /// The original's `availabilityContext()`: one file selected in /Users/demo, an empty clipboard.
    static func context(
        _ configure: (inout Context) -> Void = { _ in }
    ) -> Context {
        let entries = [file("/Users/demo/file.txt"), file("/Users/demo/notes.md")]
        var context = Context(
            shortcutContext: shortcutContext(), currentPath: "/Users/demo",
            selectedPathsInViewOrder: ["/Users/demo/file.txt"], activeContentEntries: entries,
            selectedEntry: entries[0], selectedTreeTargetPath: nil, clipboardHasItems: false,
            pasteDestinationPath: "/Users/demo", isSearchMode: false, openItemLimit: 5, writeOperationLocked: false)
        configure(&context)
        return context
    }

    static func run(_ command: RendererCommand, _ context: Context) -> Bool {
        CommandAvailability.canRun(command, context)
    }

    // T-0cb7701a F-002
    @Test func disablesSelectionCommandsWithoutAContentSelection() {
        let context = Self.context {
            $0.selectedPathsInViewOrder = []
            $0.selectedEntry = nil
        }
        for command in [
            RendererCommand.openSelection, .editSelection, .copySelection, .cutSelection, .moveSelection,
            .renameSelection, .duplicateSelection, .trashSelection, .copyPath,
        ] {
            #expect(!Self.run(command, context), "\(command)")
        }
    }

    // T-c81f8a3d F-004
    @Test func requiresAReadyClipboardAndDestinationForPaste() {
        #expect(!Self.run(.pasteSelection, Self.context { $0.clipboardHasItems = false }))
        #expect(
            !Self.run(
                .pasteSelection,
                Self.context {
                    $0.clipboardHasItems = true
                    $0.pasteDestinationPath = nil
                }))
        #expect(Self.run(.pasteSelection, Self.context { $0.clipboardHasItems = true }))
    }

    // T-a6627a45 F-083
    @Test func copiesAndCutsTheTreesFolderFromTheTreeWhateverTheListHasSelected() {
        func treeContext(_ path: String?) -> Context {
            Self.context {
                $0.shortcutContext = Self.shortcutContext(
                    focusedPane: .tree, selectedTreeTargetKind: path == nil ? nil : .filesystemFolder)
                $0.selectedTreeTargetPath = path
                $0.selectedPathsInViewOrder = []
                $0.selectedEntry = nil
            }
        }
        for command in [RendererCommand.copySelection, .cutSelection] {
            #expect(Self.run(command, treeContext("/Users/demo")))
            #expect(!Self.run(command, treeContext(nil)))
        }
    }

    // T-3bde1910 F-005
    @Test func showsAndClearsTheClipboardOnlyWhileItHoldsSomething() {
        let filled = Self.context { $0.clipboardHasItems = true }
        for command in [RendererCommand.showClipboard, .clearClipboard] {
            #expect(!Self.run(command, Self.context()))
            #expect(Self.run(command, filled))
        }
    }

    // T-7c0d1c60 F-002
    @Test func requiresEditableFilesAndRespectsTheOpenItemLimitForEdit() {
        let textFile = Self.file("/Users/demo/file.txt")
        let folder = Self.directory("/Users/demo/Folder")
        #expect(
            Self.run(
                .editSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = [textFile.path]
                    $0.activeContentEntries = [textFile]
                    $0.selectedEntry = textFile
                }))
        #expect(
            !Self.run(
                .editSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = [folder.path]
                    $0.activeContentEntries = [folder]
                    $0.selectedEntry = folder
                }))
        #expect(
            !Self.run(
                .editSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = ["/Users/demo/file.txt", "/Users/demo/notes.md"]
                    $0.activeContentEntries = [textFile, Self.file("/Users/demo/notes.md")]
                    $0.selectedEntry = textFile
                    $0.openItemLimit = 1
                }))
    }

    // T-9b208ff7 F-002
    @Test func requiresASelectedItemAndRespectsTheOpenItemLimitForOpen() {
        #expect(
            !Self.run(
                .openSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = []
                    $0.selectedEntry = nil
                }))
        #expect(
            !Self.run(
                .openSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = ["/Users/demo/file.txt", "/Users/demo/notes.md"]
                    $0.openItemLimit = 1
                }))
    }

    // T-eefbaafe F-083
    @Test func allowsTreeSafeOpenTerminalAndCopyPathCommandsOnlyWithATreeTarget() {
        let withTarget = Self.context {
            $0.shortcutContext = Self.shortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
            $0.selectedPathsInViewOrder = []
            $0.selectedEntry = nil
            $0.selectedTreeTargetPath = "/Users/demo/Folder"
        }
        #expect(Self.run(.openSelection, withTarget))
        #expect(Self.run(.openInTerminal, withTarget))
        #expect(Self.run(.copyPath, withTarget))

        let withoutTarget = Self.context {
            $0.shortcutContext = Self.shortcutContext(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
            $0.selectedPathsInViewOrder = []
            $0.selectedEntry = nil
            $0.selectedTreeTargetPath = nil
        }
        #expect(!Self.run(.openSelection, withoutTarget))
        #expect(!Self.run(.openInTerminal, withoutTarget))
        #expect(!Self.run(.copyPath, withoutTarget))
    }

    // T-fe502f1e
    @Test func allowsOpenInTerminalFromContentWithNoSelectionWhenAFolderIsOpen() {
        #expect(
            Self.run(
                .openInTerminal,
                Self.context {
                    $0.selectedPathsInViewOrder = []
                    $0.selectedEntry = nil
                    $0.currentPath = "/Users/demo"
                }))
    }

    // T-9ea9571e F-003
    // Finding files, then moving, renaming, duplicating or trashing them, is a Finder flow.
    @Test func letsSearchResultsBeMovedRenamedDuplicatedAndTrashedButNotPastedInto() {
        let search = Self.context {
            $0.isSearchMode = true
            $0.selectedPathsInViewOrder = ["/Users/demo/file.txt"]
            $0.pasteDestinationPath = nil
        }
        #expect(Self.run(.moveSelection, search))
        #expect(Self.run(.renameSelection, search))
        #expect(Self.run(.duplicateSelection, search))
        #expect(Self.run(.trashSelection, search))
        #expect(!Self.run(.newFolder, search))
        #expect(!Self.run(.pasteSelection, search))
    }

    // T-62605ecc F-003
    // A duplicate goes next to its original: results from two folders have no one folder.
    @Test func duplicatesSearchResultsOnlyWhenTheyShareAFolder() {
        let fromTwoFolders = Self.context {
            $0.isSearchMode = true
            $0.selectedPathsInViewOrder = ["/Users/demo/a.txt", "/Users/demo/Folder/b.txt"]
        }
        let fromOneFolder = Self.context {
            $0.isSearchMode = true
            $0.selectedPathsInViewOrder = ["/Users/demo/a.txt", "/Users/demo/b.txt"]
        }
        #expect(!Self.run(.duplicateSelection, fromTwoFolders))
        #expect(Self.run(.duplicateSelection, fromOneFolder))
        // Several results are renamed in the Rename sheet, each in its own folder.
        #expect(Self.run(.renameSelection, fromTwoFolders))
    }

    // T-dad828ed
    @Test func allowsNewFolderWheneverThereIsAFolderToMakeItIn() {
        #expect(
            Self.run(
                .newFolder,
                Self.context {
                    $0.selectedPathsInViewOrder = []
                    $0.selectedEntry = nil
                }))
        #expect(
            Self.run(
                .newFolder,
                Self.context {
                    $0.selectedPathsInViewOrder = ["/Users/demo/Folder"]
                    $0.activeContentEntries = [Self.directory("/Users/demo/Folder")]
                    $0.selectedEntry = Self.directory("/Users/demo/Folder")
                }))
        // With files selected, or several items, the folder goes into the folder on screen.
        #expect(
            Self.run(
                .newFolder,
                Self.context { $0.selectedPathsInViewOrder = ["/Users/demo/file.txt", "/Users/demo/notes.md"] }))
        #expect(
            !Self.run(
                .newFolder,
                Self.context {
                    $0.currentPath = ""
                    $0.selectedPathsInViewOrder = ["/Users/demo/file.txt"]
                }))
    }

    // T-d06fc2bd
    @Test func renamesOneSelectedItemInItsRowAndSeveralInTheRenameSheet() {
        #expect(Self.run(.renameSelection, Self.context { $0.selectedPathsInViewOrder = ["/Users/demo/file.txt"] }))
        #expect(
            Self.run(
                .renameSelection,
                Self.context { $0.selectedPathsInViewOrder = ["/Users/demo/file.txt", "/Users/demo/notes.md"] }))
        #expect(
            !Self.run(
                .renameSelection,
                Self.context {
                    $0.selectedPathsInViewOrder = []
                    $0.selectedEntry = nil
                }))
    }

    // T-fc267c38 F-001
    @Test func disablesWhatWouldStartAnotherOperationWhileAWriteOperationIsInFlight() {
        let context = Self.context {
            $0.writeOperationLocked = true
            $0.clipboardHasItems = true
        }
        #expect(!Self.run(.pasteSelection, context))
        #expect(!Self.run(.moveSelection, context))
        #expect(!Self.run(.newFolder, context))
        #expect(Self.run(.openSelection, context))
        // Filling the clipboard starts nothing, so it is not held back.
        #expect(Self.run(.copySelection, context))
        #expect(Self.run(.cutSelection, context))
        #expect(Self.run(.copyPath, context))
    }

    // T-639007a7 F-083
    @Test func stillRequiresContentFocusForContentOnlyActions() {
        #expect(!Self.run(.copySelection, Self.context { $0.shortcutContext = Self.shortcutContext(focusedPane: nil) }))
    }

    // MARK: Menu commands

    static let folder = directory("/Users/demo/Projects")
    static let note = file("/Users/demo/notes.md")
    static let entries = [folder, note]

    static func select(_ selected: CommandEntry..., configure: (inout Context) -> Void = { _ in }) -> Context {
        context {
            $0.activeContentEntries = entries
            $0.selectedPathsInViewOrder = selected.map(\.path)
            $0.selectedEntry = selected.first
            configure(&$0)
        }
    }

    static func treeFocused(_ path: String?, configure: (inout Context) -> Void = { _ in }) -> Context {
        context {
            $0.shortcutContext = shortcutContext(
                focusedPane: .tree, selectedTreeTargetKind: path == nil ? nil : .filesystemFolder)
            $0.activeContentEntries = entries
            $0.selectedPathsInViewOrder = []
            $0.selectedEntry = nil
            $0.selectedTreeTargetPath = path
            configure(&$0)
        }
    }

    static func target(_ context: Context) -> CommandAvailability.TargetContext {
        CommandAvailability.TargetContext(context)
    }

    // T-6c4cf0a0 F-083
    @Test func opensOneSelectedFolderOrTheTreesFolderInANewTab() {
        let run = { (context: Context) in Self.run(.openSelectionInNewTab, context) }
        #expect(run(Self.select(Self.folder)))
        #expect(!run(Self.select(Self.note)))
        #expect(!run(Self.select(Self.folder, Self.note)))
        #expect(!run(Self.select()))
        #expect(run(Self.treeFocused("/Users")))
        #expect(!run(Self.treeFocused(nil)))
        #expect(CommandAvailability.newTabTargetPath(Self.target(Self.treeFocused("/Users"))) == "/Users")
    }

    // T-cddfbbe4
    @Test func needsASelectedItemForQuickLook() {
        #expect(Self.run(.quickLookSelection, Self.select(Self.note)))
        #expect(!Self.run(.quickLookSelection, Self.select()))
        #expect(!Self.run(.quickLookSelection, Self.treeFocused("/Users")))
    }

    // T-2afa9f93 F-005
    @Test func addsTheSelectedFolderToTheFavoritesOrTheFolderOnScreenWithNothingSelected() {
        func favorite(_ context: Context) -> String? {
            CommandAvailability.favoriteTargetPath(Self.target(context))
        }
        #expect(favorite(Self.select(Self.folder)) == "/Users/demo/Projects")
        #expect(favorite(Self.select()) == "/Users/demo")
        #expect(favorite(Self.select(Self.note)) == nil)
        #expect(favorite(Self.select(Self.folder, Self.note)) == nil)
        #expect(favorite(Self.treeFocused("/Users")) == "/Users")
        // Search results are not a folder, and Trash is a favorite that stays.
        #expect(favorite(Self.select { $0.isSearchMode = true }) == nil)
        #expect(
            favorite(Self.treeFocused("/Users/demo/.Trash") { $0.trashPath = "/Users/demo/.Trash" }) == nil)
        #expect(Self.run(.toggleFavorite, Self.select(Self.folder)))
        #expect(!Self.run(.toggleFavorite, Self.select(Self.note)))
    }

    // T-fd1f6836
    @Test func showsTheSelectionInFinderOrTheFolderOnScreenWithNothingSelected() {
        func paths(_ context: Context) -> [String] {
            CommandAvailability.showInFinderPaths(Self.target(context))
        }
        #expect(paths(Self.select(Self.folder, Self.note)) == ["/Users/demo/Projects", "/Users/demo/notes.md"])
        #expect(paths(Self.select()) == ["/Users/demo"])
        #expect(paths(Self.treeFocused("/Users")) == ["/Users"])
        #expect(Self.run(.showInFinder, Self.select()))
        #expect(!Self.run(.showInFinder, Self.select { $0.currentPath = "" }))
    }

    // T-d7f1f781
    @Test func sizesTheSelectedFoldersOrTheFolderOnScreenWithNothingSelected() {
        func paths(_ context: Context) -> [String] {
            CommandAvailability.calculateSizePaths(Self.target(context))
        }
        #expect(paths(Self.select(Self.folder, Self.note)) == ["/Users/demo/Projects"])
        #expect(paths(Self.select()) == ["/Users/demo"])
        #expect(paths(Self.treeFocused("/Users")) == ["/Users"])
        // A location row (Home, a disk) in the tree shows its folder: that one is sized, never what is left selected
        // in the list.
        #expect(paths(Self.treeFocused(nil)) == ["/Users/demo"])
        let folder = Self.folder
        #expect(
            paths(
                Self.treeFocused(nil) {
                    $0.selectedPathsInViewOrder = [folder.path]
                    $0.selectedEntry = folder
                }) == ["/Users/demo"])
        #expect(Self.run(.calculateSize, Self.treeFocused(nil)))
        // Files alone have their size already; search results are no folder on screen.
        #expect(paths(Self.select(Self.note)) == [])
        #expect(paths(Self.select { $0.isSearchMode = true }) == [])
        #expect(Self.run(.calculateSize, Self.select(Self.folder)))
        #expect(!Self.run(.calculateSize, Self.select(Self.note)))
    }

    // T-e0d3c6ad F-005
    @Test func revealsASelectedSearchResultInItsFolderAndOnlyASearchResult() {
        #expect(Self.run(.revealInFolder, Self.select(Self.note) { $0.isSearchMode = true }))
        #expect(!Self.run(.revealInFolder, Self.select { $0.isSearchMode = true }))
        #expect(!Self.run(.revealInFolder, Self.select(Self.note)))
    }

    // T-ded2e1c3 F-006
    @Test func followsTheHistoryForBackAndForward() {
        #expect(!Self.run(.goBack, Self.select { $0.canGoBack = false }))
        #expect(Self.run(.goBack, Self.select { $0.canGoBack = true }))
        #expect(!Self.run(.goForward, Self.select { $0.canGoForward = false }))
        #expect(Self.run(.goForward, Self.select { $0.canGoForward = true }))
    }

    // T-d06ec78b F-006
    @Test func hasNoEnclosingFolderAtTheTopOfTheDisk() {
        #expect(Self.run(.goEnclosingFolder, Self.select()))
        #expect(!Self.run(.goEnclosingFolder, Self.select { $0.currentPath = "/" }))
        #expect(!Self.run(.goEnclosingFolder, Self.select { $0.currentPath = "" }))
    }

    // T-0ac6221f F-006
    @Test func leavesTheOrderOfSearchResultsToTheResultsBar() {
        let searching = Self.select { $0.isSearchMode = true }
        for command in [
            RendererCommand.sortByName, .sortByModified, .sortBySize, .sortByKind, .toggleFoldersFirst,
        ] {
            #expect(Self.run(command, Self.select()), "\(command)")
            #expect(!Self.run(command, searching), "\(command)")
        }
    }

    // T-2ae13f7b
    @Test func bringsBackTheLastResultsOnlyWhenThereAreSomeAndTheyAreNotOnScreen() {
        let withSearch = Self.select { $0.hasCachedSearch = true }
        #expect(Self.run(.showLastSearchResults, withSearch))
        #expect(!Self.run(.showLastSearchResults, Self.select { $0.hasCachedSearch = false }))
        #expect(
            !Self.run(
                .showLastSearchResults,
                Self.select {
                    $0.hasCachedSearch = true
                    $0.isSearchMode = true
                }))
    }

    // T-097a0447 F-006
    @Test func needsASecondTabToMoveBetweenTabs() {
        #expect(!Self.run(.selectNextTab, Self.select { $0.tabCount = 1 }))
        #expect(Self.run(.selectPreviousTab, Self.select { $0.tabCount = 3 }))
    }

    // T-c6d07093 F-083
    @Test func opensHelpFromTheHelpPageTooButNotOverADialog() {
        let onHelp = Self.select { $0.shortcutContext = Self.shortcutContext(mainView: .help) }
        let overDialog = Self.select { $0.shortcutContext = Self.shortcutContext(copyPasteModalOpen: true) }
        #expect(Self.run(.openKeyboardShortcuts, onHelp))
        #expect(!Self.run(.goBack, onHelp))
        #expect(!Self.run(.openHelp, overDialog))
    }

    // T-c08837a1
    // ⌘A in a big folder once took seconds here: every command looked up every selected item by walking the whole
    // listing. The bound is far above the few milliseconds it takes now.
    @Test func buildsTheMenuStateForABigFolderWithEverythingSelectedWithoutAFreeze() {
        let entries = (0..<20_000).map { index in
            index % 10 == 0
                ? Self.directory("/Users/demo/big/folder-\(index)") : Self.file("/Users/demo/big/photo-\(index).jpg")
        }
        let context = Self.context {
            $0.currentPath = "/Users/demo/big"
            $0.activeContentEntries = entries
            $0.selectedPathsInViewOrder = entries.map(\.path)
            $0.selectedEntry = entries.last
            $0.homePath = "/Users/demo"
        }
        // CPU time of this thread, not wall time, so a busy machine does not fail it.
        let (state, elapsed) = CPUTime.measureThread {
            ApplicationMenuState.build(
                viewMode: .list, sortBy: .name, foldersFirst: true, hiddenFilesShown: false, folderTreeOpen: true,
                infoPanelOpen: false, infoRowOpen: false, favoriteIsSet: false, textEditing: false,
                canRun: { CommandAvailability.canRun($0, context) })
        }
        #expect(state.disabledCommands.contains(.editSelection))
        #expect(!state.disabledCommands.contains(.calculateSize))
        #expect(!state.disabledCommands.contains(.copySelection))
        #expect(elapsed < 1)
    }

    // F-003 F-004
    @Test func theTrashAndEjectRules() {
        let inTrash = Self.context {
            $0.homePath = "/Users/demo"
            $0.selectedPathsInViewOrder = ["/Users/demo/.Trash/old.txt"]
        }
        #expect(!Self.run(.trashSelection, inTrash))
        #expect(!Self.run(.duplicateSelection, inTrash))
        #expect(Self.run(.renameSelection, inTrash))
        #expect(Self.run(.trashSelection, Self.context { $0.homePath = "/Users/demo" }))
        #expect(
            !Self.run(
                .newFolder,
                Self.context {
                    $0.currentPath = "/Users/demo/.Trash"
                    $0.homePath = "/Users/demo"
                }))

        #expect(Self.run(.emptyTrash, Self.context()))
        #expect(Self.run(.emptyTrash, Self.context { $0.trashIsEmpty = false }))
        #expect(!Self.run(.emptyTrash, Self.context { $0.trashIsEmpty = true }))
        #expect(!Self.run(.ejectVolume, Self.context()))
        #expect(Self.run(.ejectVolume, Self.context { $0.ejectTargetPath = "/Volumes/Backup" }))
    }

    // F-006
    @Test func theGoPlacesNeedTheHomeFolderExceptTheDiskAndApplications() {
        #expect(Self.run(.goMacintoshHD, Self.context()))
        #expect(Self.run(.goApplications, Self.context()))
        #expect(!Self.run(.goDocuments, Self.context()))
        #expect(Self.run(.goDocuments, Self.context { $0.homePath = "/Users/demo" }))
        #expect(Self.run(.goTrash, Self.context { $0.homePath = "/Users/demo" }))
        #expect(!Self.run(.goTrash, Self.context { $0.homePath = "" }))
    }
}
