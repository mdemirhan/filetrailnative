// Port of apps/desktop/src/shared/appPreferences.test.ts
import Foundation
import Testing

@testable import FTFoundation

struct AppPreferencesTests {
    // T-e5881b9a F-013 F-021
    @Test func clampsNumericPreferencesAndRoundsToWholePixels() {
        #expect(AppPreferenceLimits.clampPaneWidth(279.6, 200...320) == 280)
        #expect(AppPreferenceLimits.clampPaneWidth(99.2, 200...320) == 200)
        #expect(AppPreferenceLimits.clampOpenItemLimit(0.3) == 1)
        #expect(AppPreferenceLimits.clampOpenItemLimit(51.2) == 50)
        #expect(AppPreferenceLimits.clampZoomPercent(106.8) == 107)
        #expect(AppPreferenceLimits.clampZoomPercent(500) == 150)
    }

    // T-c3b4e67c F-013 F-070
    @Test func clampsDetailColumnWidthsUsingPerColumnLimits() {
        #expect(AppPreferenceLimits.clampDetailColumnWidth(.name, 719.8) == 720)
        #expect(AppPreferenceLimits.clampDetailColumnWidth(.size, 10) == DetailColumnKey.size.widthLimits.lowerBound)
        #expect(
            AppPreferenceLimits.clampDetailColumnWidth(.permissions, 400)
                == DetailColumnKey.permissions.widthLimits.upperBound)
        #expect(AppPreferenceLimits.clampSearchColumnWidth(.folder, 10) == 80)
        #expect(AppPreferenceLimits.clampSearchColumnWidth(.folder, 4000) == 720)
    }

    // T-23ddd45d F-011
    @Test func offersAutoLightAndDark() {
        #expect(AppPreferenceLimits.themeOptions.map(\.label) == ["Auto", "Light", "Dark"])
    }

    // T-d4a12946 F-011
    @Test func defaultsToBlueTheFirstAccentOffered() {
        let options = AppPreferenceLimits.accentOptions
        #expect(options[0].value == "#007aff")
        #expect(options[0].label == "Blue")
        #expect(AppPreferenceLimits.defaultAccent == "#007aff")
        #expect(AppPreferences.defaults().accent == AppPreferenceLimits.defaultAccent)
        #expect(Set(options.map(\.value)).count == options.count)
        #expect(options.count == 9)
    }

    // T-b6a18486 F-011 F-012 F-013 F-014 F-016 F-018 F-019 F-020 F-021 F-022
    @Test func shipsExpectedDefaultsForThePersistedPreferenceShape() {
        let defaults = AppPreferences.defaults()
        #expect(defaults.theme == .auto)
        #expect(defaults.accent == "#007aff")
        #expect(defaults.zoomPercent == 100)
        #expect(defaults.viewMode == .icons)
        #expect(defaults.searchViewMode == .details)
        #expect(defaults.sortBy == .name)
        #expect(defaults.sortDirection == .asc)
        #expect(defaults.foldersFirst)
        #expect(!defaults.singleClickExpandTreeItems)
        #expect(defaults.terminalApp == nil)
        #expect(defaults.openWithApplications == [])
        #expect(
            defaults.detailColumns
                == DetailColumnVisibility(modified: true, size: true, kind: true, created: false, permissions: false))
        #expect(
            defaults.detailColumnWidths
                == DetailColumnWidths(name: 320, modified: 152, size: 108, kind: 148, created: 152, permissions: 108))
        #expect(defaults.detailColumnOrder == [.modified, .size, .kind, .created, .permissions])
        #expect(
            defaults.searchColumns
                == SearchColumnVisibility(
                    folder: true, modified: true, size: true, kind: false, created: false, permissions: false))
        #expect(defaults.searchColumnOrder == [.folder, .modified, .size, .kind, .created, .permissions])
        #expect(defaults.searchColumnWidths.name == 300)
        #expect(defaults.searchColumnWidths.folder == 240)
        #expect(defaults.restoreSessionOnStartup)
        #expect(defaults.notificationsEnabled)
        #expect(defaults.markClipboardItems)
        #expect(defaults.autoCalculateFolderSizes)
        #expect(!defaults.propertiesOpen)
        #expect(!defaults.detailRowOpen)
        #expect(defaults.folderTreeOpen)
        #expect(defaults.topToolbarItems == ToolbarItems.defaultTopItems)
        #expect(
            defaults.defaultTextEditor
                == ApplicationSelection(appPath: "/System/Applications/TextEdit.app", appName: "TextEdit"))
        #expect(defaults.fileActivationAction == .open)
        #expect(defaults.diskImageOpensIn == .window)
        #expect(defaults.returnKeyAction == .rename)
        #expect(defaults.openItemLimit == 5)
        #expect(defaults.includeHidden == false)
        #expect(defaults.searchPatternMode == .text)
        #expect(defaults.searchMatchScope == .name)
        #expect(defaults.searchRecursive)
        #expect(defaults.searchSkipGitFolders)
        #expect(!defaults.searchSkipGitIgnored)
        #expect(defaults.searchResultsSortBy == .path)
        #expect(defaults.searchResultsSortDirection == .asc)
        #expect(defaults.treeWidth == 280)
        #expect(defaults.inspectorWidth == 320)
        #expect(defaults.openTabs == [])
        #expect(defaults.activeTabIndex == 0)
        #expect(defaults.treeRootPath == nil)
        #expect(defaults.lastVisitedPath == nil)
        #expect(defaults.lastVisitedFavoritePath == nil)
        #expect(defaults.favorites == [])
        #expect(defaults.favoritesPlacement == .integrated)
        #expect(defaults.favoritesExpanded)
        #expect(defaults.locationsExpanded)
        #expect(!defaults.favoritesInitialized)
        #expect(defaults.shortcutOverrides == [:])
    }

    // T-83f9c734
    @Test func resolvesAutoToLightOrDarkFromTheMacOSAppearance() {
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.auto, systemPrefersDark: false) == .light)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.auto, systemPrefersDark: true) == .dark)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.dark, systemPrefersDark: false) == .dark)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.light, systemPrefersDark: true) == .light)
    }

    // F-015
    @Test func savedColumnOrdersDropUnknownOrDuplicateKeysAndAppendNewColumns() {
        let order = JSONNode.array(["size", "size", "name", "bogus", "modified"].map(JSONNode.string) + [.number(5)])
        #expect(
            AppPreferenceLimits.normalizeDetailColumnOrder(order) == [.size, .modified, .kind, .created, .permissions])
        #expect(AppPreferenceLimits.normalizeDetailColumnOrder(nil) == AppPreferenceLimits.defaultDetailColumnOrder)
        #expect(
            AppPreferenceLimits.normalizeDetailColumnOrder(.string("size"))
                == AppPreferenceLimits.defaultDetailColumnOrder)
        let search = JSONNode.array(["kind", "folder"].map(JSONNode.string))
        #expect(
            AppPreferenceLimits.normalizeSearchColumnOrder(search) == [
                .kind, .folder, .modified, .size, .created, .permissions,
            ])
    }

    @Test func acceptsAnAccentAsSixHexDigitsAndWritesItInLowerCase() {
        #expect(AppPreferenceLimits.normalizeAccentColor(" #ABCDEF ") == "#abcdef")
        #expect(AppPreferenceLimits.normalizeAccentColor("#12345") == nil)
        #expect(AppPreferenceLimits.normalizeAccentColor("#1234567") == nil)
        #expect(AppPreferenceLimits.normalizeAccentColor("123456") == nil)
        #expect(AppPreferenceLimits.normalizeAccentColor("#12345g") == nil)
    }

    // F-025 F-073
    @Test func aWindowKeepsTwentyTwoSessionKeysOfItsOwn() {
        #expect(WindowSessionKeys.all.count == 22)
        #expect(WindowSessionKeys.isSessionKey("openTabs"))
        #expect(WindowSessionKeys.isSessionKey("searchColumnWidths"))
        #expect(!WindowSessionKeys.isSessionKey("theme"))
        let encoded = (try? JSONNode.of(AppPreferences.defaults().windowSession))?.object ?? [:]
        #expect(Set(encoded.keys) == Set(WindowSessionKeys.all))
        // Every preference key is one of the 57 the original has.
        let preferenceKeys = (try? JSONNode.of(AppPreferences.defaults()))?.object ?? [:]
        #expect(Set(preferenceKeys.keys) == Set(AppPreferences.keys))
        #expect(AppPreferences.keys.count == 57)
    }

    @Test func filesRoundTripWithTheSameJSONKeys() throws {
        var preferences = AppPreferences.defaults(theme: .dark)
        preferences.terminalApp = ApplicationSelection(appPath: "/Applications/iTerm.app", appName: "iTerm")
        preferences.openTabs = [
            OpenTabPreference(
                path: "/Users/me", treeRootPath: nil, favoritePath: nil, viewMode: .list, searchViewMode: .details,
                sortBy: .size, sortDirection: .desc, includeHidden: true, foldersFirst: false, favoritesExpanded: true,
                locationsExpanded: false)
        ]
        let state = AppState(
            preferences: preferences,
            windows: [
                StoredExplorerWindow(
                    id: "window-1", bounds: StoredWindowState(x: 5, width: 900, height: 700, maximized: true),
                    session: preferences.windowSession)
            ])
        let data = try JSONEncoder().encode(state)
        let read = try AppStateReader.read(data: data, defaults: .defaults(theme: .dark))
        #expect(read == state)
        // Missing values are written as null, as the original writes them.
        let json = try #require(try JSONNode.parse(data).object?["preferences"]?.object)
        #expect(json["treeRootPath"] == JSONNode.null)
        #expect(json["terminalApp"]?.object?["appName"] == JSONNode.string("iTerm"))
        #expect(json["openTabs"]?.array?.first?.object?["favoritePath"] == JSONNode.null)
    }
}
