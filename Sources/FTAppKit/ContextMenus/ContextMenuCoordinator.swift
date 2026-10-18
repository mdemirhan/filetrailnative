// Port of openItemContextMenu, openTreeItemContextMenu and runContextMenuAction (apps/desktop/src/renderer/hooks/useExplorerActions.ts)
import AppKit
import FTFileSystem
import FTFoundation

/// The right-click menus of one tab: it builds a menu for a click on the file list, its background or a sidebar row,
/// and carries out what is chosen. File operations (cut, paste, rename, trash and the rest) go to `fileOperation`, which
/// P5-08 takes over; everything else is done here.
@MainActor
final class ContextMenuCoordinator: ContextMenuResponder {
    unowned let tab: MainWindowController

    var notices: any ActionNoticePresenting = AlertNoticePresenter()
    var opener: SystemOpener = .workspace
    /// Where Copy Path puts the paths; tests give it a private pasteboard.
    var pasteboard: NSPasteboard = .general
    /// A file operation chosen in a menu (cut, copy, paste, move, rename, duplicate, new folder, trash, delete
    /// immediately, empty trash). By default it is sent as the matching command for what the menu acts on, which does
    /// something once P5-08 has the commands; the sidebar's folders are P5-08's to act on.
    var fileOperation: (ContextMenuActionID, ContextMenuSubject) -> Void = { _, _ in }
    /// Search results' "Reveal in Folder" (P5-07).
    var revealSearchResult: (String) -> Void = { _ in }
    /// Show Info for a path (P5-04's panel); by default the panel opens.
    var showInfo: ((String) -> Void)?
    /// What the clipboard holds, for Paste (P5-08 fills it; the app's shared clipboard by default).
    var clipboardSourcePaths: () -> [String] = { [] }
    private(set) var current: ContextMenuSession?

    init(tab: MainWindowController) {
        self.tab = tab
    }

    /// Puts the menus on the file list's rows and background, and on the sidebar's rows.
    func install() {
        tab.content.contextMenuProvider = { [weak self] entries in self?.contentMenu(for: entries) }
        tab.sidebarController.contextMenuProvider = { [weak self] request in self?.sidebarMenu(for: request) }
    }

