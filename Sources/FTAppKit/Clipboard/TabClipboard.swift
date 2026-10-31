// Port of the clipboard's parts of apps/desktop/src/renderer/App.tsx (:761-812, 1584) and of ClipboardButton.tsx's
// open state and placement, and of hooks/useExplorerActions.ts (revealClipboardItem, removeClipboardItem,
// clearClipboard, the clipboard source): one tab's side of the app's clipboard
import AppKit
import FTFileSystem
import FTFoundation
import FTOperations

/// One tab's clipboard: the marks on its rows and their flash, the list under the toolbar's button, and what Copy
/// takes from its panes.
@MainActor
final class TabClipboard {
    private weak var tab: MainWindowController?
    private var flash = ClipboardFlashTracker()
    private(set) var menu: ClipboardMenuView?
    private var popover: AnchoredPopover?
    private var popoverKeys: Any?
    private weak var anchor: NSView?
    /// The list was opened by a click on the button, which has the page's focus in the original.
    private var openedByClick = false
    private var keys: Int?
    private var observers: [any NSObjectProtocol] = []

    init(tab: MainWindowController) {
        self.tab = tab
    }

    // MARK: Marks

    /// The marks the rows show now, without a flash.
    var marks: ClipboardMarks? {
        guard let tab else { return nil }
        return ClipboardMarks(tab.services.clipboard.contents, enabled: tab.preferences.markClipboardItems)
    }

    /// The clipboard or the setting changed: the rows mark it again, and flash for a new Copy or Cut.
    func marksChanged() {
        guard let tab else { return }
        let contents = tab.services.clipboard.contents
        let flashes = flash.changed(to: contents)
        let marks = marks
        tab.content.clipboardMarksChanged(marks, flash: flashes && marks != nil)
        tab.sidebarController.clipboardMarksChanged(marks, flash: flashes && marks != nil)
        // An emptied clipboard closes its list (and a later Copy doesn't open it again).
        if let menu {
            if let summary = ClipboardRules.describe(contents) {
                menu.update(summary)
                popover?.setSize(menu.fittingSize(viewportWidth: Double(tab.window?.contentView?.bounds.width ?? 0)))
            } else {
                close()
            }
        }
    }

    // MARK: The list

    var isOpen: Bool { menu != nil }

    /// The toolbar's button was clicked: the list opens or closes.
    func toggle(from button: NSView) {
        if isOpen {
            close()
        } else {
            open(from: button)
            openedByClick = isOpen
        }
    }

    /// Show Clipboard: only while the clipboard holds something.
    func show() {
        guard let tab, !isOpen, let button = tab.explorerToolbar.clipboardButton else { return }
        open(from: button)
    }

    private func open(from button: NSView) {
        guard let tab, let window = tab.window, let host = window.contentView,
            let summary = ClipboardRules.describe(tab.services.clipboard.contents)
        else { return }
        AppMenuPresenter.shared.close()
        let display = ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(tab.preferences.shortcutOverrides),
            returnKeyAction: tab.preferences.returnKeyAction)
        let hint = display.label(.paste).map { "Paste with \($0)" } ?? "Ready to paste"
        let view = ClipboardMenuView(summary: summary, pasteHint: hint)
        view.iconStore = tab.services.iconStore
        view.onReveal = { [weak self] path in
            self?.close()
            self?.tab?.revealClipboardItem(path)
        }
        view.onRemove = { [weak self] path in self?.remove(path) }
        view.onClear = { [weak self] in self?.tab?.clearClipboard() }
        menu = view
        anchor = button
        let popover = AnchoredPopover(content: view, size: view.fittingSize(viewportWidth: Double(host.bounds.width)))
        self.popover = popover
        popover.show(from: button, in: window)
        (button as? ToolbarButton)?.isOn = true
        keys = WindowEventRouting.add(window) { [weak self] event in self?.intercept(event) ?? false }
        // A click inside can give the popover the keyboard, though the window stays the main one: the keys still go here.
        popoverKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) var passed: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self, let shown = self.popover?.window, event.window === shown else { return }
                passed = self.popoverKey(event)
            }
            return passed
        }
        // Not when the window only stops being key: that happens for a click in the popover too.
        if NSApp.isActive {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignMainNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } })
        }
    }

    func close() {
        guard let menu else { return }
        self.menu = nil
        popover?.close()
        popover = nil
        if let popoverKeys { NSEvent.removeMonitor(popoverKeys) }
        popoverKeys = nil
        menu.removeFromSuperview()
        (anchor as? ToolbarButton)?.isOn = false
        (anchor as? ToolbarClipboardButton)?.showsKeyboardRing = false
        openedByClick = false
        anchor = nil
        if let keys, let window = tab?.window { WindowEventRouting.remove(keys, from: window) }
        keys = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// A key the popover has: the list takes it, or, closed by it, lets it go on as a key of the window, whose shortcuts
    /// and menu bar it is for. The popover's own window is gone by then.
    func popoverKey(_ event: NSEvent) -> NSEvent? {
        if intercept(event) { return nil }
        guard let window = tab?.window else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
            characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    /// The window's events while the list is open: its keys go to it first, and a press outside it (and its button)
    /// closes it.
    func intercept(_ event: NSEvent) -> Bool {
        guard let menu else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.window === menu.window, menu.bounds.contains(menu.convert(event.locationInWindow, from: nil)) {
                return false
            }
            if let anchor, anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return false }
            close()
            return false
        case .keyDown:
            if openedByClick, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) {
                (anchor as? ToolbarClipboardButton)?.showsKeyboardRing = true
            }
            switch menu.key(event) {
            case .handled: return true
            case .close:
                close()
                return true
            case .closeAndPass:
                close()
                return false
            case .reveal(let path):
                close()
                tab?.revealClipboardItem(path)
                return true
            case .remove(let path):
                remove(path)
                return true
            case .clear:
                tab?.clearClipboard()
                return true
            }
        default:
            return false
        }
    }

    /// The × of an item: only it goes; the list stays open.
    private func remove(_ path: String) {
        guard let tab else { return }
        let clipboard = tab.services.clipboard
        clipboard.set(ClipboardRules.removeItem(clipboard.contents, path), from: tab.windowID)
        tab.clipboardChanged()
    }
}

