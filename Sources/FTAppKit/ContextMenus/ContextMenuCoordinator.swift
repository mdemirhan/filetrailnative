import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// The right-click menus of one tab: it builds a menu for a click on the file list, its background or a sidebar row,
/// and carries out what is chosen. File operations (cut, paste, rename, trash and the rest) go to `fileOperation`, which
/// Takes over; everything else is done here.
@MainActor
final class ContextMenuCoordinator: ContextMenuResponder {
    unowned let tab: MainWindowController

    var notices: any ActionNoticePresenting = InWindowNoticePresenter()
    var opener: SystemOpener = .workspace
    /// Makes an app what a kind of file opens in; tests give their own, so they leave this Mac's defaults alone.
    var setDefaultApplication: @MainActor (_ appPath: String, _ contentType: String) async -> OperationResult = {
        await SystemActions.setDefaultApplication(applicationPath: $0, contentType: $1)
    }
    /// Where Copy Path puts the paths; tests give it a private pasteboard.
    var pasteboard: NSPasteboard = .general
    /// A file operation chosen in a menu (cut, copy, paste, move, rename, duplicate, new folder, trash, delete
    /// immediately, empty trash). The window carries it out for what the menu acts on.
    var fileOperation: (ContextMenuActionID, ContextMenuSubject) -> Void = { _, _ in }
    /// Search results' "Reveal in Folder".
    var revealSearchResult: (String) -> Void = { _ in }
    /// Get Info for a path: the tab points its Info panel at it. Without one, the panel only opens.
    var showInfo: ((String) -> Void)?
    /// What the clipboard holds, for Paste (the window fills it; the app's shared clipboard by default).
    var clipboardSourcePaths: () -> [String] = { [] }
    private(set) var current: ContextMenuSession?

    init(tab: MainWindowController) {
        self.tab = tab
    }

    /// Puts the menus on the file list's rows and background, and on the sidebar's rows.
    func install() {
        install(on: tab.activePane)
        tab.sidebarController.contextMenuProvider = { [weak self] request in self?.sidebarMenu(for: request) }
    }

    /// A pane's list: a right-click there makes it the active pane first, so the menu acts on it.
    func install(on pane: BrowserPane) {
        pane.content.contextMenuProvider = { [weak self, weak pane] entries in
            guard let self, let pane else { return nil }
            self.tab.activate(pane)
            return self.contentMenu(for: entries)
        }
    }

    // MARK: Building

    private var home: String { DiskPath.home.string }

    func contentMenu(for entries: [DirectoryEntry]?) -> NSMenu? {
        let search = tab.searchRootPath != nil
        let folder = tab.shownFolderPath
        let subject: ContextMenuSubject
        if let entries, !entries.isEmpty {
            // Inside the Trash, items get the full content menu plus "Delete Immediately".
            let surface: ContextMenuSurface =
                search ? .search : (Paths.isInsideTrash(folder, homePath: home) ? .trash : .content)
            subject = ContextMenuSubject(
                surface: surface, scope: .selection, paths: entries.map(\.path), targetPath: entries[0].path,
                entries: entries.map(Self.commandEntry))
        } else {
            // Empty space: a short menu for the folder on screen; under search results, which have no one folder
            // behind them, only how they are shown.
            if !search, folder.isEmpty { return nil }
            subject = ContextMenuSubject(surface: .background, scope: .background)
        }
        return menu(for: subject)
    }

    func sidebarMenu(for request: SidebarContextMenuRequest) -> NSMenu? {
        guard let path = request.item.path else { return nil }
        let surface: ContextMenuSurface = request.kind == .favorite ? .favorite : .treeFolder
        // Eject “Backup”, naming the disk as Finder does; only for a disk that can be ejected.
        let volumes = SidebarVolumes.shared.volumes
        let disk = surface == .favorite && EjectPlanning.isEjectablePath(volumes, path: path)
        let subject = ContextMenuSubject(
            surface: surface, scope: .selection, paths: [path], targetPath: path,
            entries: [CommandEntry(path: path, kind: .directory)],
            ejectableDiskName: disk ? (volumes.first { $0.path == path }?.name ?? "") : nil)
        return menu(for: subject)
    }

