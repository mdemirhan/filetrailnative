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
        guard pane.viewer == nil, pane.content.selection.paths.count == 1, let path = leadPath(of: pane),
            let entry = pane.content.listedEntry(at: path),
            AliasOriginals.shared.commandKind(entry).isEditableFile
        else { return nil }
        return path
    }

    // MARK: Open in Viewer

    /// File ▸ Open in Viewer (⌘E): the selected file in place of the active pane's folder, a step of its own in the
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

    /// Back, Forward or a jump in the history to a file: its folder, then the file in place of it. False for a
    /// folder, which the history opens as it always has.
    func openFileFromHistory(_ target: String, move: HistoryMove) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isFolder), !isFolder.boolValue,
            let parent = ExplorerTabs.parentDirectoryPath(target)
        else { return false }
        let pane = activePane
        if pane.viewer != nil { return true }
        if samePath(parent, pane.shownFolderPath) {
            switch move {
            case .back: _ = pane.navigationHistory.goBack()
            case .forward: _ = pane.navigationHistory.goForward()
            case .jump(let index): _ = pane.navigationHistory.jump(to: index)
            default: return false
            }
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
                viewer.mode = .following
                viewer.position = nil
                if !Self.isShown(path, in: viewer) { viewer.show(path) }
                self.commandsChanged()
            }
            return
        }
        let folder = ExplorerTabs.parentDirectoryPath(path) ?? target.shownFolderPath
        if !samePath(target.shownFolderPath, folder) { target.go(to: folder) }
        let viewer = openViewer(in: target, mode: .following, path: path, focus: false)
        viewer.folderPath = folder
        focusPane(source)
        notify(.panels)
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
        in pane: BrowserPane, mode: TextViewerController.Mode, path: String?, focus: Bool
    ) -> TextViewerController {
        let viewer = makeViewer(in: pane, mode: mode)
        // The list it covers lets go of the keyboard: the viewer has it while the file is read.
        if focus { window?.makeFirstResponder(viewer.view) }
        viewer.show(path, focus: focus)
        if mode == .inPlace { updatePosition(of: viewer, in: pane) }
        return viewer
    }

    private func makeViewer(in pane: BrowserPane, mode: TextViewerController.Mode) -> TextViewerController {
        let viewer = TextViewerController(mode: mode, settings: preferences.textViewerSettings)
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
            self?.updatePreferences { $0.textViewerSettings = settings }
        }
        viewer.onOpenInEditor = { [weak self] path in self?.openInTextEditor(path) }
        viewer.onFocusChange = { [weak self] in self?.commandsChanged() }
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
        viewer.folderPath = pane.shownFolderPath
        pane.viewer = viewer
        pane.content.showViewer(viewer.view) { [weak viewer] in viewer?.keyboardView }
        commandsChanged()
        return viewer
    }

    /// Closes the viewer of `pane`, after asking about edits, and shows the pane's folder. A file in place leaves its
    /// step in the history, with the file selected and the keyboard in the list.
    @discardableResult
    func closeViewer(in pane: BrowserPane) async -> Bool {
        guard let viewer = pane.viewer else { return true }
        guard await viewer.confirmLeave() else { return false }
        guard pane.viewer === viewer else { return true }
        let hadKeyboard = viewer.hasKeyboard
        pane.viewer = nil
        pane.content.showViewer(nil)
        if viewer.mode == .inPlace, let path = viewer.path {
            if pane.navigationHistory.current.map({ samePath($0, path) }) == true, pane.navigationHistory.canGoBack {
                _ = pane.navigationHistory.goBack()
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
        guard let viewer = commandViewer, viewer.textHasKeyboard else { return false }
        viewer.showFind()
        return true
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

    /// A pane with a viewer went to another folder (the tree, the path bar, a search): the viewer gives way to the
    /// folder, unless it has edits, which stay on screen until they are saved or dropped.
    func viewerPaneMoved(_ pane: BrowserPane) {
        guard let viewer = pane.viewer, !viewer.isDirty, !samePath(pane.shownFolderPath, viewer.folderPath) else {
            return
        }
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
    /// read.
    func restoreViewer(_ saved: ViewerPreference, in pane: BrowserPane) {
        let viewer = makeViewer(in: pane, mode: saved.mode)
        viewer.setPreview(saved.preview)
        viewer.show(saved.path, editing: saved.editing)
        if saved.mode == .following, let path = saved.path {
            viewerSelectsAfterRead = path
        }
    }

    /// A pane finished reading its folder: the file a following viewer showed is selected again in it.
    func viewerPaneRead(_ pane: BrowserPane) {
        if let path = viewerSelectsAfterRead, pane !== viewerPane, pane.content.listedEntry(at: path) != nil {
            viewerSelectsAfterRead = nil
            pane.content.select(paths: [path])
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
