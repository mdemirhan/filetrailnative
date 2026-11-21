import FTFoundation
import Foundation

/// What a tab does for an item opened from another app.
enum OpenedItem {
    /// The list gets the keyboard.
    case folder
    /// The items, of the tab's folder, are selected there, and the list gets the keyboard.
    case selecting([String])
    /// What a write made, of the tab's folder: selected there even when another tab has been shown since, as several
    /// open at once, and the list gets the keyboard when the tab is the one shown.
    case made([String])
}

extension MainWindowController {
    /// Carried out once the tab has read its folder. Not when another tab has been shown since, or the folder is gone or
    /// another one has opened instead (the first read then says it didn't show it).
    func showOpenedItem(_ item: OpenedItem) {
        whenFirstReadFinished { [weak self] read in
            guard let self, read else { return }
            let shown = self.group?.selected === self
            switch item {
            case .folder: break
            case .selecting(let paths): if shown { self.selectOpenedItems(paths) }
            case .made(let paths): self.selectOpenedItems(paths)
            }
            if shown { self.content.focusList() }
        }
    }

    /// Each by its name in the folder opened, if not by its path: the listing gives its rows the folder's real path,
    /// which may be spelled otherwise than the one the other app sent (/private/tmp for /tmp). One item with no row
    /// (a hidden item, hidden items off) is selected all the same: the selection asks nothing of the listing, and the
    /// Info panel describes it. Of several, those with rows are. The row spelled exactly as the item comes first,
    /// where the folder holds the name with its accent spelled both ways; one spelled the other way only when no row
    /// is spelled so.
    private func selectOpenedItems(_ paths: [String]) {
        let rows = paths.compactMap { path in
            let name = NodePath.basename(path)
            return content.listedEntry(at: path)
                ?? content.listed.first { $0.name.utf16.elementsEqual(name.utf16) }
                ?? content.listed.first { $0.path == path }
        }
        if !rows.isEmpty {
            content.select(paths: rows.map(\.path))
        } else if paths.count == 1 {
            content.selectionChanged(.single(paths[0]))
        }
    }
}
