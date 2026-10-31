// Port of apps/desktop/src/renderer/lib/startupNavigation.ts (the tabs a window opens with)
import FTFoundation
import Foundation

/// A tab as the window opens it: where it starts and how it shows its folder (`StartupTab`).
public struct StartupTab: Equatable, Sendable {
    public var path: String
    public var rootPath: String
    public var favoritePath: String?
    public var viewMode: ExplorerViewMode
    public var searchViewMode: ExplorerViewMode
    public var sortBy: SortByPreference
    public var sortDirection: SortDirectionPreference
    public var includeHidden: Bool
    public var foldersFirst: Bool
    public var favoritesExpanded: Bool
    public var locationsExpanded: Bool

    /// The tab as it is saved between launches.
    public var openTab: OpenTabPreference {
        OpenTabPreference(
            path: path.isEmpty ? nil : path, treeRootPath: rootPath.isEmpty ? nil : rootPath,
            favoritePath: favoritePath, viewMode: viewMode, searchViewMode: searchViewMode, sortBy: sortBy,
            sortDirection: sortDirection, includeHidden: includeHidden, foldersFirst: foldersFirst,
            favoritesExpanded: favoritesExpanded, locationsExpanded: locationsExpanded)
    }
}

public enum StartupTabs {
    /// `isPathWithinRoot`.
    static func isPathWithinRoot(_ path: String, _ rootPath: String) -> Bool {
        if rootPath == "/" { return true }
        return path.utf16.elementsEqual(rootPath.utf16) || path.utf16.starts(with: (rootPath + "/").utf16)
    }

    /// `resolvePersistedStartupRoot`.
    static func persistedRoot(_ persistedRootPath: String?, homePath: String, startupPath: String) -> String {
        let volumeRoot = ExplorerTabs.volumeRootPath(startupPath)
        // Macintosh HD holds its own folders only: a folder on another disk is shown from that disk's top.
        if let persistedRootPath, persistedRootPath == homePath || (persistedRootPath == "/" && volumeRoot == "/") {
            return persistedRootPath
        }
        // A folder the tree was rooted at by hand is kept while the startup folder is inside it.
        if let persistedRootPath, !persistedRootPath.isEmpty, persistedRootPath != "/",
            isPathWithinRoot(startupPath, persistedRootPath)
        {
            return persistedRootPath
        }
        return isPathWithinRoot(startupPath, homePath) ? homePath : volumeRoot
    }

    /// `toStartupTab`: a saved tab in its folder, with the tree rooted where it was when the folder is still inside it.
    public static func startupTab(_ tab: OpenTabPreference, homePath: String) -> StartupTab {
        guard let path = tab.path, !path.isEmpty else {
            return StartupTab(
                path: homePath, rootPath: homePath, favoritePath: nil, viewMode: tab.viewMode,
                searchViewMode: tab.searchViewMode, sortBy: tab.sortBy, sortDirection: tab.sortDirection,
                includeHidden: tab.includeHidden, foldersFirst: tab.foldersFirst,
                favoritesExpanded: tab.favoritesExpanded, locationsExpanded: tab.locationsExpanded)
        }
        return StartupTab(
            path: path, rootPath: persistedRoot(tab.treeRootPath, homePath: homePath, startupPath: path),
            favoritePath: tab.favoritePath == path ? path : nil, viewMode: tab.viewMode,
            searchViewMode: tab.searchViewMode, sortBy: tab.sortBy, sortDirection: tab.sortDirection,
            includeHidden: tab.includeHidden, foldersFirst: tab.foldersFirst,
            favoritesExpanded: tab.favoritesExpanded, locationsExpanded: tab.locationsExpanded)
    }

    /// A tab saved on a favorite removed since opens as the folder it is, so a row is selected and the tree follows it
    /// (B-NAV-186, B-TREE-050).
    public static func withoutRemovedFavorite(_ tab: StartupTab, _ preferences: AppPreferences) -> StartupTab {
        guard preferences.favoritesInitialized, let favorite = tab.favoritePath,
            !preferences.favorites.contains(where: { $0.path == favorite })
        else { return tab }
        var plain = tab
        plain.favoritePath = nil
        return plain
    }

    /// `resolveStartupTabs`: "Reopen the last folder and tabs" brings back the tabs that were open; without it the
    /// window opens one tab at home. A window opened while the app runs (`restoreTabs`) always opens the tabs it was
    /// given. A folder the app was launched with is shown in a tab of its own, unless a restored tab already has it.
    public static func resolve(
        _ preferences: AppPreferences, homePath: String, startupFolderPath: String?, restoreTabs: Bool
    ) -> (tabs: [StartupTab], activeIndex: Int) {
        func tab(_ path: String, root: String, favorite: String?) -> StartupTab {
            StartupTab(
                path: path, rootPath: root, favoritePath: favorite, viewMode: preferences.viewMode,
                searchViewMode: preferences.searchViewMode, sortBy: preferences.sortBy,
                sortDirection: preferences.sortDirection, includeHidden: preferences.includeHidden,
                foldersFirst: preferences.foldersFirst, favoritesExpanded: preferences.favoritesExpanded,
                locationsExpanded: preferences.locationsExpanded)
        }
        if !(preferences.restoreSessionOnStartup || restoreTabs) || preferences.openTabs.isEmpty {
            if let startupFolderPath, !startupFolderPath.isEmpty {
                // Launch targets from the system always win.
                return (
                    [
                        tab(
                            startupFolderPath,
                            root: persistedRoot(nil, homePath: homePath, startupPath: startupFolderPath), favorite: nil)
                    ],
                    0
                )
            }
            guard preferences.restoreSessionOnStartup, let last = preferences.lastVisitedPath, !last.isEmpty else {
                return ([tab(homePath, root: homePath, favorite: nil)], 0)
            }
            let root = persistedRoot(preferences.treeRootPath, homePath: homePath, startupPath: last)
            return ([tab(last, root: root, favorite: preferences.lastVisitedFavoritePath == last ? last : nil)], 0)
        }
        var tabs = preferences.openTabs.map { startupTab($0, homePath: homePath) }
        var activeIndex = min(preferences.activeTabIndex, tabs.count - 1)
        if let startupFolderPath, !startupFolderPath.isEmpty {
            if let existing = tabs.firstIndex(where: { $0.path == startupFolderPath }) {
                activeIndex = existing
            } else {
                tabs.append(
                    tab(
                        startupFolderPath, root: persistedRoot(nil, homePath: homePath, startupPath: startupFolderPath),
                        favorite: nil))
                activeIndex = tabs.count - 1
            }
        }
        return (tabs, max(0, activeIndex))
    }
}