    static func commandEntry(_ entry: DirectoryEntry) -> CommandEntry {
        CommandEntry(path: entry.path, kind: AliasOriginals.shared.commandKind(entry))
    }

    func menu(for subject: ContextMenuSubject) -> NSMenu? {
        var world = ContextMenuWorld(
            homePath: home, currentPath: tab.shownFolderPath, isSearchMode: tab.searchRootPath != nil,
            favoritePaths: tab.sidebarController.model.favorites.map(\.path),
            writeLocked: isWriteOperationLocked, showsTwoPanes: tab.showsTwoPanes)
        let destination = ContextMenuRules.pasteDestination(
            subject, world, clipboardSourcePaths: clipboardSourcePaths())
        world.hasPasteDestination = destination != nil
        world.canPaste = clipboardHasItems && destination != nil
        world.pasteAsFileKind = tab.systemClipboard.kind
        world.clipboardCutPaths = tab.services.clipboard.contents.cutPaths
        world.clipboardCopiedPaths = tab.services.clipboard.contents.copiedPaths
        // Whether the Trash has anything to empty matters only where Empty Trash could show. The menu goes by what the
        // tab last read, as reading the Trashes here would hold the menu up behind a slow disk; it is read again behind
        // the menu, for the Trash's bar and the next menu.
        if showsEmptyTrash(subject, world) {
            world.trashIsEmpty = tab.trashIsEmpty
            tab.refreshTrashState()
        }
        let preferences = tab.preferences
        let isTree = subject.surface == .treeFolder || subject.surface == .favorite
        var shortcutContext = ShortcutContext(
            focusedPane: isTree ? .tree : .content,
            selectedTreeTargetKind: isTree ? (subject.surface == .favorite ? .favorite : .filesystemFolder) : nil)
        shortcutContext.mainView = .explorer
        var request = ContextMenuRequest(
            subject: subject, world: world, shortcutContext: shortcutContext,
            shortcuts: ShortcutDisplay(
                shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
                returnKeyAction: preferences.returnKeyAction),
            textEditorName: preferences.defaultTextEditor.appName,
            pinnedApps: preferences.openWithApplications,
            viewMode: tab.searchRootPath != nil ? tab.searchViewMode : tab.activePane.shownMode,
            sortBy: tab.activePane.shownSortBy)
        if tab.showsTwoPanes { request.otherPane = otherPaneItems(subject, request.shortcuts) }
        if subject.surface == .background {
            if !world.isSearchMode { request.folderView = folderViewItems(request.shortcuts) }
            request.groupBy = groupByItems(request.shortcuts)
            if world.isSearchMode { request.resultsSortBy = resultsSortItems(request.shortcuts) }
        }
        if subject.surface == .background, let folder = MainWindowController.templatesFolderPath {
            request.templates = NewFileTemplates.names(in: folder)
        }
        let session = ContextMenuSession(request: request, responder: self)
        current = session
        return session.menu
    }

    private func showsEmptyTrash(_ subject: ContextMenuSubject, _ world: ContextMenuWorld) -> Bool {
        switch subject.surface {
        case .background: Paths.isInsideTrash(world.currentPath, homePath: home)
        case .favorite: subject.targetPath == FavoriteLabel.trashPath(homePath: home)
        default: false
        }
    }

    // MARK: What the window knows

    /// A file operation is running, in this window or another: asked of the window each time, so a tab opened while
    /// one runs knows it too.
    var isWriteOperationLocked: Bool { tab.isWriteLocked }
    /// Something is on the clipboard.
    var clipboardHasItems: Bool {
        if case .ready = tab.services.clipboard.contents { return true }
        return false
    }

    // MARK: ContextMenuResponder

    func contextMenuDidOpen() {
        // Changes made outside the app wait while a menu is open.
        tab.holdFolderChanges(.menu, true)
    }

    func contextMenuDidClose() {
        tab.holdFolderChanges(.menu, false)
        // The right-clicked row's ring goes with the menu.
        tab.sidebarController.model.menuTarget = nil
        current = nil
    }

