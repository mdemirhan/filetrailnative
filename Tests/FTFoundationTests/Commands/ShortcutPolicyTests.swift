// Port of apps/desktop/src/renderer/lib/shortcutPolicy.test.ts
import Testing

@testable import FTFoundation

struct ShortcutPolicyTests {
    static func ctx(
        actionNoticeOpen: Bool = false, copyPasteModalOpen: Bool = false, focusedPane: FocusedPane? = .content,
        locationSheetOpen: Bool = false, mainView: MainView = .explorer,
        selectedTreeTargetKind: SelectedTreeTargetKind? = nil
    ) -> ShortcutContext {
        ShortcutContext(
            actionNoticeOpen: actionNoticeOpen, copyPasteModalOpen: copyPasteModalOpen, focusedPane: focusedPane,
            locationSheetOpen: locationSheetOpen, mainView: mainView, selectedTreeTargetKind: selectedTreeTargetKind)
    }

    static func handle(_ command: RendererCommand, _ context: ShortcutContext) -> Bool {
        ShortcutPolicy.canHandle(command, context)
    }

    static func raw(_ shortcut: RawExplorerShortcutID, _ context: ShortcutContext) -> Bool {
        ShortcutPolicy.canHandleRaw(shortcut, context)
    }

    // T-a4cb0582 F-083
    @Test func pastesIntoTheFolderOnScreenEvenWhenNoPaneHasFocus() {
        #expect(Self.handle(.pasteSelection, Self.ctx(focusedPane: nil)))
        #expect(!Self.handle(.pasteSelection, Self.ctx(focusedPane: nil, mainView: .help)))
        // Other content commands still need the file list.
        #expect(!Self.handle(.copySelection, Self.ctx(focusedPane: nil)))
    }

    // T-66231064 F-083
    @Test func allowsExplorerScopedCommandsInTheExplorerView() {
        #expect(Self.handle(.copyPath, Self.ctx()))
    }

    // T-494df166 F-083
    @Test func blocksExplorerScopedCommandsInHelpAndSettingsViews() {
        #expect(!Self.handle(.copyPath, Self.ctx(mainView: .help)))
        #expect(!Self.handle(.copyPath, Self.ctx(mainView: .settings)))
        #expect(!Self.handle(.focusFileSearch, Self.ctx(mainView: .help)))
        #expect(!Self.handle(.openLocationSheet, Self.ctx(mainView: .settings)))
    }

    // T-210cc8bf F-083
    // The zoom commands are dropped (D-005), so only Settings is checked.
    @Test func keepsSettingsAvailableOnNonExplorerViews() {
        #expect(Self.handle(.openSettings, Self.ctx(mainView: .help)))
    }

