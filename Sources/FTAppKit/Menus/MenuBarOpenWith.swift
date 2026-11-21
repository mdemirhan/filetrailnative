import AppKit
import FTFileSystem
import FTFoundation

/// File ▸ Open With: the apps that can open the items selected in the key window, listed as the right-click menu's
/// Open With lists them, and opened the same way. Filled each time it opens; the pinned apps show until macOS has
/// answered which others can open the items, and the list fills in while the menu is open.
@MainActor
final class MenuBarOpenWith: NSObject, NSMenuDelegate {
    /// The one the File menu uses: a menu holds its delegate weakly.
    static let shared = MenuBarOpenWith()

    /// The window whose selection is opened; tests give their own.
    var focusedWindow: () -> NSWindow? = { NSApp.keyWindow }

    private var paths: [String] = []
    private var lookup: OpenWithLookup?
    private weak var tab: MainWindowController?

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Open With")
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        tab = (focusedWindow() as? ExplorerTabWindow)?.explorerTab
        // Nothing selected, or a file the pane shows in place of the list: the items under it aren't on screen.
        guard let tab, !tab.selectedPaths.isEmpty, !tab.activePaneShowsFile else {
            menu.removeAllItems()
            let none = NSMenuItem(title: "No Items Selected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        if tab.selectedPaths != paths {
            paths = tab.selectedPaths
            lookup = nil
            ask(paths, pinned: tab.preferences.openWithApplications, menu: menu)
        }
        fill(menu, pinned: tab.preferences.openWithApplications)
    }

    private func ask(_ asked: [String], pinned: [OpenWithApplication], menu: NSMenu) {
        let pinnedPaths = pinned.map(\.appPath)
        Task { [weak self, weak menu] in
            let answer = await SystemActions.openWithApplications(paths: asked, pinnedAppPaths: pinnedPaths)
            guard let self, self.paths == asked else { return }
            self.lookup = answer
            if let menu { self.fill(menu, pinned: pinned) }
        }
    }

    private func fill(_ menu: NSMenu, pinned: [OpenWithApplication]) {
        menu.removeAllItems()
        for item in OpenWithMenu.menuItems(lookup: lookup, pinned: pinned, always: false) {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .action(let action):
                let row = NSMenuItem(title: action.label, action: #selector(choose(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = OpenWithChoice(action: action)
                if case .application(_, _, let appPath, _, _) = action { row.showApplicationIcon(appPath) }
                menu.addItem(row)
            }
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? OpenWithChoice, let tab else { return }
        tab.contextMenus.contextMenu(open: paths, with: choice.action, kind: lookup?.kinds.first)
    }
}
