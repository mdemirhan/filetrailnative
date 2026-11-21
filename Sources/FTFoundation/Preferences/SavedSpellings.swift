import Foundation

/// What an earlier launch saved under another spelling of a folder's path. The app knows a folder by the path its
/// listing gives, which is the disk's spelling; it once knew it by a `URL`'s, which spells every accent decomposed,
/// and by the system's name for the home folder, which may be a link to it. A favorite, a folder's view, a
/// workspace's tab or a folder chosen in Move To saved then is still spelled that way, and a path is a folder's by
/// its bytes, so it no longer finds its folder.
///
/// When a folder is listed, the spellings it may have been saved under are worked out from its path (`earlier`), and
/// what is saved under one goes to the listing's spelling once the disk has said that the two paths are one folder.
/// Nothing here asks the disk, and nothing is matched loosely: to every function a path is its bytes.
public enum SavedSpellings {
    /// The home folder as the system names it (`NSHomeDirectory()`), which is how an earlier launch spelled it, and
    /// as the disk does (`DiskPath.home`): two paths when the first is a link, or leads through one.
    public struct Home: Equatable, Sendable {
        public var system: DiskPath
        public var real: DiskPath

        public init(system: DiskPath, real: DiskPath) {
            self.system = system
            self.real = real
        }
    }

    /// A folder as a listing spells it, and a path an earlier launch may have saved it under.
    public struct Earlier: Equatable, Sendable {
        public var old: DiskPath
        public var path: DiskPath

        public init(old: DiskPath, path: DiskPath) {
            self.old = old
            self.path = path
        }
    }

    /// The paths an earlier launch may have saved the folder listed as `listed` under, and each folder above it (a
    /// listing spells them all as the disk does): the path as a `URL` spells it, and, for a folder in a home folder
    /// the system names by another path, that path in the home folder's place, as it is and as a `URL` spells it.
    /// None for a path with no accent outside such a home folder, which is nearly every folder: the work is a look
    /// at its bytes. They are guesses: whether one names the same folder is the disk's to say.
    public static func earlier(of listed: DiskPath, home: Home) -> [Earlier] {
        let homeIsRespelled = home.system != home.real && !home.real.string.isEmpty && !home.system.string.isEmpty
        let hasAccent = listed.string.utf8.contains { $0 >= 0x80 }
        guard hasAccent || (homeIsRespelled && listed.isAtOrInside(home.real)) else { return [] }
        var found: [Earlier] = []
        var folder = listed
        while folder.string.utf8.count > 1, folder.string.utf8.first == UInt8(ascii: "/") {
            var spellings: [DiskPath] = []
            if let decomposed = folder.asAURLSpells() { spellings.append(decomposed) }
            if homeIsRespelled, folder.isAtOrInside(home.real) {
                // Cut where the home folder's bytes end, which is at a slash or at the path's end.
                let rest = folder.string.utf8.index(
                    folder.string.utf8.startIndex, offsetBy: home.real.string.utf8.count)
                let inSystemHome = DiskPath(home.system.string + folder.string[rest...])
                spellings.append(inSystemHome)
                if let decomposed = inSystemHome.asAURLSpells() { spellings.append(decomposed) }
            }
            for old in spellings where old != folder && !found.contains(where: { $0.old == old }) {
                found.append(Earlier(old: old, path: folder))
            }
            folder = folder.parent
        }
        return found
    }

    // MARK: Favorites

    /// The favorites with the one saved as `old` at `path`, in its place and with its icon; where `path` is a
    /// favorite already, the one saved as `old` goes, so the folder is listed once. Nil when none is saved as `old`.
    public static func favorites(_ favorites: [FavoritePreference], from old: DiskPath, to path: DiskPath)
        -> [FavoritePreference]?
    {
        guard old != path, let index = favorites.firstIndex(where: { DiskPath($0.path) == old }) else { return nil }
        var next = favorites
        if favorites.contains(where: { DiskPath($0.path) == path }) {
            next.remove(at: index)
        } else {
            next[index].path = path.string
        }
        return next
    }

    // MARK: Tabs and workspaces

    /// The tab with each of its paths that is `old` (its folder, its second pane's, its favorite, its tree's top)
    /// spelled `path`. Nil when none is.
    public static func tab(_ tab: OpenTabPreference, from old: DiskPath, to path: DiskPath) -> OpenTabPreference? {
        var next = tab
        var changed = false
        func respelled(_ saved: String?) -> String? {
            guard let saved, DiskPath(saved) == old else { return saved }
            changed = true
            return path.string
        }
        next.path = respelled(tab.path)
        next.treeRootPath = respelled(tab.treeRootPath)
        next.favoritePath = respelled(tab.favoritePath)
        if tab.secondPane != nil { next.secondPane?.path = respelled(tab.secondPane?.path) }
        return changed ? next : nil
    }

    /// The session with every path of it and of its tabs that is `old` spelled `path`. Nil when none is.
    public static func session(_ session: WindowSession, from old: DiskPath, to path: DiskPath) -> WindowSession? {
        var next = session
        var changed = false
        for index in session.openTabs.indices {
            if let tab = tab(session.openTabs[index], from: old, to: path) {
                next.openTabs[index] = tab
                changed = true
            }
        }
        func respelled(_ saved: String?) -> String? {
            guard let saved, DiskPath(saved) == old else { return saved }
            changed = true
            return path.string
        }
        next.treeRootPath = respelled(session.treeRootPath)
        next.lastVisitedPath = respelled(session.lastVisitedPath)
        next.lastVisitedFavoritePath = respelled(session.lastVisitedFavoritePath)
        return changed ? next : nil
    }

    /// The workspaces with every tab saved on `old` on `path`. Nil when no workspace has one.
    public static func workspaces(_ workspaces: [Workspace], from old: DiskPath, to path: DiskPath) -> [Workspace]? {
        guard old != path else { return nil }
        var next = workspaces
        var changed = false
        for index in workspaces.indices {
            if let session = session(workspaces[index].session, from: old, to: path) {
                next[index].session = session
                changed = true
            }
        }
        return changed ? next : nil
    }

    // MARK: What is saved under a spelling

    /// Whether a favorite or a workspace's tab is saved as `old`.
    public static func preferencesHold(_ old: DiskPath, _ preferences: AppPreferences) -> Bool {
        preferences.favorites.contains { DiskPath($0.path) == old }
            || preferences.workspaces.contains { paths(of: $0.session).contains { DiskPath($0) == old } }
    }

    /// Every path a session holds: its own and its tabs'.
    private static func paths(of session: WindowSession) -> [String] {
        var paths = [session.treeRootPath, session.lastVisitedPath, session.lastVisitedFavoritePath]
        for tab in session.openTabs {
            paths += [tab.path, tab.treeRootPath, tab.favoritePath, tab.secondPane?.path]
        }
        return paths.compactMap { $0 }
    }

    /// Whether a visit, or a folder chosen in Move To, is recorded as `old`.
    public static func foldersHold(_ old: DiskPath, _ folders: [VisitedFolder]) -> Bool {
        folders.contains { DiskPath($0.path) == old }
    }
}
