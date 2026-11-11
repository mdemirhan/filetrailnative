import Foundation
import Testing

@testable import FTFoundation

struct PreferenceKeyTests {
    /// Preferences that differ from the defaults in every field.
    static let allDifferent = PreferencesSanitizer.sanitize(
        try? JSONNode.parse(
            Data(
                """
                {"theme": "dark", "accent": "#2cb5a0", "viewMode": "details", "searchViewMode": "list",
                 "sortBy": "modified", "sortDirection": "desc", "foldersFirst": false, "density": "finder",
                 "singleClickExpandTreeItems": true,
                 "detailColumns": {"size": false, "modified": false, "permissions": true, "kind": true, "created": true},
                 "detailColumnOrder": ["kind", "size", "modified", "permissions", "created"],
                 "detailColumnWidths": {"name": 360, "size": 120, "modified": 181, "permissions": 160, "kind": 149,
                                        "created": 169},
                 "searchColumns": {"folder": false, "kind": true, "created": true},
                 "searchColumnOrder": ["size", "folder", "modified", "kind", "created", "permissions"],
                 "searchColumnWidths": {"name": 400, "folder": 300},
                 "notificationsEnabled": false, "markClipboardItems": false, "autoCalculateFolderSizes": false,
                 "folderTreeOpen": false, "propertiesOpen": true, "detailRowOpen": true,
                 "topToolbarItems": ["search", "back", "title"],
                 "terminalApp": {"appPath": "/Applications/iTerm.app", "appName": "iTerm"},
                 "defaultTextEditor": {"appPath": "/Applications/Zed.app", "appName": "Zed"},
                 "openWithApplications": [{"id": "zed", "appPath": "/Applications/Zed.app", "appName": "Zed"}],
                 "fileActivationAction": "edit", "diskImageOpensIn": "tab", "returnKeyAction": "open",
                 "shortcutOverrides": {"newTab": ["Cmd+Option+N"]}, "openItemLimit": 9, "includeHidden": true,
                 "searchPatternMode": "glob", "searchMatchScope": "path", "searchRecursive": false,
                 "searchSkipGitFolders": false, "searchSkipGitIgnored": true, "searchResultsSortBy": "name",
                 "searchResultsSortDirection": "desc", "treeWidth": 312, "inspectorWidth": 388,
                 "restoreSessionOnStartup": false,
                 "openTabs": [{"path": "/Users/demo/src", "viewMode": "list"}], "activeTabIndex": 1,
                 "treeRootPath": "/Users/demo", "lastVisitedPath": "/Users/demo/src",
                 "lastVisitedFavoritePath": "/Users/demo/Documents",
                 "favorites": [{"path": "/Users/demo/Documents", "icon": "documents"}],
                 "favoritesPlacement": "separate", "favoritesExpanded": false, "locationsExpanded": false,
                 "favoritesInitialized": true, "batchRenameSettings": {"mode": "format", "digits": "auto"},
                 "batchRenamePresets": [{"name": "Photos", "settings": {"mode": "add"}}]}
                """.utf8)),
        defaults: .defaults())

    @Test func namesEveryFieldOfThePreferencesOnce() throws {
        let encoded = try #require(try JSONNode.of(AppPreferences.defaults()).object)
        #expect(Set(encoded.keys) == Set(PreferenceKey.allCases.map(\.rawValue)))
        #expect(PreferenceKey.allCases.count == 53)
        #expect(PreferenceKey(\AppPreferences.theme) == .theme)
        #expect(PreferenceKey(\AppPreferences.terminalApp) == .terminalApp)
        #expect(PreferenceKey(\AppPreferences.detailColumnWidths.name) == nil)
    }

    @Test func comparesTheFieldsOneByOne() throws {
        let defaults = AppPreferences.defaults()
        #expect(defaults.keys(differingFrom: Self.allDifferent) == PreferenceKey.allCases)
        #expect(defaults.keys(differingFrom: defaults).isEmpty)
        for key in PreferenceKey.allCases {
            var changed = defaults
            changed.take(key, from: Self.allDifferent)
            #expect(changed.keys(differingFrom: defaults) == [key], "\(key)")
            #expect(changed.node(key) == Self.allDifferent.node(key), "\(key)")
            #expect(changed.node(key) == (try JSONNode.of(Self.allDifferent)).object?[key.rawValue], "\(key)")
        }
    }

