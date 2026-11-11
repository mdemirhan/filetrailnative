import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

/// The typed changes against the patches they replace: the same steps, sent both ways to two stores, leave the same
/// preferences, windows, timers and files.
struct TypedUpdateEquivalenceTests {
    typealias Kit = StateTestKit

    static let allDifferent = PreferencesSanitizer.sanitize(
        Kit.json(
            """
            {"theme": "light", "accent": "#2cb5a0", "viewMode": "details", "searchViewMode": "list",
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
            """), defaults: .defaults())

    /// Values the file's reader would not keep as they are: past a limit, not normalized, empty or repeated.
    static let unchecked: AppPreferences = {
        var preferences = AppPreferences.defaults(theme: .light)
        preferences.accent = " #ABCDEF "
        preferences.treeWidth = 5000
        preferences.inspectorWidth = 1
        preferences.openItemLimit = 999
        preferences.activeTabIndex = -3
        preferences.lastVisitedPath = ""
        preferences.treeRootPath = ""
        preferences.detailColumnWidths.name = 9999
        preferences.detailColumnWidths.size = 1
        preferences.searchColumnWidths.folder = 5
        preferences.detailColumnOrder = [.kind, .kind, .size]
        preferences.topToolbarItems = [.back, .back, .search]
        preferences.shortcutOverrides = ["newTab": ["option+cmd+n", "Cmd+C", "D"], "noSuchCommand": ["Cmd+J"]]
        preferences.terminalApp = ApplicationSelection(appPath: "   ", appName: "iTerm")
        preferences.defaultTextEditor = ApplicationSelection(appPath: "", appName: "")
        preferences.openWithApplications = [
            OpenWithApplication(id: " zed ", appPath: " /Applications/Zed.app ", appName: " Zed "),
            OpenWithApplication(id: "", appPath: "/Applications/Bad.app", appName: "Bad"),
        ]
        preferences.openTabs = Array(
            repeating: OpenTabPreference(
                path: "", treeRootPath: "/Users/demo", favoritePath: nil, viewMode: .list, searchViewMode: .icons,
                sortBy: .size, sortDirection: .desc, includeHidden: true, foldersFirst: false,
                favoritesExpanded: false, locationsExpanded: true),
            count: 30)
        preferences.favorites = [
            FavoritePreference(path: " /Users/demo ", icon: .home),
            FavoritePreference(path: "/Users/demo", icon: .star),
            FavoritePreference(path: "  ", icon: .star),
        ]
        preferences.batchRenameSettings.startAt = -5
        preferences.batchRenameSettings.find = String(repeating: "x", count: 300)
        preferences.batchRenamePresets = [
            BatchRenamePreset(name: String(repeating: "n", count: 100), settings: .defaults),
            BatchRenamePreset(name: "  ", settings: .defaults),
            BatchRenamePreset(name: "Photos", settings: .defaults),
            BatchRenamePreset(name: "photos", settings: .defaults),
        ]
        return preferences
    }()

    struct Side {
        let store: AppStateStore
        let path: String
        let timer = ManualTimer()
        let files = RecordingFileSystem()

        init(_ folder: String) {
            path = Kit.statePath(folder)
            store = Kit.store(path, fileSystem: files, timer: timer)
        }
    }

    @Test func typedChangesDoWhatTheirPatchesDid() throws {
        try Kit.withFolder { oldFolder in
            try Kit.withFolder { newFolder in
                let old = Side(oldFolder)
                let new = Side(newFolder)
                for side in [old, new] {
                    for id in ["window-b", "window-a"] {
                        side.store.addExplorerWindow(
                            id: id, bounds: Kit.bounds, session: side.store.createWindowSession())
                    }
                }
                var rng = AppStateStoreTests.SeededGenerator(seed: 7)
                let targets: [String?] = [nil, "window-a", "window-b", "window-gone"]
                for step in 0..<1500 {
                    let target = rng.pick(targets)
                    let count = 1 + Int(rng.next() % 3)
                    var keys: [PreferenceKey] = []
                    for _ in 0..<count {
                        let key = rng.pick(PreferenceKey.allCases)
                        if !keys.contains(key) { keys.append(key) }
                    }
                    let seen = target.map { new.store.windowPreferences($0) } ?? new.store.preferences()
                    let source = rng.pick([AppPreferences.defaults(), Self.allDifferent, Self.unchecked, seen])
                    let patch = Dictionary(uniqueKeysWithValues: keys.map { ($0.rawValue, source.node($0)) })
                    let change: (inout EditedPreferences) -> Void = { edited in
                        for key in keys { edited.take(key, from: source) }
                    }
                    let before = old.store.preferences()
                    let oldResult =
                        target.map { old.store.updateWindowPreferences($0, patch) }
                        ?? old.store.updatePreferences(patch)
                    let newResult =
                        target.map { new.store.updateWindow($0, change) } ?? new.store.update(change)
                    let context = "step \(step): \(target ?? "app") \(keys) from \(before.keys(differingFrom: source))"
                    #expect(newResult == oldResult, "\(context)")
                    #expect(new.store.preferences() == old.store.preferences(), "\(context)")
                    #expect(new.store.explorerWindows() == old.store.explorerWindows(), "\(context)")
                    #expect(new.timer.pendingDelays == old.timer.pendingDelays, "\(context)")
                    if rng.chance(0.1) {
                        old.timer.run()
                        new.timer.run()
                        #expect(new.files.written == old.files.written, "\(context)")
                        #expect(
                            (try? String(contentsOfFile: new.path, encoding: .utf8))
                                == (try? String(contentsOfFile: old.path, encoding: .utf8)), "\(context)")
                    }
                }
                old.store.flush()
                new.store.flush()
                #expect(new.files.written == old.files.written)
                let newText = try String(contentsOfFile: new.path, encoding: .utf8)
                let oldText = try String(contentsOfFile: old.path, encoding: .utf8)
                #expect(newText == oldText)
            }
        }
    }

    @Test func aNewWindowsSessionIsTheOneItsPatchMade() throws {
        try Kit.withFolder { folder in
            let store = Kit.store(Kit.statePath(folder))
            for source in [AppPreferences.defaults(), Self.allDifferent, Self.unchecked] {
                let patch = (try? JSONNode.of(source.windowSession))?.object ?? [:]
                #expect(
                    store.createWindowSession { $0 = source.windowSession }
                        == store.createWindowSession(overrides: patch))
            }
            #expect(store.createWindowSession() == store.createWindowSession(overrides: [:]))
        }
    }
}
