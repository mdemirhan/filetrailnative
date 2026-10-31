// Port of the write commands of apps/desktop/src/renderer/hooks/useExplorerShortcuts.ts (runGenericEditCommand, the
// write cases of runRendererCommand) and of refreshDirectory's after-write options
// (apps/desktop/src/renderer/hooks/useExplorerNavigationController.ts): what a tab does with a write command, and with
// a write's end
import AppKit
import FTFoundation
import FTOperations

extension MainWindowController {
    /// The commands that write (`WRITE_LOCKED_COMMANDS` with the clipboard's): each goes to the file operations.
    static let writeCommands: Set<RendererCommand> = [
        .undo, .redo, .renameSelection, .duplicateSelection, .newFolder, .trashSelection, .emptyTrash, .cutSelection,
        .copySelection, .pasteSelection, .moveSelection, .editCut, .editCopy, .editPaste,
    ]

    /// This tab's file operations; nil until the app has started them.
    var writeActions: WindowWriteActions? {
        AppWriteOperations.current?.actions(for: self)
    }

    /// Whether this tab's window may not start a write now: one runs in it, or in another window.
    var isWriteLocked: Bool {
        guard let group, let operations = AppWriteOperations.current else { return false }
        return operations.session(for: group).isWriteLocked
    }

    /// A write started or ended here or in another window: the changes to the folder that waited meanwhile are read.
    func writeLockChanged() {
        if !isWriteLocked {
            flushPendingChange()
            refreshTrashState()
        }
        commandsChanged()
    }

    /// Whether the files' Undo (Redo) runs for the event that chose it: a held ⌘Z repeats the menu's command, and Undo
    /// runs once per press (`options.repeated` of `runRendererCommand`, B-CLIP-185, B-SEL-114). A click always runs it.
    static func undoRuns(for event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        return !event.isARepeat
    }

    /// `startDuplicatePaths`: nothing is made in the Trash (the menus offer no Duplicate there).
    static func duplicatesInTrash(_ paths: [String], destination: String, homePath: String) -> Bool {
        Paths.isInsideTrash(destination, homePath: homePath)
            || paths.contains { Paths.isInsideTrash($0, homePath: homePath) }
    }

