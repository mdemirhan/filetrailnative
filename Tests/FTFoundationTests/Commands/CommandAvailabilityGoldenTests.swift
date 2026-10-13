// Checks the port against goldens recorded from the reference: tools/parity/golden/command-availability.ts
import FTTestSupport
import Foundation
import Testing

@testable import FTFoundation

struct CommandAvailabilityGoldenTests {
    struct Shortcut: Codable, Sendable {
        let actionNoticeOpen: Bool
        let copyPasteModalOpen: Bool
        let focusedPane: String?
        let locationSheetOpen: Bool
        let mainView: String
        let selectedTreeTargetKind: String?
    }

    struct Entry: Codable, Sendable {
        let path: String
        let kind: String
    }

    struct Input: Codable, Sendable {
        let shortcut: Shortcut
        let currentPath: String
        let selectedPaths: [String]
        let entries: [Entry]
        let selectedEntry: Entry?
        let selectedTreeTargetPath: String?
        let clipboardHasItems: Bool
        let pasteDestinationPath: String?
        let isSearchMode: Bool
        let openItemLimit: Int
        let writeOperationLocked: Bool
        let textEditing: Bool
        let focusedPane: String?
        let lastFocusedPane: String?
        let contextMenuPaths: [String]
        let contextMenuFolderPath: String?
        let selectedContentFolderPath: String?
        let canGoBack: Bool?
        let canGoForward: Bool?
        let hasCachedSearch: Bool?
        let tabCount: Int?
        let trashPath: String?
        let homePath: String?
        let trashIsEmpty: Bool?
        let ejectTargetPath: String?
    }

    struct Output: Codable, Equatable, Sendable {
        let disabled: [String]
        let newTab: String?
        let favorite: String?
        let showInFinder: [String]
        let calculateSize: [String]
        let openTerminal: [String]
        let openPaths: [String]
        let editPaths: [String]
        let rootTree: String?
    }

    static func pane(_ name: String?) -> FocusedPane? { name.flatMap { FocusedPane(rawValue: $0) } }

    static func entry(_ entry: Entry) -> CommandEntry {
        CommandEntry(path: entry.path, kind: EntryKind(rawValue: entry.kind) ?? .other)
    }

    static func run(_ input: Input) -> Output {
        let shortcut = ShortcutContext(
            actionNoticeOpen: input.shortcut.actionNoticeOpen, copyPasteModalOpen: input.shortcut.copyPasteModalOpen,
            focusedPane: pane(input.shortcut.focusedPane), locationSheetOpen: input.shortcut.locationSheetOpen,
            mainView: MainView(rawValue: input.shortcut.mainView) ?? .explorer,
            selectedTreeTargetKind: input.shortcut.selectedTreeTargetKind.flatMap {
                SelectedTreeTargetKind(rawValue: $0)
            })
        let context = CommandAvailabilityContext(
            shortcutContext: shortcut, currentPath: input.currentPath, selectedPathsInViewOrder: input.selectedPaths,
            activeContentEntries: input.entries.map(entry), selectedEntry: input.selectedEntry.map(entry),
            selectedTreeTargetPath: input.selectedTreeTargetPath, clipboardHasItems: input.clipboardHasItems,
            pasteDestinationPath: input.pasteDestinationPath, isSearchMode: input.isSearchMode,
            openItemLimit: input.openItemLimit, writeOperationLocked: input.writeOperationLocked,
            canGoBack: input.canGoBack, canGoForward: input.canGoForward, hasCachedSearch: input.hasCachedSearch,
            tabCount: input.tabCount, trashPath: input.trashPath, homePath: input.homePath,
            trashIsEmpty: input.trashIsEmpty, ejectTargetPath: input.ejectTargetPath)
        let state = ApplicationMenuState.build(
            viewMode: .list, sortBy: .name, foldersFirst: true, hiddenFilesShown: false, folderTreeOpen: true,
            infoPanelOpen: false, infoRowOpen: false, favoriteIsSet: false, textEditing: input.textEditing,
            canRun: { CommandAvailability.canRun($0, context) })
        let target = CommandAvailability.TargetContext(context)
        let selection = ShortcutTargets.Selection(
            focusedPane: pane(input.focusedPane), lastFocusedPane: pane(input.lastFocusedPane),
            contextMenuPaths: input.contextMenuPaths, selectedContentPaths: input.selectedPaths,
            selectedTreePath: input.selectedTreeTargetPath, currentPath: input.currentPath)
        return Output(
            disabled: state.disabledCommands.map(\.rawValue), newTab: CommandAvailability.newTabTargetPath(target),
            favorite: CommandAvailability.favoriteTargetPath(target),
            showInFinder: CommandAvailability.showInFinderPaths(target),
            calculateSize: CommandAvailability.calculateSizePaths(target),
            openTerminal: ShortcutTargets.openInTerminalPaths(selection),
            openPaths: ShortcutTargets.openSelectionPaths(selection),
            editPaths: ShortcutTargets.editSelectionPaths(selection),
            rootTree: ShortcutTargets.rootTreeTargetPath(
                ShortcutTargets.RootTreeInput(
                    focusedPane: pane(input.focusedPane), lastFocusedPane: pane(input.lastFocusedPane),
                    contextMenuFolderPath: input.contextMenuFolderPath,
                    selectedContentFolderPath: input.selectedContentFolderPath,
                    selectedTreePath: input.selectedTreeTargetPath, currentPath: input.currentPath)))
    }

    @Test func commandAvailabilityMatchesTheReference() throws {
        let cases: [GoldenCase<Input, Output>] = try Golden.load(suite: "command-availability")
        #expect(cases.count >= 300)
        Golden.expectMatches(cases) { Self.run($0) }
    }
}
