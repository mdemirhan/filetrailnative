// Checks how the state file keeps the workspaces
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct WorkspaceStateTests {
    typealias Kit = StateTestKit

    @Test func aWindowsWorkspaceFromAnOlderFileIsDroppedWhenItIsWrittenAgain() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            // Windows were once linked to the workspace they came from.
            try #"""
            {"preferences": {}, "windows": [
              {"id": "window-a", "bounds": {"width": 900, "height": 600, "maximized": false},
               "workspaceID": "workspace-1", "session": {}}
            ]}
            """#.write(toFile: path, atomically: true, encoding: .utf8)
            let store = Kit.store(path)
            #expect(store.explorerWindows().map(\.id) == ["window-a"])
            store.setExplorerWindowBounds("window-a", StoredWindowState(width: 1000, height: 700, maximized: false))
            store.flush()
            let windows = Kit.json(try String(contentsOfFile: path, encoding: .utf8))["windows"]?.array ?? []
            #expect(windows.map { $0["id"]?.string } == ["window-a"])
            #expect(windows.allSatisfy { $0["workspaceID"] == nil })
        }
    }

    @Test func workspacesAreKeptWithThePreferencesAndWrittenAtOnce() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            let timer = ManualTimer()
            let store = Kit.store(path, timer: timer)
            var session = store.createWindowSession()
            session.openTabs = [
                OpenTabPreference(
                    path: "/Users/demo/Pictures", treeRootPath: nil, favoritePath: nil, viewMode: .icons,
                    searchViewMode: .details, sortBy: .name, sortDirection: .asc, includeHidden: false,
                    foldersFirst: true, favoritesExpanded: true, locationsExpanded: true)
            ]
            let workspace = Workspace(
                id: "workspace-1", name: "Photos",
                bounds: StoredWindowState(x: 5, y: 5, width: 900, height: 600, maximized: false), session: session)
            store.update { $0.workspaces = [workspace] }
            // Saving one is a choice made on purpose: written soon, not with the windows' places.
            #expect(timer.pendingDelays == [AppStateStore.promptSaveDelayMilliseconds])
            timer.run()

            let text = try String(contentsOfFile: path, encoding: .utf8)
            let saved = Kit.json(text)["preferences"]?["workspaces"]?.array?.first
            #expect(saved?["name"] == .string("Photos"))
            #expect(saved?["bounds"]?["x"] == nil)
            #expect(text.contains("\"id\": \"workspace-1\",\n        \"name\": \"Photos\",\n        \"bounds\""))
            #expect(Kit.store(path).preferences().workspaces.map(\.name) == ["Photos"])
        }
    }
}
