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

    /// The tab whose selection the row acts on, when it can: items of a folder or of search results, as Tags…. It is
    /// the tab the key window is part of, as for every other menu item: its own, or the one a popover of it or the
    /// Info panel in a window of its own belongs to.
    var tab: MainWindowController? {
        guard let tab = focusedWindow().flatMap(ExplorerWindows.tab(for:)), tab.canPerform(.editTags) else {
            return nil
        }
        return tab
    }

    /// Counts the times the menu opened: only the latest one's read sets the checks.
    private var shows = 0

    private func show(in row: TagColorsMenuRow) {
        row.show([:])
        shows += 1
        let show = shows
        let paths = tab?.selectedPaths ?? []
        row.isEnabled = !paths.isEmpty
        guard !paths.isEmpty, paths.count <= TagColorsMenuRow.stateLimit else { return }
        Task { @MainActor [weak self, weak row] in
            let states = await BlockingWork.run { FinderTags.states(of: paths) }
            // A read of an earlier opening that ends late would put that selection's checks back.
            guard self?.shows == show else { return }
            row?.show(states)
        }
    }

    private func choose(_ color: FinderTagColor) {
        guard let tab else { return }
        tab.contextMenus.contextMenu(toggleTag: color, paths: tab.selectedPaths)
    }
}
