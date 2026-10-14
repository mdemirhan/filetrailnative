// No TypeScript source: a file in the Electron app's shape is read, sanitized and written back with the same meaning
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct AppStateRoundTripTests {
    typealias Kit = StateTestKit

    /// A hand-made `app-state.json` with a value for every preference key, two windows and a window closed last, as the
    /// Electron app writes one.
    static let everyKey = """
        {
          "preferences": {
            "theme": "light",
            "accent": "#34c759",
            "zoomPercent": 110,
            "viewMode": "details",
            "searchViewMode": "list",
            "sortBy": "modified",
            "sortDirection": "desc",
            "foldersFirst": false,
            "compactListView": true,
            "compactDetailsView": true,
            "compactIconView": true,
            "compactTreeView": true,
            "detailColumns": {"modified": true, "size": false, "kind": true, "created": true, "permissions": true},
            "detailColumnOrder": ["size", "modified", "kind", "created", "permissions"],
            "detailColumnWidths": {"name": 400, "modified": 160, "size": 120, "kind": 150, "created": 170, "permissions": 110},
            "searchColumns": {"folder": true, "modified": false, "size": true, "kind": true, "created": false, "permissions": false},
            "searchColumnOrder": ["modified", "folder", "size", "kind", "created", "permissions"],
            "searchColumnWidths": {"name": 310, "folder": 250, "modified": 150, "size": 110, "kind": 140, "created": 150, "permissions": 100},
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
            "fileActivationAction": "edit",
            "diskImageOpensIn": "tab",
            "returnKeyAction": "open",
            "shortcutOverrides": {},
            "openItemLimit": 12,
            "includeHidden": true,
            "searchPatternMode": "glob",
            "searchMatchScope": "path",
            "searchRecursive": false,
            "searchSkipGitFolders": false,
            "searchSkipGitIgnored": true,
            "searchResultsSortBy": "kind",
            "searchResultsSortDirection": "desc",
            "treeWidth": 300,
            "inspectorWidth": 350,
            "restoreSessionOnStartup": false,
            "openTabs": [
              {"path": "/Users/demo/work", "treeRootPath": "/Users/demo", "favoritePath": null, "viewMode": "list",
               "searchViewMode": "details", "sortBy": "name", "sortDirection": "asc", "includeHidden": false,
               "foldersFirst": true, "favoritesExpanded": true, "locationsExpanded": false}
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

    // The reference writes a file this way, and the store reads and rewrites it; the meaning is the same after one pass
    // and the text does not move after the second.
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
            first.updatePreferences(["restoreSessionOnStartup": .bool(true)])
            first.updatePreferences(["restoreSessionOnStartup": .bool(false)])
            first.updatePreferences(["propertiesOpen": .bool(false)])
            first.updatePreferences(["propertiesOpen": .bool(true)])
            first.flush()

            let second = Kit.store(path)
            #expect(second.preferences() == read)
            #expect(second.explorerWindows() == first.explorerWindows())
            #expect(second.lastClosedWindow() == first.lastClosedWindow())

            // Every key the reference wrote is still there with the value it had.
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
            second.updatePreferences(["propertiesOpen": .bool(false)])
            second.updatePreferences(["propertiesOpen": .bool(true)])
            second.flush()
            #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        }
    }

    // The keys come out in the order the original's object literals give them.
    @Test func writesKeysInTheOriginalsOrder() throws {
        let state = try AppStateReader.read(data: Data(Self.everyKey.utf8), defaults: .defaults(theme: .auto))
        let text = try AppStateJSON.serialize(state)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "{")
        #expect(lines.dropFirst().first == "  \"preferences\": {")
        #expect(lines.dropFirst(2).first == "    \"theme\": \"light\",")
        let order = [
            "\"theme\"", "\"accent\"", "\"zoomPercent\"", "\"openTabs\"", "\"favorites\"", "\"batchRenamePresets\"",
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
            store.updatePreferences(["foldersFirst": .bool(false)])
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