    // T-e8df5f44 F-083
    @Test func keepsGenericEditCommandsAvailableRegardlessOfTheActiveView() {
        #expect(Self.handle(.editCopy, Self.ctx(focusedPane: .tree, mainView: .help)))
        #expect(
            Self.handle(
                .editSelectAll,
                Self.ctx(
                    actionNoticeOpen: true, copyPasteModalOpen: true, focusedPane: .tree, locationSheetOpen: true,
                    mainView: .settings)))
    }

    // T-c6b12327 F-083
    @Test func blocksContentCapturingCommandsWhileTransientOverlaysAreOpen() {
        #expect(!Self.handle(.openSelection, Self.ctx(copyPasteModalOpen: true)))
        #expect(!Self.handle(.copySelection, Self.ctx(actionNoticeOpen: true)))
        #expect(!Self.handle(.openSettings, Self.ctx(actionNoticeOpen: true)))
    }

    // T-16e0aa3f F-083
    @Test func keepsExplorerKeyboardShortcutsScopedToTheExplorerSurface() {
        #expect(ShortcutPolicy.canHandleExplorerKeyboardShortcuts(Self.ctx()))
        #expect(!ShortcutPolicy.canHandleExplorerKeyboardShortcuts(Self.ctx(mainView: .help)))
        #expect(!ShortcutPolicy.canHandleExplorerKeyboardShortcuts(Self.ctx(locationSheetOpen: true)))
    }

    // T-3b956017 F-083
    @Test func blocksContentOnlyRendererCommandsWhenTheTreeIsFocused() {
        #expect(!Self.handle(.newFolder, Self.ctx(focusedPane: .tree)))
    }

    // T-1c6942ba F-083
    @Test func blocksContentOnlyRendererCommandsWhenNoExplorerPaneIsFocused() {
        #expect(!Self.handle(.newFolder, Self.ctx(focusedPane: nil)))
        #expect(!Self.handle(.copySelection, Self.ctx(focusedPane: nil)))
        #expect(!Self.handle(.openSelection, Self.ctx(focusedPane: nil)))
        #expect(!Self.handle(.copyPath, Self.ctx(focusedPane: nil)))
    }

    // T-0549b302 F-083
    @Test func keepsGlobalRendererCommandsAvailableWhenTheTreeIsFocused() {
        #expect(Self.handle(.focusFileSearch, Self.ctx(focusedPane: .tree)))
        #expect(Self.handle(.refreshOrApplySearchSort, Self.ctx(focusedPane: .tree)))
    }

    // T-17185cd3 F-083
    @Test func blocksContentOnlyRawShortcutsWhenTheTreeIsFocused() {
        #expect(!Self.raw(.copySelection, Self.ctx(focusedPane: .tree)))
        #expect(!Self.raw(.newFolder, Self.ctx(focusedPane: .tree)))
    }

    // T-51dd068f F-083
    @Test func keepsAllowedRawShortcutsAvailableWhenTheTreeIsFocused() {
        #expect(Self.raw(.treeArrowNavigation, Self.ctx(focusedPane: .tree)))
        #expect(Self.raw(.focusFileSearch, Self.ctx(focusedPane: .tree)))
    }

    private func contentOnlyCommands(_ context: ShortcutContext) -> [RendererCommand] {
        RendererCommand.allCases.filter {
            ShortcutPolicy.treeFocusBucket(of: $0) == .contentOnly && Self.handle($0, context)
        }
    }

    private func contentOnlyRawShortcuts(_ context: ShortcutContext) -> [RawExplorerShortcutID] {
        RawExplorerShortcutID.allCases.filter {
            ShortcutPolicy.treeFocusBucket(of: $0) == .contentOnly && Self.raw($0, context)
        }
    }

    // T-95ae41b4 F-083
    @Test func allowsOnlyTheSafeContentTargetCommandsForFilesystemTreeFolders() {
        let treeFolder = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        #expect(
            contentOnlyCommands(treeFolder) == [
                .openSelection, .openInTerminal, .copySelection, .cutSelection, .pasteSelection, .copyPath,
                .openSelectionInNewTab, .openSelectionInNewWindow,
            ])
        #expect(
            contentOnlyRawShortcuts(treeFolder) == [
                .copySelection, .cutSelection, .pasteSelection, .copyPath, .openInTerminal,
            ])
    }

    // T-9a3fddde F-083
    @Test func allowsOnlyTheSafeContentTargetCommandsForFavorites() {
        let favorite = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .favorite)
        #expect(
            contentOnlyCommands(favorite) == [
                .openSelection, .openInTerminal, .pasteSelection, .copyPath, .openSelectionInNewTab,
                .openSelectionInNewWindow,
            ])
        #expect(contentOnlyRawShortcuts(favorite) == [.pasteSelection, .copyPath, .openInTerminal])
    }

    // T-2c614522 F-083
    @Test func blocksContentTargetActionsEntirelyForTheFavoritesRoot() {
        let favoritesRoot = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .favoritesRoot)
        #expect(!Self.handle(.openSelection, favoritesRoot))
        #expect(!Self.handle(.openInTerminal, favoritesRoot))
        #expect(!Self.handle(.copyPath, favoritesRoot))
        #expect(!Self.raw(.copyPath, favoritesRoot))
    }

    // T-709ce3da F-083
    @Test func pastesIntoTheTreesFolderFromTheTreeButNeverFromTheFavoritesRoot() {
        for kind in [SelectedTreeTargetKind.filesystemFolder, .favorite] {
            let treeContext = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: kind)
            #expect(Self.handle(.pasteSelection, treeContext))
            #expect(Self.raw(.pasteSelection, treeContext))
        }
        for kind in [SelectedTreeTargetKind?.some(.favoritesRoot), nil] {
            let treeContext = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: kind)
            #expect(!Self.handle(.pasteSelection, treeContext))
            #expect(!Self.raw(.pasteSelection, treeContext))
        }
        #expect(
            !Self.handle(
                .pasteSelection,
                Self.ctx(focusedPane: .tree, mainView: .help, selectedTreeTargetKind: .filesystemFolder)))
    }

    // T-dcaeba9c F-083
    @Test func copiesAndCutsAFolderOfTheTreeButNeverAFavorite() {
        let treeFolder = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        let pairs: [(RendererCommand, RawExplorerShortcutID)] = [
            (.copySelection, .copySelection), (.cutSelection, .cutSelection),
        ]
        for (command, shortcut) in pairs {
            #expect(Self.handle(command, treeFolder))
            #expect(Self.raw(shortcut, treeFolder))
            for kind in [SelectedTreeTargetKind?.some(.favorite), .some(.favoritesRoot), nil] {
                let context = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: kind)
                #expect(!Self.handle(command, context))
                #expect(!Self.raw(shortcut, context))
            }
        }
    }

    // T-61d42520 F-083
    @Test func keepsTheDangerousRendererCommandDenylistFullyBlockedForTreeFoldersAndFavorites() {
        let dangerous: [RendererCommand] = [
            .editSelection, .moveSelection, .renameSelection, .duplicateSelection, .newFolder, .trashSelection,
        ]
        for kind in [SelectedTreeTargetKind.filesystemFolder, .favorite, .favoritesRoot] {
            let context = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: kind)
            #expect(dangerous.filter { !Self.handle($0, context) } == dangerous)
        }
    }

    // T-b95c0791 F-083
    @Test func keepsTheDangerousRawShortcutDenylistFullyBlockedForTreeFoldersAndFavorites() {
        let dangerous: [RawExplorerShortcutID] = [
            .moveSelection, .renameSelection, .duplicateSelection, .newFolder, .trashSelection,
        ]
        for kind in [SelectedTreeTargetKind.filesystemFolder, .favorite, .favoritesRoot] {
            let context = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: kind)
            #expect(dangerous.filter { !Self.raw($0, context) } == dangerous)
        }
    }

    static func badge(_ action: String, _ context: ShortcutContext) -> String? {
        ShortcutPolicy.contextMenuShortcutLabel(actionID: action, context: context)
    }

    // T-61d0b4a9 F-083
    @Test func showsContextMenuShortcutBadgesOnlyForEnabledTreeFolderActions() {
        let treeFolder = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder)
        #expect(Self.badge("open", treeFolder) == "⌘O")
        #expect(Self.badge("showInfo", treeFolder) == "⌘I")
        #expect(Self.badge("terminal", treeFolder) == "⌥⌘T")
        #expect(Self.badge("copyPath", treeFolder) == "⌥⌘C")
        #expect(Self.badge("copy", treeFolder) == "⌘C")
        #expect(Self.badge("cut", treeFolder) == "⌘X")
        #expect(Self.badge("paste", treeFolder) == nil)
        #expect(Self.badge("rename", treeFolder) == nil)
        #expect(Self.badge("trash", treeFolder) == nil)
    }

    // T-ec632f27 F-083
    @Test func showsTheSameSafeContextMenuShortcutBadgesForFavoritesAndNoneForFavoritesRoot() {
        let favorite = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .favorite)
        let favoritesRoot = Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .favoritesRoot)
        #expect(Self.badge("showInfo", favorite) == "⌘I")
        #expect(Self.badge("terminal", favorite) == "⌥⌘T")
        #expect(Self.badge("copyPath", favorite) == "⌥⌘C")
        #expect(Self.badge("paste", favorite) == nil)
        #expect(Self.badge("newFolder", favorite) == nil)
        #expect(Self.badge("showInfo", favoritesRoot) == "⌘I")
        #expect(Self.badge("terminal", favoritesRoot) == nil)
        #expect(Self.badge("copyPath", favoritesRoot) == nil)
    }

    // T-827a2584 F-083
    @Test func rootsTheTreeFromEitherPaneAndBadgesRootTreeHereInTheTreeMenus() {
        for pane in [FocusedPane?.some(.tree), .some(.content), nil] {
            let context = Self.ctx(focusedPane: pane, selectedTreeTargetKind: .filesystemFolder)
            #expect(Self.handle(.goHomeRootTree, context))
            #expect(Self.handle(.rootTreeAtSelection, context))
            #expect(Self.raw(.goHomeRootTree, context))
            #expect(Self.raw(.rootTreeAtSelection, context))
        }
        #expect(!Self.handle(.rootTreeAtSelection, Self.ctx(mainView: .help)))
        #expect(
            Self.badge("rootTreeHere", Self.ctx(focusedPane: .tree, selectedTreeTargetKind: .filesystemFolder))
                == "⇧⌘R")
    }

    // T-c4a3910c
    // The compiler checks that the bucket table covers every command (the original's test compares key lists).
    @Test func keepsRendererCommandTreeFocusBucketsExhaustive() {
        for command in RendererCommand.allCases {
            _ = ShortcutPolicy.treeFocusBucket(of: command)
        }
        #expect(RendererCommand.allCases.count == 71)
        // The two commands the original keeps in two buckets' worth of notes.
        #expect(ShortcutPolicy.treeFocusBucket(of: .ejectVolume) == .globalExplorer)
        #expect(ShortcutPolicy.treeFocusBucket(of: .calculateSize) == .globalExplorer)
    }

    // T-fb9e7595
    @Test func keepsRawShortcutTreeFocusBucketsExhaustive() {
        for shortcut in RawExplorerShortcutID.allCases {
            _ = ShortcutPolicy.treeFocusBucket(of: shortcut)
        }
        #expect(RawExplorerShortcutID.allCases.count == 47)
    }
}