    /// Carries out a write command; false for any other command.
    func performWriteCommand(_ command: RendererCommand) -> Bool {
        guard Self.writeCommands.contains(command) else { return false }
        // A command the focused pane doesn't take does nothing (Move To with the tree focused, Cut on a favorite).
        guard Self.canRunWriteCommand(command, writeCommandContext), let actions = writeActions else { return true }
        switch command {
        case .copySelection, .editCopy:
            actions.putOnClipboard(.copy, paths: clipboardSourcePaths, entries: clipboardSourceEntries)
        case .cutSelection, .editCut:
            actions.putOnClipboard(.cut, paths: clipboardSourcePaths, entries: clipboardSourceEntries)
        case .pasteSelection, .editPaste:
            // Pastes into the folder on screen from the keyboard or menu bar, whatever is selected; never into
            // search results or the Trash (`resolvePasteDestinationPath`).
            guard let destination = pasteDestinationPath else { return true }
            Task { await actions.pasteFromClipboard(into: destination) }
        case .duplicateSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            // Next to the items (`startDuplicateOfSelection`): search results may be from several folders, and then
            // there is no one folder for their copies.
            let destination: String
            if searchRootPath == nil {
                destination = folder.path
            } else if let one = ContextMenuRules.duplicateFolder(of: paths) {
                destination = one
            } else {
                NotificationOverlay.push(.info, title: "Duplicate items from one folder at a time", in: window)
                return true
            }
            let homePath = actions.session.coordinator.homePath
            guard !Self.duplicatesInTrash(paths, destination: destination, homePath: homePath),
                !actions.refuseWhileBusy(.operation(.duplicate))
            else { return true }
            actions.session.pendingTreeSelectionPath = nil
            Task { actions.reviewIfAsked(await actions.duplicate(paths, in: destination), action: .duplicate) }
        case .moveSelection:
            // Move To says so as soon as pressed, not after a folder was chosen (B-CLIP-107).
            let paths = selectedPaths
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.moveTo)) else { return true }
            chooseMoveDestination(for: paths, actions)
        case .renameSelection:
            // One item in its row; several in the Rename sheet.
            renameSelected()
        case .newFolder:
            // From the keyboard or the menu bar: in the folder on screen, whatever is selected.
            guard
                let target = LocalWriteRules.newFolderTargetPath(
                    currentPath: shownFolderPath, selectedEntry: nil, selectedPaths: selectedPaths,
                    isSearchMode: searchRootPath != nil, homePath: actions.session.coordinator.homePath)
            else { return true }
            Task { _ = try? await actions.newFolder(in: target) }
        case .trashSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            Task { _ = try? await actions.trash(paths) }
        case .emptyTrash:
            Task { _ = try? await actions.emptyTrash() }
        case .undo, .redo:
            // The files' Undo; a text field with the keyboard undoes its own typing before this is reached.
            guard Self.undoRuns(for: NSApp?.currentEvent) else { return true }
            guard !actions.refuseWhileBusy(.operation(command == .undo ? .undo : .redo)) else { return true }
            Task { await actions.startUndo(command == .undo ? .undo : .redo) }
        default:
            break
        }
        return true
    }

    /// The folder just made in the folder on screen is renamed in its row once it is listed (and selected, see
    /// `AfterWrite.selection`). Leaving the folder forgets it.
    func renamePendingFolder(_ session: ExplorerWriteSession) {
        guard let path = session.pendingInlineRenamePath else { return }
        if !NodePath.dirname(path).utf16.elementsEqual(shownFolderPath.utf16) {
            session.pendingInlineRenamePath = nil
            return
        }
        // By its name in the folder on screen: the listing gives its rows the folder's real path, which may be spelled
        // otherwise than the one the tab was opened on (/private/var for /var).
        let name = NodePath.basename(path)
        guard let row = content.listed.first(where: { $0.name.utf16.elementsEqual(name.utf16) }) else { return }
        session.pendingInlineRenamePath = nil
        if let actions = writeActions, actions.refuseWhileBusy(.operation(.rename)) { return }
        content.beginRename(path: row.path)
    }

    /// The file operations of the right-click menus (`runContextMenuAction`): Rename, New Folder, Move to Trash,
    /// Delete Immediately, Empty Trash, Move and Duplicate. They act on what the menu was opened on, whichever pane has
    /// the keyboard: right-clicking a sidebar folder focuses the tree, where the commands of the same names refuse.
    func performContextFileOperation(_ action: ContextMenuActionID, _ subject: ContextMenuSubject) {
        guard let actions = writeActions else { return }
        let paths = subject.paths
        let fromTree = subject.surface == .treeFolder || subject.surface == .favorite
        switch action {
        case .rename:
            guard !paths.isEmpty else { return }
            if fromTree || paths.count == 1 && !content.listed.contains(where: { $0.path == paths[0] }) {
                if paths.count == 1, !actions.refuseWhileBusy(.operation(.rename)) {
                    Task { await actions.renameInDialog(paths[0], hiddenFilesShown: includeHidden) }
                }
            } else if paths.count > 1 {
                renameSelected()
            } else if !actions.refuseWhileBusy(.operation(.rename)) {
                content.beginRename(path: paths[0])
            }
        case .newFolder:
            let target: String?
            if fromTree {
                target = subject.targetPath
            } else {
                let entry = subject.entries.first { $0.path == subject.targetPath } ?? subject.entries.first
                target = LocalWriteRules.newFolderTargetPath(
                    currentPath: shownFolderPath, selectedEntry: entry.map { ($0.path, $0.kind.isDirectoryLike) },
                    selectedPaths: paths, isSearchMode: searchRootPath != nil,
                    homePath: actions.session.coordinator.homePath,
                    scope: subject.scope == .selection ? .selection : .background)
            }
            guard let target else { return }
            Task { _ = try? await actions.newFolder(in: target, selectInTree: fromTree) }
        case .trash:
            Task { _ = try? await actions.trash(paths, askFirst: subject.surface == .treeFolder) }
        case .deleteImmediately:
            Task { _ = try? await actions.deleteImmediately(paths) }
        case .emptyTrash:
            Task { _ = try? await actions.emptyTrash() }
        case .cut: actions.putOnClipboard(.cut, paths: paths)
        case .copy: actions.putOnClipboard(.copy, paths: paths)
        case .paste: _ = performWriteCommand(.pasteSelection)
        case .move:
            // Says so as soon as chosen, not after a folder was chosen (B-CLIP-107).
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.moveTo)) else { return }
            openMoveDialog(paths, actions)
        case .duplicate:
            duplicateFromMenu(subject, actions)
        default: break
        }
    }

    /// Duplicate of `runContextMenuAction`: a tree folder's copy goes next to it and is selected in the tree; a search
    /// result's goes next to it; anything else's into the folder on screen.
    private func duplicateFromMenu(_ subject: ContextMenuSubject, _ actions: WindowWriteActions) {
        let paths = subject.paths
        let inTree = subject.surface == .treeFolder
        let destination: String?
        switch subject.surface {
        case .treeFolder:
            destination = paths.first.flatMap { TreePaths.parent(of: $0) } ?? shownFolderPath
        case .search:
            destination = ContextMenuRules.duplicateFolder(of: paths)
        default:
            destination = shownFolderPath
        }
        guard let destination, !paths.isEmpty, !destination.isEmpty else { return }
        let homePath = actions.session.coordinator.homePath
        guard !Self.duplicatesInTrash(paths, destination: destination, homePath: homePath),
            !actions.refuseWhileBusy(.operation(.duplicate))
        else { return }
        // The copy's name is known only once it is made: it is asked for by the folder it goes into, and
        // `completedTreeSelectionPath` selects the copy.
        actions.session.pendingTreeSelectionPath = inTree ? destination : nil
        Task {
            let outcome = await actions.duplicate(paths, in: destination)
            switch outcome {
            case .blocked, .error, .cancelled:
                if inTree { actions.session.pendingTreeSelectionPath = nil }
            case .queued, .review:
                break
            }
            actions.reviewIfAsked(outcome, action: .duplicate)
        }
    }

    /// `canHandleRendererCommand`, asked before a write command acts (`runRendererCommand`; Cut, Copy and Paste of
    /// the Edit menu as `runGenericEditCommand` asks it): the list's commands only with the list focused, Cut and
    /// Copy from the tree only on a folder of it (a favorite only points to one), Paste also with no pane focused.
    static func canRunWriteCommand(_ command: RendererCommand, _ context: ShortcutContext) -> Bool {
        let asked: RendererCommand =
            switch command {
            case .editCut: .cutSelection
            case .editCopy: .copySelection
            case .editPaste: .pasteSelection
            default: command
            }
        return ShortcutPolicy.canHandle(asked, context)
    }

    private var writeCommandContext: ShortcutContext {
        let pane: FTFoundation.FocusedPane? =
            switch focusedPane {
            case .tree: .tree
            case .content: .content
            case nil: nil
            }
        return ShortcutContext(focusedPane: pane, selectedTreeTargetKind: sidebarController.selectedTreeTargetKind)
    }

    /// What Copy and Cut take (`resolveClipboardSource`): the folder selected in the tree while it has the keyboard
    /// (nothing for a favorite, which only points to one), else the items selected in the list.
    static func clipboardSource(
        focusedPane: ExplorerPane?, treeTargetKind: SelectedTreeTargetKind?, treeTargetPath: String?,
        selectedPaths: [String]
    ) -> [String] {
        guard focusedPane == .tree else { return selectedPaths }
        guard treeTargetKind == .filesystemFolder, let treeTargetPath else { return [] }
        return [treeTargetPath]
    }

    private var clipboardSourcePaths: [String] {
        Self.clipboardSource(
            focusedPane: focusedPane, treeTargetKind: sidebarController.selectedTreeTargetKind,
            treeTargetPath: sidebarController.selectedTreeTargetPath, selectedPaths: selectedPaths)
    }

    /// Move To's folder: the Move To box (Dialogs/).
    private func chooseMoveDestination(for paths: [String], _ actions: WindowWriteActions) {
        openMoveDialog(paths, actions)
    }

    /// A write ended (`refreshDirectory` with `treeSelectionPath` and `extraTreeReloadPaths`): the folder on screen is
    /// read again, at its new place if the write moved it, overwriting its step of the history, what the write made is
    /// selected once it is listed, and the tree comes back to the folder, or to the row the write asks for.
    func applyWriteEnd(_ refresh: WriteEndRefresh) {
        // No folder on screen, none to read: `refreshDirectory` stops here, before the tree too.
        guard !refresh.path.isEmpty else { return }
        let session = group.flatMap { AppWriteOperations.current?.session(for: $0) }
        if refresh.selecting != nil || session?.pendingInlineRenamePath != nil {
            final class Once {
                var token: ExplorerWindowObservation?
            }
            let once = Once()
            once.token = observe { [weak self, once] change in
                guard change == .folder, let self, let token = once.token, token.isValid else { return }
                token.invalidate()
                once.token = nil
                if let selecting = refresh.selecting, folder.path == refresh.path {
                    content.select(paths: selecting)
                }
                if let session { renamePendingFolder(session) }
            }
        }
        let model = sidebarController.model
        var open = model.openReadingAgain(refresh.path)
        open.selectingRow = refresh.treeSelectionPath
        var treeFollows = false
        if refresh.path == folder.path {
            readAgain()
            treeFollows = treeFollowsReadingAgain && (open.forceTreeReload || open.selectingRow != nil)
        } else {
            go(to: URL(fileURLWithPath: refresh.path), history: .replace, open: open)
        }
        // The folder stays, so the tree only follows, opening nothing; then what it shows is read again.
        Task { [path = refresh.path] in
            if treeFollows { await model.folderOpened(path, open) }
            if !refresh.treeReloadPaths.isEmpty { await model.refreshWriteBranches(refresh.treeReloadPaths) }
        }
    }
}

extension SidebarModel {
    /// `extraTreeReloadPaths` (`refreshDirectory`): the tree branches a write touched are read again, each from its
    /// folder down through its open folders, a folder read once for all of them (`refreshVisibleTreePath`). The rest
    /// of the tree stays as it is.
    func refreshWriteBranches(_ paths: [String]) async {
        var visited = Set<ExactKeyBox>()
        func refresh(_ path: String) async {
            guard visited.insert(ExactKeyBox(path)).inserted, !path.isEmpty, TreePaths.isWithinRoot(path, rootPath),
                nodes[path] != nil
            else { return }
            await loadChildren(path, activePath: currentPath, forceReload: true)
            guard let reloaded = nodes[path], reloaded.expanded else { return }
            for child in reloaded.childPaths where nodes[child]?.expanded == true { await refresh(child) }
        }
        var unique = Set<ExactKeyBox>()
        for path in paths where unique.insert(ExactKeyBox(path)).inserted { await refresh(path) }
    }
}