    func contextMenu(setViewMode mode: ExplorerViewMode) {
        tab.setMode(mode)
    }

    func contextMenu(sortBy field: SortByPreference) {
        tab.sort(by: field)
    }

    func contextMenu(newFile choice: NewFileChoice) {
        switch choice {
        case .textFile: _ = tab.performWriteCommand(.newTextFile)
        case .template(let name): tab.newFileFromTemplate(named: name)
        case .openTemplatesFolder: tab.openTemplatesFolder()
        }
    }

    /// The Other Pane submenu for what the menu is for: Open, Copy and Move for items of the list, and for the list's
    /// background Show This Folder and Go to Its Folder. What can't run now is dimmed, so the submenu keeps its shape.
    /// A folder of the tree or the favorites has one thing to do there, so its menu has Open in Other Pane itself.
    private func otherPaneItems(_ subject: ContextMenuSubject, _ shortcuts: ShortcutDisplay) -> [OtherPaneMenuItem] {
        func key(_ command: AppCommand) -> MenuKeyEquivalent? {
            ShortcutCommandID(rawValue: command.rawValue).flatMap { shortcuts.written($0) }
                .flatMap(MenuKeyEquivalent.parse)
        }
        func item(_ title: String, _ command: AppCommand, _ enabled: Bool) -> OtherPaneMenuItem {
            OtherPaneMenuItem(title: title, command: command, enabled: enabled, key: key(command))
        }
        let other = tab.otherPane
        switch subject.surface {
        case .background:
            let folder = tab.shownFolderPath
            let otherFolder = other?.shownFolderPath ?? ""
            return [
                item("Show This Folder", .showFolderInOtherPane, !folder.isEmpty),
                item("Go to Its Folder", .goToOtherPaneFolder, !otherFolder.isEmpty && otherFolder != folder),
            ]
        case .treeFolder, .favorite:
            return []
        case .content, .search, .trash:
            // One folder shows there; one file shows there in the viewer.
            let oneFolder =
                subject.entries.count == 1
                && (subject.entries[0].kind.opensAsFolder || subject.entries[0].kind.isEditableFile)
            // Into the folder the other pane shows: not when it shows none, search results, the Trash, or this list's
            // folder.
            let destination = other.flatMap(tab.otherPaneDestination) ?? ""
            let fromHere = tab.searchRootPath != nil || destination != tab.shownFolderPath
            let canSend = !subject.paths.isEmpty && !destination.isEmpty && fromHere && !isWriteOperationLocked
            return [
                item("Open", .openSelectionInOtherPane, oneFolder),
                item("Copy", .copyToOtherPane, canSend),
                item("Move", .moveToOtherPane, canSend),
            ]
        }
    }

    /// View ▸ Folder View's items, as the menu bar has them now.
    private func folderViewItems(_ shortcuts: ShortcutDisplay) -> [OtherPaneMenuItem] {
        let canRun = tab.commandAvailability()
        let remembered = tab.activePane.shownFolderView?.isOwnSaved == true
        func item(_ title: String, _ command: AppCommand, checked: Bool = false) -> OtherPaneMenuItem {
            OtherPaneMenuItem(
                title: title, command: command, enabled: canRun(command),
                key: ShortcutCommandID(rawValue: command.rawValue).flatMap { shortcuts.written($0) }
                    .flatMap(MenuKeyEquivalent.parse),
                checked: checked)
        }
        return [
            item("Remember View for This Folder", .rememberFolderView, checked: remembered),
            item("Update Folder View", .updateFolderView), item("Revert to Saved View", .revertFolderView),
            .separator, item("Folder View Options…", .folderViewOptions), .separator,
            item("Reset Folder View", .resetFolderView), item("Manage Folder Views…", .manageFolderViews),
        ]
    }

    /// Sort By's items under search results: their own fields, Folder among them, checked as they are ordered.
    private func resultsSortItems(_ shortcuts: ShortcutDisplay) -> [OtherPaneMenuItem] {
        let current = tab.activePane.resultsSortBy
        return SearchResultsSortByPreference.menuOrder.map { field in
            OtherPaneMenuItem(
                title: field.title, command: field.command, enabled: true,
                key: ShortcutCommandID(rawValue: field.command.rawValue).flatMap { shortcuts.written($0) }
                    .flatMap(MenuKeyEquivalent.parse),
                checked: current == field)
        }
    }

