import FTFoundation
import Testing

@testable import FTAppKit

@Suite struct StartupTabsTests {
    private static let home = "/Users/demo"

    // A tab saved on a favorite removed since opens as the folder it is.
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

    // A tab that waits behind the one in front is left out when its folder is gone. One with two panes stays while
    // either pane's folder is there: with the first one's gone, it opens with its second pane alone.
    @Test func aWaitingTabWhoseFirstPanesFolderIsGoneStaysOnItsSecondPane() throws {
        func tab(_ path: String, second: String? = nil) -> StartupTab {
            var tab = StartupTab(
                path: path, rootPath: Self.home, favoritePath: path, viewMode: .list, searchViewMode: .details,
                sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: false,
                locationsExpanded: true)
            if let second {
                tab.secondPane = OpenPanePreference(
                    path: second, viewMode: .icons, searchViewMode: .list, sortBy: .modified, sortDirection: .desc,
                    includeHidden: true, foldersFirst: false)
                tab.activePane = 1
                tab.paneSplit = 0.7
            }
            return tab
        }
        let waiting = [
            tab("/Users/demo/there"), tab("/Users/demo/gone"),
            tab("/Users/demo/gone", second: "/Users/demo/Projects/app"),
            tab("/Users/demo/there", second: "/Users/demo/gone"), tab("/Users/demo/gone", second: "/Users/demo/gone"),
        ]
        var asked: [[String]] = []

        let kept = StartupTabs.waitingTabs(waiting, homePath: Self.home) { paths in
            asked.append(paths)
            return paths.map { $0 != "/Users/demo/gone" }
        }

        // Every folder is asked about in one go.
        #expect(asked.count == 1)
        #expect(
            kept.map { $0?.path } == ["/Users/demo/there", nil, "/Users/demo/Projects/app", "/Users/demo/there", nil])
        #expect(kept[0] == waiting[0])
        // A second pane whose folder is gone finds the folder above it when the tab is shown.
        #expect(kept[3] == waiting[3])
        let survivor = try #require(kept[2])
        #expect(survivor.secondPane == nil)
        #expect(survivor.activePane == nil)
        #expect(survivor.paneSplit == nil)
        #expect(survivor.favoritePath == nil)
        #expect(survivor.rootPath == Self.home)
        #expect(survivor.viewMode == .icons)
        #expect(survivor.searchViewMode == .list)
        #expect(survivor.sortBy == .modified)
        #expect(survivor.sortDirection == .desc)
        #expect(survivor.includeHidden)
        #expect(!survivor.foldersFirst)
        #expect(!survivor.favoritesExpanded)
    }

    /// The single view a window opens with when no tabs were saved.
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

    @Test func keepsAHandPickedTreeRootWhenTheLastVisitedFolderIsInsideIt() {
        let tab = single(
            restore: true, last: "/Users/demo/projects/filetrail", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo/projects/filetrail", root: "/Users/demo/projects", favorite: nil)
    }

    @Test func keepsAHandPickedTreeRootThatIsTheLastVisitedFolderItself() {
        let tab = single(restore: true, last: "/Applications", favorite: nil, root: "/Applications")
        expect(tab, path: "/Applications", root: "/Applications", favorite: nil)
    }

    @Test func usesHomeAsTheTreeRootWhenTheLastVisitedFolderIsInsideHomeButOutsideTheSavedRoot() {
        let tab = single(restore: true, last: "/Users/demo/Documents", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo/Documents", root: "/Users/demo", favorite: nil)
    }

    @Test func usesSlashAsTheTreeRootWhenTheLastVisitedFolderIsAboveHomeAndOutsideTheSavedRoot() {
        let tab = single(restore: true, last: "/Applications", favorite: nil, root: "/Users/demo/projects")
        expect(tab, path: "/Applications", root: "/", favorite: nil)
    }

    @Test func usesThePersistedSlashRootWhenRestoringAPathInsideHome() {
        let tab = single(
            restore: true, last: "/Users/demo/Documents", favorite: "/Users/demo/Documents", root: "/")
        expect(tab, path: "/Users/demo/Documents", root: "/", favorite: "/Users/demo/Documents")
    }

    @Test func usesTheExplicitStartupFolderInsteadOfTheLastVisitedFolder() {
        let tab = single(
            restore: true, last: "/Users/demo/projects/filetrail", favorite: "/Users/demo/projects/filetrail",
            root: "/Users/demo/projects", startupFolder: "/Applications")
        expect(tab, path: "/Applications", root: "/", favorite: nil)
    }

    @Test func usesHomeAsTheTreeRootWhenTheExplicitStartupFolderIsInsideHome() {
        let tab = single(
            restore: false, last: nil, favorite: nil, root: "/Users/demo/projects",
            startupFolder: "/Users/demo/src/filetrail")
        expect(tab, path: "/Users/demo/src/filetrail", root: "/Users/demo", favorite: nil)
    }

    @Test func startsAtHomeWhenTheLastSessionIsNotReopened() {
        let tab = single(
            restore: false, last: "/Users/demo/projects/filetrail", favorite: "/Users/demo/projects/filetrail",
            root: "/Users/demo/projects")
        expect(tab, path: "/Users/demo", root: "/Users/demo", favorite: nil)
    }

    @Test func restoresASelectedFavoritePathWhenTheRestoredFolderExactlyMatchesIt() {
        let tab = single(
            restore: true, last: "/Users/demo/Documents", favorite: "/Users/demo/Documents", root: "/Users/demo")
        expect(tab, path: "/Users/demo/Documents", root: "/Users/demo", favorite: "/Users/demo/Documents")
    }

    // MARK: The tabs a window starts with

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

    @Test func showsAFolderTheAppWasLaunchedWithInARestoredTabOrInANewOne() {
        #expect(resolve(Self.preferences, startupFolder: "/Users/demo/work").activeIndex == 0)
        let launched = resolve(Self.preferences, startupFolder: "/Users/demo/Pictures")
        #expect(launched.activeIndex == 3)
        #expect(launched.tabs.count == 4)
        #expect(launched.tabs.last?.path == "/Users/demo/Pictures")
        #expect(launched.tabs.last?.rootPath == "/Users/demo")
    }

    @Test func opensTheTabsAWindowWasGivenWhateverTheSettingSays() {
        var off = Self.preferences
        off.restoreSessionOnStartup = false
        #expect(resolve(off).tabs.count == 1)
        let given = resolve(off, restoreTabs: true)
        #expect(given.activeIndex == 1)
        #expect(given.tabs.map(\.path) == ["/Users/demo/work", "/Users/demo/Documents", "/Volumes/Backup"])
    }

    @Test func fallsBackToTheLastTabWhenTheSavedActiveTabIsOutOfRange() {
        var outOfRange = Self.preferences
        outOfRange.activeTabIndex = 9
        #expect(resolve(outOfRange).activeIndex == 2)
        var pathless = Self.preferences
        pathless.openTabs = [Self.savedTab(nil)]
        #expect(resolve(pathless).tabs.first?.path == "/Users/demo")
        #expect(resolve(pathless).tabs.first?.rootPath == "/Users/demo")
    }

    // A tab keeps what its panes group folders and search results by: saved, read back, and on its second pane alone.
    @Test func aTabKeepsItsPanesGroupings() throws {
        var tab = StartupTab(
            path: "/a", rootPath: Self.home, favoritePath: nil, viewMode: .list, searchViewMode: .details,
            sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true, favoritesExpanded: true,
            locationsExpanded: true, groupBy: .modified, searchGroupBy: .folder)
        tab.secondPane = OpenPanePreference(
            path: "/b", viewMode: .icons, searchViewMode: .list, sortBy: .size, sortDirection: .desc,
            includeHidden: false, foldersFirst: true, groupBy: .tags, searchGroupBy: .kind)
        let saved = tab.openTab
        #expect(saved.groupBy == .modified && saved.searchGroupBy == .folder)
        let back = StartupTabs.startupTab(saved, homePath: Self.home)
        #expect(back.groupBy == .modified && back.searchGroupBy == .folder)
        let second = try #require(StartupTabs.onSecondPane(back, homePath: Self.home))
        #expect(second.groupBy == .tags && second.searchGroupBy == .kind)
        // A tab saved without groups starts without.
        var plain = saved
        plain.groupBy = nil
        plain.searchGroupBy = nil
        #expect(StartupTabs.startupTab(plain, homePath: Self.home).groupBy == GroupByPreference.none)
    }
}
