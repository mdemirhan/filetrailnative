import Foundation
import Testing

@testable import FTFoundation

struct AppPreferencesTests {
    @Test func clampsNumericPreferencesAndRoundsToWholePixels() {
        #expect(AppPreferenceLimits.clampPaneWidth(279.6, 200...320) == 280)
        #expect(AppPreferenceLimits.clampPaneWidth(99.2, 200...320) == 200)
        #expect(AppPreferenceLimits.clampOpenItemLimit(0.3) == 1)
        #expect(AppPreferenceLimits.clampOpenItemLimit(51.2) == 50)
    }

    @Test func clampsDetailColumnWidthsUsingPerColumnLimits() {
        #expect(AppPreferenceLimits.clampDetailColumnWidth(.name, 999.8) == 1000)
        #expect(AppPreferenceLimits.clampDetailColumnWidth(.size, 10) == DetailColumnKey.size.widthLimits.lowerBound)
        #expect(
            AppPreferenceLimits.clampDetailColumnWidth(.permissions, 400)
                == DetailColumnKey.permissions.widthLimits.upperBound)
        #expect(AppPreferenceLimits.clampSearchColumnWidth(.folder, 10) == 80)
        #expect(AppPreferenceLimits.clampSearchColumnWidth(.folder, 4000) == 1000)
    }

    @Test func defaultsToBlueTheFirstAccentOffered() {
        let options = AppPreferenceLimits.accentOptions
        #expect(options[0].value == "#007aff")
        #expect(options[0].label == "Blue")
        #expect(AppPreferenceLimits.defaultAccent == "#007aff")
        #expect(AppPreferences.defaults().accent == AppPreferenceLimits.defaultAccent)
        #expect(Set(options.map(\.value)).count == options.count)
        #expect(options.count == 9)
    }

    @Test func shipsExpectedDefaultsForThePersistedPreferenceShape() {
        let defaults = AppPreferences.defaults()
        #expect(defaults.theme == .auto)
        #expect(defaults.accent == "#007aff")
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

    @Test func resolvesAutoToLightOrDarkFromTheMacOSAppearance() {
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.auto, systemPrefersDark: false) == .light)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.auto, systemPrefersDark: true) == .dark)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.dark, systemPrefersDark: false) == .dark)
        #expect(AppPreferenceLimits.resolveEffectiveTheme(.light, systemPrefersDark: true) == .light)
    }

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

    @Test func aWindowKeepsTwentyTwoSessionKeysOfItsOwn() {
        #expect(WindowSession.keys.count == 22)
        #expect(PreferenceKey.openTabs.isWindowSessionKey)
        #expect(PreferenceKey.searchColumnWidths.isWindowSessionKey)
        #expect(!PreferenceKey.theme.isWindowSessionKey)
        let encoded = (try? JSONNode.of(AppPreferences.defaults().windowSession))?.object ?? [:]
        #expect(Set(encoded.keys) == Set(WindowSession.keys.map(\.rawValue)))
        // Every preference key is listed.
        let preferenceKeys = (try? JSONNode.of(AppPreferences.defaults()))?.object ?? [:]
        #expect(Set(preferenceKeys.keys) == Set(PreferenceKey.allCases.map(\.rawValue)))
        #expect(PreferenceKey.allCases.count == 58)
    }

    // The Compact List keeps a width for each density; a saved one is kept within 160…600, a missing one is the
    // density's default.
    @Test func compactListWidthsAreKeptPerDensityWithinTheirLimits() throws {
        #expect(AppPreferences.defaults().compactListWidths == DensitySizes(standard: 292, finder: 252))
        let read = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"compactListWidths": {"standard": 9000, "finder": "wide"}}"#.utf8)),
            defaults: .defaults())
        #expect(read.compactListWidths == DensitySizes(standard: 600, finder: 252))
        let narrow = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"compactListWidths": {"finder": 12.4}}"#.utf8)), defaults: .defaults())
        #expect(narrow.compactListWidths == DensitySizes(standard: 292, finder: 160))
        #expect(!PreferenceKey.compactListWidths.isWindowSessionKey)
    }

    // The Icons view keeps an icon size for each density, from 32 to 128 in steps of 8; a missing one is 64.
    @Test func iconSizesAreKeptPerDensityInStepsWithinTheirLimits() throws {
        #expect(AppPreferences.defaults().iconSizes == DensitySizes(standard: 64, finder: 64))
        let read = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"iconSizes": {"standard": 99, "finder": 4}}"#.utf8)), defaults: .defaults())
        #expect(read.iconSizes == DensitySizes(standard: 96, finder: 32))
        let large = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"iconSizes": {"finder": 500}}"#.utf8)), defaults: .defaults())
        #expect(large.iconSizes == DensitySizes(standard: 64, finder: 128))
        #expect(AppPreferenceLimits.clampIconSize(75.9) == 72)
        #expect(AppPreferenceLimits.clampIconSize(76) == 80)
        #expect(!PreferenceKey.iconSizes.isWindowSessionKey)
    }

    @Test func previewCountsAreKeptPerDensityAndOnlyNineFourTwoOrOne() throws {
        #expect(AppPreferences.defaults().previewCounts == DensitySizes(standard: 4, finder: 4))
        let read = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"previewCounts": {"standard": 9, "finder": 1}}"#.utf8)), defaults: .defaults())
        #expect(read.previewCounts == DensitySizes(standard: 9, finder: 1))
        let other = PreferencesSanitizer.sanitize(
            try JSONNode.parse(Data(#"{"previewCounts": {"standard": 3, "finder": 240}}"#.utf8)), defaults: .defaults())
        #expect(other.previewCounts == DensitySizes(standard: 4, finder: 4))
        #expect(!PreferenceKey.previewCounts.isWindowSessionKey)
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
        // Missing values are written as null.
        let json = try #require(try JSONNode.parse(data).object?["preferences"]?.object)
        #expect(json["treeRootPath"] == JSONNode.null)
        #expect(json["terminalApp"]?.object?["appName"] == JSONNode.string("iTerm"))
        #expect(json["openTabs"]?.array?.first?.object?["favoritePath"] == JSONNode.null)
    }
}