    /// View ▸ Group By's items, as the menu bar has them now: a folder's, or search results' while they show.
    private func groupByItems(_ shortcuts: ShortcutDisplay) -> [OtherPaneMenuItem] {
        let canRun = tab.commandAvailability()
        let searching = tab.searchRootPath != nil
        let grouped = tab.activePane.activeGroupBy
        func item(_ title: String, _ command: AppCommand, checked: Bool = false) -> OtherPaneMenuItem {
            OtherPaneMenuItem(
                title: title, command: command, enabled: canRun(command),
                key: ShortcutCommandID(rawValue: command.rawValue).flatMap { shortcuts.written($0) }
                    .flatMap(MenuKeyEquivalent.parse),
                checked: checked)
        }
        let fields = searching ? GroupByPreference.searchMenuOrder : GroupByPreference.menuOrder
        return [item("None", .groupByNone, checked: grouped == .none), .separator]
            + fields.map { item($0.title, $0.command, checked: grouped == $0) }
            + [
                .separator,
                item("Reverse Group Order", .reverseGroupOrder, checked: tab.activePane.activeGroupReversed),
            ]
    }

    func contextMenu(otherPane command: AppCommand, subject: ContextMenuSubject) {
        switch command {
        case .openSelectionInOtherPane:
            guard let target = subject.targetPath ?? subject.paths.first else { return }
            if subject.entries.first?.kind.isEditableFile == true {
                tab.openFileInOtherPane(target)
            } else {
                tab.openSecondPane(at: target)
            }
        case .copyToOtherPane, .moveToOtherPane:
            tab.sendToOtherPane(subject.paths, copying: command == .copyToOtherPane)
        default:
            tab.perform(command)
        }
    }

    func contextMenu(open paths: [String], with choice: OpenWithAction, kind: OpenWithKind?) {
        holdingTheTab { [self] in await openWith(paths: paths, choice: choice, kind: kind) }
    }

    func contextMenu(toggleTag color: FinderTagColor, paths: [String]) {
        let name = color.systemName
        holdingTheTab { [self] in
            let failures = await BlockingWork.run {
                FinderTags.toggle(color, name: name, on: paths)
            }
            tab.content.tagsChanged(paths)
            showTagFailures(failures)
        }
    }

    /// A choice of the Tags popover: written, the items' tags read again for it, and what couldn't be written said.
    /// Nil when the tags couldn't be read again.
    func changeTags(_ change: TagChange, paths: [String]) async -> FinderTagsOnItems? {
        let (failures, read) = await BlockingWork.run(qos: .userInitiated) {
            let failures =
                switch change {
                case .toggle(let tag): FinderTags.toggle(tag, on: paths)
                case .removeAll: FinderTags.removeAll(from: paths)
                }
            return (failures, FinderTags.onItems(paths))
        }
        tab.content.tagsChanged(paths)
        showTagFailures(failures)
        return read
    }

    /// A change of the permissions popover: written through the app's file operations, as one Undo with the popover's
    /// other changes; the panes and the Info panel read the items again, and what couldn't be changed is said. The
    /// items read again for the popover; nil when nothing could be written.
    func changePermissions(_ change: PermissionsChange, paths: [String], visit: PermissionsVisit) async
        -> PermissionsRead?
    {
        guard let coordinator = AppWriteOperations.current?.coordinator else { return nil }
        let run: PermissionsWriteRun
        do {
            run = try await coordinator.changePermissions(change, paths: paths, visit: visit)
        } catch {
            let message = errorMessage(error)
            notices.show(
                title: Self.permissionsFailureTitle,
                message: message.contains(WriteServiceMessages.writeOperationBusy) ? WriteDialogs.busyMessage : message,
                in: tab.window)
            return await BlockingWork.run(qos: .userInitiated) { PermissionsReader.read(paths) }
        }
        if !run.items.isEmpty { tab.permissionsChanged(run.items.map(\.path)) }
        if let first = run.failures.first {
            notices.show(
                title: Self.permissionsFailureTitle,
                message: "\(ClipboardSummary.leafName(first.path)): \(first.message)"
                    + (run.failures.count > 1
                        ? " \(FormatLocale.count(run.failures.count - 1)) more couldn’t be changed." : ""),
                in: tab.window)
        }
        return await BlockingWork.run(qos: .userInitiated) { PermissionsReader.read(paths) }
    }

