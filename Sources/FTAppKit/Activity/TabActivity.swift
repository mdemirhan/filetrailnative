// One tab's Activity list under the ring at the end of its toolbar's title
import AppKit
import FTFoundation

/// One tab's Activity list: it opens under the title's ring, follows what runs while open, and closes on Escape, a
/// press outside it, or once nothing runs.
@MainActor
final class TabActivity {
    private weak var tab: MainWindowController?
    private(set) var view: ActivityView?
    private var list: ToolbarListPopover?
    private var observer: NSObjectProtocol?

    init(tab: MainWindowController) {
        self.tab = tab
    }

    var isOpen: Bool { view != nil }

    /// The ring was clicked: the list opens or closes.
    func toggle(from button: NSView) {
        if isOpen {
            close()
        } else {
            open(from: button)
        }
    }

    private func open(from button: NSView) {
        let center = ActivityCenter.shared
        center.refresh()
        guard let tab, let window = tab.window, !center.items.isEmpty else { return }
        tab.clipboardUI.close()
        tab.undoHistoryUI.close()
        AppMenuPresenter.shared.close()
        let view = ActivityView(items: center.items)
        view.onStop = { item in ActivityCenter.shared.stop(item) }
        self.view = view
        let list = ToolbarListPopover(
            content: view, size: view.listSize, key: { [weak self] event in self?.key(event) ?? false },
            dismiss: { [weak self] in self?.close() })
        self.list = list
        list.show(from: button, in: window)
        observer = NotificationCenter.default.addObserver(
            forName: ActivityCenter.changed, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.changed() } }
    }

    func close() {
        guard view != nil else { return }
        view = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        list?.close()
        list = nil
    }

    /// What runs changed: the list shows it, or closes with nothing left.
    private func changed() {
        guard let view else { return }
        let items = ActivityCenter.shared.items
        guard !items.isEmpty else {
            close()
            return
        }
        view.update(items)
        view.layoutSubtreeIfNeeded()
        list?.setSize(view.listSize)
    }

    /// Escape closes the list; the other keys go on to the window.
    private func key(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return false
        }
        close()
        return true
    }
}
