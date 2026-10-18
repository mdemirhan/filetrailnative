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
        if !isWriteLocked { flushPendingChange() }
    }

    /// Carries out a write command; false for any other command.
    func performWriteCommand(_ command: RendererCommand) -> Bool {
        guard Self.writeCommands.contains(command) else { return false }
        // A command the focused pane doesn't take does nothing (Move To with the tree focused, Cut on a favorite).
        guard Self.canRunWriteCommand(command, writeCommandContext), let actions = writeActions else { return true }
        switch command {
        case .copySelection, .editCopy:
            actions.putOnClipboard(.copy, paths: clipboardSourcePaths)
        case .cutSelection, .editCut:
            actions.putOnClipboard(.cut, paths: clipboardSourcePaths)
        case .pasteSelection, .editPaste:
            // Pastes into the folder on screen from the keyboard or menu bar, whatever is selected; never into
            // search results.
            guard searchRootPath == nil else { return true }
            let destination = folder.path
            Task { await actions.paste(into: destination) }
        case .duplicateSelection:
            let paths = selectedPaths
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.duplicate)) else { return true }
            let destination = folder.path
            Task { await actions.duplicate(paths, in: destination) }
        case .moveSelection:
            // Move To says so as soon as pressed, not after a folder was chosen (B-CLIP-107).
            let paths = selectedPaths
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.moveTo)) else { return true }
            chooseMoveDestination(for: paths, actions)
        case .undo, .redo, .renameSelection, .newFolder, .trashSelection, .emptyTrash:
            let action: WriteStartAction =
                switch command {
                case .undo: .operation(.undo)
                case .redo: .operation(.redo)
                case .renameSelection: .operation(.rename)
                case .newFolder: .operation(.newFolder)
                case .trashSelection: .operation(.trash)
                default: .emptyTrash
                }
            guard !actions.refuseWhileBusy(action) else { return true }
            // P3-06 to P3-08 fill these; until then they say they aren't there.
            NSSound.beep()
        default:
            break
        }
        return true
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

    /// Move To's folder (the Move To sheet is P5-08's; a folder chooser stands in for it).
    private func chooseMoveDestination(for paths: [String], _ actions: WindowWriteActions) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.directoryURL = folder
        let choose: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await actions.moveTo(paths, destination: url.path) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: choose)
        } else {
            choose(panel.runModal())
        }
    }

    /// A write ended (`refreshDirectory` with `treeSelectionPath` and `extraTreeReloadPaths`): the folder on screen is
    /// read again, at its new place if the write moved it, what the write made is selected once it is listed, and the
    /// tree follows.
    func applyWriteEnd(_ refresh: WriteEndRefresh) {
        if let selecting = refresh.selecting {
            final class Once {
                var token: ExplorerWindowObservation?
            }
            let once = Once()
            once.token = observe { [weak self, once] change in
                guard change == .folder, let self, let token = once.token, token.isValid else { return }
                token.invalidate()
                once.token = nil
                if folder.path == refresh.path {
                    content.select(paths: selecting)
                }
            }
        }
        if let treeSelectionPath = refresh.treeSelectionPath {
            sidebarController.reveal(treeSelectionPath)
        }
        if !refresh.treeReloadPaths.isEmpty {
            let model = sidebarController.model
            Task { await model.refreshWriteBranches(refresh.treeReloadPaths) }
        }
        if refresh.path != folder.path {
            go(to: URL(fileURLWithPath: refresh.path), history: .none)
        } else {
            reload()
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