    static let permissionsFailureTitle = "Couldn’t Change the Permissions"

    /// Asks before a change takes away your own Open of a folder of yours: `what` is the folder (“Projects”), or how
    /// many.
    func confirmLockOut(_ what: String) async -> Bool {
        await notices.confirm(
            WriteQuestion(
                title: "Turn Off Open for You?",
                message: "You won\u{2019}t be able to open \(what) until it is turned back on.",
                confirmLabel: "Turn Off", destructive: false, cancelIsDefault: true),
            in: tab.window)
    }

    private func showTagFailures(_ failures: [FinderTagFailure]) {
        guard let first = failures.first else { return }
        notices.show(
            title: "Couldn’t Change the Tag",
            message: "\(ClipboardSummary.leafName(first.path)): \(first.message)"
                + (failures.count > 1
                    ? " \(FormatLocale.count(failures.count - 1)) more couldn’t be changed." : ""),
            in: tab.window)
    }

    func contextMenu(perform action: ContextMenuActionID, subject: ContextMenuSubject) {
        // A running operation blocks the others (the menu left them out, unless it began after the menu opened; a key
        // can still ask), and says so. This comes before the actions, some of which ask a
        // question first. A lock this tab hears of late is no refusal: the action goes ahead.
        if ContextMenuRules.writeLockedActions.contains(action), isWriteOperationLocked {
            guard let actions = tab.writeActions, !actions.refuseWhileBusy(busyAction(action, actions)) else { return }
        }
        if subject.surface == .background, ContextMenuRules.backgroundFolderActions.contains(action) {
            backgroundFolderAction(action)
            return
        }
        switch action {
        case .revealInFolder:
            if let first = subject.paths.first { revealSearchResult(first) }
        case .showOriginal:
            if let first = subject.paths.first { tab.showOriginal(of: first) }
        case .copyPath:
            copyPath(subject.paths)
        case .copyContents:
            if let first = subject.paths.first { holdingTheTab { [tab] in await tab.contentsCopier.copy(first) } }
        case .convertImages:
            tab.openConvertImagesSheet(subject.paths)
        case .share:
            tab.share(subject.paths)
        case .tags:
            tab.editTags(subject.paths)
        case .open:
            holdingTheTab { [self] in await openPaths(subject) }
        case .quickLook:
            if let first = subject.paths.first { tab.quickLook(path: first) }
        case .openInViewer:
            if let first = subject.paths.first { tab.openInViewer(first) }
        case .edit:
            holdingTheTab { [self] in await edit(subject) }
        case .showInfo:
            if let first = subject.paths.first { showInfoPanel(for: first) }
        case .calculateSize:
            calculateSize(subject)
        case .toggleFavorite:
            if let first = subject.paths.first { toggleFavorite(first, subject: subject) }
        case .revealInTree:
            if let first = subject.paths.first { tab.sidebarController.revealFavoriteInTree(first) }
        case .rootTreeHere:
            if let target = subject.targetPath ?? subject.paths.first { tab.sidebarController.rootTree(at: target) }
        case .openInNewTab, .openInNewWindow:
            if let target = subject.targetPath ?? subject.paths.first {
                openFolder(target, subject: subject, inWindow: action == .openInNewWindow)
            }
        case .openInOtherPane:
            contextMenu(otherPane: .openSelectionInOtherPane, subject: subject)
        case .showPackageContents:
            if let first = subject.paths.first { tab.go(to: first) }
        case .terminal:
            if let first = subject.paths.first { holdingTheTab { [self] in await openTerminal(first) } }
        case .showInFinder:
            if !subject.paths.isEmpty { holdingTheTab { [self] in await showInFinder(subject.paths) } }
        case .eject:
            if let target = subject.targetPath ?? subject.paths.first { tab.sidebarController.eject(target) }
        case .cut, .copy, .paste, .pasteAsFile, .move, .rename, .duplicate, .makeAlias, .newFolder,
            .newFolderWithSelection, .trash, .deleteImmediately, .emptyTrash, .compress, .extract, .extractTo,
            .saveAsTemplate:
            fileOperation(action, subject)
        case .addToCopied, .addToCut, .switchClipboardMode, .removeFromClipboard:
            tab.contextMenuClipboardAction(action, subject)
        case .openWith, .viewAs, .sortBy, .otherPane, .newFile, .folderView, .groupBy:
            break
        }
    }

