// A file shown in a pane: in place of its folder (Open in Viewer), or in the other pane, following the list's
// selection (Open in Other Pane on a file)
import AppKit
import FTFileSystem
import FTFoundation

extension MainWindowController {
    /// The pane showing a file beside the other one, following its selection or not.
    var viewerPane: BrowserPane? {
        panes.first { $0.viewer.map { $0.mode != .inPlace } ?? false }
    }

    /// The pane whose selection the viewer beside it follows.
    private var followedPane: BrowserPane? {
        guard let viewerPane else { return nil }
        return panes.first { $0 !== viewerPane }
    }

    /// The item the selection leads with in `pane`.
    private func leadPath(of pane: BrowserPane) -> String? {
        let selection = pane.content.selection
        return selection.leadPath ?? selection.paths.first
    }

    /// The one file selected in the active pane, when it is one a viewer shows.
    var selectedViewableFile: String? {
        let pane = activePane
        guard pane.viewer == nil else { return nil }
        return selectedFile(of: pane)
    }

    // MARK: Open in Viewer

    /// File ▸ Open in Viewer (⇧⌘E): the selected file in place of the active pane's folder, a step of its own in the
    /// pane's Back and Forward. Back, Esc and ⌘W return to the folder with the file selected.
    func viewFile() {
        guard let path = selectedViewableFile else { return }
        let pane = activePane
        pane.navigationHistory.record(path, mode: .push)
        openViewer(in: pane, mode: .inPlace, path: path, focus: true)
        paneChanged(.history, in: pane)
    }

    /// Open in Viewer from a file's right-click menu: that file, selected first.
    func openInViewer(_ path: String) {
        activePane.content.select(paths: [path])
        viewFile()
    }

    /// Next File and Previous File, from the viewer's bar, its menu or its keys: the file in place steps to the
    /// folder's next or previous file as the list orders them, which the list selects under it, so Back lands on it.
    func stepFile(by step: Int) {
        guard let pane = panes.first(where: { $0.viewer?.mode == .inPlace && $0.viewer === commandViewer }),
            let viewer = pane.viewer, let path = viewer.path
        else { return }
        let files = viewableFiles(of: pane)
        guard let index = files.firstIndex(where: { samePath($0, path) }), files.count > 1 else { return }
        let next = files[(index + step + files.count) % files.count]
        Task { [weak self] in
            guard await viewer.confirmLeave(), let self, pane.viewer === viewer else { return }
            pane.content.select(paths: [next])
            pane.navigationHistory.record(next, mode: .replace)
            viewer.show(next, focus: true)
            self.updatePosition(of: viewer, in: pane)
            self.paneChanged(.history, in: pane)
        }
    }

    private func viewableFiles(of pane: BrowserPane) -> [String] {
        // An alias not looked up yet is stepped to as well: the viewer says so if it leads to a folder.
        pane.content.listed.filter { $0.kind.isViewableFile || $0.kind == .alias }.map(\.path)
    }

    private func updatePosition(of viewer: TextViewerController, in pane: BrowserPane) {
        let files = viewableFiles(of: pane)
        if let path = viewer.path, let index = files.firstIndex(where: { samePath($0, path) }) {
            viewer.position = (index, files.count)
        } else {
            viewer.position = nil
        }
    }

