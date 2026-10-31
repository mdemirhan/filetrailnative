// Ports apps/desktop/src/renderer/lib/startupNavigation.test.ts
import FTFoundation
import Testing

@testable import FTAppKit

@Suite struct StartupTabsTests {
    private static let home = "/Users/demo"

    // B-NAV-186 B-TREE-050: a tab saved on a favorite removed since opens as the folder it is.
    @Test func aRemovedFavoriteOpensAsItsFolder() throws {
        var preferences = AppPreferences.defaults()
        preferences.favoritesInitialized = true
        preferences.favorites = [FavoritePreference(path: "/kept", icon: .home)]
        func tab(_ favorite: String) -> StartupTab {
            StartupTab(
                path: favorite, rootPath: favorite, favoritePath: favorite, viewMode: preferences.viewMode,
                searchViewMode: preferences.searchViewMode, sortBy: preferences.sortBy,
                sortDirection: preferences.sortDirection, includeHidden: preferences.includeHidden,
                foldersFirst: preferences.foldersFirst, favoritesExpanded: preferences.favoritesExpanded,
                locationsExpanded: preferences.locationsExpanded)
        }
        #expect(StartupTabs.withoutRemovedFavorite(tab("/kept"), preferences).favoritePath == "/kept")
        #expect(StartupTabs.withoutRemovedFavorite(tab("/gone"), preferences).favoritePath == nil)
        // Before the favorites are first made, nothing can be said about them.
        preferences.favoritesInitialized = false
        #expect(StartupTabs.withoutRemovedFavorite(tab("/gone"), preferences).favoritePath == "/gone")
    }

    /// `resolveStartupNavigation`: the single view a window opens with when no tabs were saved.
    private func single(
        restore: Bool, last: String?, favorite: String?, root: String?, startupFolder: String? = nil
    ) -> StartupTab? {
        var preferences = AppPreferences.defaults()
        preferences.restoreSessionOnStartup = restore
        preferences.lastVisitedPath = last
        preferences.lastVisitedFavoritePath = favorite
        preferences.treeRootPath = root
        preferences.openTabs = []
        let resolved = StartupTabs.resolve(
            preferences, homePath: Self.home, startupFolderPath: startupFolder, restoreTabs: false)
        #expect(resolved.tabs.count == 1)
        #expect(resolved.activeIndex == 0)
        return resolved.tabs.first
    }

    private func expect(
        _ tab: StartupTab?, path: String, root: String, favorite: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(tab?.path == path, sourceLocation: sourceLocation)
        #expect(tab?.rootPath == root, sourceLocation: sourceLocation)
        #expect(tab?.favoritePath == favorite, sourceLocation: sourceLocation)
    }

