// What a tab does with a write command, and with a write's end
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

extension MainWindowController {
    /// The commands that write, the clipboard's among them: each goes to the file operations.
    static let writeCommands: Set<AppCommand> = [
        .undo, .redo, .renameSelection, .duplicateSelection, .makeAlias, .newFolder, .newFolderWithSelection,
        .newTextFile,
        .saveAsTemplate, .pasteAsFile,
        .trashSelection, .deleteImmediately, .emptyTrash, .cutSelection, .copySelection, .pasteSelection,
        .moveSelection, .editCut,
        .editCopy, .editPaste, .addToCopied, .addToCut, .moveItemsHere, .removeFromClipboard,
        .compressSelection, .extractSelection, .extractSelectionTo,
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
            recheckFolderChanges()
            refreshTrashState()
        }
        commandsChanged()
    }

    /// Whether the files' Undo (Redo) runs for the event that chose it: a held ⌘Z repeats the menu's command, and Undo
    /// runs once per press. A click always runs it.
    static func undoRuns(for event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return true }
        return !event.isARepeat
    }

    /// Nothing is made in the Trash (the menus offer no Duplicate there).
    static func duplicatesInTrash(_ paths: [String], destination: String, homePath: String) -> Bool {
        Paths.isInsideTrash(destination, homePath: homePath)
            || paths.contains { Paths.isInsideTrash($0, homePath: homePath) }
    }

    /// Carries out a write command; false for any other command.
    func performWriteCommand(_ command: AppCommand) -> Bool {
        guard Self.writeCommands.contains(command) else { return false }
        // A command the focused pane doesn't take does nothing (Move To with the tree focused, Cut on a favorite).
        guard Self.canRunWriteCommand(command, writeCommandContext), let actions = writeActions else { return true }
        switch command {
        case .copySelection, .editCopy:
            actions.putOnClipboard(.copy, paths: clipboardSourcePaths, entries: clipboardSourceEntries)
        case .cutSelection, .editCut:
            actions.putOnClipboard(.cut, paths: clipboardSourcePaths, entries: clipboardSourceEntries)
        case .addToCopied, .addToCut:
            addToClipboard(
                command == .addToCut ? .cut : .copy, paths: clipboardSourcePaths, entries: clipboardSourceEntries)
        case .removeFromClipboard:
            removeFromClipboard(clipboardSourcePaths)
        case .pasteSelection, .editPaste, .moveItemsHere:
            // Pastes into the folder on screen from the keyboard or menu bar, whatever is selected; never into
            // search results or the Trash. Move Items Here moves every item, as Finder's does after Copy.
            guard let destination = pasteDestinationPath else { return true }
            let moveAll = command == .moveItemsHere
            Task { await actions.pasteFromClipboard(into: destination, moveAll: moveAll) }
        case .duplicateSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            // Next to the items: search results may be from several folders, and then
            // there is no one folder for their copies.
            let destination: String
            if searchRootPath == nil {
                destination = folderPath
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
        case .makeAlias:
            // Beside each item, as Duplicate puts its copies; its item is dimmed in the Trash and for results from
            // several folders, and a dimmed item's key still comes here.
            let paths = selectedPaths
            guard !paths.isEmpty, canPerform(.makeAlias) else { return true }
            Task { _ = await actions.makeAliases(paths) }
        case .moveSelection:
            // Move To says so as soon as pressed, not after a folder was chosen.
            let paths = selectedPaths
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.moveTo)) else { return true }
            chooseMoveDestination(for: paths, actions)
        case .renameSelection:
            // One item in its row; several in the Rename sheet.
            renameSelected()
        case .compressSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            Task { _ = await actions.compress(paths) }
        case .extractSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            Task { _ = await actions.extract(paths) }
        case .extractSelectionTo:
            // Says so as soon as pressed, not after a folder was chosen.
            let paths = selectedPaths
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.extract)) else { return true }
            openExtractToDialog(paths, actions)
        case .newFolder:
            // From the keyboard or the menu bar: in the folder on screen, whatever is selected.
            guard
                let target = LocalWriteRules.newFolderTargetPath(
                    currentPath: shownFolderPath, selectedEntry: nil, selectedPaths: selectedPaths,
                    isSearchMode: searchRootPath != nil, homePath: actions.session.coordinator.homePath)
            else { return true }
            Task { _ = await actions.newFolder(in: target) }
        case .saveAsTemplate:
            // Its item is dimmed for anything but files outside the Trash whose names don't start with a dot, and the
            // key of a dimmed item still comes here (`keyOfDimmedItem`), where a selected folder would be copied
            // whole into the Templates folder, or a `.gitignore` copied there, neither of which New File lists.
            guard selectionAllows(.saveAsTemplate) else { return true }
            saveAsTemplate(selectedPaths)
        case .newTextFile:
            // Into the folder on screen, whatever is selected, as New Folder.
            guard let target = pasteAsFileTargetPath(actions) else { return true }
            Task { _ = await actions.newFile(in: target, named: NewFileTemplates.textFileName, contents: Data()) }
        case .newFolderWithSelection:
            let paths = selectedPaths
            guard
                let target = CommandAvailability.newFolderWithSelectionTarget(
                    currentPath: shownFolderPath, selectedPaths: paths, isSearchMode: searchRootPath != nil,
                    homePath: actions.session.coordinator.homePath)
            else { return true }
            Task { _ = await actions.newFolderWithSelection(paths, in: target) }
        case .pasteAsFile:
            // Into the folder on screen, whatever is selected and whichever pane has the keyboard, as New Folder.
            guard let target = pasteAsFileTargetPath(actions) else { return true }
            Task { _ = await actions.pasteAsFile(in: target, from: systemClipboard) }
        case .trashSelection:
            let paths = selectedPaths
            guard !paths.isEmpty else { return true }
            Task { _ = await actions.trash(paths) }
        case .deleteImmediately:
            // What is selected in the Trash, after Finder's question; never anything outside it, whichever way the
            // key arrives (a dimmed item's key still reaches the window).
            let paths = selectedPaths
            guard !paths.isEmpty, canPerform(.deleteImmediately) else {
                NSSound.beep()
                return true
            }
            Task { _ = await actions.deleteImmediately(paths) }
        case .emptyTrash:
            Task { _ = await actions.emptyTrash() }
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

    /// File ▸ New File ▸ a template: a copy of what the file of the Templates folder holds, with a date of its own, in
    /// the folder on screen.
    func newFileFromTemplate(named name: String) {
        guard let actions = writeActions, let folder = Self.templatesFolderPath,
            let target = pasteAsFileTargetPath(actions)
        else { return }
        if actions.refuseWhileBusy(.operation(.newFile)) { return }
        let path = (folder as NSString).appendingPathComponent(name)
        Task {
            let read = await Task.detached { Result { try Data(contentsOf: DiskPath(path).url(isDirectory: false)) } }
                .value
            switch read {
            case .success(let contents):
                _ = await actions.newFile(in: target, named: name, contents: contents)
            case .failure:
                actions.dialogs.show(
                    "The file couldn\u{2019}t be made",
                    "The template \u{201C}\(name)\u{201D} can\u{2019}t be read. It may have been moved or removed.",
                    window)
            }
        }
    }

    /// File ▸ Save as Template: the files copied into the Templates folder (made the first time), as Copy To copies, so
    /// a name already there is asked about and Undo takes the copies back; New File lists them from then on.
    func saveAsTemplate(_ paths: [String]) {
        guard let actions = writeActions, let folder = Self.templatesFolderPath, !paths.isEmpty else { return }
        if actions.refuseWhileBusy(.operation(.copyTo)) { return }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            actions.dialogs.show("The Templates folder couldn\u{2019}t be made", error.localizedDescription, window)
            return
        }
        Self.templatesFolderOpened?()
        Task { actions.reviewIfAsked(await actions.copyTo(paths, destination: folder), action: .copyTo) }
    }

    /// File ▸ New File ▸ Open Templates Folder: the folder in this tab, made the first time.
    func openTemplatesFolder() {
        guard let folder = Self.templatesFolderPath else { return }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            writeActions?.dialogs.show(
                "The Templates folder couldn\u{2019}t be made", error.localizedDescription, window)
            return
        }
        Self.templatesFolderOpened?()
        go(to: folder)
    }

    /// Where Paste as File writes: the folder on screen; none in search results or in the Trash.
    private func pasteAsFileTargetPath(_ actions: WindowWriteActions) -> String? {
        LocalWriteRules.newFolderTargetPath(
            currentPath: shownFolderPath, selectedEntry: nil, selectedPaths: selectedPaths,
            isSearchMode: searchRootPath != nil, homePath: actions.session.coordinator.homePath)
    }

    /// The folder just made in `pane`'s folder is renamed in its row, now that the pane's own read has listed it (and
    /// selected it, see `AfterWrite.selection`). A pane that left the folder forgets it, and so does one whose
    /// listing doesn't have it: it is asked for once. `onDisk` has what the disk names it, when no row is spelled as
    /// the write named it (`BrowserPane.writeEndShown`): a disk may store a name's accent its own way.
    func renamePendingFolder(
        _ session: ExplorerWriteSession, in pane: BrowserPane, onDisk: [DiskPath: DiskPath] = [:]
    ) {
        guard let path = session.pendingInlineRenamePath else { return }
        session.pendingInlineRenamePath = nil
        // The one folder, however each spells an accent: New Folder with Selection's folder is spelled as its rows.
        guard NameKeys.pathsMatchIgnoringEncoding(NodePath.dirname(path), pane.shownFolderPath) else { return }
        // By its name in the folder on screen: the listing gives its rows the folder's real path, which may be spelled
        // otherwise than the one the tab was opened on (/private/var for /var).
        let name = (onDisk[DiskPath(path)] ?? DiskPath(path)).name
        guard let row = pane.content.listed.first(where: { $0.name.utf16.elementsEqual(name.utf16) }) else { return }
        if let actions = writeActions, actions.refuseWhileBusy(.operation(.rename)) { return }
        pane.content.beginRename(path: row.path)
    }

    /// The file operations of the right-click menus: Rename, New Folder, Move to Trash,
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
            Task { _ = await actions.newFolder(in: target, selectInTree: fromTree) }
        case .saveAsTemplate:
            saveAsTemplate(paths)
        case .newFolderWithSelection:
            guard
                let target = CommandAvailability.newFolderWithSelectionTarget(
                    currentPath: shownFolderPath, selectedPaths: paths, isSearchMode: searchRootPath != nil,
                    homePath: actions.session.coordinator.homePath)
            else { return }
            Task { _ = await actions.newFolderWithSelection(paths, in: target) }
        case .pasteAsFile:
            // Only the background's menu has it: the folder on screen.
            guard let target = pasteAsFileTargetPath(actions) else { return }
            Task { _ = await actions.pasteAsFile(in: target, from: systemClipboard) }
        case .trash:
            Task { _ = await actions.trash(paths, askFirst: subject.surface == .treeFolder) }
        case .deleteImmediately:
            Task { _ = await actions.deleteImmediately(paths) }
        case .emptyTrash:
            Task { _ = await actions.emptyTrash() }
        case .move:
            // Says so as soon as chosen, not after a folder was chosen.
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.moveTo)) else { return }
            openMoveDialog(paths, actions)
        case .duplicate:
            duplicateFromMenu(subject, actions)
        case .makeAlias:
            // Beside each item, as Duplicate's copies; the menu offers it where Duplicate is offered.
            guard !paths.isEmpty else { return }
            Task { _ = await actions.makeAliases(paths) }
        case .compress:
            guard !paths.isEmpty else { return }
            Task { _ = await actions.compress(paths) }
        case .extract:
            guard !paths.isEmpty else { return }
            Task { _ = await actions.extract(paths) }
        case .extractTo:
            // Says so as soon as chosen, not after a folder was chosen.
            guard !paths.isEmpty, !actions.refuseWhileBusy(.operation(.extract)) else { return }
            openExtractToDialog(paths, actions)
        default: break
        }
    }

    /// Duplicate from the context menu: a tree folder's copy goes next to it and is selected in the tree; a search
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

    /// Asked before a write command acts (Cut, Copy and Paste of the Edit menu as the list's own): the list's commands
    /// only with the list focused, Cut and Copy from the tree only on a folder of it (a favorite only points to one),
    /// Paste also with no pane focused.
    static func canRunWriteCommand(_ command: AppCommand, _ context: ShortcutContext) -> Bool {
        let asked: AppCommand =
            switch command {
            case .editCut, .addToCut: .cutSelection
            case .editCopy, .addToCopied, .removeFromClipboard: .copySelection
            case .editPaste, .moveItemsHere: .pasteSelection
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

    /// What Copy and Cut take: the folder selected in the tree while it has the keyboard
    /// (nothing for a favorite, which only points to one), else the items selected in the list.
    static func clipboardSource(
        focusedPane: ExplorerPane?, treeTargetKind: SelectedTreeTargetKind?, treeTargetPath: String?,
        selectedPaths: [String]
    ) -> [String] {
        guard focusedPane == .tree else { return selectedPaths }
        guard treeTargetKind == .filesystemFolder, let treeTargetPath else { return [] }
        return [treeTargetPath]
    }

    var clipboardSourcePaths: [String] {
        Self.clipboardSource(
            focusedPane: focusedPane, treeTargetKind: sidebarController.selectedTreeTargetKind,
            treeTargetPath: sidebarController.selectedTreeTargetPath, selectedPaths: selectedPaths)
    }

    /// Move To's folder: the Move To box (Dialogs/).
    private func chooseMoveDestination(for paths: [String], _ actions: WindowWriteActions) {
        openMoveDialog(paths, actions)
    }

    /// A write ended: the active pane's folder is read again, at its new place if the write moved it, overwriting its
    /// step of the history, what the write made is selected once that pane's own read lists it, and the tree comes
    /// back to the folder, or to the row the write asks for.
    func applyWriteEnd(_ refresh: WriteEndRefresh) {
        // No folder on screen, none to read: this stops here, before the tree too.
        guard !refresh.path.isEmpty else { return }
        let session = group.flatMap { AppWriteOperations.current?.session(for: $0) }
        // The pane the write's end was worked out for, whichever is active by the time its read lands.
        let acting = activePane
        let renaming = session?.pendingInlineRenamePath
        if refresh.selecting != nil || renaming != nil {
            acting.showWriteEnd(
                BrowserPane.WriteEndRead(folder: refresh.path, selecting: refresh.selecting, naming: renaming) {
                    [weak self, weak acting] shown, onDisk in
                    // A folder made since has a name field of its own to wait for.
                    guard let session, session.pendingInlineRenamePath == renaming else { return }
                    if shown, let self, let acting {
                        self.renamePendingFolder(session, in: acting, onDisk: onDisk)
                    } else {
                        session.pendingInlineRenamePath = nil
                    }
                })
        }
        let model = sidebarController.model
        var open = model.openReadingAgain(refresh.path)
        open.selectingRow = refresh.treeSelectionPath
        var treeFollows = false
        if refresh.path == acting.folderPath {
            acting.content.dropFromSelection(refresh.leftPaths)
            acting.readAgain()
            treeFollows = acting.treeFollowsReadingAgain && (open.forceTreeReload || open.selectingRow != nil)
        } else {
            acting.go(to: refresh.path, history: .replace, open: open)
        }
        // The tab's other pane is read again now too, instead of when the folder watch tells of the change: a copy, a
        // move or a drag between the panes changed both. What arrived there is selected. A pane on a folder the write
        // had nothing to do with is left alone.
        for pane in panes where pane !== acting && pane.loaded && !pane.shownFolderPath.isEmpty {
            guard refresh.touched?.mayShow(in: pane.shownFolderPath) ?? true else { continue }
            let arrived = refresh.arrived.flatMap { samePath($0.folder, pane.shownFolderPath) ? $0.paths : nil }
            pane.readAgain(selecting: arrived)
        }
        showExtractedElsewhere(refresh.extracted)
        // The folder stays, so the tree only follows, opening nothing; then what it shows is read again.
        Task { [path = refresh.path] in
            if treeFollows { await model.folderOpened(path, open) }
            if !refresh.treeReloadPaths.isEmpty { await model.refreshWriteBranches(refresh.treeReloadPaths) }
        }
    }
}

extension MainWindowController {
    /// What an Extract made where no pane of the tab shows it (Extract To another folder, archives in search
    /// results) opens in a new tab, or a new window, as Settings says for disk images and archives: one for each
    /// folder it went into (`extractedOpenings`). What went into a folder on screen is selected there instead.
    func showExtractedElsewhere(_ made: [String]) {
        guard !made.isEmpty, let group else { return }
        let shown = panes.compactMap { pane -> String? in
            pane.loaded && pane.searchRootPath == nil && !pane.shownFolderPath.isEmpty ? pane.shownFolderPath : nil
        }
        let inNewWindow = preferences.diskImageOpensIn == .window
        Task { [weak self] in
            // A link is opened as a file, in its folder: what it points to isn't looked at, which may be on a disk
            // that has to be reached first, or anywhere else.
            let kinds = await BlockingWork.run {
                made.map { (try? NativeFileSystem().lstat($0))?.isDirectory ?? false }
            }
            guard let self else { return }
            for opening in Self.extractedOpenings(made, isFolder: kinds, shown: shown) {
                if inNewWindow {
                    group.openNewWindow(from: self, path: opening.path, openedItem: opening.item)
                } else {
                    group.openTab(path: opening.path, from: self, openedItem: opening.item)
                }
            }
        }
    }

    /// The tabs or windows that show what an Extract made, `isFolder` saying which of `made` are folders: one for
    /// each folder something went into that isn't one of `shown`, in the order of what was made, with all of it
    /// selected. A folder made alone in its folder opens on itself.
    static func extractedOpenings(_ made: [String], isFolder: [Bool], shown: [String]) -> [(
        path: String, item: OpenedItem
    )] {
        var groups: [(folder: String, paths: [String], folders: Int)] = []
        for (path, folder) in zip(made, isFolder) {
            guard let parent = ExplorerTabs.parentDirectoryPath(path), !shown.contains(where: { samePath($0, parent) })
            else { continue }
            if let index = groups.firstIndex(where: { samePath($0.folder, parent) }) {
                groups[index].paths.append(path)
                groups[index].folders += folder ? 1 : 0
            } else {
                groups.append((parent, [path], folder ? 1 : 0))
            }
        }
        return groups.map { group in
            if group.paths.count == 1, group.folders == 1 { return (group.paths[0], .folder) }
            return (group.folder, .made(group.paths))
        }
    }
}

extension SidebarModel {
    /// The tree branches a write touched are read again, each from its
    /// folder down through its open folders, a folder read once for all of them. The rest
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