    @Test func aWindowSessionHoldsItsKeysAndNoOther() throws {
        let encoded = try #require(try JSONNode.of(AppPreferences.defaults().windowSession).object)
        #expect(Set(encoded.keys) == Set(WindowSession.keys.map(\.rawValue)))
        #expect(WindowSession.keys.count == 22)
        let applied = Self.allDifferent.windowSession.applied(to: .defaults())
        #expect(applied.keys(differingFrom: .defaults()) == PreferenceKey.allCases.filter(\.isWindowSessionKey))
        #expect(PreferenceKey.allCases.filter(\.isWindowSessionKey).count == 22)
        #expect(!PreferenceKey.theme.isWindowSessionKey)
    }

    @Test func notesEveryFieldWrittenEvenWithTheValueItHad() {
        var edited = EditedPreferences(.defaults())
        edited.theme = .auto
        edited.detailColumnWidths.name = 400
        edited.favorites.append(FavoritePreference(path: "/Users/demo", icon: .home))
        edited.theme = .dark
        _ = edited.accent
        #expect(edited.written == [.theme, .detailColumnWidths, .favorites])
        #expect(edited.preferences.theme == .dark)
        #expect(edited.preferences.detailColumnWidths.name == 400)
        #expect(edited.preferences.keys(differingFrom: .defaults()) == [.theme, .detailColumnWidths, .favorites])
    }

    @Test func aChangeWrittenOnWholePreferencesWritesWhatItChanged() {
        var edited = EditedPreferences(.defaults())
        edited.apply {
            $0.theme = .auto
            $0.markClipboardItems = false
            $0.detailColumns[.size] = !$0.detailColumns[.size]
        }
        #expect(edited.written == [.detailColumns, .markClipboardItems])
        var taken = EditedPreferences(.defaults())
        taken.take(.accent, from: Self.allDifferent)
        #expect(taken.written == [.accent])
        #expect(taken.preferences.accent == "#2cb5a0")
    }

    // A field written is checked as the file's reader checks it; the others are left alone.
    @Test func checksTheKeysWrittenAsTheFileIsRead() {
        let defaults = AppPreferences.defaults(theme: .dark)
        var written = defaults
        written.treeWidth = 5000
        written.inspectorWidth = 1
        written.openItemLimit = 999
        written.accent = "red"
        written.lastVisitedPath = ""
        written.activeTabIndex = -3
        written.detailColumnWidths.name = 9999
        written.openTabs = Array(
            repeating: OpenTabPreference(
                path: "/Users/demo", treeRootPath: nil, favoritePath: nil, viewMode: .icons, searchViewMode: .details,
                sortBy: .name, sortDirection: .asc, includeHidden: false, foldersFirst: true,
                favoritesExpanded: true, locationsExpanded: true),
            count: 30)
        written.favorites = [
            FavoritePreference(path: " /Users/demo ", icon: .home),
            FavoritePreference(path: "/Users/demo", icon: .star),
        ]
        written.batchRenamePresets = [
            BatchRenamePreset(name: String(repeating: "n", count: 100), settings: .defaults),
            BatchRenamePreset(name: "  ", settings: .defaults),
        ]
        written.foldersFirst = false
        let keys: [PreferenceKey] = [
            .treeWidth, .inspectorWidth, .openItemLimit, .accent, .lastVisitedPath, .activeTabIndex,
            .detailColumnWidths, .openTabs, .favorites, .batchRenamePresets,
        ]
        let checked = PreferencesSanitizer.sanitize(keys, of: written, defaults: defaults)
        var record = (try? JSONNode.of(defaults))?.object ?? [:]
        for key in keys {
            record[key.rawValue] = written.node(key)
        }
        let read = PreferencesSanitizer.sanitize(.object(record), defaults: defaults)
        for key in keys {
            #expect(checked.node(key) == read.node(key), "\(key)")
            #expect(checked.node(key) != written.node(key), "\(key)")
        }
        // Not written, so not checked.
        #expect(!checked.foldersFirst)
        #expect(checked.treeWidth == AppPreferenceLimits.treeWidthRange.upperBound)
        #expect(checked.accent == defaults.accent)
        #expect(checked.lastVisitedPath == nil)
        #expect(checked.openTabs.count == AppPreferenceLimits.openTabsLimit)
        #expect(checked.favorites.map(\.path) == ["/Users/demo"])
        #expect(checked.batchRenamePresets.map(\.name.count) == [80])
    }
}