    // T-5c8a8dd9 B-NAV-177 B-NAV-178
    // B-TREE-185
    @Test func keepsAHandPickedTreeRootWhenTheLastVisitedFolderIsInsideIt() {
        let tab = single(
            restore: true, last: "/Users/demo/projects/filetrail", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo/projects/filetrail", root: "/Users/demo/projects", favorite: nil)
    }

    // T-d09ea64b B-NAV-178
    @Test func keepsAHandPickedTreeRootThatIsTheLastVisitedFolderItself() {
        let tab = single(restore: true, last: "/Applications", favorite: nil, root: "/Applications")
        expect(tab, path: "/Applications", root: "/Applications", favorite: nil)
    }

    // T-68eb3d87 B-NAV-178
    @Test func usesHomeAsTheTreeRootWhenTheLastVisitedFolderIsInsideHomeButOutsideTheSavedRoot() {
        let tab = single(restore: true, last: "/Users/demo/Documents", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo/Documents", root: "/Users/demo", favorite: nil)
    }

    // T-b8580b99 B-NAV-178
    @Test func usesSlashAsTheTreeRootWhenTheLastVisitedFolderIsAboveHomeAndOutsideTheSavedRoot() {
        let tab = single(restore: true, last: "/Applications", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Applications", root: "/", favorite: nil)
    }

    // T-b43fba42 B-NAV-178
    @Test func usesThePersistedSlashRootWhenRestoringAPathInsideHome() {
        let tab = single(
            restore: true, last: "/Users/demo/Documents", favorite: "/Users/demo/Documents", root: "/")
        expect(tab, path: "/Users/demo/Documents", root: "/", favorite: "/Users/demo/Documents")
    }

    // T-d612583c B-NAV-175
    @Test func usesTheExplicitStartupFolderInsteadOfTheLastVisitedFolder() {
        let tab = single(
            restore: true, last: "/Users/demo/projects/filetrail", favorite: "/Users/demo/projects/filetrail",
            root: "/Users/demo/projects", startupFolder: "/Applications")
        expect(tab, path: "/Applications", root: "/", favorite: nil)
    }

    // T-ae917c88 B-NAV-175
    @Test func usesHomeAsTheTreeRootWhenTheExplicitStartupFolderIsInsideHome() {
        let tab = single(
            restore: false, last: nil, favorite: nil, root: "/Users/demo/projects",
            startupFolder: "/Users/demo/src/filetrail")
        expect(tab, path: "/Users/demo/src/filetrail", root: "/Users/demo", favorite: nil)
    }

    // T-d3b23be1 B-NAV-176
    // T-fbbe09e1
    @Test func startsAtHomeWhenTheLastSessionIsNotReopened() {
        let tab = single(
            restore: false, last: "/Users/demo/projects/filetrail", favorite: "/Users/demo/projects/filetrail",
            root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo", root: "/Users/demo", favorite: nil)
    }

    // T-d0468635 B-NAV-180
    // T-d4d05739
    @Test func restoresASelectedFavoritePathWhenTheRestoredFolderExactlyMatchesIt() {
        let tab = single(
            restore: true, last: "/Users/demo/Documents", favorite: "/Users/demo/Documents", root: "/Users/demo")
        expect(tab, path: "/Users/demo/Documents", root: "/Users/demo", favorite: "/Users/demo/Documents")
    }

    // MARK: resolveStartupTabs

    private static func savedTab(_ path: String?, _ change: (inout OpenTabPreference) -> Void = { _ in })
        -> OpenTabPreference
    {
        var tab = OpenTabPreference(
            path: path, treeRootPath: "/Users/demo", favoritePath: nil, viewMode: .list, searchViewMode: .details,
            sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true)
        change(&tab)
        return tab
    }

    private static var preferences: AppPreferences {
        var preferences = AppPreferences.defaults()
        preferences.restoreSessionOnStartup = true
        preferences.openTabs = [
            savedTab("/Users/demo/work") {
                $0.viewMode = .details
                $0.sortBy = .size
                $0.sortDirection = .desc
                $0.includeHidden = true
                $0.foldersFirst = false
                $0.favoritesExpanded = false
                $0.locationsExpanded = false
            },
            savedTab("/Users/demo/Documents") { $0.favoritePath = "/Users/demo/Documents" },
            savedTab("/Volumes/Backup") { $0.treeRootPath = "/" },
        ]
        preferences.activeTabIndex = 1
        preferences.lastVisitedPath = "/Users/demo/Documents"
        preferences.lastVisitedFavoritePath = "/Users/demo/Documents"
        preferences.treeRootPath = "/Users/demo"
        preferences.viewMode = .list
        preferences.searchViewMode = .details
        preferences.sortBy = .name
        preferences.sortDirection = .asc
        preferences.includeHidden = false
        preferences.foldersFirst = true
        preferences.favoritesExpanded = true
        preferences.locationsExpanded = false
        return preferences
    }

    private static func startup(
        _ path: String, root: String, favorite: String? = nil, viewMode: ExplorerViewMode = .list,
        sortBy: SortByPreference = .name, sortDirection: SortDirectionPreference = .asc, includeHidden: Bool = false,
        foldersFirst: Bool = true, favoritesExpanded: Bool = true, locationsExpanded: Bool = true
    ) -> StartupTab {
        StartupTab(
            path: path, rootPath: root, favoritePath: favorite, viewMode: viewMode, searchViewMode: .details,
            sortBy: sortBy, sortDirection: sortDirection, includeHidden: includeHidden, foldersFirst: foldersFirst,
            favoritesExpanded: favoritesExpanded, locationsExpanded: locationsExpanded)
    }

    private func resolve(
        _ preferences: AppPreferences, startupFolder: String? = nil, restoreTabs: Bool = false
    ) -> (tabs: [StartupTab], activeIndex: Int) {
        StartupTabs.resolve(
            preferences, homePath: Self.home, startupFolderPath: startupFolder, restoreTabs: restoreTabs)
    }

    // T-d8fbdd46 B-NAV-179 B-NAV-181
    // B-TREE-187 B-VIEW-164 T-b7541fe2
    @Test func bringsEveryTabBackAtItsOwnFolderWithItsOwnView() {
        let resolved = resolve(Self.preferences)
        #expect(resolved.activeIndex == 1)
        #expect(
            resolved.tabs == [
                Self.startup(
                    "/Users/demo/work", root: "/Users/demo", viewMode: .details, sortBy: .size, sortDirection: .desc,
                    includeHidden: true, foldersFirst: false, favoritesExpanded: false, locationsExpanded: false),
                Self.startup("/Users/demo/Documents", root: "/Users/demo", favorite: "/Users/demo/Documents"),
                // Saved with the tree at Macintosh HD: another disk is shown from its own top.
                Self.startup("/Volumes/Backup", root: "/Volumes/Backup"),
            ])
    }

    // T-25e74d78 B-NAV-184 B-VIEW-176
    // T-020497b2 T-fbbe09e1
    @Test func opensASingleViewAtHomeWhenTheLastSessionIsNotReopened() {
        var off = Self.preferences
        off.restoreSessionOnStartup = false
        // Not reopening the session: the window's sidebar.
        #expect(resolve(off).tabs == [Self.startup("/Users/demo", root: "/Users/demo", locationsExpanded: false)])

        // No tabs were saved yet (the first launch with tabs): the last folder, in one view.
        var none = Self.preferences
        none.openTabs = []
        let resolved = resolve(none)
        #expect(resolved.activeIndex == 0)
        #expect(resolved.tabs.map(\.path) == ["/Users/demo/Documents"])
        #expect(resolved.tabs.first?.favoritePath == "/Users/demo/Documents")
    }

    // T-ff6743f1 B-NAV-185
    @Test func showsAFolderTheAppWasLaunchedWithInARestoredTabOrInANewOne() {
        #expect(resolve(Self.preferences, startupFolder: "/Users/demo/work").activeIndex == 0)
        let launched = resolve(Self.preferences, startupFolder: "/Users/demo/Pictures")
        #expect(launched.activeIndex == 3)
        #expect(launched.tabs.count == 4)
        #expect(launched.tabs.last?.path == "/Users/demo/Pictures")
        #expect(launched.tabs.last?.rootPath == "/Users/demo")
    }

    // T-bd036e34 B-NAV-183 B-VIEW-181
    // T-180a5b4f
    @Test func opensTheTabsAWindowWasGivenWhateverTheSettingSays() {
        var off = Self.preferences
        off.restoreSessionOnStartup = false
        #expect(resolve(off).tabs.count == 1)
        let given = resolve(off, restoreTabs: true)
        #expect(given.activeIndex == 1)
        #expect(given.tabs.map(\.path) == ["/Users/demo/work", "/Users/demo/Documents", "/Volumes/Backup"])
    }

    // T-0a1f16d6 B-NAV-182
    @Test func fallsBackToTheLastTabWhenTheSavedActiveTabIsOutOfRange() {
        var outOfRange = Self.preferences
        outOfRange.activeTabIndex = 9
        #expect(resolve(outOfRange).activeIndex == 2)
        var pathless = Self.preferences
        pathless.openTabs = [Self.savedTab(nil)]
        #expect(resolve(pathless).tabs.first?.path == "/Users/demo")
        #expect(resolve(pathless).tabs.first?.rootPath == "/Users/demo")
    }
}
