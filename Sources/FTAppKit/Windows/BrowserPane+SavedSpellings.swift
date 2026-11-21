// What an earlier launch saved under another spelling of a folder's path, taken over as the folder is listed
import AppKit
import FTFileSystem
import FTFoundation

/// What taking over saved spellings did, for the navigation it happened in.
struct SavedSpellingsTakenOver {
    /// How the sidebar reached the folder: by a favorite's row, the row as the favorite is now spelled.
    var open: SidebarOpen
    /// A folder's view went to the path of the folder listed, or of one above it: the view the folder uses is looked
    /// for again.
    var views = false
}

extension BrowserPane {
    /// The home folder as the system names it and as the disk spells it; a test gives its own.
    static var savedHome = SavedSpellings.Home(system: DiskPath(NSHomeDirectory()), real: .home)

    /// The pane's folder was listed (`read`), which says how the disk spells its path, and the paths of the folders
    /// above it. A favorite, a folder's view, a workspace's tab, a visit or a folder chosen in Move To that an
    /// earlier launch saved under another spelling of one of those paths (`SavedSpellings.earlier`) is that folder's:
    /// it goes to the listing's spelling, in every window, and is saved so. It happens once for each, as nothing is
    /// then left under the old spelling.
    ///
    /// Only the disk says that two paths are one folder. Nearly every folder has no other spelling, and of those
    /// that have one nearly none has anything saved under it: both are found out here, in memory. Where something
    /// is, the disk is asked where the old spelling leads, once, off the main thread; where that is another folder,
    /// or nothing, what is saved stays as it is: two folders a disk keeps apart stay two.
    func takeOverSavedSpellings(
        of read: Result<DirectorySnapshot, any Error>, open: SidebarOpen
    ) async -> SavedSpellingsTakenOver {
        var result = SavedSpellingsTakenOver(open: open)
        guard case .success(let snapshot) = read, let tab else { return result }
        let earlier = SavedSpellings.earlier(of: DiskPath(snapshot.path), home: Self.savedHome)
        guard !earlier.isEmpty else { return result }
        let store = MainWindowController.visitStore()
        let views = tab.services.folderViews
        let preferences = tab.preferences
        let visits = store?.folders() ?? []
        let destinations = store?.destinations() ?? []
        // The rows of this tab's sidebar that are a favorite's by the old spelling: the one selected (a tab that
        // waited unread on its favorite while another window took the favorite over), and the one pressed.
        var rows = [tab.sidebarController.model.selected?.favoritePath].compactMap { $0.map { DiskPath($0) } }
        if case .favorite(let row) = open.origin, let path = row.favoritePath { rows.append(DiskPath(path)) }
        let held = earlier.filter {
            views.views.own($0.old.string) != nil || SavedSpellings.preferencesHold($0.old, preferences)
                || SavedSpellings.foldersHold($0.old, visits) || SavedSpellings.foldersHold($0.old, destinations)
                || rows.contains($0.old)
        }
        guard !held.isEmpty else { return result }

        let service = tab.services.directoryService
        var same: [SavedSpellings.Earlier] = []
        for spelling in held {
            if let real = await service.realPath(spelling.old.string), DiskPath(real) == spelling.path {
                same.append(spelling)
            }
        }
        // The tab may have closed while the disk was asked.
        guard !same.isEmpty, let tab = self.tab else { return result }

        for spelling in same {
            let (old, path) = (spelling.old.string, spelling.path.string)
            if views.views.own(old) != nil {
                views.update(from: nil) { $0.respell(from: old, to: path) }
                result.views = true
            }
            store?.folderVisitsRespelled(from: old, to: path)
            store?.destinationsRespelled(from: old, to: path)
        }
        var favorites: [FavoritePreference]?
        var workspaces: [Workspace]?
        let current = tab.preferences
        for spelling in same {
            if let next = SavedSpellings.favorites(
                favorites ?? current.favorites, from: spelling.old, to: spelling.path)
            {
                favorites = next
            }
            if let next = SavedSpellings.workspaces(
                workspaces ?? current.workspaces, from: spelling.old, to: spelling.path)
            {
                workspaces = next
            }
        }
        if favorites != nil || workspaces != nil {
            tab.updatePreferences {
                if let favorites { $0.favorites = favorites }
                if let workspaces { $0.workspaces = workspaces }
            }
        }
        if !rows.isEmpty { result.open = favoriteRowsFollowed(same, open: open, in: tab) }
        return result
    }

    /// A favorite's row in the sidebar is known by the favorite's path: the row this tab has selected, and the one
    /// the folder was opened by, go with their favorite to the spelling it now has.
    private func favoriteRowsFollowed(
        _ respelled: [SavedSpellings.Earlier], open: SidebarOpen, in tab: MainWindowController
    ) -> SidebarOpen {
        let favorites = tab.preferences.favorites
        func followed(_ row: TreeItemID) -> TreeItemID? {
            guard let favorite = row.favoritePath.map({ DiskPath($0) }),
                let spelling = respelled.first(where: { $0.old == favorite }),
                Favorites.contains(favorites, path: spelling.path.string)
            else { return nil }
            return .favorite(spelling.path.string)
        }
        let model = tab.sidebarController.model
        if let selected = model.selected, let row = followed(selected) { model.restoreSelected(row) }
        var open = open
        if case .favorite(let row) = open.origin, let row = followed(row) { open.origin = .favorite(row) }
        return open
    }
}