    /// The operation a blocked item would have started, which the notice is titled for.
    private func busyAction(_ action: ContextMenuActionID, _ actions: WindowWriteActions) -> WriteStartAction {
        switch action {
        case .paste:
            if actions.session.clipboard?.contents.mode == .cut { return .operation(.moveTo) }
            return .operation(.paste)
        case .move: return .operation(.moveTo)
        case .rename: return .operation(.rename)
        case .duplicate: return .operation(.duplicate)
        case .makeAlias: return .operation(.makeAlias)
        case .convertImages: return .operation(.convertImages)
        case .newFolder: return .operation(.newFolder)
        case .newFolderWithSelection: return .operation(.newFolderWithSelection)
        case .saveAsTemplate: return .operation(.copyTo)
        case .pasteAsFile: return .operation(.pasteAsFile)
        case .compress: return .operation(.compress)
        case .extract, .extractTo: return .operation(.extract)
        case .trash: return .operation(.trash)
        case .deleteImmediately: return .operation(.deleteImmediately)
        default: return .emptyTrash
        }
    }

    // MARK: The folder on screen

    /// The background's actions act on the folder on screen, which the menu does not carry as a path.
    private func backgroundFolderAction(_ action: ContextMenuActionID) {
        let folder = tab.shownFolderPath
        guard !folder.isEmpty else { return }
        switch action {
        case .showInfo: showInfoPanel(for: folder)
        case .calculateSize:
            // With nothing selected the status bar shows the folder on screen's size.
            tab.folderSizes.recalculate(folder)
        case .copyPath: copyPath([folder])
        case .terminal: holdingTheTab { [self] in await openTerminal(folder) }
        default: holdingTheTab { [self] in await showInFinder([folder]) }
        }
    }

    // MARK: Actions

    /// Asks the system something for the tab. The window can close before the answer comes, and what follows the answer
    /// reads `tab`: the tab stays until then.
    private func holdingTheTab(_ work: @escaping @MainActor () async -> Void) {
        Task { @MainActor [tab] in
            await work()
            withExtendedLifetime(tab) {}
        }
    }

    private func showInfoPanel(for path: String) {
        if let showInfo {
            showInfo(path)
        } else {
            tab.updatePanels { $0.propertiesOpen = true }
        }
    }

    private func calculateSize(_ subject: ContextMenuSubject) {
        // The status bar shows the size as it comes in: the selection's, which a right-clicked item is part of.
        if subject.entries.count > 1 {
            tab.folderSizes.calculate(
                subject.entries.filter { $0.kind.isFolderSizeEligible }.map(\.path), recalculate: true)
            return
        }
        guard let target = subject.targetPath ?? subject.paths.first else { return }
        tab.folderSizes.recalculate(target)
        // A folder in the sidebar is not selected in the list, so the status bar shows it only when it is the folder on
        // screen, and the Size column only when it is a row there in the List. Anywhere else only the Info panel can
        // show its size.
        let isSidebarFolder = subject.surface == .treeFolder || subject.surface == .favorite
        let preferences = tab.preferences
        let shownInSizeColumn =
            tab.searchRootPath == nil && tab.activePane.shownMode == .details
            && tab.activePane.shownPreferences(preferences).detailColumns.size
            && tab.content.entries.contains { $0.path == target }
        if isSidebarFolder, target != tab.shownFolderPath, !shownInSizeColumn {
            showInfoPanel(for: target)
        }
    }

