// A full app-state.json is read, sanitized and written back with the same meaning
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct AppStateRoundTripTests {
    typealias Kit = StateTestKit

    /// A hand-made `app-state.json` with a value for every preference key, two windows and a window closed last.
    static let everyKey = """
        {
          "preferences": {
            "theme": "light",
            "accent": "#34c759",
            "viewMode": "details",
            "searchViewMode": "list",
            "sortBy": "modified",
            "sortDirection": "desc",
            "foldersFirst": false,
            "density": "finder",
            "detailColumns": {"modified": true, "size": false, "kind": true, "created": true, "added": true, "lastOpened": false, "permissions": true, "tags": true},
            "detailColumnOrder": ["size", "added", "modified", "kind", "created", "lastOpened", "permissions", "tags"],
            "detailColumnWidths": {"name": 400, "modified": 160, "size": 120, "kind": 150, "created": 170, "added": 165, "lastOpened": 175, "permissions": 110, "tags": 220},
            "searchColumns": {"folder": true, "modified": false, "size": true, "kind": true, "created": false, "added": true, "lastOpened": true, "permissions": false, "tags": true},
            "searchColumnOrder": ["modified", "folder", "size", "kind", "created", "added", "lastOpened", "permissions", "tags"],
            "searchColumnWidths": {"name": 310, "folder": 250, "modified": 150, "size": 110, "kind": 140, "created": 150, "added": 145, "lastOpened": 155, "permissions": 100, "tags": 230},
            "notificationsEnabled": false,
            "markClipboardItems": false,
            "autoCalculateFolderSizes": false,
            "folderTreeOpen": false,
            "propertiesOpen": true,
            "detailRowOpen": true,
            "topToolbarItems": ["folderTree", "topSeparator", "back", "forward", "title", "clipboard", "view", "sort", "search", "viewOptions", "infoPanel"],
            "terminalApp": {"appPath": "/Applications/iTerm.app", "appName": "iTerm"},
            "defaultTextEditor": {"appPath": "/Applications/Zed.app", "appName": "Zed"},
            "openWithApplications": [{"id": "a1", "appPath": "/Applications/Zed.app", "appName": "Zed"}],
            "diskImageOpensIn": "tab",
            "returnKeyAction": "open",
            "shortcutOverrides": {},
            "openItemLimit": 12,
            "includeHidden": true,
            "searchPatternMode": "glob",
            "searchMatchScope": "path",
            "searchRecursive": false,
            "searchSkipGitFolders": false,
            "searchResultsSortBy": "kind",
            "searchResultsSortDirection": "desc",
            "treeWidth": 300,
            "inspectorWidth": 350,
            "restoreSessionOnStartup": false,
            "openTabs": [
              {"path": "/Users/demo/work", "treeRootPath": "/Users/demo", "favoritePath": null, "viewMode": "list",
               "searchViewMode": "details", "sortBy": "name", "sortDirection": "asc", "includeHidden": false,
               "foldersFirst": true, "favoritesExpanded": true, "locationsExpanded": false, "groupBy": "kind",
               "searchGroupBy": "folder", "groupReversed": true}
            ],
            "activeTabIndex": 0,
            "treeRootPath": "/Users/demo",
            "lastVisitedPath": "/Users/demo/work",
            "lastVisitedFavoritePath": null,
            "favorites": [{"path": "/Users/demo/Desktop", "icon": "desktop"}],
            "favoritesPlacement": "separate",
            "favoritesExpanded": false,
            "locationsExpanded": false,
            "favoritesInitialized": true,
            "singleClickExpandTreeItems": true,
            "batchRenameSettings": {},
            "batchRenamePresets": []
          },
          "windows": [
            {"id": "window-1", "bounds": {"width": 900, "height": 600, "maximized": false, "x": 10, "y": 20},
             "session": {"treeWidth": 310, "propertiesOpen": true}},
            {"id": "window-2", "bounds": {"width": 1000, "height": 700, "maximized": true}, "session": {}}
          ],
          "lastClosedWindow": {"id": "window-0", "bounds": {"width": 800, "height": 500, "maximized": false}, "session": {}}
        }
        """

    // The store reads and rewrites a file like this; the meaning is the same after one pass and the text does not move
    // after the second.
    @Test func aFileWithEveryKeyReadsSanitizesAndWritesBackWithTheSameMeaning() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try Self.everyKey.write(toFile: path, atomically: true, encoding: .utf8)
            let first = Kit.store(path)
            let read = first.preferences()
            #expect(read.theme == .light)
            #expect(read.accent == "#34c759")
            #expect(read.openWithApplications.count == 1)
            #expect(first.explorerWindows().map(\.id) == ["window-1", "window-2"])
            #expect(first.lastClosedWindow()?.id == "window-0")

            // A change that touches nothing else makes the store write the whole file.
            first.update { $0.restoreSessionOnStartup = true }
            first.update { $0.restoreSessionOnStartup = false }
            first.update { $0.propertiesOpen = false }
            first.update { $0.propertiesOpen = true }
            first.flush()

            let second = Kit.store(path)
            #expect(second.preferences() == read)
            #expect(second.explorerWindows() == first.explorerWindows())
            #expect(second.lastClosedWindow() == first.lastClosedWindow())

            // Every key the file had is still there with the value it had.
            let original = try #require(Kit.json(Self.everyKey)["preferences"]?.object)
            let rewritten = try #require(Kit.readFile(path)["preferences"]?.object)
            for (key, value) in original where key != "batchRenameSettings" {
                #expect(rewritten[key] == value, "\(key)")
            }
            #expect(Set(rewritten.keys).isSuperset(of: Set(original.keys)))
            let windows = try #require(Kit.readFile(path)["windows"]?.array)
            #expect(
                windows.first?["bounds"]
                    == Kit.json(#"{"width": 900, "height": 600, "maximized": false, "x": 10, "y": 20}"#))
            #expect(windows.first?["session"]?["treeWidth"] == .number(310))

            // Writing again changes nothing in the text.
            let text = try String(contentsOfFile: path, encoding: .utf8)
            second.update { $0.propertiesOpen = false }
            second.update { $0.propertiesOpen = true }
            second.flush()
            #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        }
    }

    // System is written back as System, and a saved Blue as Blue: a color picked before System was the default is
    // not taken for it.
    @Test func theSystemAccentAndASavedBlueAreWrittenBackAsTheyWere() throws {
        for (saved, expected) in [("system", "system"), ("#007AFF", "#007aff"), ("teal", "system")] {
            try Kit.withFolder { folder in
                let path = Kit.statePath(folder)
                try #"{"preferences": {"accent": "\#(saved)"}}"#.write(toFile: path, atomically: true, encoding: .utf8)
                let store = Kit.store(path)
                #expect(store.preferences().accent == expected, "\(saved)")
                store.update { $0.propertiesOpen = !$0.propertiesOpen }
                store.flush()
                #expect(Kit.readFile(path)["preferences"]?["accent"] == .string(expected), "\(saved)")
                #expect(Kit.store(path).preferences().accent == expected, "\(saved)")
            }
        }
    }

    // The keys come out in a fixed order.
    @Test func writesKeysInAFixedOrder() throws {
        let state = try AppStateReader.read(data: Data(Self.everyKey.utf8), defaults: .defaults(theme: .auto))
        let text = try AppStateJSON.serialize(state)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "{")
        #expect(lines.dropFirst().first == "  \"preferences\": {")
        #expect(lines.dropFirst(2).first == "    \"theme\": \"light\",")
        let order = [
            "\"theme\"", "\"accent\"", "\"openTabs\"", "\"favorites\"", "\"batchRenamePresets\"",
        ]
        let positions = order.compactMap { key in text.range(of: "    \(key):")?.lowerBound }
        #expect(positions == positions.sorted())
        #expect(positions.count == order.count)
        #expect(
            text.contains(
                "\"bounds\": {\n        \"width\": 900,\n        \"height\": 600,\n        \"maximized\": false,\n        \"x\": 10,\n        \"y\": 20\n      }"
            ))
        #expect(text.hasSuffix("}\n"))
    }

    // A file a newer version wrote keeps that version's settings when this one saves over it: they are written back
    // as they were read, beside and among the preferences this version writes, never in place of one. A preference
    // this version retired goes at the next write.
    @Test func aNewerVersionsSettingsSurviveASaveByThisOne() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try """
            {
              "preferences": {
                "theme": "light",
                "laterViews": [{"id": "v1", "name": "Later", "keeps": {"panes": 2, "somethingNew": true}}],
                "workspaces": [{"id": "w", "name": "Old"}]
              },
              "laterFile": {"version": 3}
            }
            """.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            store.update { $0.foldersFirst = false }
            store.flush()
            let written = Kit.readFile(path)
            let preferences = try #require(written["preferences"]?.object)
            #expect(
                preferences["laterViews"]
                    == Kit.json(#"[{"id": "v1", "name": "Later", "keeps": {"panes": 2, "somethingNew": true}}]"#))
            #expect(preferences["workspaces"] == nil)
            #expect(preferences["theme"] == .string("light") && preferences["foldersFirst"] == .bool(false))
            #expect(written["laterFile"] == Kit.json(#"{"version": 3}"#))

            // Read and written again, they are still there, and the text doesn't change.
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let again = Kit.store(path)
            again.update { $0.foldersFirst = true }
            again.update { $0.foldersFirst = false }
            again.flush()
            #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        }
    }

    // What this version writes comes first; a newer version's settings follow, in the order of their names.
    @Test func aNewerVersionsSettingsAreWrittenAfterThisOnesOwn() throws {
        var state = try AppStateReader.read(data: Data(Self.everyKey.utf8), defaults: .defaults(theme: .auto))
        state.unknownPreferences = ["zLater": .bool(true), "aLater": .number(1), "theme": .string("not this")]
        state.unknown = ["laterFile": .string("x")]
        let text = try AppStateJSON.serialize(state)
        let preferences = try #require(Kit.json(text)["preferences"]?.object)
        // A setting this version writes is never replaced by one kept from the file.
        #expect(preferences["theme"] == .string("light"))
        let order = ["\"batchRenamePresets\"", "\"aLater\"", "\"zLater\""]
        let positions = order.compactMap { key in text.range(of: "    \(key):")?.lowerBound }
        #expect(positions.count == 3 && positions == positions.sorted())
        #expect(Kit.json(text)["laterFile"] == .string("x"))
    }

    // The tolerant reading: a file that is not JSON gives the defaults, and is replaced at the next write.
    @Test func aDamagedFileGivesTheDefaultsAndIsReplacedAtTheNextWrite() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            try "{ not json".write(toFile: path, atomically: true, encoding: .utf8)
            let failures = Failures()
            let store = AppStateStore(
                filePath: path, defaultTheme: .dark, timer: ManualTimer(), onReadError: { failures.add($0) })
            #expect(failures.all.count == 1)
            #expect(store.preferences() == .defaults(theme: .dark))
            store.update { $0.foldersFirst = false }
            store.flush()
            #expect(Kit.store(path).preferences().foldersFirst == false)
        }
    }

    @Test func theUserDataFolderIsNamedForTheBundleID() {
        let base = URL(fileURLWithPath: "/Users/demo/Library/Application Support")
        let userData = AppStatePaths.userDataDirectory(applicationSupport: base)
        #expect(userData.path == "/Users/demo/Library/Application Support/com.filetrail.native")
        #expect(AppStatePaths.appState(in: userData).lastPathComponent == "app-state.json")
        #expect(
            AppStatePaths.visitedFolders(besideAppState: AppStatePaths.appState(in: userData)).path
                == userData.path + "/visited-folders.json")
        #expect(AppStatePaths.appLog(in: userData).path == userData.path + "/logs/app.log")
    }
}
