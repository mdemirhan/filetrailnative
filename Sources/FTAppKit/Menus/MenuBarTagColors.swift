import AppKit
import FTFileSystem
import FTFoundation

/// File ▸ the row of tag colors, as Finder's File menu has it before Tags…: the right-click menu's row, for the items
/// selected in the key window. Its checks are read each time the menu opens; a color chosen goes on or off the items
/// as it does from the right-click menu.
@MainActor
final class MenuBarTagColors {
    /// The one the File menu uses.
    static let shared = MenuBarTagColors()

    /// The window whose selection is tagged; tests give their own.
    var focusedWindow: () -> NSWindow? = { NSApp.keyWindow }

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Tag Colors", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(Self.itemID)
        let row = TagColorsMenuRow { [weak self] color in self?.choose(color) }
        row.onShow = { [weak self, weak row] in
            guard let self, let row else { return }
            self.show(in: row)
        }
        item.view = row
        return item
    }

    static let itemID = "fileMenuTagColors"

    /// The window whose selection the row acts on, when it can: items of a folder or of search results, as Tags….
    private var tab: MainWindowController? {
        guard let tab = (focusedWindow() as? ExplorerTabWindow)?.explorerTab, tab.canPerform(.editTags) else {
            return nil
        }
        return tab
    }

    private func show(in row: TagColorsMenuRow) {
        row.show([:])
        let paths = tab?.selectedPaths ?? []
        row.isEnabled = !paths.isEmpty
        guard !paths.isEmpty, paths.count <= TagColorsMenuRow.stateLimit else { return }
        Task { @MainActor [weak row] in
            let states = await BlockingWork.run { FinderTags.states(of: paths) }
            row?.show(states)
        }
    }

    private func choose(_ color: FinderTagColor) {
        guard let tab else { return }
        tab.contextMenus.contextMenu(toggleTag: color, paths: tab.selectedPaths)
    }
}
