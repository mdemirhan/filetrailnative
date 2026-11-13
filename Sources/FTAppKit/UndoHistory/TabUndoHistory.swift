// One tab's Undo History list under its toolbar button
import AppKit
import FTFoundation
import FTOperations

/// One tab's Undo History list: it opens under the toolbar's button, follows the history while open (an Undo made
/// with ⌘Z shows in it at once), and closes on Escape, a press outside it, or once there is nothing left to list.
@MainActor
final class TabUndoHistory {
    private weak var tab: MainWindowController?
    private(set) var view: UndoHistoryView?
    private var list: ToolbarListPopover?
    private var stopListening: (@MainActor () -> Void)?
    /// The rows built while the list is open: a change to the history builds only the rows that are new.
    private var rows = UndoHistoryRowCache()

    init(tab: MainWindowController) {
        self.tab = tab
    }

    var isOpen: Bool { view != nil }

    /// The history the tab's toolbar follows.
    private var history: UndoHistory? { tab?.explorerToolbar.undoHistory() }

    /// The history as the list shows it.
    private func content() -> UndoHistoryContent? {
        guard let history else { return nil }
        let content = UndoHistoryRows.content(
            history, homePath: FileManager.default.homeDirectoryForCurrentUser.path, cache: rows)
        return content.isEmpty ? nil : content
    }

    /// The toolbar's button was clicked: the list opens or closes.
    func toggle(from button: NSView) {
        if isOpen {
            close()
        } else {
            open(from: button)
        }
    }

    private func open(from button: NSView) {
        guard let tab, let window = tab.window, let host = window.contentView, let history, let content = content()
        else { return }
        tab.clipboardUI.close()
        AppMenuPresenter.shared.close()
        let display = ShortcutDisplay(
            shortcuts: ShortcutCommands.resolve(tab.preferences.shortcutOverrides),
            returnKeyAction: tab.preferences.returnKeyAction)
        let view = UndoHistoryView(content: content, undoKey: display.label(.undo), redoKey: display.label(.redo))
        self.view = view
        let list = ToolbarListPopover(
            content: view, size: view.fittingSize(viewportWidth: Double(host.bounds.width)),
            key: { [weak self] event in self?.key(event) ?? false }, dismiss: { [weak self] in self?.close() })
        self.list = list
        list.show(from: button, in: window)
        stopListening = history.onChange { [weak self] in self?.historyChanged() }
    }

    func close() {
        guard view != nil else { return }
        view = nil
        stopListening?()
        stopListening = nil
        list?.close()
        list = nil
        rows = UndoHistoryRowCache()
    }

    /// An operation, an Undo or a Redo ended: the list shows it, or closes with nothing left to list.
    private func historyChanged() {
        guard let view else { return }
        guard let content = content() else {
            close()
            return
        }
        view.update(content)
        view.layoutSubtreeIfNeeded()
        let width = Double(tab?.window?.contentView?.bounds.width ?? 0)
        list?.setSize(view.fittingSize(viewportWidth: width))
    }

    /// Escape closes the list; the other keys go on to the window (⌘Z undoes, and the list shows it).
    private func key(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return false
        }
        close()
        return true
    }
}

extension MainWindowController {
    /// The toolbar's Undo and Redo: always the files', even while a text field (the search field) has the keyboard,
    /// as their tooltips name a file operation.
    func performFileUndo(_ command: AppCommand) {
        guard command == .undo || command == .redo, !isCustomizingToolbar, !isDialogOpen,
            ShortcutPolicy.canHandle(command, shortcutContext)
        else { return }
        _ = performWriteCommand(command)
    }
}
