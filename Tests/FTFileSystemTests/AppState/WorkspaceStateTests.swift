// Checks how the state file keeps the workspaces and the workspace each window came from
import FTFoundation
import Foundation
import Testing

@testable import FTFileSystem

struct WorkspaceStateTests {
    typealias Kit = StateTestKit

    @Test func aWindowKeepsItsWorkspaceThroughItsChangesAndBetweenLaunches() throws {
        try Kit.withFolder { folder in
            let path = Kit.statePath(folder)
            let store = Kit.store(path)
            let bounds = StoredWindowState(x: 10, y: 20, width: 900, height: 600, maximized: false)
            store.addExplorerWindow(id: "window-a", bounds: bounds, workspaceID: "workspace-1")
            store.addExplorerWindow(id: "window-b", bounds: bounds)
            #expect(store.explorerWindowWorkspace("window-a") == "workspace-1")
            #expect(store.explorerWindowWorkspace("window-b") == nil)
            #expect(store.explorerWindowWorkspace("window-gone") == nil)

            // Moved, and its tabs changed: still the workspace's.
            store.setExplorerWindowBounds("window-a", StoredWindowState(width: 1000, height: 700, maximized: false))
            store.updateWindow("window-a") { $0.treeWidth = 333 }
            #expect(store.explorerWindowWorkspace("window-a") == "workspace-1")
            store.setExplorerWindowWorkspace("window-b", "workspace-2")
            store.flush()

            let saved = Kit.json(try String(contentsOfFile: path, encoding: .utf8))
            let windows = saved["windows"]?.array ?? []
            #expect(windows.compactMap { $0["workspaceID"]?.string } == ["workspace-2", "workspace-1"])
            let reopened = Kit.store(path)
            #expect(reopened.explorerWindowWorkspace("window-a") == "workspace-1")
            #expect(reopened.explorerWindowWorkspace("window-b") == "workspace-2")

            // Closed, it is no window of the workspace: the next window opened with none open starts from it as any.
            reopened.rememberClosedWindow("window-a")
            #expect(reopened.lastClosedWindow()?.workspaceID == nil)
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
