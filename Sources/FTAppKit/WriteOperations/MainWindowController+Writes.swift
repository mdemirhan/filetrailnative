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

    /// Carries out a write command; false for any other command.
    func performWriteCommand(_ command: RendererCommand) -> Bool {
        guard Self.writeCommands.contains(command) else { return false }
        guard let actions = writeActions else { return true }
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
            Task { await actions.duplicate(paths) }
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

    /// What Copy and Cut take: the folder selected in the tree while it has the keyboard, else the items selected in
    /// the list (`resolveClipboardSource`).
    private var clipboardSourcePaths: [String] {
        if focusedPane == .tree, let path = sidebarController.selectedTreeTargetPath { return [path] }
        return selectedPaths
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
            sidebarController.refreshBranches()
        }
        if refresh.path != folder.path {
            go(to: URL(fileURLWithPath: refresh.path), history: .none)
        } else {
            reload()
        }
    }
}