    /// Back, Forward or a jump in the history to a file: its folder, then the file in place of it. A file shown in
    /// place already gives way to it, after asking about its edits: one a link in Markdown's Preview led from or to.
    /// False for a folder, which the history opens as it always has.
    func openFileFromHistory(_ target: String, move: HistoryMove) -> Bool {
        guard Self.isFile(target), let parent = ExplorerTabs.parentDirectoryPath(target) else { return false }
        let pane = activePane
        if let viewer = pane.viewer {
            guard viewer.mode == .inPlace else { return true }
            Task { [weak self] in
                guard await viewer.confirmLeave(), let self, pane.viewer === viewer, self.activePane === pane else {
                    return
                }
                if samePath(parent, pane.shownFolderPath) {
                    guard Self.step(move, in: &pane.navigationHistory) else { return }
                    if pane.content.listedEntry(at: target) != nil { pane.content.select(paths: [target]) }
                    viewer.show(target, focus: true)
                    self.updatePosition(of: viewer, in: pane)
                    self.paneChanged(.history, in: pane)
                } else if await self.navigate(to: parent, history: move), self.activePane === pane, pane.viewer == nil {
                    pane.content.select(paths: [target])
                    self.openViewer(in: pane, mode: .inPlace, path: target, focus: true)
                }
            }
            return true
        }
        if samePath(parent, pane.shownFolderPath) {
            guard Self.step(move, in: &pane.navigationHistory) else { return false }
            pane.content.select(paths: [target])
            openViewer(in: pane, mode: .inPlace, path: target, focus: true)
            paneChanged(.history, in: pane)
            return true
        }
        Task { [weak self] in
            guard let self, await self.navigate(to: parent, history: move),
                self.activePane === pane, pane.viewer == nil
            else { return }
            pane.content.select(paths: [target])
            self.openViewer(in: pane, mode: .inPlace, path: target, focus: true)
        }
        return true
    }

    /// Whether something is at `path` that isn't a folder.
    private static func isFile(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
    }

    /// Moves `history` as `move` says, Back, Forward or a jump; false for any other move.
    private static func step(_ move: HistoryMove, in history: inout NavigationHistory) -> Bool {
        switch move {
        case .back: _ = history.goBack()
        case .forward: _ = history.goForward()
        case .jump(let index): _ = history.jump(to: index)
        default: return false
        }
        return true
    }

    /// Back while the active pane shows a file in place and the step before isn't the folder under it: a file there,
    /// one a link in Markdown's Preview led from, shows in its place; another folder opens as Back opens one, after
    /// asking about the file's edits. False otherwise: Back shows the folder under the file (`leaveFileInPlace`).
    func backFromFileInPlace() -> Bool {
        let pane = activePane
        guard let viewer = pane.viewer, viewer.mode == .inPlace, let target = pane.navigationHistory.backTarget,
            !samePath(target, pane.shownFolderPath)
        else { return false }
        if openFileFromHistory(target, move: .back) { return true }
        afterLeavingViewer(of: pane) { $0.go(to: target, history: .back) }
        return true
    }

    // MARK: Links in Markdown's Preview