    // MARK: Building

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    func contentMenu(for entries: [DirectoryEntry]?) -> NSMenu? {
        let search = tab.searchRootPath != nil
        let folder = tab.folder.path
        let subject: ContextMenuSubject
        if let entries, !entries.isEmpty {
            // Inside the Trash, items get the full content menu plus "Delete Immediately".
            let surface: ContextMenuSurface =
                search ? .search : (Paths.isInsideTrash(folder, homePath: home) ? .trash : .content)
            subject = ContextMenuSubject(
                surface: surface, scope: .selection, paths: entries.map(\.path), targetPath: entries[0].path,
                entries: entries.map(Self.commandEntry))
        } else {
            // Empty space: a short menu for the folder on screen. Search results have no single folder behind them,
            // so there is no menu there.
            if search || folder.isEmpty { return nil }
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
        CommandEntry(path: entry.path, kind: FTFoundation.EntryKind(rawValue: entry.kind.rawValue) ?? .other)
    }

    func menu(for subject: ContextMenuSubject) -> NSMenu? {
        var world = ContextMenuWorld(
            homePath: home, currentPath: tab.folder.path, isSearchMode: tab.searchRootPath != nil,
            favoritePaths: tab.sidebarController.model.favorites.map(\.path),
            writeLocked: isWriteOperationLocked)
        let destination = ContextMenuRules.pasteDestination(
            subject, world, clipboardSourcePaths: clipboardSourcePaths())
        world.hasPasteDestination = destination != nil
        world.canPaste = clipboardHasItems && destination != nil
        // Whether the Trash has anything to empty is looked at only where Empty Trash could show.
        if showsEmptyTrash(subject, world) {
            world.trashIsEmpty = TrashState.isEmpty(home: home, uid: getuid())
        }
        let preferences = tab.preferences
        let isTree = subject.surface == .treeFolder || subject.surface == .favorite
        var shortcutContext = ShortcutContext(
            focusedPane: isTree ? .tree : .content,
            selectedTreeTargetKind: isTree ? (subject.surface == .favorite ? .favorite : .filesystemFolder) : nil)
        shortcutContext.mainView = .explorer
        let request = ContextMenuRequest(
            subject: subject, world: world, shortcutContext: shortcutContext,
            shortcuts: ShortcutDisplay(
                shortcuts: ShortcutCommands.resolve(preferences.shortcutOverrides),
                returnKeyAction: preferences.returnKeyAction),
            textEditorName: preferences.defaultTextEditor.appName,
            pinnedApps: preferences.openWithApplications,
            viewMode: tab.searchRootPath != nil ? tab.searchViewMode : tab.viewMode, sortBy: tab.sortBy)
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

    /// A file operation is running, in any tab (`isWriteOperationLocked`); P5-08 sets this.
    var isWriteOperationLocked = false
    /// Something is on the clipboard.
    var clipboardHasItems: Bool {
        if case .ready = tab.services.clipboard.contents { return true }
        return false
    }

    // MARK: ContextMenuResponder

    func contextMenuDidOpen() {
        // Changes made outside the app wait while a menu is open (B-VIEW-187).
        tab.folderChangesHeld = true
    }

    func contextMenuDidClose() {
        tab.folderChangesHeld = false
        // The right-clicked row's ring goes with the menu.
        tab.sidebarController.model.menuTarget = nil
        current = nil
    }

    func contextMenu(openedSubmenu id: ContextMenuActionID) {
        #if DEBUG
            AutomationSubmenuMarker.show(in: tab.window)
        #endif
    }

    func contextMenu(setViewMode mode: ExplorerViewMode) {
        tab.setMode(mode)
    }

    func contextMenu(sortBy field: SortByPreference) {
        tab.sort(by: field)
    }

    func contextMenu(open paths: [String], with choice: OpenWithAction, kind: OpenWithKind?) {
        Task { @MainActor in await openWith(paths: paths, choice: choice, kind: kind) }
    }

    func contextMenu(perform action: ContextMenuActionID, subject: ContextMenuSubject) {
        // A running operation blocks the others (the menu left them out already; a key can still ask).
        if ContextMenuRules.writeLockedActions.contains(action), isWriteOperationLocked {
            return
        }
        if subject.surface == .background, ContextMenuRules.backgroundFolderActions.contains(action) {
            backgroundFolderAction(action)
            return
        }
        switch action {
        case .revealInFolder:
            if let first = subject.paths.first { revealSearchResult(first) }
        case .copyPath:
            copyPath(subject.paths)
        case .open:
            Task { @MainActor in await openPaths(subject) }
        case .quickLook:
            if let first = subject.paths.first { tab.quickLook(path: first) }
        case .edit:
            Task { @MainActor in await edit(subject) }
        case .showInfo:
            if let first = subject.paths.first { showInfoPanel(for: first) }
        case .calculateSize:
            calculateSize(subject)
        case .toggleFavorite:
            if let first = subject.paths.first { toggleFavorite(first, subject: subject) }
        case .revealInTree:
            if let first = subject.paths.first { tab.sidebarController.reveal(first) }
        case .rootTreeHere:
            if let target = subject.targetPath ?? subject.paths.first { tab.sidebarController.rootTree(at: target) }
        case .openInNewTab, .openInNewWindow:
            if let target = subject.targetPath ?? subject.paths.first {
                openFolder(target, subject: subject, inWindow: action == .openInNewWindow)
            }
        case .showPackageContents:
            if let first = subject.paths.first { tab.go(to: URL(fileURLWithPath: first)) }
        case .terminal:
            if let first = subject.paths.first { Task { @MainActor in await openTerminal(first) } }
        case .showInFinder:
            if !subject.paths.isEmpty { Task { @MainActor in await showInFinder(subject.paths) } }
        case .eject:
            if let target = subject.targetPath ?? subject.paths.first { tab.sidebarController.eject(target) }
        case .cut, .copy, .paste, .move, .rename, .duplicate, .newFolder, .trash, .deleteImmediately, .emptyTrash:
            fileOperation(action, subject)
        case .openWith, .viewAs, .sortBy:
            break
        }
    }

    // MARK: The folder on screen

    /// The background's actions act on the folder on screen, which the menu does not carry as a path.
    private func backgroundFolderAction(_ action: ContextMenuActionID) {
        let folder = tab.folder.path
        guard !folder.isEmpty else { return }
        switch action {
        case .showInfo: showInfoPanel(for: folder)
        case .calculateSize:
            // With nothing selected the status bar shows the folder on screen's size.
            tab.folderSizes.calculate(folder)
        case .copyPath: copyPath([folder])
        case .terminal: Task { @MainActor in await openTerminal(folder) }
        default: Task { @MainActor in await showInFinder([folder]) }
        }
    }

    // MARK: Actions

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
            tab.folderSizes.calculate(subject.entries.filter { $0.kind.isFolderSizeEligible }.map(\.path))
            return
        }
        guard let target = subject.targetPath ?? subject.paths.first else { return }
        tab.folderSizes.calculate(target)
        // A folder in the sidebar is not selected in the list, so the status bar shows it only when it is the folder on
        // screen, and the Size column only when it is a row there in the List. Anywhere else only the Info panel can
        // show its size.
        let isSidebarFolder = subject.surface == .treeFolder || subject.surface == .favorite
        let preferences = tab.preferences
        let shownInSizeColumn =
            tab.searchRootPath == nil && tab.viewMode == .details && preferences.detailColumns.size
            && tab.content.entries.contains { $0.path == target }
        if isSidebarFolder, target != tab.folder.path, !shownInSizeColumn {
            showInfoPanel(for: target)
        }
    }

