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

    /// `patch` over `preferences`, read as the file's reader reads it: a value that isn't valid takes its default.
    static func applied(_ patch: [String: JSONNode], over preferences: AppPreferences) -> AppPreferences {
        var record = (try? JSONNode.of(preferences))?.object ?? [:]
        record.merge(patch) { _, new in new }
        return PreferencesSanitizer.sanitize(.object(record), defaults: preferences)
    }

    // With no file the store holds the defaults of the platform's first-launch theme and no windows.
    // What this version doesn't know, a newer version's settings, is kept as it was read, beside the preferences and
    // among them; what it knows is read as ever, and a preference it retired is not kept.
    @Test func keepsWhatANewerVersionWroteAndDropsWhatThisOneRetired() {
        let state = Self.read(
            """
            {
              "preferences": {
                "theme": "light",
                "laterSetting": {"kept": [1, "two", null], "on": true},
                "workspaces": [{"id": "w"}],
                "fileActivationAction": "open",
                "previewSizes": {"standard": 3}
              },
              "windows": [],
              "laterFile": "kept as it is",
              "window": {"width": 900, "height": 600, "maximized": false}
            }
            """)
        #expect(state.preferences?.theme == .light)
        #expect(state.unknownPreferences == ["laterSetting": Self.node(#"{"kept": [1, "two", null], "on": true}"#)])
        #expect(state.unknown == ["laterFile": .string("kept as it is")])
        // Nothing of a file without anything unknown.
        #expect(Self.read(#"{"preferences": {"theme": "dark"}}"#).unknownPreferences.isEmpty)
        #expect(Self.read(#"{"preferences": {"theme": "dark"}}"#).unknown.isEmpty)
        // Every preference this version names is its own, and none it retired is one of them.
        #expect(PreferenceKey.retired.allSatisfy { PreferenceKey(rawValue: $0) == nil })
    }

    @Test func returnsDefaultsWhenNoStateFileExists() {
        let defaults = AppPreferences.defaults(theme: .dark)
        #expect(defaults.theme == .dark)
        #expect(defaults.returnKeyAction == .rename)
        #expect(defaults.shortcutOverrides == [:])
        #expect(defaults.openWithApplications == [])
        #expect(defaults.node(.batchRenameSettings) == SavedSettingsTests.defaultSettings)
        #expect(defaults.node(.batchRenamePresets) == .array([]))
        // A file that is not an object holds nothing, so the defaults stand.
        #expect(Self.read("[]") == AppState())
        #expect(Self.read("") == AppState())
        #expect(Self.read("{") == AppState())
        // A file with no preferences gets the defaults.
        #expect(Self.preferences("{}") == defaults)
    }

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

    // A file saved before the density had the four Compact switches: all of them on is Finder's sizes.
    @Test func readsTheDensityOrTheCompactSwitchesItReplaced() {
        func load(_ fields: String) -> Density { Self.preferences("{\"preferences\": {\(fields)}}").density }
        #expect(load("") == .standard)
        #expect(load(#""density": "finder""#) == .finder)
        #expect(load(#""density": "compact""#) == .standard)
        let all =
            #""compactListView": true, "compactDetailsView": true, "compactIconView": true, "compactTreeView": true"#
        #expect(load(all) == .finder)
        #expect(load(#""compactListView": true, "compactDetailsView": false"#) == .standard)
        #expect(load(#""density": "standard", "# + all) == .standard)
    }

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

    @Test func sanitizesInvalidPersistedValues() {
        let defaults = AppPreferences.defaults(theme: .dark)
        // A change applied through updatePreferences, then read back from the file.
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
                 "density": "huge",
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
        let applied = Self.applied(patch, over: defaults)
        let state = AppState(preferences: applied)
        let reloaded =
            (try? AppStateReader.read(data: JSONEncoder().encode(state), defaults: defaults))?.preferences ?? defaults

        // An accent that is not a color falls back to the default, System.
        #expect(reloaded.accent == "system")
        #expect(reloaded.sortBy == .name)
        #expect(reloaded.sortDirection == .asc)
        #expect(reloaded.topToolbarItems == [.back, .search, .title])
        #expect(reloaded.treeWidth == 220)
        #expect(reloaded.inspectorWidth == 480)
        // Settings that no longer exist are dropped when loading.
        let keys = Set((try? JSONNode.of(reloaded))?.object?.keys.map { $0 } ?? [])
        for removed in [
            "uiFontFamily", "tabStyle", "highlightHoveredItems", "notificationDurationSeconds", "notifyClipboardItems",
            "uiFontSize", "uiFontWeight", "favoritesPaneHeight", "typeaheadEnabled", "typeaheadDebounceMs",
            "searchResultsFilterScope", "zoomPercent", "compactListView", "compactDetailsView", "compactIconView",
            "compactTreeView",
        ] {
            #expect(!keys.contains(removed), "\(removed)")
        }
        #expect(reloaded.terminalApp == nil)
        #expect(
            reloaded.defaultTextEditor
                == ApplicationSelection(appPath: "/System/Applications/TextEdit.app", appName: "TextEdit"))
        #expect(reloaded.openWithApplications == [])
        #expect(reloaded.density == .standard)
        #expect(
            reloaded.detailColumns
                == DetailColumnVisibility(modified: false, size: true, kind: true, created: false, permissions: true))
        #expect(reloaded.detailColumnOrder == [.kind, .size, .modified, .created, .lastOpened, .added, .permissions])
        #expect(
            reloaded.detailColumnWidths
                == DetailColumnWidths(name: 1000, modified: 180, size: 60, kind: 148, created: 168, permissions: 40))
        // Search results' columns are read the same way, apart from a folder's.
        #expect(
            reloaded.searchColumns
                == SearchColumnVisibility(
                    folder: false, modified: true, size: true, kind: false, created: true, permissions: false))
        #expect(
            reloaded.searchColumnOrder == [
                .size, .folder, .modified, .created, .lastOpened, .added, .kind, .permissions,
            ])
        #expect(reloaded.searchColumnWidths.name == 400)
        #expect(reloaded.searchColumnWidths.folder == 80)
        #expect(reloaded.searchColumnWidths.size == 108)
        #expect(reloaded.searchResultsSortBy == .kind)
        #expect(reloaded.diskImageOpensIn == .window)
        #expect(reloaded.openItemLimit == 50)
        #expect(reloaded.treeRootPath == nil)
        #expect(reloaded.lastVisitedPath == nil)
        #expect(reloaded.lastVisitedFavoritePath == nil)
    }

    @Test func preservesAnExplicitlyEmptyOpenWithApplicationList() {
        let defaults = AppPreferences.defaults(theme: .dark)
        let patch: [String: JSONNode] = ["openWithApplications": .array([])]
        let applied = Self.applied(patch, over: defaults)
        let reloaded =
            (try? AppStateReader.read(data: JSONEncoder().encode(AppState(preferences: applied)), defaults: defaults))?
            .preferences
        #expect(reloaded?.openWithApplications == [])
    }

    // The sanitizing half: a hand-edited change is stored as the app will read it back.
    @Test func persistsPreferencesAndWindowStateInOneFile() throws {
        let defaults = AppPreferences.defaults(theme: .dark)
        let patch =
            Self.node(
                """
                {"theme": "dark",
                 "shortcutOverrides": {"newTab": ["option+cmd+n", "Cmd+C", "D"], "duplicateSelection": [],
                                       "closePane": ["Cmd+W"], "noSuchCommand": ["Cmd+J"]},
                 "accent": "#2cb5a0", "viewMode": "details", "sortBy": "modified",
                 "sortDirection": "desc", "foldersFirst": false, "density": "finder",
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
        let applied = Self.applied(patch, over: defaults)
        let bounds = StoredWindowState(x: 120, y: 140, width: 1600, height: 1000, maximized: true)
        let state = AppState(
            preferences: applied,
            windows: [StoredExplorerWindow(id: "window-a", bounds: bounds, session: applied.windowSession)])
        let reloaded = try AppStateReader.read(data: JSONEncoder().encode(state), defaults: defaults)

        #expect(reloaded.preferences == applied)
        #expect(applied.shortcutOverrides == ["newTab": ["Cmd+Option+N"], "duplicateSelection": []])
        #expect(applied.accent == "#2cb5a0")
        #expect(applied.openTabs.count == 2)
        #expect(applied.activeTabIndex == 1)
        #expect(applied.favorites.map(\.icon) == [.documents, .applications])
        #expect(reloaded.windows?.map(\.bounds) == [bounds])
        #expect(reloaded.windows?.first?.session.activeTabIndex == 1)
    }

    // MARK: Windows

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

    // A pane's Read or Edit and Follow are read back with it; a pane saved before it had them starts at the app's
    // Read or Edit, with Follow on.
    @Test func aPanesReadOrEditAndFollowAreReadBack() {
        let state = Self.read(
            """
            {"preferences": {"textViewerSettings": {"opensForEditing": true}},
             "windows": [{"id": "window-a",
                          "session": {"openTabs": [{"path": "/Users/demo/a",
                                                    "viewSizes": {"viewerEditing": false, "viewerFollows": false}},
                                                   {"path": "/Users/demo/b", "viewSizes": {"iconSizes": {"standard": 96}}},
                                                   {"path": "/Users/demo/c", "viewSizes": {"viewerFollows": "no"}}]}}]}
            """)
        let tabs = state.windows?.first?.session.openTabs ?? []
        #expect(tabs.count == 3)
        #expect(tabs[0].viewSizes?.viewerEditing == false && tabs[0].viewSizes?.viewerFollows == false)
        #expect(tabs[1].viewSizes?.viewerEditing == true && tabs[1].viewSizes?.viewerFollows == true)
        #expect(tabs[2].viewSizes?.viewerFollows == true)
    }

    // A window kept the List's column widths before each pane had its own: a pane saved with its sizes but without
    // widths takes its window's, as it showed them, and one saved without sizes starts from the app's when it is
    // first read. The window's session keeps none from then on; the app's are those set last.
    @Test func aPaneSavedWithoutColumnWidthsTakesItsWindows() {
        let state = Self.read(
            """
            {"preferences": {"detailColumnWidths": {"name": 300}, "searchColumnWidths": {"folder": 200}},
             "windows": [{"id": "window-a",
                          "session": {"detailColumnWidths": {"name": 410}, "searchColumnWidths": {"folder": 150},
                                      "openTabs": [{"path": "/Users/demo/a", "viewSizes": {"iconSizes": {"standard": 96}},
                                                    "secondPane": {"path": "/Users/demo/b",
                                                                   "viewSizes": {"detailColumnWidths": {"name": 500}}}},
                                                   {"path": "/Users/demo/c"}]}}]}
            """)
        let tabs = state.windows?.first?.session.openTabs ?? []
        #expect(tabs.count == 2)
        #expect(tabs.first?.viewSizes?.iconSizes.standard == 96)
        #expect(tabs.first?.viewSizes?.detailColumnWidths.name == 410)
        #expect(tabs.first?.viewSizes?.detailColumnWidths.size == DetailColumnWidths.defaults.size)
        #expect(tabs.first?.viewSizes?.searchColumnWidths.folder == 150)
        // A width it has is its own, and a column's it doesn't say is its window's.
        #expect(tabs.first?.secondPane?.viewSizes?.detailColumnWidths.name == 500)
        #expect(tabs.first?.secondPane?.viewSizes?.searchColumnWidths.folder == 150)
        #expect(tabs.last?.viewSizes == nil)
        #expect(state.preferences?.detailColumnWidths.name == 300)
        let encoded = (try? JSONNode.of(state.windows?.first?.session))?.object ?? [:]
        #expect(encoded["detailColumnWidths"] == nil)
        #expect(encoded["searchColumnWidths"] == nil)
    }

    // A pane saved while the columns shown, the results' order and the search options were the window's kept only its
    // sizes and widths: it comes back with the columns, order and options it showed, not a new install's, and its
    // results at its folders' sizes. What the pane says is its own.
    @Test func aPaneSavedBeforeItHadItsOwnColumnsAndSearchSettingsTakesItsWindows() {
        let state = Self.read(
            """
            {"preferences": {"detailColumns": {"kind": false, "created": true}, "detailColumnOrder": ["created", "size"],
                             "searchColumns": {"folder": false}, "searchPatternMode": "regex",
                             "searchSkipGitIgnored": true, "searchResultsSortBy": "name",
                             "iconSizes": {"standard": 112}, "previewCounts": {"standard": 9}},
             "windows": [{"id": "window-a",
                          "session": {"searchResultsSortBy": "modified", "searchResultsSortDirection": "desc",
                                      "openTabs": [{"path": "/Users/demo/a",
                                                    "viewSizes": {"iconSizes": {"standard": 96},
                                                                  "compactListWidths": {"standard": 320},
                                                                  "previewCounts": {"standard": 2},
                                                                  "detailColumnWidths": {"name": 410}},
                                                    "secondPane": {"path": "/Users/demo/b",
                                                                   "viewSizes": {"iconSizes": {"standard": 48},
                                                                                 "searchIconSizes": {"standard": 80},
                                                                                 "detailColumns": {"kind": true},
                                                                                 "searchPatternMode": "glob"}}}]}}]}
            """)
        let app = state.preferences ?? .defaults()
        let tab = state.windows?.first?.session.openTabs.first
        let own = tab?.viewSizes
        #expect(own?.detailColumns == app.detailColumns)
        #expect(own?.detailColumns[.created] == true && own?.detailColumns[.kind] == false)
        #expect(own?.detailColumnOrder == app.detailColumnOrder)
        #expect(own?.searchColumns[.folder] == false)
        // "searchSkipGitIgnored", an option search no longer has, is passed over.
        #expect(own?.searchPatternMode == .regex)
        // The results' order was the window's.
        #expect(own?.searchResultsSortBy == .modified && own?.searchResultsSortDirection == .desc)
        #expect(own?.detailColumnWidths.name == 410)
        // Results showed at the folders' sizes: the pane's, and for the app the app's.
        #expect(own?.searchIconSizes.standard == 96 && own?.searchCompactListWidths.standard == 320)
        #expect(own?.searchPreviewCounts.standard == 2)
        #expect(app.searchIconSizes.standard == 112 && app.searchPreviewCounts.standard == 9)
        let second = tab?.secondPane?.viewSizes
        #expect(second?.detailColumns[.kind] == true && second?.detailColumns[.created] == true)
        #expect(second?.searchPatternMode == .glob)
        #expect(second?.searchIconSizes.standard == 80 && second?.iconSizes.standard == 48)
    }

    // Results' sizes the file has are kept, whatever the folders' are.
    @Test func resultsSizesTheFileHasAreNotTheFolders() {
        let app = Self.preferences(
            #"{"preferences": {"iconSizes": {"standard": 112}, "searchIconSizes": {"standard": 48}}}"#)
        #expect(app.iconSizes.standard == 112 && app.searchIconSizes.standard == 48)
    }

    // A window and the window closed last, as 1.2 saved them, kept the List's column widths in their session too: each
    // pane saved without widths takes those of the window it is in, not the app's nor another's.
    @Test func aWindowAndTheWindowClosedLastSavedWithoutPaneWidthsTakeTheirOwn() {
        func session(_ name: Int, _ folder: Int, tabs: String) -> String {
            """
            {"detailColumnWidths": {"name": \(name)}, "searchColumnWidths": {"folder": \(folder)},
             "openTabs": \(tabs)}
            """
        }
        let panes = """
            [{"path": "/Users/demo/a", "viewSizes": {"iconSizes": {"standard": 96}},
              "secondPane": {"path": "/Users/demo/b", "viewSizes": {"iconSizes": {"standard": 48}}}}]
            """
        let state = Self.read(
            """
            {"preferences": {"detailColumnWidths": {"name": 300}, "searchColumnWidths": {"folder": 200}},
             "windows": [{"id": "window-a", "session": \(session(410, 150, tabs: panes))}],
             "lastClosedWindow": {"id": "window-b", "session": \(session(430, 170, tabs: panes))}}
            """)
        let sessions = [
            (state.windows?.first?.session, 410, 150), (state.lastClosedWindow?.session, 430, 170),
        ]
        for (session, name, folder) in sessions {
            let tab = session?.openTabs.first
            #expect(tab?.viewSizes?.detailColumnWidths.name == name)
            #expect(tab?.viewSizes?.searchColumnWidths.folder == folder)
            #expect(tab?.viewSizes?.iconSizes.standard == 96)
            #expect(tab?.secondPane?.viewSizes?.detailColumnWidths.name == name)
            #expect(tab?.secondPane?.viewSizes?.searchColumnWidths.folder == folder)
            #expect(tab?.secondPane?.viewSizes?.iconSizes.standard == 48)
            // Saved before a pane kept its filter mode: it starts with the one chosen last.
            #expect(tab?.filterMode == nil && tab?.secondPane?.filterMode == nil)
        }
        #expect(state.preferences?.detailColumnWidths.name == 300)
    }

    @Test func halfPixelWidthsRoundUpAndBadBoundsFallBack() {
        let state = Self.preferences(
            "{\"preferences\": {\"treeWidth\": 220.5, \"inspectorWidth\": 260.5, \"openItemLimit\": 1.5}}"
        )
        #expect(state.treeWidth == 221)
        #expect(state.inspectorWidth == 261)
        #expect(state.openItemLimit == 2)
        #expect(AppStateReader.windowState(.object(["width": .number(319), "height": .number(6001)])).width == 1200)
        #expect(AppStateReader.windowState(.object(["width": .number(320), "height": .number(6000)])).height == 6000)
        #expect(AppStateReader.windowState(.object(["x": .string("1"), "maximized": .number(1)])).maximized == false)
    }
}
