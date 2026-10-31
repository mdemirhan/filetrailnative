// Port of what apps/desktop/src/renderer/hooks/useExplorerTabs.ts does for openPathInNewTab's focusContent and selectPath (the .then after navigateToNearestExistingFolder), and of the "select" request in App.tsx
import FTFoundation
import Foundation

/// What a tab does for an item opened from another app.
enum OpenedItem {
    /// The list gets the keyboard.
    case folder
    /// The item is selected in the tab's folder, and the list gets the keyboard.
    case selecting(String)
}

extension MainWindowController {
    /// Carried out once the tab has read its folder. Not when another tab has been shown since, or the folder is gone or
    /// another one has opened instead (the first read then says it didn't show it).
    func showOpenedItem(_ item: OpenedItem) {
        whenFirstReadFinished { [weak self] read in
            guard let self, read, self.group?.selected === self else { return }
            if case .selecting(let path) = item { self.selectOpenedItem(path) }
            self.content.focusList()
        }
    }

    /// By its name in the folder opened, if not by its path: the listing gives its rows the folder's real path, which may be
    /// spelled otherwise than the one the other app sent (/private/tmp for /tmp). One with no row (a hidden item, hidden
    /// items off) is selected all the same: `setSingleContentSelection` asks nothing of the listing, and the Info panel
    /// describes it.
    private func selectOpenedItem(_ path: String) {
        let name = NodePath.basename(path)
        let row =
            content.listed.first { $0.path == path }
            ?? content.listed.first { $0.name.utf16.elementsEqual(name.utf16) }
        if let row {
            content.select(paths: [row.path])
        } else {
            content.selectionChanged(.single(path))
        }
    }
}