    private func toggleFavorite(_ path: String, subject: ContextMenuSubject) {
        let wasFavorite = tab.sidebarController.isFavorite(path)
        tab.sidebarController.toggleFavorite(path)
        // Taking a favorite out from its own menu shows the folder in the tree.
        if wasFavorite, subject.surface == .favorite { tab.sidebarController.reveal(path) }
    }

    private func openFolder(_ path: String, subject: ContextMenuSubject, inWindow: Bool) {
        // An alias of a folder opens the folder it points to, as it does when it is opened in place.
        let isAlias = subject.entries.first { $0.path == path }?.kind == .symlinkDirectory
        let resolved = isAlias ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        if inWindow {
            tab.group?.openNewWindow(from: tab, path: resolved)
        } else {
            tab.group?.openTab(path: resolved, from: tab)
        }
    }

    // MARK: Open, Edit, Open With

    private var openItemLimit: Int { tab.preferences.openItemLimit }

    /// `openPaths`: the entries open (a folder in place), up to the item limit.
    private func openPaths(_ subject: ContextMenuSubject) async {
        let entries = tab.content.entries.filter { entry in subject.paths.contains(entry.path) }
        guard !subject.paths.isEmpty else { return }
        if subject.paths.count > openItemLimit {
            notices.show(
                title: "Too Many Items to Open",
                message: ActionNoticeText.openItemLimit("Open", selected: subject.paths.count, limit: openItemLimit),
                in: tab.window)
            return
        }
        if entries.count == subject.paths.count {
            tab.open(entries)
        } else {
            for path in subject.paths { _ = await SystemActions.openPath(path, opener: opener) }
        }
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
            let result = await SystemActions.setDefaultApplication(
                applicationPath: selection.path, contentType: kind.contentType)
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
        let result = await SystemActions.openPaths(paths, withApplication: appPath, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: ActionNoticeText.openFailureTitle(name),
            message: ActionNoticeText.openFailureMessage(
                count: paths.count, appName: name, detail: result.error ?? "\(name) didn’t answer."),
            in: tab.window)
    }

    private func openTerminal(_ path: String) async {
        let result = await SystemActions.openInTerminal(
            path: path, terminalApp: tab.preferences.terminalApp, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: "Couldn’t Open Terminal", message: "File Trail couldn’t open the terminal app in this folder.",
            in: tab.window)
    }

    private func showInFinder(_ paths: [String]) async {
        let result = await SystemActions.openPaths(
            paths, withApplication: ApplicationPaths.finderAppPath, opener: opener)
        guard !result.ok else { return }
        notices.show(
            title: "Couldn’t Show in Finder",
            message:
                "Finder couldn’t show \(paths.count == 1 ? "it" : "them"). \(result.error ?? "Finder didn’t answer.")",
            in: tab.window)
    }

    // MARK: Copy Path

    /// `runCopyPathAction`: the paths, one to a line and shell-quoted where they have whitespace, on the pasteboard.
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

/// `formatClipboardItemSummary`: the first name, and how many more.
enum ClipboardSummary {
    static func summary(_ paths: [String]) -> String {
        guard let first = paths.first else { return "item" }
        let name = leafName(first)
        return paths.count <= 1 ? name : "\(name) and \(paths.count - 1) more"
    }

    static func leafName(_ path: String) -> String {
        ProgressCardText.leafName(path)
    }
}