    private func toggleFavorite(_ path: String, subject: ContextMenuSubject) {
        let wasFavorite = tab.sidebarController.isFavorite(path)
        tab.sidebarController.toggleFavorite(path)
        // Taking a favorite out from its own menu shows the folder in the tree.
        if wasFavorite, subject.surface == .favorite { tab.sidebarController.revealFavoriteInTree(path) }
    }

    private func openFolder(_ path: String, subject: ContextMenuSubject, inWindow: Bool) {
        // A symbolic link or an alias of a folder opens the folder it leads to, as it does when it is opened in place.
        let kind = subject.entries.first { DiskPath($0.path) == DiskPath(path) }?.kind
        let open: (String) -> Void = { [tab] folder in
            if inWindow {
                tab.group?.openNewWindow(from: tab, path: folder)
            } else {
                tab.group?.openTab(path: folder, from: tab)
            }
        }
        guard kind?.isLink == true else { return open(path) }
        // Where it leads, as the disk spells it, asked off the main thread: it may lead into a slow disk.
        holdingTheTab { [tab] in
            guard let original = await MainWindowController.original(of: path) else {
                return tab.showOriginalMissing(path)
            }
            if original.isFolder { open(original.path) }
        }
    }

    // MARK: Open, Edit, Open With

    private var openItemLimit: Int { tab.preferences.openItemLimit }

    /// `openPaths`: one item on screen goes through what it is; of several, the archives are extracted together and the
    /// rest, folders included, handed to the system item by item.
    private func openPaths(_ subject: ContextMenuSubject) async {
        let paths = subject.paths
        guard !paths.isEmpty else { return }
        if paths.count > openItemLimit {
            notices.show(
                title: "Too Many Items to Open",
                message: ActionNoticeText.openItemLimit("Open", selected: paths.count, limit: openItemLimit),
                in: tab.window)
            return
        }
        if paths.count == 1, let entry = tab.content.entries.first(where: { DiskPath($0.path) == DiskPath(paths[0]) }) {
            await openEntry(entry)
            return
        }
        // A folder or a package named as an archive is isn't one: the system opens it with the rest.
        let folders = Set(subject.entries.filter(OpenItems.isFolderNamedAsArchive).map(\.path))
        let archives = paths.filter { ArchiveNames.isArchive(NodePath.basename($0)) && !folders.contains($0) }
        for path in paths where !archives.contains(path) {
            if folders.contains(path) { await handToSystem(path) } else { await openExternally(path) }
        }
        tab.extractToOpen(archives)
    }

    /// Opens one item: a folder, or a symbolic link or an alias of one, opens in the tab; anything else is handed to
    /// the system, a link or an alias as the item it leads to.
    private func openEntry(_ entry: DirectoryEntry) async {
        switch OpenItems.step(for: Self.commandEntry(entry)) {
        case .navigate, .resolveThenNavigate, .resolveThenFollow:
            // A folder is never edited, so the tab's own opening goes where this one does.
            tab.open([entry])
        case .resolveThenOpen(let path):
            guard let original = await MainWindowController.original(of: path) else {
                return tab.showOriginalMissing(path)
            }
            await openExternally(original.path)
        case .openExternally(let path):
            await openExternally(path)
        case .handToSystem(let path):
            await handToSystem(path)
        case .extract(let paths):
            tab.extractToOpen(paths)
        }
    }

    /// The system opens it, whatever its name. A failure is only logged.
    private func handToSystem(_ path: String) async {
        tab.onFolderUsed?()
        ActionNoticeText.logOpenFailure(await SystemActions.openPath(path, opener: opener))
    }

    /// A failure is only logged.
    private func openExternally(_ path: String) async {
        if tab.noteUseAndOpenDiskImage(path) { return }
        if ArchiveNames.isArchive(NodePath.basename(path)) {
            tab.extractToOpen([path])
            return
        }
        ActionNoticeText.logOpenFailure(await SystemActions.openPath(path, opener: opener))
    }

