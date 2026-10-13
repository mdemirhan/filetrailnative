// Port of the sanitizing and migration cases of apps/desktop/src/main/appStateStore.test.ts. The cases that write
// files, time the writes, or drive the store's window operations are P2-07's, which cites them; the Rename sheet's
// settings and presets (T-85076d5a, T-4842d062, T-c05abda2) are checked by the batch-rename package's sanitizers.
import Foundation
import Testing

@testable import FTFoundation

struct AppStateReaderTests {
    static func node(_ text: String) -> JSONNode {
        (try? JSONNode.parse(Data(text.utf8))) ?? .null
    }

    static func read(_ text: String, theme: ThemePreference = .dark) -> AppState {
        (try? AppStateReader.read(data: Data(text.utf8), defaults: .defaults(theme: theme))) ?? AppState()
    }

    static func preferences(_ text: String, theme: ThemePreference = .dark) -> AppPreferences {
        read(text, theme: theme).preferences ?? .defaults(theme: theme)
    }

    static func tab(_ path: String) -> String {
        """
        {"path": "\(path)", "treeRootPath": "/Users/demo", "favoritePath": null, "viewMode": "list",
         "searchViewMode": "details", "sortBy": "name", "sortDirection": "asc", "includeHidden": false,
         "foldersFirst": true, "favoritesExpanded": true, "locationsExpanded": true}
        """
    }