extension MainWindowController {
    /// The marks follow the clipboard and the setting.
    func clipboardMarksChanged() {
        clipboardUI.marksChanged()
    }

    /// `showClipboard`: the list opens under the toolbar's button.
    func showClipboard() {
        clipboardUI.show()
    }

    /// `clearClipboard`: the clipboard is emptied, in every window.
    func clearClipboard() {
        services.clipboard.set(.empty, from: windowID)
        clipboardChanged()
    }

    /// `revealClipboardItem`: the item's folder opens (in place when it is on screen already) with the item selected,
    /// and the list has the keyboard.
    func revealClipboardItem(_ path: String) {
        let parent = ClipboardRules.parentPath(path)
        let selectIt = { [weak self] in
            guard let self else { return }
            self.content.select(paths: [path])
            self.content.focusList()
        }
        if samePath(parent, shownFolderPath) {
            selectIt()
            return
        }
        final class Once {
            var token: ExplorerWindowObservation?
        }
        let once = Once()
        once.token = observe { [weak self, once] change in
            guard change == .folder, let self, let token = once.token, token.isValid else { return }
            token.invalidate()
            once.token = nil
            if samePath(self.folder.path, parent) { selectIt() }
        }
        go(to: URL(fileURLWithPath: parent, isDirectory: true))
    }

    /// What Copy records of each item (B-CLIP-006): from the list, its kind, link and executable flags; from the tree,
    /// a folder.
    var clipboardSourceEntries: [String: ClipboardSourceEntry] {
        if focusedPane == .tree {
            guard let path = sidebarController.selectedTreeTargetPath else { return [:] }
            return [path: ClipboardSourceEntry(kind: .directory, isSymlink: false)]
        }
        var entries: [String: ClipboardSourceEntry] = [:]
        let selected = Set(selectedPaths.map(PathBox.init))
        for entry in content.entries where selected.contains(PathBox(entry.path)) {
            entries[entry.path] = ClipboardSourceEntry(
                kind: entry.kind.rules, isSymlink: entry.isSymlink, isExecutable: entry.isExecutable)
        }
        return entries
    }

    /// `resolvePasteDestinationPath` for the keyboard and the menu bar: the folder on screen, never search results
    /// or the Trash.
    var pasteDestinationPath: String? {
        PasteDestination.resolve(
            menu: nil, clipboardSourcePaths: services.clipboard.contents.sourcePaths, currentPath: shownFolderPath,
            isSearchMode: searchRootPath != nil, homePath: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}

extension MainWindowController {
    /// A file operation chosen in a right-click menu (`runContextMenuAction`): Copy and Cut take the menu's items
    /// (the folder of a tree row or favorite), Paste goes where the menu says (into its folder, or the folder on
    /// screen from the background); the others are the matching commands.
    func contextMenuFileOperation(_ action: ContextMenuActionID, _ subject: ContextMenuSubject) {
        guard let actions = writeActions else { return }
        switch action {
        case .copy, .cut:
            guard !subject.paths.isEmpty else { return }
            let tree = subject.surface == .treeFolder || subject.surface == .favorite
            var entries: [String: ClipboardSourceEntry] = [:]
            for entry in subject.entries {
                entries[entry.path] = ClipboardSourceEntry(kind: tree ? .directory : entry.kind, isSymlink: false)
            }
            if !tree {
                let listed = Set(subject.paths.map(PathBox.init))
                for entry in content.entries where listed.contains(PathBox(entry.path)) {
                    entries[entry.path] = ClipboardSourceEntry(
                        kind: entry.kind.rules, isSymlink: entry.isSymlink, isExecutable: entry.isExecutable)
                }
            }
            actions.putOnClipboard(action == .cut ? .cut : .copy, paths: subject.paths, entries: entries)
        case .paste:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let world = ContextMenuWorld(
                homePath: home, currentPath: shownFolderPath, isSearchMode: searchRootPath != nil,
                writeLocked: isWriteLocked)
            guard
                let destination = ContextMenuRules.pasteDestination(
                    subject, world, clipboardSourcePaths: services.clipboard.contents.sourcePaths)
            else { return }
            Task { await actions.pasteFromClipboard(into: destination) }
        default: break
        }
    }
}

extension WindowWriteActions {
    /// A copy-like start that found clashes goes to the review.
    func reviewIfAsked(_ outcome: CopyLikeOutcome, action: WriteOperationAction, clearsCutClipboard: String? = nil) {
        guard case .review(let report) = outcome else { return }
        PasteReview.presenter.review(report, action: action, clearsCutClipboard: clearsCutClipboard, actions: self)
    }
}