    /// A link clicked in the Preview of `viewer`, the viewer of `pane`. A web page or an email address opens in the
    /// app the system has for it. A file shows in the same viewer, at the heading the link names: in place of the
    /// folder as a step of Back, its own folder opened first if it is in another; beside the list, the viewer stops
    /// following it. A folder opens in the pane as a step of Back, and a package is selected in its folder, never
    /// opened. One that isn't there says so. A file with edits not saved is asked about first.
    func openLink(_ link: MarkdownLink, from viewer: TextViewerController, in pane: BrowserPane) {
        switch link {
        case .heading:
            return
        case .other(let url):
            openFile(url)
        case .disk(let path, let heading):
            Task { [weak self] in
                let found = await BlockingWork.run { () -> (path: String, isFolder: Bool)? in
                    let named = DiskPath(path).itemAsOnDisk().string
                    var isFolder: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: named, isDirectory: &isFolder) else { return nil }
                    return (named, isFolder.boolValue)
                }
                guard let self, pane.viewer === viewer else { return }
                guard let found else { return self.showLinkMissing(path) }
                guard await viewer.confirmLeave(), pane.viewer === viewer else { return }
                if self.activePane !== pane { self.activate(pane) }
                if found.isFolder && NSWorkspace.shared.isFilePackage(atPath: found.path) {
                    self.revealOriginal(found.path)
                } else if found.isFolder {
                    self.go(to: found.path)
                } else {
                    await self.showLinkedFile(found.path, heading: heading, in: viewer, of: pane)
                }
            }
        }
    }

    private func showLinkedFile(
        _ path: String, heading: String?, in viewer: TextViewerController, of pane: BrowserPane
    ) async {
        guard viewer.mode == .inPlace else {
            viewer.mode = .pinned
            viewer.position = nil
            viewer.show(path, focus: true, heading: heading)
            commandsChanged()
            return
        }
        let parent = DiskPath(path).parent.string
        guard samePath(parent, pane.shownFolderPath) else {
            guard await navigate(to: parent), activePane === pane, pane.viewer == nil else { return }
            pane.content.select(paths: [path])
            pane.navigationHistory.record(path, mode: .push)
            openViewer(in: pane, mode: .inPlace, path: path, focus: true, heading: heading)
            paneChanged(.history, in: pane)
            return
        }
        if pane.content.listedEntry(at: path) != nil { pane.content.select(paths: [path]) }
        pane.navigationHistory.record(path, mode: .push)
        viewer.show(path, focus: true, heading: heading)
        updatePosition(of: viewer, in: pane)
        paneChanged(.history, in: pane)
    }

    private func showLinkMissing(_ path: String) {
        showNotice(
            title: "The Linked Item Can\u{2019}t Be Found",
            message:
                "\u{201C}\(NodePath.basename(path))\u{201D} isn\u{2019}t there. It may have been moved or deleted, or be on a disk or a server that isn\u{2019}t connected."
        )
    }

    // MARK: In the other pane

    /// Open in Other Pane on a file: the other pane shows it in the viewer, and follows the list's selection from then
    /// on. With one pane, the second opens first, as it does for a folder.
    func openFileInOtherPane(_ path: String) {
        let source = activePane
        let target = otherPane ?? openSecondPane(reopening: false)
        if let viewer = target.viewer {
            Task { [weak self] in
                if !Self.isShown(path, in: viewer) {
                    guard await viewer.confirmLeave() else { return }
                }
                guard let self else { return }
                viewer.mode = target.viewerDefaults.follows ? .following : .pinned
                viewer.position = nil
                if !Self.isShown(path, in: viewer) { viewer.show(path) }
                self.commandsChanged()
            }
            return
        }
        let folder = ExplorerTabs.parentDirectoryPath(path) ?? target.shownFolderPath
        if !samePath(target.shownFolderPath, folder) { target.go(to: folder, cause: .viewersFolder) }
        openViewer(in: target, mode: target.viewerDefaults.follows ? .following : .pinned, path: path, focus: false)
        focusPane(source)
        notify(.panels)
    }

    /// A tab view's viewer: `pane` shows the file `list` selects, following its selection or staying on that file,
    /// read or edited. The keyboard stays in the list.
    ///
    /// A viewer there already takes this on. Shown the same file the same way, it keeps it, edits and all: only how
    /// it follows changes. Another file, or the same one read rather than edited, asks about edits not saved first,
    /// and Cancel leaves the viewer as it was. A file shown in place of the pane's folder gives way first, as Back
    /// would.
    func showTabViewViewer(_ setting: PaneViewer, in pane: BrowserPane, beside list: BrowserPane) {
        let mode: TextViewerController.Mode = setting.follows ? .following : .pinned
        guard let viewer = pane.viewer else {
            let viewer = makeViewer(in: pane, mode: mode)
            viewer.show(leadPath(of: list), editing: setting.editing)
            focusPane(list)
            notify(.panels)
            return
        }
        if viewer.mode == .inPlace {
            Task { [weak self] in
                guard let self, await closeViewer(in: pane), pane.viewer == nil else { return }
                showTabViewViewer(setting, in: pane, beside: list)
            }
            return
        }
        if Self.isShown(leadPath(of: list), in: viewer), viewer.isEditing == setting.editing {
            follow(with: viewer, mode: mode, beside: list)
            return
        }
        Task { [weak self] in
            if viewer.isDirty {
                guard await viewer.confirmLeave() else { return }
            }
            // The question may have been open a while: the viewer may be gone, and the list may select another file.
            guard let self, pane.viewer === viewer else { return }
            follow(with: viewer, mode: mode, beside: list)
            viewer.show(leadPath(of: list), editing: setting.editing)
        }
    }

    /// A tab view's viewer over the pane's own list: the file selected there, in place of the folder, as Open in
    /// Viewer shows it (a step of Back and Forward), read or edited as `setting` says; with no file selected, the
    /// viewer opens with nothing in it, and Esc shows the list. A viewer the pane shows already stays, with its file
    /// and its edits. In the active pane the viewer takes the keyboard from the list it covers, as Open in Viewer's
    /// does.
    func showTabViewViewerInPlace(_ setting: PaneViewer, in pane: BrowserPane) {
        guard pane.viewer == nil else { return }
        let path = selectedFile(of: pane)
        if let path { pane.navigationHistory.record(path, mode: .push) }
        let viewer = makeViewer(in: pane, mode: .inPlace)
        let focus = pane === activePane
        if focus { window?.makeFirstResponder(viewer.view) }
        viewer.show(path, focus: focus, editing: setting.editing)
        updatePosition(of: viewer, in: pane)
        if path != nil { paneChanged(.history, in: pane) }
        notify(.panels)
    }

    /// The one file `pane` selects, when it is one a viewer shows.
    private func selectedFile(of pane: BrowserPane) -> String? {
        guard pane.content.selection.paths.count == 1, let path = leadPath(of: pane),
            let entry = pane.content.listedEntry(at: path), AliasOriginals.shared.commandKind(entry).isEditableFile
        else { return nil }
        return path
    }

    /// `viewer` follows `list` as `mode` says, the keyboard in the list.
    private func follow(with viewer: TextViewerController, mode: TextViewerController.Mode, beside list: BrowserPane) {
        viewer.mode = mode
        viewer.position = nil
        focusPane(list)
        commandsChanged()
    }

    /// The selection of `pane` changed: the viewer beside it shows its lead item a moment after the last change, as
    /// the Info panel waits (`InfoMetrics.fetchDelay`), so holding an arrow key reads only where it stops. A file
    /// with unsaved edits is asked about first; Cancel keeps it, and the list's selection goes back to it.
    func followSelection(of pane: BrowserPane) {
        guard let viewerPane, viewerPane !== pane, let viewer = viewerPane.viewer, viewer.mode == .following else {
            return
        }
        let path = leadPath(of: pane)
        guard !Self.isShown(path, in: viewer) else { return }
        viewerFollowNumber += 1
        let number = viewerFollowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + InfoMetrics.fetchDelay) { [weak self, weak viewer] in
            MainActor.assumeIsolated {
                guard let self, let viewer, number == self.viewerFollowNumber, viewer.mode == .following,
                    !Self.isShown(path, in: viewer)
                else { return }
                self.follow(path, in: viewer, from: pane)
            }
        }
    }

    private func follow(_ path: String?, in viewer: TextViewerController, from pane: BrowserPane) {
        guard viewer.isDirty else {
            viewer.show(path)
            return
        }
        // Nothing selected, or another folder: the edited file stays on screen until something else is chosen.
        guard let path, !viewerAsking else { return }
        viewerAsking = true
        Task { [weak self] in
            let leave = await viewer.confirmLeave()
            guard let self else { return }
            self.viewerAsking = false
            if leave {
                // The selection may have moved on while the question was open.
                viewer.show(self.leadPath(of: pane) ?? path)
            } else if let kept = viewer.path, pane.content.listedEntry(at: kept) != nil {
                pane.content.select(paths: [kept])
            }
        }
    }

    /// Follow, in the bar of a viewer beside the list: on shows the list's selection again, after asking about
    /// edits; off keeps the file on screen whatever the list selects.
    private func setFollow(_ on: Bool, viewer: TextViewerController) {
        // The pane's from then on: a viewer opened in it after starts the same way.
        if let pane = panes.first(where: { $0.viewer === viewer }) {
            pane.setViewSize { $0.viewerFollows = on }
            group?.tabChanged(self)
        }
        guard on else {
            viewer.mode = .pinned
            commandsChanged()
            return
        }
        viewer.mode = .following
        if let source = followedPane, !Self.isShown(leadPath(of: source), in: viewer) {
            follow(leadPath(of: source), in: viewer, from: source)
        }
        commandsChanged()
    }

    // MARK: Making and closing

    @discardableResult
    private func openViewer(
        in pane: BrowserPane, mode: TextViewerController.Mode, path: String?, focus: Bool, heading: String? = nil
    ) -> TextViewerController {
        let viewer = makeViewer(in: pane, mode: mode)
        // The list it covers lets go of the keyboard: the viewer has it while the file is read.
        if focus { window?.makeFirstResponder(viewer.view) }
        viewer.show(path, focus: focus, heading: heading)
        if mode == .inPlace { updatePosition(of: viewer, in: pane) }
        return viewer
    }

    private func makeViewer(in pane: BrowserPane, mode: TextViewerController.Mode) -> TextViewerController {
        let viewer = TextViewerController(
            mode: mode, settings: preferences.textViewerSettings, opensForEditing: pane.viewerDefaults.editing)
        _ = viewer.view
        viewer.onClose = { [weak self, weak pane] in
            guard let self, let pane else { return }
            Task { await self.closeViewer(in: pane) }
        }
        viewer.onPrevious = { [weak self] in self?.stepFile(by: -1) }
        viewer.onNext = { [weak self] in self?.stepFile(by: 1) }
        viewer.onFollowChange = { [weak self, weak viewer] on in
            guard let viewer else { return }
            self?.setFollow(on, viewer: viewer)
        }
        viewer.onStateChange = { [weak self] in self?.commandsChanged() }
        viewer.onSettingsChange = { [weak self] settings in
            // Read or Edit is the panes' (`onEditingChosen`): the viewer's look leaves the app's as it is.
            self?.updatePreferences {
                let editing = $0.textViewerSettings.opensForEditing
                $0.textViewerSettings = settings
                $0.textViewerSettings.opensForEditing = editing
            }
        }
        viewer.onEditingChosen = { [weak self, weak pane] editing in
            guard let pane else { return }
            pane.changeOwnSettings { $0.viewerEditing = editing }
            if let self { self.group?.tabChanged(self) }
        }
        viewer.onOpenInEditor = { [weak self] path in self?.openInTextEditor(path) }
        viewer.onFocusChange = { [weak self] in self?.commandsChanged() }
        viewer.onMoved = { [weak self, weak pane, weak viewer] old, new in
            guard let self, let pane, let viewer, pane.viewer === viewer else { return }
            self.viewerFileMoved(viewer, in: pane, from: old, to: new)
        }
        viewer.onGone = { [weak self, weak pane, weak viewer] in
            guard let self, let pane, let viewer, pane.viewer === viewer else { return }
            if viewer.mode == .inPlace { viewer.position = nil }
            self.commandsChanged()
        }
        viewer.onLink = { [weak self, weak pane, weak viewer] link in
            guard let self, let pane, let viewer else { return }
            self.openLink(link, from: viewer, in: pane)
        }
        viewer.onStatusChange = { [weak pane] status in pane?.content.contentShell.pathBarRow.fileStatus = status }
        viewer.onTab = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.tabKeyPressed(from: pane)
        }
        viewer.commandForKey = { [weak self] event in
            guard let self, let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)) else {
                return nil
            }
            return ShortcutCommands.resolve(self.preferences.shortcutOverrides).command(pressed: pressed)
        }
        viewer.keyLabel = { [weak self] id in
            guard let self else { return nil }
            return ShortcutDisplay(shortcuts: ShortcutCommands.resolve(self.preferences.shortcutOverrides)).label(id)
        }
        pane.viewer = viewer
        pane.content.showViewer(viewer.view) { [weak viewer] in viewer?.keyboardView }
        commandsChanged()
        return viewer
    }

    /// Closes the viewer of `pane`, after asking about edits, and shows the pane's folder. A file in place leaves its
    /// step in the history, with the file selected and the keyboard in the list: Back to the folder, or the folder a
    /// step of its own after a file a link in Markdown's Preview led from, so Back comes back to the file.
    @discardableResult
    func closeViewer(in pane: BrowserPane) async -> Bool {
        guard let viewer = pane.viewer else { return true }
        guard await viewer.confirmLeave() else { return false }
        guard pane.viewer === viewer else { return true }
        let hadKeyboard = viewer.hasKeyboard
        pane.viewer = nil
        pane.content.showViewer(nil)
        if viewer.mode == .inPlace, let path = viewer.path {
            let history = pane.navigationHistory
            if history.current.map({ samePath($0, path) }) == true, let back = history.backTarget {
                if !samePath(back, pane.shownFolderPath) && Self.isFile(back) {
                    pane.navigationHistory.record(pane.shownFolderPath, mode: .push)
                } else {
                    _ = pane.navigationHistory.goBack()
                }
                paneChanged(.history, in: pane)
            }
            if pane.content.listedEntry(at: path) != nil { pane.content.select(paths: [path]) }
        }
        if hadKeyboard || pane === activePane { focusPane(pane) }
        commandsChanged()
        notify(.panels)
        return true
    }

    /// Whether every pane's file may be left: each with edits asks in turn.
    func confirmLeavingViewers() async -> Bool {
        for pane in panes {
            if let viewer = pane.viewer, viewer.isDirty {
                guard await viewer.confirmLeave() else { return false }
            }
        }
        return true
    }

    var hasUnsavedViewer: Bool { panes.contains { $0.viewer?.isDirty == true } }

    /// The tabs of `window` (nil: of every window) with a file whose edits aren't saved.
    static func tabsWithUnsavedFiles(in window: NSWindow?) -> [MainWindowController] {
        let windows = window.map { $0.tabbedWindows ?? [$0] } ?? NSApp.windows
        return windows.compactMap { ($0 as? ExplorerTabWindow)?.explorerTab }.filter(\.hasUnsavedViewer)
    }

    /// Asks about each file with edits in `window`'s tabs (nil: every window's), its tab brought forward: true once all
    /// are saved or dropped, false on Cancel.
    static func confirmUnsavedFiles(in window: NSWindow?) async -> Bool {
        for tab in tabsWithUnsavedFiles(in: window) {
            tab.window?.makeKeyAndOrderFront(nil)
            guard await tab.confirmLeavingViewers() else { return false }
        }
        return true
    }

    var activePaneShowsFile: Bool { activePane.viewer != nil }

    /// A key for a PDF or Quick Look's preview a viewer shows with the keyboard in it, taken before the view with the
    /// keyboard sees it (`TextViewerController.pagesKey`).
    func viewerPagesKey(_ event: NSEvent) -> Bool {
        guard !isDialogOpen else { return false }
        return panes.contains { $0.viewer?.pagesKey(event) == true }
    }

    /// A key let go reaches every viewer: one gliding with an arrow held down eases to a stop. It goes on as it would.
    func viewerKeyUp(_ event: NSEvent) {
        for pane in panes { pane.viewer?.arrowKeyUp(event) }
    }

    /// A press in the viewer whose view is `root`: its pane becomes the active one, and the viewer takes the keyboard
    /// unless something in it (its text, its find bar) has it already.
    func viewerPressed(_ root: NSView) {
        guard let pane = panes.first(where: { $0.viewer?.view === root }), let viewer = pane.viewer else { return }
        activate(pane)
        if !viewer.hasKeyboard { window?.makeFirstResponder(viewer.keyboardView) }
    }

    // MARK: Commands

    /// The viewer the window's commands reach: the one with the keyboard, else the active pane's.
    var commandViewer: TextViewerController? {
        if let pane = panes.first(where: { $0.viewer?.hasKeyboard == true }) { return pane.viewer }
        return activePane.viewer
    }

    /// Save File's key (⌘S unless Settings changes it): the file the active pane shows, while it has edits; the viewer
    /// with the keyboard is in that pane. False for any other key, in a pane showing a folder, and with no edits, so
    /// the key goes on as it would.
    func saveViewerKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !isDialogOpen,
            let pressed = Shortcuts.fromKeyboardEvent(ContentKeyboard.shortcutEvent(event)),
            ShortcutCommands.resolve(preferences.shortcutOverrides).command(pressed: pressed) == .saveViewerFile
        else { return false }
        guard let viewer = activePane.viewer, viewer.isDirty else { return false }
        viewer.save()
        return true
    }

    /// ⌘F from the menu while the viewer's text has the keyboard: the find bar over the text.
    func findInViewer() -> Bool {
        guard let viewer = commandViewer, viewer.findTakesKeyboard else { return false }
        viewer.showFind()
        return true
    }

    /// Go ▸ Go to Page…: asks for a page of the PDF, or a slide of the presentation, the pane shows, and shows it. A
    /// number it doesn't have is refused under the field.
    func goToPage() {
        guard let viewer = commandViewer, viewer.pageCount > 1, let window else { return }
        let noun = viewer.showsSlides ? "Slide" : "Page"
        let count = viewer.pageCount
        let prompt = NamePrompt(
            title: "Go to \(noun)", message: "\(noun) 1 to \(FormatLocale.count(count))", label: noun,
            submitLabel: "Go", initialName: "\((viewer.pageIndex ?? 0) + 1)", selectsAll: true)
        Task { [weak viewer] in
            await InWindowAlerts.askName(prompt, in: window) { text in
                guard let number = Int(text.trimmingCharacters(in: .whitespaces)), (1...count).contains(number) else {
                    return .refuse("Type a number from 1 to \(FormatLocale.count(count)).")
                }
                viewer?.goToPage(number - 1)
                return .close
            }
            if let viewer { window.makeFirstResponder(viewer.keyboardView) }
        }
    }

    /// Back, Enclosing Folder and ⌘W while the active pane shows a file: its folder again.
    func leaveFileInPlace() -> Bool {
        guard activePane.viewer != nil else { return false }
        let pane = activePane
        Task { await closeViewer(in: pane) }
        return true
    }

    /// Every viewer of the tab takes the viewer's settings and its keys as they now are.
    func viewerSettingsChanged() {
        for pane in panes {
            pane.viewer?.settings = preferences.textViewerSettings
            // Its ⋯ menu writes the keys Settings → Shortcuts has now.
            pane.viewer?.refreshChrome()
        }
    }

    /// A command sent a pane with a viewer to another folder, and it arrived (the tree, the path bar, Back, a search's
    /// result): the viewer gives way to the folder, unless it has edits, which stay on screen until they are saved or
    /// dropped. Nothing the pane reads on its own closes it (`NavigationCause`).
    func paneWasSentElsewhere(_ pane: BrowserPane) {
        guard let viewer = pane.viewer, !viewer.isDirty else { return }
        pane.viewer = nil
        pane.content.showViewer(nil)
        commandsChanged()
        notify(.panels)
    }

    /// ⌘W closes the innermost thing first: a file a pane shows, then the pane, then the tab.
    func closePaneLeavingViewer() {
        if leaveFileInPlace() { return }
        closePane()
    }

    /// Runs `action` once the viewer of `pane`, if it has edits, may be left.
    func afterLeavingViewer(of pane: BrowserPane?, _ action: @escaping (MainWindowController) -> Void) {
        guard let viewer = pane?.viewer, viewer.isDirty else {
            action(self)
            return
        }
        Task { [weak self] in
            guard await viewer.confirmLeave(), let self else { return }
            action(self)
        }
    }

    /// Opens `path` in the text editor chosen in Settings.
    func openInTextEditor(_ path: String) {
        perform(OpenItems.editPlan([path], limit: preferences.openItemLimit))
    }

    // MARK: Saved with the tab

    /// What the pane keeps of its viewer in a saved tab, a workspace, Reopen Closed Tab and a pane closed with ⌘\.
    func savedViewer(of pane: BrowserPane) -> ViewerPreference? {
        guard let viewer = pane.viewer else { return nil }
        if viewer.mode != .following && viewer.path == nil { return nil }
        return ViewerPreference(
            mode: viewer.mode, path: viewer.path, preview: viewer.showsPreview, editing: viewer.isEditing)
    }

    /// A pane comes back with the file it showed, read or edited as it was. A following viewer's file is selected
    /// again in the pane beside it, once that pane has read its folder, so the window opens showing what was being
    /// read. A following viewer's pane opened again beside a list in use (`beside`, Two Panes after it was closed)
    /// follows that list as it is now instead: it shows what the list selects, which keeps its selection.
    func restoreViewer(_ saved: ViewerPreference, in pane: BrowserPane, beside list: BrowserPane? = nil) {
        let viewer = makeViewer(in: pane, mode: saved.mode)
        viewer.setPreview(saved.preview)
        if saved.mode == .following, let list {
            viewer.show(leadPath(of: list), editing: saved.editing)
            return
        }
        viewer.show(saved.path, editing: saved.editing)
        if saved.mode == .following, let path = saved.path {
            viewerSelectsAfterRead = path
        }
    }

    /// The file a viewer shows was moved or renamed. In place, its step of the history goes with it, so Back and
    /// Forward find it, and it is placed among its folder's files again: none, once it has left the folder. Beside the
    /// list, nothing more: what follows the list shows what the list selects, and a viewer that doesn't stays on it.
    private func viewerFileMoved(
        _ viewer: TextViewerController, in pane: BrowserPane, from old: String, to new: String
    ) {
        guard viewer.mode == .inPlace else { return }
        if pane.navigationHistory.current.map({ samePath($0, old) }) == true {
            pane.navigationHistory.record(new, mode: .replace)
            paneChanged(.history, in: pane)
        }
        updatePosition(of: viewer, in: pane)
    }

    /// File Trail renamed or moved items: each pane's viewer follows its file (`TextViewerController.follow`).
    func viewersFollow(_ moves: [PathMove]) {
        for pane in panes { pane.viewer?.follow(moves) }
    }

    /// The list under a file in place was read: the file's place among the folder's files follows.
    func inPlaceViewerListChanged(in pane: BrowserPane) {
        if let viewer = pane.viewer, viewer.mode == .inPlace { updatePosition(of: viewer, in: pane) }
    }

    /// A pane finished its first read: the file a following viewer showed is selected again in the list beside it,
    /// if that list has it. Either way nothing waits any more, so no later read selects it.
    func viewerPaneRead(_ pane: BrowserPane) {
        if let path = viewerSelectsAfterRead, pane !== viewerPane {
            viewerSelectsAfterRead = nil
            if pane.content.listedEntry(at: path) != nil { pane.content.select(paths: [path]) }
        }
        if let viewer = pane.viewer, viewer.mode == .inPlace { updatePosition(of: viewer, in: pane) }
    }
}

extension MainWindowController {
    /// Whether `viewer` shows the file at `path`, or shows nothing for nil: paths are told apart by their bytes, as
    /// two names that differ only in how an accent is spelled are two files.
    static func isShown(_ path: String?, in viewer: TextViewerController) -> Bool {
        switch (path, viewer.path) {
        case (nil, nil): true
        case (let path?, let shown?): samePath(path, shown)
        default: false
        }
    }
}

extension FTFileSystem.EntryKind {
    /// A file, or a link to one: what Open in Viewer shows.
    var isViewableFile: Bool { self == .file || self == .symlinkFile }
}