    private func edit(_ subject: ContextMenuSubject) async {
        guard !subject.paths.isEmpty, subject.entries.count == subject.paths.count,
            subject.entries.allSatisfy({ $0.kind.isEditableFile })
        else { return }
        if subject.paths.count > openItemLimit {
            notices.show(
                title: "Too Many Items to Edit",
                message: ActionNoticeText.openItemLimit("Edit", selected: subject.paths.count, limit: openItemLimit),
                in: tab.window)
            return
        }
        let editor = tab.preferences.defaultTextEditor
        await openPaths(subject.paths, with: editor.appPath, name: editor.appName)
    }

    /// An app of the Open With list was chosen: Other… asks which app; Always Open With asks first, as Finder does.
    private func openWith(paths: [String], choice: OpenWithAction, kind: OpenWithKind?) async {
        guard !paths.isEmpty else { return }
        let selection: (path: String, name: String)
        let always: Bool
        switch choice {
        case .application(_, _, let appPath, let appName, let isAlways):
            selection = (appPath, appName)
            always = isAlways
        case .other(_, _, _, let isAlways):
            let picked = await SystemPickers.pickApplication(window: tab.window)
            guard !picked.canceled, let path = picked.appPath, let name = picked.appName else { return }
            selection = (path, name)
            always = isAlways
        }
        if always, let kind, !kind.isFolder {
            guard await notices.confirmAlwaysOpenWith(appName: selection.name, kindName: kind.name, in: tab.window)
            else { return }
            let result = await setDefaultApplication(selection.path, kind.contentType)
            guard result.ok else {
                notices.show(
                    title: "Couldn’t Change the App",
                    message:
                        "\(kind.name.map { "\($0) files" } ?? "These files") still open in the app they opened in before. \(result.error ?? "macOS refused the change.")",
                    in: tab.window)
                return
            }
            OpenWithCatalog.shared.forget()
        }
        await openPaths(paths, with: selection.path, name: selection.name)
    }

    private func openPaths(_ paths: [String], with appPath: String, name: String) async {
        tab.onFolderUsed?()
        let result = await SystemActions.openPaths(paths, withApplication: appPath, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: ActionNoticeText.openFailureTitle(name),
            message: ActionNoticeText.openFailureMessage(
                count: paths.count, appName: name, detail: result.error ?? "\(name) didn’t answer."),
            in: tab.window)
    }

    /// As the commands ask for it.
    func openInTerminal(_ path: String) {
        holdingTheTab { [self] in await openTerminal(path) }
    }

    /// As the commands ask for it.
    func revealInFinder(_ paths: [String]) {
        holdingTheTab { [self] in await showInFinder(paths) }
    }

    private func openTerminal(_ path: String) async {
        tab.onFolderUsed?()
        let result = await SystemActions.openInTerminal(
            path: path, terminalApp: tab.preferences.terminalApp, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: ActionNoticeText.terminalFailureTitle, message: ActionNoticeText.terminalFailureMessage,
            in: tab.window)
    }

    private func showInFinder(_ paths: [String]) async {
        let result = await SystemActions.openPaths(
            paths, withApplication: ApplicationPaths.finderAppPath, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: ActionNoticeText.finderFailureTitle,
            message: ActionNoticeText.finderFailureMessage(count: paths.count, detail: result.error),
            in: tab.window)
    }

    // MARK: Copy Path

    /// The paths, one to a line and shell-quoted where they have whitespace, on the pasteboard.
    func copyPath(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let text = paths.map(formatPathForShell).joined(separator: "\n")
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            notices.show(
                title: paths.count == 1 ? "Couldn’t Copy the Path" : "Couldn’t Copy the Paths",
                message: "File Trail couldn’t put them on the clipboard.", in: tab.window)
            return
        }
        tab.notifications?.toasts.push(
            .success, title: paths.count == 1 ? "Copied path" : "Copied paths",
            message: ClipboardSummary.summary(paths))
    }
}

/// The first name, and how many more.
enum ClipboardSummary {
    static func summary(_ paths: [String]) -> String {
        guard let first = paths.first else { return "item" }
        let name = leafName(first)
        return paths.count <= 1 ? name : "\(name) and \(FormatLocale.count(paths.count - 1)) more"
    }

    static func leafName(_ path: String) -> String {
        ProgressCardText.leafName(path)
    }
}