    // T-ce547ed1 F-022
    @Test func keepsTheSavedTabsThatMakeSenseAndDropsTheRest() {
        let preferences = Self.preferences(
            """
            {"preferences": {"restoreSessionOnStartup": true, "activeTabIndex": -3, "locationsExpanded": false,
              "openTabs": [
                {"path": "/Users/demo/work", "viewMode": "details", "sortBy": "size", "sortDirection": "desc",
                 "includeHidden": true, "favoritesExpanded": false},
                "not a tab",
                {"path": "", "treeRootPath": 7, "viewMode": "gallery", "sortBy": "colour"}]}}
            """)
        #expect(preferences.restoreSessionOnStartup)
        #expect(preferences.activeTabIndex == 0)
        #expect(
            preferences.openTabs == [
                OpenTabPreference(
                    path: "/Users/demo/work", treeRootPath: nil, favoritePath: nil, viewMode: .details,
                    searchViewMode: .details, sortBy: .size, sortDirection: .desc, includeHidden: true,
                    foldersFirst: true, favoritesExpanded: false,
                    // Saved before tabs kept their sidebar: the window's setting.
                    locationsExpanded: false),
                // A tab without settings of its own takes the defaults, and the window's sidebar.
                OpenTabPreference(
                    path: nil, treeRootPath: nil, favoritePath: nil, viewMode: .icons, searchViewMode: .details,
                    sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true,
                    favoritesExpanded: true, locationsExpanded: false),
            ])
    }

    // T-817178dd F-011
    // With no file the store holds the defaults of the platform's first-launch theme and no windows.
    @Test func returnsDefaultsWhenNoStateFileExists() {
        let defaults = AppPreferences.defaults(theme: .dark)
        #expect(defaults.theme == .dark)
        #expect(defaults.returnKeyAction == .rename)
        #expect(defaults.shortcutOverrides == [:])
        #expect(defaults.openWithApplications == [])
        #expect(defaults.batchRenameSettings == BatchRenameSanitizers.defaultSettings)
        #expect(defaults.batchRenamePresets == .array([]))
        // A file that is not an object holds nothing, so the defaults stand.
        #expect(Self.read("[]") == AppState())
        #expect(Self.read("") == AppState())
        #expect(Self.read("{") == AppState())
        // A file with no preferences gets the defaults.
        #expect(Self.preferences("{}") == defaults)
    }

    // T-472f579d F-011
    @Test func keepsASavedThemeAndDefaultsAnyOtherValue() {
        func load(_ theme: String) -> ThemePreference {
            Self.preferences("{\"preferences\": {\"theme\": \(theme)}}", theme: .auto).theme
        }
        #expect(load("\"light\"") == .light)
        #expect(load("\"dark\"") == .dark)
        #expect(load("\"auto\"") == .auto)
        #expect(load("\"macos-light\"") == .auto)
        #expect(load("7") == .auto)
    }

    // T-fe1b8d68 F-020
    @Test func keepsASavedSearchMatchModeAndDefaultsToPlainText() {
        func load(_ mode: String?) -> SearchPatternModePreference {
            let body = mode.map { "\"searchPatternMode\": \($0)" } ?? ""
            return Self.preferences("{\"preferences\": {\(body)}}").searchPatternMode
        }
        #expect(load("\"regex\"") == .regex)
        #expect(load("\"glob\"") == .glob)
        #expect(load("\"text\"") == .text)
        #expect(load(nil) == .text)
        #expect(load("\"fuzzy\"") == .text)
    }

    // T-183c3ee2 F-011 F-013 F-014 F-015 F-019 F-021
    @Test func sanitizesInvalidPersistedValues() {
        let defaults = AppPreferences.defaults(theme: .dark)
        // The change the original applies through updatePreferences, then reads back from the file.
        let patch =
            Self.node(
                """
                {"accent": "bad-accent", "zoomPercent": 999, "sortBy": "oops", "sortDirection": "sideways",
                 "topToolbarItems": ["back", "search", "search", "home"],
                 "uiFontFamily": "lexend", "tabStyle": "cards", "highlightHoveredItems": true,
                 "notificationDurationSeconds": 8, "notifyClipboardItems": false, "uiFontSize": 15, "uiFontWeight": 600,
                 "favoritesPaneHeight": 224, "typeaheadEnabled": false, "typeaheadDebounceMs": 9999,
                 "searchResultsFilterScope": "path",
                 "terminalApp": {"appPath": "   ", "appName": "iTerm"},
                 "defaultTextEditor": {"appPath": "   ", "appName": "TextEdit"},
                 "openWithApplications": [{"id": "", "appPath": "/Applications/Bad.app", "appName": "Bad"}],
                 "compactDetailsView": "yes",
                 "detailColumns": {"size": "nope", "modified": false, "permissions": true},
                 "detailColumnOrder": ["kind", "kind", "bogus", "size"],
                 "searchColumns": {"folder": false, "kind": "yes", "created": true},
                 "searchColumnOrder": ["size", "name", "size", "folder"],
                 "searchColumnWidths": {"folder": 5, "name": 400},
                 "searchResultsSortBy": "kind",
                 "detailColumnWidths": {"name": 9999, "size": 1, "modified": 180, "permissions": 40, "kind": 148,
                                        "created": 168},
                 "fileActivationAction": "launch", "diskImageOpensIn": "sideways", "openItemLimit": 999,
                 "treeWidth": 1, "inspectorWidth": 9999, "treeRootPath": "", "lastVisitedPath": "",
                 "lastVisitedFavoritePath": ""}
                """
            ).object ?? [:]
        let applied = PreferencesSanitizer.apply(patch, to: defaults, defaults: defaults)
        let state = AppState(preferences: applied)
        let reloaded =
            (try? AppStateReader.read(data: JSONEncoder().encode(state), defaults: defaults))?.preferences ?? defaults

        #expect(reloaded.accent == "#007aff")
        #expect(reloaded.zoomPercent == 150)
        #expect(reloaded.sortBy == .name)
        #expect(reloaded.sortDirection == .asc)
        #expect(reloaded.topToolbarItems == [.back, .search, .title, .clipboard, .viewOptions])
        #expect(reloaded.treeWidth == 220)
        #expect(reloaded.inspectorWidth == 480)
        // Settings that no longer exist are dropped when loading.
        let keys = Set((try? JSONNode.of(reloaded))?.object?.keys.map { $0 } ?? [])
        for removed in [
            "uiFontFamily", "tabStyle", "highlightHoveredItems", "notificationDurationSeconds", "notifyClipboardItems",
            "uiFontSize", "uiFontWeight", "favoritesPaneHeight", "typeaheadEnabled", "typeaheadDebounceMs",
            "searchResultsFilterScope",
        ] {
            #expect(!keys.contains(removed), "\(removed)")
        }
        #expect(reloaded.terminalApp == nil)
        #expect(
            reloaded.defaultTextEditor
                == ApplicationSelection(appPath: "/System/Applications/TextEdit.app", appName: "TextEdit"))
        #expect(reloaded.openWithApplications == [])
        #expect(reloaded.compactDetailsView == false)
        #expect(
            reloaded.detailColumns
                == DetailColumnVisibility(modified: false, size: true, kind: true, created: false, permissions: true))
        #expect(reloaded.detailColumnOrder == [.kind, .size, .modified, .created, .permissions])
        #expect(
            reloaded.detailColumnWidths
                == DetailColumnWidths(name: 720, modified: 180, size: 60, kind: 148, created: 168, permissions: 40))
        // Search results' columns are read the same way, apart from a folder's.
        #expect(
            reloaded.searchColumns
                == SearchColumnVisibility(
                    folder: false, modified: true, size: true, kind: false, created: true, permissions: false))
        #expect(reloaded.searchColumnOrder == [.size, .folder, .modified, .kind, .created, .permissions])
        #expect(reloaded.searchColumnWidths.name == 400)
        #expect(reloaded.searchColumnWidths.folder == 80)
        #expect(reloaded.searchColumnWidths.size == 108)
        #expect(reloaded.searchResultsSortBy == .kind)
        #expect(reloaded.fileActivationAction == .open)
        #expect(reloaded.diskImageOpensIn == .window)
        #expect(reloaded.openItemLimit == 50)
        #expect(reloaded.treeRootPath == nil)
        #expect(reloaded.lastVisitedPath == nil)
        #expect(reloaded.lastVisitedFavoritePath == nil)
    }

    // T-d22ddcc1 F-018
    @Test func preservesAnExplicitlyEmptyOpenWithApplicationList() {
        let defaults = AppPreferences.defaults(theme: .dark)
        let patch: [String: JSONNode] = ["openWithApplications": .array([])]
        let applied = PreferencesSanitizer.apply(patch, to: defaults, defaults: defaults)
        let reloaded =
            (try? AppStateReader.read(data: JSONEncoder().encode(AppState(preferences: applied)), defaults: defaults))?
            .preferences
        #expect(reloaded?.openWithApplications == [])
    }

    // T-60062fcd
    // The sanitizing half: a hand-edited change is stored as the app will read it back.
    @Test func persistsPreferencesAndWindowStateInOneFile() throws {
        let defaults = AppPreferences.defaults(theme: .dark)
        let patch =
            Self.node(
                """
                {"theme": "dark",
                 "shortcutOverrides": {"newTab": ["option+cmd+n", "Cmd+C", "D"], "duplicateSelection": [],
                                       "closeTab": ["Cmd+W"], "noSuchCommand": ["Cmd+J"]},
                 "accent": "#2cb5a0", "zoomPercent": 115, "viewMode": "details", "sortBy": "modified",
                 "sortDirection": "desc", "foldersFirst": false, "compactListView": true,
                 "detailColumns": {"size": true, "modified": false, "permissions": true, "kind": true, "created": false},
                 "detailColumnOrder": ["kind", "size", "modified", "permissions", "created"],
                 "detailColumnWidths": {"name": 360, "size": 120, "modified": 180, "permissions": 160, "kind": 148,
                                        "created": 168},
                 "topToolbarItems": ["search", "back", "title", "copyPath", "clipboard", "viewOptions"],
                 "terminalApp": {"appPath": "/Applications/iTerm.app", "appName": "iTerm"},
                 "defaultTextEditor": {"appPath": "/Applications/Zed.app", "appName": "Zed"},
                 "openWithApplications": [{"id": "zed", "appPath": "/Applications/Zed.app", "appName": "Zed"}],
                 "fileActivationAction": "edit", "diskImageOpensIn": "tab", "openItemLimit": 9, "includeHidden": true,
                 "searchPatternMode": "glob", "searchMatchScope": "path", "searchRecursive": false,
                 "searchResultsSortBy": "name", "searchResultsSortDirection": "desc", "detailRowOpen": true,
                 "treeWidth": 312, "inspectorWidth": 388, "restoreSessionOnStartup": false,
                 "openTabs": [\(Self.tab("/Users/demo/src")), \(Self.tab("/Users/demo/Documents"))],
                 "activeTabIndex": 1, "treeRootPath": "/Users/demo", "lastVisitedPath": "/Users/demo/src",
                 "lastVisitedFavoritePath": "/Users/demo/Documents",
                 "favorites": [{"path": "/Users/demo/Documents", "icon": "documents"},
                               {"path": "/Applications", "icon": "applications"}],
                 "favoritesPlacement": "separate", "favoritesExpanded": false, "locationsExpanded": true,
                 "favoritesInitialized": true}
                """
            ).object ?? [:]
        let applied = PreferencesSanitizer.apply(patch, to: defaults, defaults: defaults)
        let bounds = StoredWindowState(x: 120, y: 140, width: 1600, height: 1000, maximized: true)
        let state = AppState(
            preferences: applied,
            windows: [StoredExplorerWindow(id: "window-a", bounds: bounds, session: applied.windowSession)])
        let reloaded = try AppStateReader.read(data: JSONEncoder().encode(state), defaults: defaults)

        #expect(reloaded.preferences == applied)
        #expect(applied.shortcutOverrides == ["newTab": ["Cmd+Option+N"], "duplicateSelection": []])
        #expect(applied.accent == "#2cb5a0")
        #expect(applied.zoomPercent == 115)
        #expect(applied.openTabs.count == 2)
        #expect(applied.activeTabIndex == 1)
        #expect(applied.favorites.map(\.icon) == [.documents, .applications])
        #expect(reloaded.windows?.map(\.bounds) == [bounds])
        #expect(reloaded.windows?.first?.session.activeTabIndex == 1)
    }

    // MARK: Windows

    // T-894b255d
    @Test func readsAFileSavedWithOneWindowAsThatWindowWithItsTabsAndPanels() {
        let state = Self.read(
            """
            {"preferences": {"openTabs": [\(Self.tab("/Users/demo/work")), \(Self.tab("/Users/demo/music"))],
                             "activeTabIndex": 1, "treeWidth": 300, "propertiesOpen": true},
             "window": {"x": 10, "y": 20, "width": 900, "height": 600, "maximized": false}}
            """)
        let windows = state.windows ?? []
        #expect(windows.count == 1)
        #expect(windows.first?.id == "window-1")
        #expect(windows.first?.bounds == StoredWindowState(x: 10, y: 20, width: 900, height: 600, maximized: false))
        #expect(windows.first?.session.openTabs.map(\.path) == ["/Users/demo/work", "/Users/demo/music"])
        #expect(windows.first?.session.activeTabIndex == 1)
        #expect(windows.first?.session.treeWidth == 300)
        #expect(windows.first?.session.propertiesOpen == true)
        #expect(state.lastClosedWindow == nil)
    }

    // T-bedcb0e7
    @Test func opensAsTheWindowClosedLastEndedWhenTheListOfWindowsIsDamaged() {
        let state = Self.read(
            """
            {"preferences": {"openTabs": [\(Self.tab("/Users/demo/stale"))]},
             "windows": "not a list",
             "lastClosedWindow": {"id": "window-a", "bounds": {"x": 40, "y": 60, "width": 900, "height": 600},
                                  "session": {"openTabs": [\(Self.tab("/Users/demo/work"))]}}}
            """)
        // Not a window made up from the preferences, as for a file from before there were several: this file had them.
        #expect(state.windows == [])
        #expect(state.lastClosedWindow?.session.openTabs.map(\.path) == ["/Users/demo/work"])
    }

    // T-ad5ce6b9
    // The reading half; remembering a window as it closes is the store's.
    @Test func bringsBackTheWindowClosedLastOnATabItHasWhateverItsFrontTabSays() {
        let state = Self.read(
            """
            {"preferences": {},
             "windows": [{"id": "window-b",
                          "session": {"openTabs": [\(Self.tab("/Users/demo/a")), \(Self.tab("/Users/demo/b"))],
                                      "activeTabIndex": 7}}],
             "lastClosedWindow": {"id": "window-a",
                                  "session": {"openTabs": [\(Self.tab("/Users/demo/work"))], "activeTabIndex": 3}}}
            """)
        #expect(state.lastClosedWindow?.session.activeTabIndex == 0)
        #expect(state.windows?.first?.session.activeTabIndex == 1)
        #expect(state.windows?.first?.session.frontTabIndex == 1)
    }

    // T-7fddaaf9
    @Test func keepsTheWindowsOfADamagedFileThatMakeSense() {
        var sixty = ""
        for index in 0..<60 { sixty += ", {\"id\": \"window-\(index + 1000)\"}" }
        let state = Self.read(
            """
            {"preferences": {"treeWidth": 300},
             "windows": ["not a window", {"id": "", "bounds": {}},
               {"id": "window-a", "bounds": {"width": 10}, "session": {"treeWidth": "wide", "openTabs": 3}},
               {"id": "window-a", "session": {"treeWidth": 400}}\(sixty)]}
            """)
        let windows = state.windows ?? []
        #expect(windows.count == AppStateReader.windowsLimit)
        #expect(windows.first?.id == "window-a")
        // A missing or bad value takes the app's.
        #expect(windows.first?.session.treeWidth == 300)
        #expect(windows.first?.session.openTabs == [])
        #expect(windows.first?.bounds == StoredWindowState(width: 1200, height: 760, maximized: false))
    }

    @Test func aWindowKeepsItsOwnSessionKeysOverTheApps() {
        let state = Self.read(
            """
            {"preferences": {"treeWidth": 300, "notificationsEnabled": false, "propertiesOpen": false},
             "windows": [{"id": "window-a", "session": {"treeWidth": 400, "propertiesOpen": true,
                                                        "notificationsEnabled": true}}]}
            """)
        let window = state.windows?.first
        #expect(window?.session.treeWidth == 400)
        #expect(window?.session.propertiesOpen == true)
        // notificationsEnabled is not a session key: the window's copy is ignored.
        let merged = window?.session.applied(to: state.preferences ?? .defaults())
        #expect(merged?.notificationsEnabled == false)
        #expect(merged?.treeWidth == 400)
        #expect(state.preferences?.treeWidth == 300)
    }

    @Test func halfPixelWidthsRoundUpAndBadBoundsFallBack() {
        let state = Self.preferences(
            "{\"preferences\": {\"treeWidth\": 220.5, \"inspectorWidth\": 260.5, \"zoomPercent\": 75.5, \"openItemLimit\": 1.5}}"
        )
        #expect(state.treeWidth == 221)
        #expect(state.inspectorWidth == 261)
        #expect(state.zoomPercent == 76)
        #expect(state.openItemLimit == 2)
        #expect(AppStateReader.windowState(.object(["width": .number(319), "height": .number(6001)])).width == 1200)
        #expect(AppStateReader.windowState(.object(["width": .number(320), "height": .number(6000)])).height == 6000)
        #expect(AppStateReader.windowState(.object(["x": .string("1"), "maximized": .number(1)])).maximized == false)
    }
}
